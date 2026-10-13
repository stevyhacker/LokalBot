/// <reference types="@cloudflare/workers-types" />
import { DurableObject } from "cloudflare:workers";
import { digest, isRecord, MAX_RESPONSE_BYTES, rpcError, type RPC } from "./protocol.js";

type Device = { secretHash: string; generation: string; connectionId?: string };
export type Pairing = { deviceId: string; generation: string; expiresAt: number };
type Pending = { id: RPC["id"]; resolve: (response: Response) => void; timer: ReturnType<typeof setTimeout> };
const json = (data: unknown, status = 200) => Response.json(data, { status, headers: { "Cache-Control": "no-store" } });

// The binding is private to the Worker. Only the outer router chooses the object
// and invokes internal routes. No RPC bodies or results enter durable storage.
export class RelayRoom extends DurableObject<unknown> {
  private pending = new Map<string, Pending>();
  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/pair/store") {
      const pairing = await request.json<Pairing>();
      await this.ctx.storage.put("pairing", pairing);
      await this.ctx.storage.setAlarm(pairing.expiresAt);
      return json({ ok: true });
    }
    if (path === "/pair/consume") {
      const pairing = await this.ctx.storage.transaction(async storage => {
        const value = await storage.get<Pairing>("pairing");
        await storage.delete("pairing");
        return value;
      });
      return pairing && pairing.expiresAt > Date.now() ? json(pairing) : json({ error: "Invalid or expired pairing code" }, 400);
    }
    if (path === "/init") {
      if (await this.ctx.storage.get("device")) return json({ error: "Already registered" }, 409);
      await this.ctx.storage.put("device", await request.json<Device>());
      await this.ctx.storage.setAlarm(Date.now() + 24 * 60 * 60 * 1000);
      return json({ ok: true });
    }
    const rpc = path === "/rpc" ? await request.json<RPC>() : undefined;
    const bearer = request.headers.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
    const secretHash = bearer ? await digest(bearer) : undefined;
    // Read current authorization after asynchronous parsing/hashing, so a
    // simultaneous revoke cannot be undone by a stale authenticated connect.
    const device = await this.ctx.storage.get<Device>("device");
    if (!device) return json({ error: "Device unavailable" }, 404);
    if (path === "/rpc") {
      if (request.headers.get("X-Grant-Generation") !== device.generation) return json({ error: "Pairing revoked" }, 403);
      const socket = this.currentSocket(device);
      if (!socket) return json({ error: "Your Mac is offline. Start the LokalBot connection and try again." }, 503);
      if (this.pending.size >= 8) return json({ error: "Too many in-flight requests" }, 429);
      const job = crypto.randomUUID();
      return new Promise<Response>(resolve => {
        const timer = setTimeout(() => {
          this.pending.delete(job);
          resolve(json(rpcError(rpc!.id, -32001, "The Mac did not respond in time. Retry the request."), 504));
          try { socket.send(JSON.stringify({ type: "cancel", job })); } catch { /* disconnected */ }
        }, 20_000);
        this.pending.set(job, { id: rpc!.id, resolve, timer });
        try { socket.send(JSON.stringify({ type: "request", job, rpc })); }
        catch { this.finish(job, json(rpcError(rpc!.id, -32002, "The Mac disconnected."), 503)); }
      });
    }
    if (secretHash !== device.secretHash) return json({ error: "Unauthorized device" }, 401);
    if (path === "/identity") return json({ generation: device.generation });
    if (path === "/revoke") {
      await this.ctx.storage.deleteAll();
      await this.ctx.storage.deleteAlarm();
      for (const socket of this.ctx.getWebSockets()) socket.close(4003, "Pairing revoked");
      this.failPending();
      return json({ revoked: true });
    }
    if (path === "/connect" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      this.failPending();
      for (const existing of this.ctx.getWebSockets()) existing.close(4001, "Connection replaced");
      const pair = new WebSocketPair();
      device.connectionId = crypto.randomUUID();
      pair[1].serializeAttachment({ connectionId: device.connectionId });
      this.ctx.acceptWebSocket(pair[1]);
      await this.ctx.storage.put("device", device);
      // Unused credentials expire after 90 days without a connection.
      await this.ctx.storage.setAlarm(Date.now() + 90 * 24 * 60 * 60 * 1000);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return json({ error: "Not found" }, 404);
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    // Ignore replies from a connection superseded while work was in flight.
    const device = await this.ctx.storage.get<Device>("device");
    if (!device || this.currentSocket(device) !== socket) return;
    if (message === "ping") { socket.send("pong"); return; }
    if (typeof message !== "string" || new TextEncoder().encode(message).length > MAX_RESPONSE_BYTES) {
      socket.close(1009, "Response too large"); this.failPending(); return;
    }
    try {
      const value: unknown = JSON.parse(message);
      if (!isRecord(value) || value.type !== "response" || typeof value.job !== "string") return;
      const pending = this.pending.get(value.job);
      if (!pending || !isRecord(value.rpc) || value.rpc.jsonrpc !== "2.0") return;
      if (!("result" in value.rpc) && !("error" in value.rpc)) return;
      this.finish(value.job, json({ ...value.rpc, id: pending.id }));
    } catch { socket.close(1003, "Invalid response"); this.failPending(); }
  }
  webSocketClose(socket: WebSocket) {
    // A closing old socket must not cancel requests on its replacement.
    if (!this.ctx.getWebSockets().some(current => current !== socket && current.readyState === WebSocket.OPEN)) this.failPending();
  }
  webSocketError(socket: WebSocket) { this.webSocketClose(socket); }
  private currentSocket(device: Device): WebSocket | undefined {
    return this.ctx.getWebSockets().find(socket => socket.readyState === WebSocket.OPEN &&
      socket.deserializeAttachment()?.connectionId === device.connectionId);
  }
  async alarm() {
    if (this.ctx.getWebSockets().some(socket => socket.readyState === WebSocket.OPEN)) {
      await this.ctx.storage.setAlarm(Date.now() + 90 * 24 * 60 * 60 * 1000);
    } else await this.ctx.storage.deleteAll();
  }
  private finish(job: string, response: Response) {
    const pending = this.pending.get(job);
    if (!pending) return;
    clearTimeout(pending.timer); this.pending.delete(job); pending.resolve(response);
  }
  private failPending() {
    for (const [job, pending] of this.pending) this.finish(job, json(rpcError(pending.id, -32002, "The Mac disconnected."), 503));
  }
}
