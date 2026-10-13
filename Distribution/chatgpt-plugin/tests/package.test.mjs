import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { packagePublic, publicOrigin, verifyRelay } from "../scripts/package-public.mjs";

const origin = "https://synthetic-relay.lokalbot.com";
const probe = async url => {
  if (url.endsWith("/health")) return Response.json({ service: "lokalbot-mcp-relay", status: "ok" });
  if (url.includes("/.well-known/")) return Response.json({ resource: `${origin}/mcp`, authorization_servers: [origin] });
  return new Response(null, { status: 401, headers: { "WWW-Authenticate": 'Bearer scope="meetings:read"' } });
};
test("public packaging requires a live authenticated relay and excludes local executables", async t => {
  for (const bad of ["http://relay.lokalbot.com", "https://localhost", "https://127.0.0.1", "https://configure-before-deploy.invalid", `${origin}/mcp`, `${origin}?secret=x`]) assert.throws(() => publicOrigin(bad));
  await assert.rejects(verifyRelay(origin, async () => new Response(null, { status: 503 })), /probe failed/);
  await assert.rejects(verifyRelay(origin, async url => url.endsWith("/mcp") && !url.includes(".well-known") ? new Response(null) : probe(url)), /require OAuth/);
  const root = await mkdtemp(path.join(tmpdir(), "lokalbot-public-package-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const output = path.join(root, "plugin");
  await packagePublic(origin, undefined, probe, output);
  const files = await readdir(output);
  assert.deepEqual(files.sort(), ["LICENSE", "README.md", "assets", "mcp.json", "plugin.json", "skills"].sort());
  const config = JSON.parse(await readFile(path.join(output, "mcp.json"), "utf8"));
  assert.deepEqual(config.mcpServers.lokalbot, { type: "streamable-http", url: `${origin}/mcp` });
  await packagePublic(origin, "plugin_asdk_app_synthetic", probe, output);
  const mapping = JSON.parse(await readFile(path.join(output, ".app.json"), "utf8"));
  assert.equal(mapping.apps.lokalbot.id, "asdk_app_synthetic");
  assert(!(await readdir(output)).includes("mcp.json"));
});
