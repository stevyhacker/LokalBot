import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js";

test("packaged server delegates to the real CLI using only an isolated synthetic library", { skip: !process.env.LOKALBOT_TEST_CLI, timeout: 15_000 }, async t => {
  const root = await mkdtemp(path.join(tmpdir(), "lokalbot-plugin-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const relativePath = "meetings/2026/10/09-synthetic";
  const folder = path.join(root, relativePath);
  await mkdir(folder, { recursive: true }); await mkdir(path.join(root, "control"));
  const id = "aaaaaaaa-1111-4222-8333-444444444444";
  await writeFile(path.join(folder, "meta.json"), JSON.stringify({ id, relativePath, title: "Synthetic Redis plan", appName: "Fixture", hasSystemTrack: false, startedAt: "2026-10-09T10:00:00Z", endedAt: "2026-10-09T10:20:00Z" }));
  await writeFile(path.join(folder, "summary.md"), "We chose Redis in this synthetic meeting.");
  await writeFile(path.join(folder, "transcript.json"), JSON.stringify({ engine: "fixture", segments: [{ start: 2, end: 8, speaker: "me", text: "Synthetic transcript-only fact." }] }));
  const client = new Client({ name: "isolated-integration", version: "1" });
  t.after(() => client.close());
  await client.connect(new StdioClientTransport({
    command: process.execPath, args: [path.resolve("dist/companion/dist/server.js")], stderr: "ignore",
    env: { PATH: process.env.PATH!, LOKALBOT_CLI_PATH: process.env.LOKALBOT_TEST_CLI!, LOKALBOT_STORAGE_ROOT: root, LOKALBOT_AGENT_CAPABILITY: "must-not-bypass" },
  }), { timeout: 8_000 });
  const call = async (name: string, args = {}) => CallToolResultSchema.parse(await client.callTool({ name, arguments: args }));
  assert((await call("list_meetings")).isError);
  const marker = path.join(root, "control/agent-access-enabled");
  await writeFile(marker, "synthetic-test-grant", { mode: 0o600 });
  const list = await call("list_meetings");
  assert(!list.isError); assert(JSON.stringify(list).includes("Synthetic Redis plan"));
  const summary = await call("get_meeting", { id });
  assert(JSON.stringify(summary).includes("We chose Redis"));
  assert(!JSON.stringify(summary).includes("transcript-only"));
  const transcript = await call("get_meeting", { id, include_transcript: true });
  assert(JSON.stringify(transcript).includes("transcript-only"));
  await unlink(marker);
  assert((await call("get_meeting", { id })).isError);
  await assert.rejects(client.readResource({ uri: `lokalbot://meetings/${id}` }), /access_disabled/);
});
