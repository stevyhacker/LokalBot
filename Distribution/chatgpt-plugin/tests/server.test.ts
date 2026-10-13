import assert from "node:assert/strict";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { CallToolResultSchema, type CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { createPlugin, meetingURI, resultText, UI_URI } from "../src/server.js";
import { cliEnvironment, type LibraryBackend, type LibraryTool } from "../src/backend.js";

const UUID = "aaaaaaaa-1111-4222-8333-444444444444";
class Library implements LibraryBackend {
  enabled = true;
  broken = false;
  calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  async close() {}
  async call(name: LibraryTool, args: Record<string, unknown>): Promise<CallToolResult> {
    this.calls.push({ name, args });
    if (this.broken) throw new Error("/Users/private/library must never leak");
    if (!this.enabled) return { isError: true, content: [{ type: "text", text: "[access_disabled] off" }] };
    const data = name === "list_meetings" ? [{ id: "aaaaaaaa", uuid: UUID, title: "Cache planning", date: "2026-10-09T10:00:00Z", duration_seconds: 1200, has_summary: true }] : [];
    return { content: [{ type: "text", text: name === "get_meeting" ? `# Cache planning\n**Date:** October 9, 2026\n## Summary\nWe chose Redis.${String(args.include).includes("transcript") ? "\n## Transcript\n[00:00:02] Transcript excerpt" : ""}` : JSON.stringify(data) }] };
  }
}
async function session() {
  const backend = new Library();
  const server = createPlugin(backend, "<!doctype html><title>Synthetic panel</title>", "<svg/>");
  const client = new Client({ name: "test", version: "1" });
  const [front, back] = InMemoryTransport.createLinkedPair();
  await server.connect(back); await client.connect(front);
  return { backend, client, close: async () => { await client.close(); await server.close(); } };
}
async function call(client: Client, name: string, args: Record<string, unknown> = {}) {
  return CallToolResultSchema.parse(await client.callTool({ name, arguments: args }));
}

test("discovery advertises the panel, app-only mentions, and only read-only meeting tools", async t => {
  const s = await session(); t.after(s.close);
  s.backend.enabled = false;
  const { tools } = await s.client.listTools();
  assert.deepEqual(tools.map(tool => tool.name).sort(), ["open_library", "list_meetings", "search_meetings", "get_meeting", "get_action_items", "list_people", "get_person", "search_mentions"].sort());
  for (const tool of tools) assert.deepEqual(tool.annotations, { readOnlyHint: true, destructiveHint: false, openWorldHint: false });
  assert.deepEqual(tools.find(tool => tool.name === "open_library")?._meta?.["openai/ui"], { entrypoints: [{ type: "global" }, { type: "thread" }] });
  assert.deepEqual(tools.find(tool => tool.name === "search_mentions")?._meta?.ui, { visibility: ["app"] });
  assert.equal(s.backend.calls.length, 0, "handshake/discovery must not scan a private library");
  const { resources } = await s.client.listResources();
  assert.equal(resources.length, 1); assert.equal(resources[0]!.uri, UI_URI);
});
test("summary-first retrieval opts into bounded transcripts explicitly", async t => {
  const s = await session(); t.after(s.close);
  const summary = await call(s.client, "get_meeting", { id: UUID });
  assert.equal(summary.isError, undefined);
  assert(!resultText(summary).includes("Transcript"));
  assert.deepEqual(s.backend.calls.at(-1)?.args, { id: UUID, include: "metadata,summary" });
  await call(s.client, "get_meeting", { id: UUID, include_transcript: true, transcript_from: "00:14:00", max_characters: 2000 });
  assert.deepEqual(s.backend.calls.at(-1)?.args, { id: UUID, include: "metadata,summary,transcript", transcript_from: "00:14:00", max_characters: 2000 });
  const before = s.backend.calls.length;
  const oversized = await call(s.client, "get_meeting", { id: UUID, include_transcript: true, max_characters: 20001 });
  assert(oversized.isError); assert.equal(s.backend.calls.length, before);
});
test("mention references are stable, resolve across sessions, and recheck revocation", async t => {
  const s = await session(); t.after(s.close);
  const mentions = await call(s.client, "search_mentions", { query: "Cache" });
  const items = mentions.structuredContent?.items as Array<{ uri: string }>;
  assert.equal(items[0]?.uri, meetingURI(UUID));
  const fresh = await session(); t.after(fresh.close);
  assert((await fresh.client.readResource({ uri: items[0]!.uri })).contents.length);
  fresh.backend.enabled = false;
  await assert.rejects(fresh.client.readResource({ uri: items[0]!.uri }), /access_disabled/);
  assert((await call(fresh.client, "search_mentions", { query: "Cache" })).isError);
  assert((await call(fresh.client, "open_library")).isError);
});
test("untrusted resource paths, unknown tools, and extra arguments never reach the helper", async t => {
  const s = await session(); t.after(s.close);
  for (const uri of ["file:///etc/passwd", "lokalbot://meetings/..%2F..%2Fprivate", `${meetingURI(UUID)}?include=transcript`]) {
    await assert.rejects(s.client.readResource({ uri }));
  }
  assert((await call(s.client, "get_meeting", { id: "latest" })).isError);
  assert((await call(s.client, "get_meeting", { id: UUID, path: "/private" })).isError);
  assert((await call(s.client, "search_screen", { query: "secret" })).isError);
  assert.equal(s.backend.calls.length, 0);
});
test("backend failures do not disclose filesystem diagnostics or cached content", async t => {
  const s = await session(); t.after(s.close);
  await call(s.client, "open_library");
  s.backend.broken = true;
  const result = await call(s.client, "open_library");
  assert(result.isError); assert(!resultText(result).includes("/Users"));
  assert.equal(result.structuredContent, undefined);
});
test("CLI environment excludes Agent Mode capabilities and cloud credentials", () => {
  assert.deepEqual(cliEnvironment({ HOME: "/fixture", PATH: "/bin", LOKALBOT_STORAGE_ROOT: "/synthetic", LOKALBOT_AGENT_CAPABILITY: "private", OPENAI_API_KEY: "private", CONTROL_PLANE_API_KEY: "private", NODE_OPTIONS: "--inspect" }), {
    HOME: "/fixture", PATH: "/bin", LOKALBOT_STORAGE_ROOT: "/synthetic",
  });
});
