import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { packagePreview } from "../scripts/package-preview.mjs";

test("preview launcher selects its bundled CLI even from a path containing spaces", async t => {
  const root = await mkdtemp(path.join(tmpdir(), "lokalbot-preview-"));
  t.after(() => rm(root, { force: true, recursive: true }));
  const companion = path.join(root, "companion");
  await mkdir(path.join(companion, "dist"), { recursive: true });
  await writeFile(path.join(companion, "dist/device.js"), 'console.log(JSON.stringify({ cli: process.env.LOKALBOT_CLI_PATH, args: process.argv.slice(2) }));');
  const cli = path.join(root, "native"); const license = path.join(root, "LICENSE");
  await writeFile(cli, "synthetic executable"); await writeFile(license, "synthetic license");
  const commit = "a".repeat(40);
  const output = await packagePreview({ cli, license, companion, output: path.join(root, "preview with spaces"), version: "0.1.0-preview.1", commit });
  const env = { PATH: process.env.PATH };
  const result = JSON.parse(execFileSync(path.join(output, "lokalbot-connect"), ["run", "--config", "/synthetic path/device.json"], { env, encoding: "utf8" }));
  assert.equal(result.cli, path.join(output, "bin/lokalbot-cli"));
  assert.deepEqual(result.args, ["run", "--config", "/synthetic path/device.json"]);
  assert.equal(JSON.parse(await readFile(path.join(output, "SOURCE.json"), "utf8")).commit, commit);
  assert.equal(await readFile(path.join(output, "swift-argument-parser-LICENSE.txt"), "utf8"), "synthetic license");
  await assert.rejects(packagePreview({ cli, license, version: "0.1.0", commit }), /preview version/);
});
