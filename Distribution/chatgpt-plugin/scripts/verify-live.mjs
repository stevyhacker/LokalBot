// Explicit opt-in network validation. Uses only temporary synthetic libraries.
import assert from "node:assert/strict";
import { randomBytes, createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, unlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { publicOrigin, verifyRelay } from "./package-public.mjs";

const { values } = parseArgs({ options: { origin: { type: "string" }, cli: { type: "string" } } });
const origin = publicOrigin(values.origin);
assert(values.cli && path.isAbsolute(values.cli), "Supply an absolute --cli path to the source-built preview helper.");
const root = await mkdtemp(path.join(tmpdir(), "lokalbot-live-verification-"));
const devices = [];
const meetingId = "aaaaaaaa-1111-4222-8333-444444444444";
const callback = "https://mcp.lokalbot.com/synthetic-verification-callback";
const request = (route, init = {}) => fetch(`${origin}${route}`, { ...init, redirect: "manual", signal: AbortSignal.timeout(25_000) });
const jsonPost = (route, data, headers = {}) => request(route, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(data) });
const formPost = (route, data, headers = {}) => request(route, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", ...headers }, body: new URLSearchParams(data).toString() });
async function json(response, status) { assert.equal(response.status, status, `Unexpected HTTP status ${response.status}`); return response.json(); }

async function makeDevice(label) {
  const device = await json(await request("/devices", { method: "POST" }), 201);
  devices.push(device);
  const storage = path.join(root, label);
  const relativePath = "meetings/2026/10/09-synthetic";
  const folder = path.join(storage, relativePath);
  await mkdir(folder, { recursive: true }); await mkdir(path.join(storage, "control"));
  await writeFile(path.join(folder, "meta.json"), JSON.stringify({ id: meetingId, relativePath, title: `Synthetic ${label} plan`, appName: "Fixture", hasSystemTrack: false, startedAt: "2026-10-09T10:00:00Z", endedAt: "2026-10-09T10:20:00Z" }));
  await writeFile(path.join(folder, "summary.md"), `Synthetic ${label}: we chose Redis. No real meeting data.`);
  await writeFile(path.join(folder, "transcript.json"), JSON.stringify({ engine: "fixture", segments: [{ start: 2, end: 8, speaker: "me", text: `Synthetic ${label} transcript-only fact.` }] }));
  device.marker = path.join(storage, "control/agent-access-enabled");
  await writeFile(device.marker, "synthetic-only", { mode: 0o600 });
  const config = path.join(root, `${label}.json`);
  await writeFile(config, JSON.stringify({ relay: origin, deviceId: device.deviceId, credential: device.credential }), { mode: 0o600 });
  const child = spawn(process.execPath, ["dist/companion/dist/device.js", "run", "--config", config], {
    env: { PATH: process.env.PATH, HOME: process.env.HOME, LOKALBOT_CLI_PATH: values.cli, LOKALBOT_STORAGE_ROOT: storage },
    stdio: ["ignore", "ignore", "pipe"],
  });
  device.child = child;
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Synthetic companion did not connect.")), 15_000);
    child.once("exit", () => { clearTimeout(timeout); reject(new Error("Synthetic companion exited.")); });
    child.stderr.on("data", chunk => { if (String(chunk).includes("LokalBot connected.")) { clearTimeout(timeout); resolve(); } });
  });
  const client = await json(await jsonPost("/oauth/register", { client_name: "LokalBot synthetic deployment check", redirect_uris: [callback], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }), 201);
  const verifier = randomBytes(32).toString("base64url");
  const state = randomBytes(16).toString("hex");
  const params = new URLSearchParams({ client_id: client.client_id, response_type: "code", redirect_uri: callback, state,
    scope: "meetings:read offline_access", resource: `${origin}/mcp`, code_challenge: createHash("sha256").update(verifier).digest("base64url"), code_challenge_method: "S256" });
  const consent = await request(`/authorize?${params}`);
  assert.equal(consent.status, 200);
  const html = await consent.text();
  const handle = /name="handle" value="([^"]+)"/.exec(html)?.[1]; assert(handle);
  const cookie = consent.headers.get("set-cookie")?.split(";")[0]; assert(cookie);
  const approved = await formPost("/authorize", { handle, code: device.code, decision: "approve" }, { Cookie: cookie, Origin: origin });
  assert.equal(approved.status, 302);
  const redirect = new URL(approved.headers.get("location")); assert.equal(redirect.searchParams.get("state"), state);
  device.tokens = await json(await formPost("/oauth/token", { grant_type: "authorization_code", code: redirect.searchParams.get("code"), client_id: client.client_id, redirect_uri: callback, code_verifier: verifier, resource: `${origin}/mcp` }), 200);
  device.clientId = client.client_id;
  return device;
}
async function rpc(device, method, params = {}, extraHeaders = {}, expectedStatus = 200) {
  return json(await jsonPost("/mcp", { jsonrpc: "2.0", id: 1, method, params }, {
    Authorization: `Bearer ${device.tokens.access_token}`, Accept: "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18", ...extraHeaders,
  }), expectedStatus);
}
const call = (device, name, args = {}, extraHeaders = {}) => rpc(device, "tools/call", { name, arguments: args }, extraHeaders);
async function revoke(device) {
  const response = await request(`/devices/${device.deviceId}/revoke`, { method: "POST", headers: { Authorization: `Bearer ${device.credential}` } });
  assert(response.ok, "Synthetic device revocation failed.");
  device.revoked = true;
}

try {
  await verifyRelay(origin);
  const alpha = await makeDevice("Alpha");
  const beta = await makeDevice("Beta");
  const initialized = await rpc(alpha, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "synthetic-check", version: "1" } });
  assert.equal(initialized.result.protocolVersion, "2025-06-18");
  const discovered = await rpc(alpha, "tools/list"); assert(discovered.result.tools.some(tool => tool.name === "open_library"));
  for (const [device, label, other] of [[alpha, "Alpha", beta], [beta, "Beta", alpha]]) {
    const response = await call(device, "get_meeting", { id: meetingId }, { "X-Device-Id": other.deviceId });
    assert(!response.result.isError);
    const payload = JSON.stringify(response); assert(payload.includes(`Synthetic ${label}`)); assert(!payload.includes("transcript-only"));
    assert(!payload.includes(label === "Alpha" ? "Synthetic Beta" : "Synthetic Alpha"));
  }
  assert(JSON.stringify(await call(alpha, "get_meeting", { id: meetingId, include_transcript: true })).includes("Alpha transcript-only"));
  const forbidden = await call(alpha, "search_screen", { query: "synthetic" }); assert(forbidden.error || forbidden.result?.isError);
  await unlink(alpha.marker);
  assert((await call(alpha, "get_meeting", { id: meetingId })).result.isError);
  const resource = await rpc(alpha, "resources/read", { uri: `lokalbot://meetings/${meetingId}` }); assert(resource.error);
  assert(!(await call(beta, "list_meetings")).result.isError);
  await revoke(alpha);
  const denied = await rpc(alpha, "tools/list", {}, {}, 404); assert(denied.error);
  const refreshed = await json(await formPost("/oauth/token", { grant_type: "refresh_token", refresh_token: alpha.tokens.refresh_token, client_id: alpha.clientId, resource: `${origin}/mcp` }), 200);
  alpha.tokens = refreshed;
  assert((await rpc(alpha, "tools/list", {}, {}, 404)).error);
  assert(!(await call(beta, "list_meetings")).result.isError);
  console.log("PASS: deployed OAuth + actual companion + native CLI; two-user isolation, summary/transcript selection, local permission revocation, forbidden tools, and old/refreshed-token denial after revocation.");
} finally {
  for (const device of devices) {
    if (!device.revoked) await revoke(device).catch(() => { console.error("Cleanup needs attention: synthetic device could not be revoked."); });
    device.child?.kill("SIGTERM");
  }
  await rm(root, { recursive: true, force: true });
}
