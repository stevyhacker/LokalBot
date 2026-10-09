import { build } from "esbuild";
import { cp, mkdir, readFile, writeFile, rm, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const dist = path.join(root, "dist");
await mkdir(dist, { recursive: true });
const [app, template, styles] = await Promise.all([
  build({ absWorkingDir: root, entryPoints: ["src/app/index.ts"], bundle: true, format: "esm", platform: "browser", target: "es2022", minify: true, write: false, metafile: true }),
  readFile(path.join(root, "src/app/index.html"), "utf8"),
  readFile(path.join(root, "node_modules/@openai/mcp-extensions/styles.css"), "utf8"),
]);
const script = app.outputFiles[0].text.replace(/<\/script/gi, "<\\/script");
const html = template.replace("/* HOST_STYLES */", () => styles)
  .replace("<!-- APP_SCRIPT -->", () => `<script type="module">${script}</script>`);
await writeFile(path.join(dist, "app.html"), html);
const server = await build({
  absWorkingDir: root, entryPoints: ["src/index.ts"], outfile: "dist/server.js",
  bundle: true, platform: "node", format: "esm", target: "node22", metafile: true,
  banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
});
const device = await build({
  absWorkingDir: root, entryPoints: ["src/device.ts"], outfile: "dist/device.js",
  bundle: true, platform: "node", format: "esm", target: "node22", external: ["bufferutil", "utf-8-validate"], metafile: true,
  banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
});
const relay = await build({
  absWorkingDir: root, entryPoints: ["src/relay/index.ts"], outfile: "dist/relay.js",
  bundle: true, platform: "browser", format: "esm", target: "es2022", external: ["cloudflare:workers"], metafile: true,
});

const packages = new Set();
for (const result of [app, server, device, relay]) {
  for (const input of Object.keys(result.metafile.inputs)) {
    const packagePath = /(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(input)?.[1];
    if (packagePath) packages.add(path.resolve(root, packagePath));
  }
}
const notices = [];
for (const folder of [...packages].sort()) {
  const metadata = JSON.parse(await readFile(path.join(folder, "package.json"), "utf8"));
  const names = (await readdir(folder)).filter(name => /^(?:licen[sc]e|copying|notice)(?:[.-]|$)/i.test(name));
  // This npm tarball omits its license; keep the notice from its published gitHead.
  if (metadata.name === "@cfworker/json-schema" && metadata.version === "4.1.1") {
    notices.push(`${metadata.name} ${metadata.version}\n${await readFile(path.join(root, "third_party/cfworker-json-schema-LICENSE.txt"), "utf8")}`);
    continue;
  }
  if (!names.length) throw new Error(`Missing bundled license notice for ${metadata.name}`);
  notices.push(`${metadata.name} ${metadata.version}\n${(await Promise.all(names.map(name => readFile(path.join(folder, name), "utf8")))).join("\n")}`);
}
await writeFile(path.join(dist, "THIRD_PARTY_NOTICES.txt"), notices.join("\n\n---\n\n"));

// A separate, self-contained install folder avoids copying node_modules or test fixtures.
const install = path.join(dist, "companion");
await rm(install, { recursive: true, force: true });
await mkdir(path.join(install, "dist"), { recursive: true });
for (const name of ["assets"]) {
  await cp(path.join(root, name), path.join(install, name), { recursive: true });
}
for (const name of ["server.js", "device.js", "app.html"]) await cp(path.join(dist, name), path.join(install, "dist", name));
await writeFile(path.join(install, "package.json"), JSON.stringify({ private: true, type: "module", engines: { node: ">=22.12" } }, null, 2) + "\n");
await cp(path.join(dist, "THIRD_PARTY_NOTICES.txt"), path.join(install, "THIRD_PARTY_NOTICES.txt"));
await cp(path.join(root, "../../LICENSE"), path.join(install, "LICENSE"));
await cp(path.join(root, "docs/CONNECT.md"), path.join(install, "README.md"));
const local = path.join(dist, "local-plugin");
await rm(local, { recursive: true, force: true });
await cp(install, local, { recursive: true });
for (const name of ["plugin.json", "skills"]) await cp(path.join(root, name), path.join(local, name), { recursive: true });
await writeFile(path.join(local, "mcp.json"), JSON.stringify({
  $schema: "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
  mcpServers: { lokalbot: { type: "stdio", command: "node", args: ["./dist/server.js"], cwd: "." } },
}, null, 2) + "\n");
console.log("Built dist/companion, dist/local-plugin, and dist/relay.js. Public packaging needs a verified deployed origin.");
