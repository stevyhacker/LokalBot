import { lstat, mkdir, open, unlink, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { ResultSchema } from "@modelcontextprotocol/sdk/types.js";
import WebSocket from "ws";
import { z } from "zod";
import { cliEnvironment } from "./backend.js";
import { isRecord, isRPC, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, PROTOCOL_VERSIONS, rpcError } from "./relay/protocol.js";

const configSchema = z.strictObject({
  relay: z.string().url(), deviceId: z.string().uuid(), credential: z.string().regex(/^[a-f0-9]{64}$/),
});
type Config = z.infer<typeof configSchema>;
export function relayOrigin(value: string): string {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("Use the relay's HTTPS origin without credentials, a path, or query parameters.");
  }
  return url.origin;
}
export async function readConfig(file: string): Promise<Config> {
  let handle;
  try { handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch { throw new Error("The device credential file must be a regular file readable only by its owner (mode 600)."); }
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 || (process.getuid && stat.uid !== process.getuid()) || stat.size > 4096) {
      throw new Error("The device credential file must be a regular file readable only by its owner (mode 600).");
    }
    const config = configSchema.parse(JSON.parse(await handle.readFile("utf8")));
    return { ...config, relay: relayOrigin(config.relay) };
  } finally {
    await handle.close();
  }
}
async function post(origin: string, route: string, credential?: string) {
  const response = await fetch(`${origin}${route}`, {
    method: "POST", redirect: "error", signal: AbortSignal.timeout(15_000),
    headers: credential ? { Authorization: `Bearer ${credential}` } : {},
  });
  if (!response.ok) throw new Error(`Relay refused the request (${response.status}). Check the connection and retry.`);
  return await response.json() as Record<string, unknown>;
}

export async function serveConnection(client: Client, socket: WebSocket): Promise<void> {
  const pending = new Map<string, AbortController>();
  return new Promise(resolve => {
    let waitingForHeartbeat = false;
    const heartbeat = setInterval(() => {
      if (socket.readyState !== WebSocket.OPEN) return;
      if (waitingForHeartbeat) { socket.terminate(); return; }
      waitingForHeartbeat = true;
      socket.send("ping");
    }, 25_000);
    socket.on("message", async raw => {
      let message: unknown;
      try {
        const payload = Array.isArray(raw) ? Buffer.concat(raw) : Buffer.from(raw as ArrayBuffer);
        if (payload.toString() === "pong") { waitingForHeartbeat = false; return; }
        if (payload.byteLength > MAX_REQUEST_BYTES + 1024) { socket.close(1009); return; }
        message = JSON.parse(payload.toString());
      } catch { socket.close(1003); return; }
      if (!isRecord(message) || typeof message.job !== "string") return;
      const job = message.job;
      if (message.type === "cancel") { pending.get(job)?.abort(); return; }
      if (message.type !== "request" || !isRPC(message.rpc) || pending.has(job)) return;
      const rpc = message.rpc;
      if (pending.size >= 8) {
        socket.send(JSON.stringify({ type: "response", job, rpc: rpcError(rpc.id, -32004, "Too many in-flight requests. Retry shortly.") }));
        return;
      }
      const controller = new AbortController();
      pending.set(job, controller);
      let reply: unknown;
      try {
        const result = rpc.method === "initialize" ? {
          protocolVersion: PROTOCOL_VERSIONS.includes(String(rpc.params?.protocolVersion)) ? rpc.params!.protocolVersion : "2025-06-18",
          capabilities: { tools: {}, resources: {} }, serverInfo: client.getServerVersion(), instructions: client.getInstructions(),
        } : await client.request({ method: rpc.method, params: rpc.params }, ResultSchema, { signal: controller.signal, timeout: 17_000 });
        reply = { jsonrpc: "2.0", id: rpc.id, result };
      } catch {
        reply = rpcError(rpc.id, -32603, "LokalBot could not complete this request. Check local access and retry.");
      } finally { pending.delete(job); }
      if (socket.readyState !== WebSocket.OPEN || controller.signal.aborted) return;
      let payload = JSON.stringify({ type: "response", job, rpc: reply });
      if (Buffer.byteLength(payload) > MAX_RESPONSE_BYTES) payload = JSON.stringify({ type: "response", job, rpc: rpcError(rpc.id, -32003, "Result too large. Request a smaller selection.") });
      socket.send(payload);
    });
    socket.once("close", () => { clearInterval(heartbeat); for (const controller of pending.values()) controller.abort(); resolve(); });
    // Connection errors are surfaced by the close/handshake path without logging credentials.
    socket.on("error", () => {});
  });
}

async function run(config: Config) {
  const env = cliEnvironment(process.env);
  if (process.env.LOKALBOT_CLI_PATH) env.LOKALBOT_CLI_PATH = process.env.LOKALBOT_CLI_PATH;
  const client = new Client({ name: "lokalbot-device-connection", version: "0.1.0" });
  await client.connect(new StdioClientTransport({
    command: process.execPath, args: [fileURLToPath(new URL("./server.js", import.meta.url))], env, stderr: "ignore",
  }), { timeout: 8_000 });
  let stopped = false;
  let current: WebSocket | undefined;
  const abort = new AbortController();
  const stop = () => { stopped = true; abort.abort(); current?.terminate(); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
  let delay = 1000;
  try {
    while (!stopped) {
      current = new WebSocket(`${config.relay.replace(/^https:/, "wss:")}/devices/${config.deviceId}/connect`, {
        headers: { Authorization: `Bearer ${config.credential}` }, followRedirects: false,
        maxPayload: MAX_REQUEST_BYTES + 1024, handshakeTimeout: 15_000,
      });
      current.once("open", () => { delay = 1000; process.stderr.write("LokalBot connected. Requested meeting results can now pass through the relay to your authorized client.\n"); });
      current.once("unexpected-response", (_request, response) => {
        response.resume();
        if ([401, 403, 404].includes(response.statusCode ?? 0)) stopped = true;
        current?.terminate();
      });
      current.once("close", code => {
        if ([4001, 4003].includes(code)) {
          stopped = true;
          process.stderr.write(code === 4001 ? "Another helper replaced this connection. Stopping.\n" : "Pairing revoked. Stopping.\n");
        }
      });
      await serveConnection(client, current);
      if (!stopped) {
        process.stderr.write("Connection interrupted; reconnecting.\n");
        await new Promise<void>(resolve => {
          const done = () => { clearTimeout(timer); abort.signal.removeEventListener("abort", done); resolve(); };
          const timer = setTimeout(done, delay);
          abort.signal.addEventListener("abort", done, { once: true });
        });
        delay = Math.min(delay * 2, 30_000);
      }
    }
  } finally { await client.close(); }
}

async function main() {
  const { values, positionals } = parseArgs({
    allowPositionals: true, options: { relay: { type: "string" }, config: { type: "string" } },
  });
  const command = positionals[0];
  if (positionals.length !== 1) throw new Error("Choose exactly one command: pair, run, code, or revoke.");
  const file = path.resolve(values.config ?? path.join(homedir(), ".config/lokalbot-chatgpt/device.json"));
  if (command === "pair") {
    if (!values.relay) throw new Error("Usage: node device.js pair --relay https://YOUR_RELAY_ORIGIN");
    try { await lstat(file); throw new Error("Already paired. Use code to authorize another client, or revoke before pairing again."); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    const relay = relayOrigin(values.relay);
    const registered = await post(relay, "/devices");
    const config = configSchema.parse({ relay, deviceId: registered.deviceId, credential: registered.credential });
    await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
    await writeFile(file, JSON.stringify(config) + "\n", { flag: "wx", mode: 0o600 });
    process.stdout.write(`Pairing code (expires in 10 minutes): ${registered.code}\nEnter it only on ${relay}/authorize after starting Connect in ChatGPT.\nNext, start this helper with the run command. Keep the same --config path if set.\n`);
    return;
  }
  if (!["run", "code", "revoke"].includes(command ?? "")) throw new Error("Usage: node device.js pair --relay https://ORIGIN | run | code | revoke [--config PATH]");
  const config = await readConfig(file);
  if (command === "run") return run(config);
  const result = await post(config.relay, `/devices/${config.deviceId}/${command}`, config.credential);
  if (command === "revoke") {
    await unlink(file);
    process.stdout.write("Pairing revoked. This Mac no longer accepts relay requests.\n");
  } else process.stdout.write(`Pairing code (expires in 10 minutes): ${result.code}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    process.stderr.write("LokalBot connection failed. Check the command, HTTPS relay, and owner-only credential file. Use pair, run, code, or revoke; never paste credentials into chat.\n");
    process.exitCode = 1;
  });
}
