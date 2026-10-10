import { chmod, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { parseArgs } from "node:util";

export async function packagePreview({ cli, license, version, commit, output, companion }) {
  if (!/^\d+\.\d+\.\d+-preview\.\d+$/.test(version) || !/^[a-f0-9]{40}$/.test(commit)) throw new Error("A preview version and full source commit are required.");
  const root = fileURLToPath(new URL("../", import.meta.url));
  const destination = output ?? path.join(root, "dist/preview/LokalBot-ChatGPT");
  const nativeLicense = await readFile(license, "utf8");
  await rm(destination, { recursive: true, force: true });
  await cp(companion ?? path.join(root, "dist/companion"), destination, { recursive: true });
  await mkdir(path.join(destination, "bin"));
  await cp(cli, path.join(destination, "bin/lokalbot-cli"));
  await chmod(path.join(destination, "bin/lokalbot-cli"), 0o755);
  await writeFile(path.join(destination, "lokalbot-connect"), `#!/bin/sh
set -eu
PREVIEW_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LOKALBOT_CLI_PATH="\${LOKALBOT_CLI_PATH:-$PREVIEW_ROOT/bin/lokalbot-cli}"
exec node "$PREVIEW_ROOT/dist/device.js" "$@"
`, { mode: 0o755 });
  await writeFile(path.join(destination, "swift-argument-parser-LICENSE.txt"), nativeLicense);
  await cp(path.join(root, "docs/PREVIEW.md"), path.join(destination, "README.md"));
  await writeFile(path.join(destination, "SOURCE.json"), JSON.stringify({ version, commit,
    source: `https://github.com/stevyhacker/LokalBot/tree/${commit}/Distribution/chatgpt-plugin`,
    nativeSource: `https://github.com/stevyhacker/LokalBot/tree/${commit}/CLI`,
    relay: "https://mcp.lokalbot.com", platform: "macOS 15+, Apple Silicon", node: ">=22.12",
  }, null, 2) + "\n");
  return destination;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: { version: { type: "string" } } });
  const root = fileURLToPath(new URL("../", import.meta.url));
  const result = await packagePreview({
    version: values.version, commit: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
    cli: path.join(root, ".test-cli/DerivedData/Build/Products/Release/lokalbot-cli"),
    license: path.join(root, ".test-cli/DerivedData/SourcePackages/checkouts/swift-argument-parser/LICENSE.txt"),
  });
  console.log(`Preview staged at ${result}. Signing and notarization are separate release steps.`);
}
