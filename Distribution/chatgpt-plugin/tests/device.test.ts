import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, writeFile, rm, chmod, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { once } from "node:events";
import { WebSocketServer, WebSocket } from "ws";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createPlugin } from "../src/server.js";
import { readConfig, relayOrigin, serveConnection } from "../src/device.js";

test("credentials cannot be sent to cleartext or ambiguous relay origins", () => {
  assert.equal(relayOrigin("https://plugin.example/"), "https://plugin.example");
  for (const invalid of ["http://plugin.example", "https://user:password@plugin.example", "https://plugin.example/path", "https://plugin.example?token=secret"]) assert.throws(() => relayOrigin(invalid));
});

test("companion forwards protocol requests through the real adapter and cancels disconnected work", { timeout: 10_000 }, async t => {
  let aborted = false;
  let held = false;
  const backend = {
    async call(_name: string, args: Record<string, unknown>, signal?: AbortSignal) {
      if (args.query === "hold") {
        held = true;
        await new Promise<void>(resolve => signal!.addEventListener("abort", () => { aborted = true; resolve(); }, { once: true }));
      }
      return { content: [{ type: "text" as const, text: "[]" }] };
    },
    async close() {},
  };
  const server = createPlugin(backend, "<html></html>", "<svg></svg>");
  const client = new Client({ name: "synthetic-companion-test", version: "1" });
  const [local, remote] = InMemoryTransport.createLinkedPair();
  await Promise.all([client.connect(local), server.connect(remote)]);
  const sockets = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await once(sockets, "listening");
  const address = sockets.address(); assert(address && typeof address !== "string");
  const connected = once(sockets, "connection");
  const connection = new WebSocket(`ws://127.0.0.1:${address.port}`);
  const serving = serveConnection(client, connection);
  const [relay] = await connected as [WebSocket];
  t.after(async () => {
    connection.terminate(); relay.terminate();
    await serving;
    await Promise.all([client.close(), server.close(), new Promise<void>(resolve => sockets.close(() => resolve()))]);
  });
  const request = async (job: string, method: string, params?: Record<string, unknown>) => {
    const reply = once(relay, "message");
    relay.send(JSON.stringify({ type: "request", job, rpc: { jsonrpc: "2.0", id: 7, method, params } }));
    return JSON.parse(String((await reply)[0]));
  };
  const initialize = await request("init", "initialize", { protocolVersion: "2025-11-25" });
  assert.equal(initialize.rpc.result.protocolVersion, "2025-11-25");
  assert.deepEqual(initialize.rpc.result.capabilities, { tools: {}, resources: {} });
  const list = await request("list", "tools/list");
  assert(list.rpc.result.tools.some((tool: { name: string }) => tool.name === "search_meetings"));
  const result = await request("recall", "tools/call", { name: "list_meetings", arguments: {} });
  assert.deepEqual(result.rpc.result.structuredContent, { view: "meetings", data: [] });
  const forbidden = await request("forbidden", "tools/call", { name: "search_screen", arguments: { query: "secret" } });
  assert(forbidden.rpc.result?.isError || forbidden.rpc.error);
  relay.send(JSON.stringify({ type: "request", job: "slow", rpc: { jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "list_meetings", arguments: { query: "hold" } } } }));
  // Wait for the adapter's request before disconnecting the socket.
  const deadline = Date.now() + 1000;
  while (!held && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
  assert(held);
  relay.close(); await serving;
  await new Promise(resolve => setImmediate(resolve));
  assert(aborted);
});
test("device credential reads reject group/world-readable files and symlinks", async t => {
  const root = await mkdtemp(path.join(tmpdir(), "lokalbot-credential-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const file = path.join(root, "device.json");
  await writeFile(file, JSON.stringify({ relay: "https://plugin.example", deviceId: "aaaaaaaa-1111-4222-8333-444444444444", credential: "a".repeat(64) }), { mode: 0o600 });
  assert.equal((await readConfig(file)).relay, "https://plugin.example");
  await chmod(file, 0o644); await assert.rejects(readConfig(file), /owner/);
  await chmod(file, 0o600); await symlink(file, path.join(root, "link"));
  await assert.rejects(readConfig(path.join(root, "link")), /regular file/);
});
