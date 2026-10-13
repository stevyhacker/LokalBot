import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { randomBytes, createHash } from "node:crypto";
import path from "node:path";

const ORIGIN = "https://relay.lokalbot.test";
const CALLBACK = "https://client.example/callback";
let runtime: Miniflare;
let address = 0;
before(async () => {
  runtime = new Miniflare(convertV4MiniflareOptions({
    modules: true, scriptPath: path.resolve("dist/relay.js"),
    compatibilityDate: "2026-07-30", compatibilityFlags: ["global_fetch_strictly_public"],
    bindings: { PUBLIC_ORIGIN: ORIGIN }, kvNamespaces: ["OAUTH_KV"],
    durableObjects: { ROOMS: { className: "RelayRoom", useSQLite: true } },
    ratelimits: {
      PAIR_LIMIT: { namespace_id: "1001", simple: { limit: 5, period: 60 } },
      AUTH_LIMIT: { namespace_id: "1002", simple: { limit: 60, period: 60 } },
    },
  }));
  await runtime.ready;
});
after(async () => { await runtime?.dispose(); });
function request(route: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  if (!headers.has("CF-Connecting-IP")) headers.set("CF-Connecting-IP", `192.0.2.${++address}`);
  return runtime.dispatchFetch(`${ORIGIN}${route}`, { ...init, headers: Object.fromEntries(headers) } as Parameters<Miniflare["dispatchFetch"]>[1]);
}
type Device = { deviceId: string; credential: string; code: string };
async function pair(): Promise<Device> {
  const response = await request("/devices", { method: "POST" });
  assert.equal(response.status, 201);
  return await response.json() as Device;
}
type Auth = { clientId: string; verifier: string; handle: string; cookie: string };
async function begin(): Promise<Auth> {
  const registration = await request("/oauth/register", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ client_name: "Synthetic Client", redirect_uris: [CALLBACK], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }),
  });
  assert.equal(registration.status, 201, await registration.clone().text());
  const { client_id: clientId } = await registration.json() as { client_id: string };
  const verifier = randomBytes(32).toString("base64url");
  const params = new URLSearchParams({
    client_id: clientId, response_type: "code", redirect_uri: CALLBACK, state: "synthetic-state",
    scope: "meetings:read offline_access", resource: `${ORIGIN}/mcp`,
    code_challenge: createHash("sha256").update(verifier).digest("base64url"), code_challenge_method: "S256",
  });
  const response = await request(`/authorize?${params}`);
  assert.equal(response.status, 200, await response.clone().text());
  const html = await response.text();
  assert(html.includes("client.example")); assert(html.includes("read-only"));
  assert(response.headers.get("content-security-policy")?.includes("frame-ancestors 'none'"));
  const handle = /name="handle" value="([^"]+)"/.exec(html)?.[1];
  assert(handle);
  const cookie = response.headers.get("set-cookie")!.split(";")[0]!;
  return { clientId, verifier, handle, cookie };
}
async function approve(auth: Auth, code: string, cookie = auth.cookie) {
  return request("/authorize", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", Origin: ORIGIN, Cookie: cookie },
    body: new URLSearchParams({ handle: auth.handle, code, decision: "approve" }).toString(), redirect: "manual",
  });
}
async function exchange(auth: Auth, code: string, verifier = auth.verifier, resource = `${ORIGIN}/mcp`) {
  return request("/oauth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({
    grant_type: "authorization_code", code, client_id: auth.clientId, redirect_uri: CALLBACK,
    code_verifier: verifier, resource,
  }).toString() });
}
async function authorize(device: Device) {
  const auth = await begin();
  const response = await approve(auth, device.code);
  assert.equal(response.status, 302, await response.clone().text());
  const url = new URL(response.headers.get("location")!);
  assert.equal(url.searchParams.get("state"), "synthetic-state");
  const token = await exchange(auth, url.searchParams.get("code")!);
  assert.equal(token.status, 200, await token.clone().text());
  return { ...await token.json() as { access_token: string; refresh_token: string }, clientId: auth.clientId };
}
function mcp(token: string, body: unknown, headers: Record<string, string> = {}) {
  return request("/mcp", { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...headers }, body: JSON.stringify(body) });
}
async function connect(device: Device, label?: string) {
  const response = await request(`/devices/${device.deviceId}/connect`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${device.credential}` } });
  assert.equal(response.status, 101);
  const socket = response.webSocket!; socket.accept();
  socket.addEventListener("message", event => {
    const message = JSON.parse(String(event.data));
    if (message.type === "request" && label) socket.send(JSON.stringify({ type: "response", job: message.job, rpc: { jsonrpc: "2.0", id: message.rpc.id, result: { owner: label } } }));
  });
  return socket;
}

test("public MCP discovery requires OAuth and advertises its protected resource", async () => {
  const response = await request("/mcp", { method: "POST" });
  assert.equal(response.status, 401);
  const challenge = response.headers.get("www-authenticate")!;
  assert(challenge.includes("meetings:read"));
  const resource = /resource_metadata="([^"]+)"/.exec(challenge)![1]!;
  const metadata = await (await request(new URL(resource).pathname)).json() as { authorization_servers: string[] };
  assert.deepEqual(metadata.authorization_servers, [ORIGIN]);
});
test("public preview pages explain the relay data boundary without granting library access", async () => {
  for (const route of ["/", "/privacy"]) {
    const response = await request(route);
    assert.equal(response.status, 200);
    assert(response.headers.get("content-security-policy")?.includes("default-src 'none'"));
    const text = await response.text();
    assert(text.includes("Cloudflare"));
    assert(!text.includes("<script"));
  }
  assert.equal((await request("/.well-known/openai-apps-challenge")).status, 404);
  assert.equal((await request("/mcp", { method: "POST" })).status, 401);
});
test("OAuth consent is browser-bound and pairing codes cannot be replayed", async () => {
  const device = await pair(); const auth = await begin();
  assert.equal((await approve(auth, device.code, "")).status, 400);
  // A rejected CSRF request must not consume the Mac's code.
  const token = await authorize(device); assert(token.access_token);
  assert.equal((await approve(await begin(), device.code)).status, 400);
});
test("PKCE and OAuth resource audience prevent code theft and token reuse elsewhere", async () => {
  const device = await pair(); const auth = await begin();
  const response = await approve(auth, device.code);
  const code = new URL(response.headers.get("location")!).searchParams.get("code")!;
  assert.equal((await exchange(auth, code, randomBytes(32).toString("base64url"))).status, 400);
  const second = await begin();
  const approved = await approve(second, (await pair()).code);
  const secondCode = new URL(approved.headers.get("location")!).searchParams.get("code")!;
  assert.equal((await exchange(second, secondCode, second.verifier, "https://another.example/mcp")).status, 400);
});
test("each OAuth grant reaches only its paired Mac, including colliding JSON-RPC ids", async t => {
  const alice = await pair(); const bob = await pair();
  const at = await authorize(alice); const bt = await authorize(bob);
  const a = await connect(alice, "alice"); const b = await connect(bob, "bob");
  t.after(() => { a.close(); b.close(); });
  const [ar, br] = await Promise.all([
    mcp(at.access_token, { jsonrpc: "2.0", id: 1, method: "tools/list" }, { "X-Device-ID": bob.deviceId }),
    mcp(bt.access_token, { jsonrpc: "2.0", id: 1, method: "tools/list" }, { "X-Device-ID": alice.deviceId }),
  ]);
  assert.equal(ar.status, 200, await ar.clone().text()); assert.equal(br.status, 200);
  assert.deepEqual(await ar.json(), { jsonrpc: "2.0", id: 1, result: { owner: "alice" } });
  assert.deepEqual(await br.json(), { jsonrpc: "2.0", id: 1, result: { owner: "bob" } });
  const stolen = await request(`/devices/${alice.deviceId}/connect`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${bob.credential}` } });
  assert.equal(stolen.status, 401);
});
test("offline devices fail explicitly and revocation blocks existing OAuth tokens", async t => {
  const device = await pair(); const tokens = await authorize(device);
  const rpc = { jsonrpc: "2.0", id: 1, method: "ping" };
  assert.equal((await mcp(tokens.access_token, rpc)).status, 503);
  const socket = await connect(device, "test"); t.after(() => socket.close());
  assert.equal((await mcp(tokens.access_token, rpc)).status, 200);
  const revoked = await request(`/devices/${device.deviceId}/revoke`, { method: "POST", headers: { Authorization: `Bearer ${device.credential}` } });
  assert.equal(revoked.status, 200);
  assert.equal((await mcp(tokens.access_token, rpc)).status, 404);
  const refresh = await request("/oauth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({
    grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id: tokens.clientId, resource: `${ORIGIN}/mcp`,
  }).toString() });
  // Even if an OAuth grant outlives the device, it cannot restore device access.
  assert.equal(refresh.status, 200);
  const token = await refresh.json() as { access_token: string };
  assert.equal((await mcp(token.access_token, rpc)).status, 404);
});
test("connection replacement routes new work to the replacement and fails old in-flight work", async t => {
  const device = await pair(); const tokens = await authorize(device);
  const old = await connect(device);
  const seen = new Promise<void>(resolve => old.addEventListener("message", () => resolve(), { once: true }));
  const pending = mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "ping" });
  await seen;
  const replacement = await connect(device, "replacement");
  t.after(() => { old.close(); replacement.close(); });
  assert.equal((await pending).status, 503);
  for (let index = 0; index < 3; index++) {
    const result = await mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "ping" });
    assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), { jsonrpc: "2.0", id: 1, result: { owner: "replacement" } });
  }
});
test("relay caps concurrent requests and revocation clears all in-flight work", async t => {
  const device = await pair(); const tokens = await authorize(device);
  const socket = await connect(device); t.after(() => socket.close());
  const pending = [];
  for (let index = 0; index < 8; index++) {
    const seen = new Promise<void>(resolve => socket.addEventListener("message", () => resolve(), { once: true }));
    pending.push(mcp(tokens.access_token, { jsonrpc: "2.0", id: index, method: "ping" }));
    await seen;
  }
  assert.equal((await mcp(tokens.access_token, { jsonrpc: "2.0", id: 8, method: "ping" })).status, 429);
  await request(`/devices/${device.deviceId}/revoke`, { method: "POST", headers: { Authorization: `Bearer ${device.credential}` } });
  for (const result of await Promise.all(pending)) assert.equal(result.status, 503);
});
test("HTTP and RPC validation rejects cross-origin, oversized, and unsupported requests", async () => {
  const device = await pair(); const tokens = await authorize(device);
  assert.equal((await request("/mcp", { method: "GET", headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 405);
  assert.equal((await mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "shell/execute" })).status, 400);
  assert.equal((await mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "ping" }, { Origin: "https://evil.example" })).status, 403);
  assert.equal((await mcp(tokens.access_token, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { blob: "x".repeat(70_000) } })).status, 400);
  assert.equal((await mcp(tokens.access_token, { jsonrpc: "2.0", method: "notifications/initialized" })).status, 202);
  assert.equal((await request("/mcp", { headers: { Authorization: `Bearer ${tokens.access_token}` } })).status, 405);
});
test("device registration is rate-limited before allocating durable objects", async () => {
  for (let attempt = 0; attempt < 5; attempt++) assert.equal((await request("/devices", { method: "POST", headers: { "CF-Connecting-IP": "198.51.100.1" } })).status, 201);
  assert.equal((await request("/devices", { method: "POST", headers: { "CF-Connecting-IP": "198.51.100.1" } })).status, 429);
});
