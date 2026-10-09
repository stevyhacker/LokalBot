import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export function publicOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash ||
      /(?:^|\.)(?:localhost|invalid|test|example)$/.test(url.hostname) || /^(?:\[|\d+\.)/.test(url.hostname)) {
    throw new Error("Supply the deployed public HTTPS origin, without a path, credentials, query, or fragment.");
  }
  return url.origin;
}

export async function verifyRelay(origin, fetcher = fetch) {
  const get = async route => {
    const response = await fetcher(`${origin}${route}`, { redirect: "error", signal: AbortSignal.timeout(10_000) });
    if (!response.ok) throw new Error(`Relay probe failed: ${route} (${response.status})`);
    return response.json();
  };
  const health = await get("/health");
  if (health.service !== "lokalbot-mcp-relay" || health.status !== "ok") throw new Error("Not a healthy LokalBot relay.");
  const metadata = await get("/.well-known/oauth-protected-resource/mcp");
  if (metadata.resource !== `${origin}/mcp` || !metadata.authorization_servers?.includes(origin)) throw new Error("OAuth resource does not match the deployment origin.");
  const challenge = await fetcher(`${origin}/mcp`, { method: "POST", redirect: "error", signal: AbortSignal.timeout(10_000) });
  if (challenge.status !== 401 || !challenge.headers.get("www-authenticate")?.includes("meetings:read")) throw new Error("Public MCP must require OAuth with meetings:read.");
}

export async function packagePublic(origin, appId, fetcher = fetch, outputRoot) {
  origin = publicOrigin(origin);
  if (appId && !/^(?:plugin_)?asdk_app_[a-zA-Z0-9-]+$/.test(appId)) throw new Error("Use the actual plugin_asdk_app ID from ChatGPT registration.");
  await verifyRelay(origin, fetcher);
  const root = fileURLToPath(new URL("../", import.meta.url));
  const output = outputRoot ?? path.join(root, "dist/public-plugin");
  await rm(output, { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  for (const name of ["assets", "skills"]) await cp(path.join(root, name), path.join(output, name), { recursive: true });
  await cp(path.join(root, "../../LICENSE"), path.join(output, "LICENSE"));
  await cp(path.join(root, "docs/CONNECT.md"), path.join(output, "README.md"));
  const manifest = JSON.parse(await readFile(path.join(root, "plugin.json"), "utf8"));
  if (appId) {
    manifest.extensions["com.openai"].apps = "./.app.json";
    await writeFile(path.join(output, ".app.json"), JSON.stringify({ apps: { lokalbot: { id: appId.replace(/^plugin_/, "") } } }, null, 2) + "\n");
  } else {
    const config = JSON.parse(await readFile(path.join(root, "mcp.json"), "utf8"));
    config.mcpServers.lokalbot.url = `${origin}/mcp`;
    await writeFile(path.join(output, "mcp.json"), JSON.stringify(config, null, 2) + "\n");
  }
  await writeFile(path.join(output, "plugin.json"), JSON.stringify(manifest, null, 2) + "\n");
  return output;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { origin: { type: "string" }, "app-id": { type: "string" } } });
    if (!values.origin) throw new Error("Usage: npm run package:public -- --origin https://DEPLOYED_ORIGIN [--app-id REGISTERED_ID]");
    const output = await packagePublic(values.origin, values["app-id"]);
    console.log(`Public package: ${output}. Relay discovery verified; this does not submit or publish it.`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
