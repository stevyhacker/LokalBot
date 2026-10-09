/// <reference types="@cloudflare/workers-types" />
import OAuthProvider, { AuthorizationError, CimdFetchError, type OAuthHelpers, type ConsentDescription } from "@cloudflare/workers-oauth-provider";
import { boundedText, digest, isRecord, isRPC, normalizePairCode, PROTOCOL_VERSIONS, READ_SCOPE, rpcError, secret } from "./protocol.js";
import type { Pairing } from "./room.js";
import { publicPage } from "./pages.js";
export { RelayRoom } from "./room.js";

interface Env {
  PUBLIC_ORIGIN: string;
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  ROOMS: DurableObjectNamespace;
  PAIR_LIMIT: RateLimit;
  AUTH_LIMIT: RateLimit;
  OPENAI_DOMAIN_CHALLENGE?: string;
}
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const json = (data: unknown, status = 200) => Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
const room = (env: Env, name: string) => env.ROOMS.get(env.ROOMS.idFromName(name));
const escape = (value: string) => value.replace(/[&<>"']/g, char => `&#${char.charCodeAt(0)};`);

function consentPage(details: ConsentDescription, handle: string) {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect LokalBot</title><body><main><h1>Connect your Mac to ${escape(details.clientName)}</h1>
<p>${details.clientDomain ? `Client domain: <strong>${escape(details.clientDomain)}</strong>.` : "This client's name is self-registered, not verified."}
 Access returns to <strong>${escape(details.redirectHost)}</strong>.</p>
${details.redirectIsLoopback ? "<p>Only continue if you just started this connection from an app on your computer.</p>" : ""}
<p>Allow read-only access to meeting titles, summaries, requested transcript excerpts, commitments, and people. The library stays on your Mac. Requested results pass through the LokalBot relay on Cloudflare to this client. No screen memory or write access is granted.</p>
<p>Run the LokalBot connection helper on your own Mac to get a pairing code. Keep the helper running while using this plugin. Do not use a code sent by someone else.</p>
<form method="post" action="/authorize"><input type="hidden" name="handle" value="${escape(handle)}">
<label>Pairing code from your Mac <input name="code" autocomplete="off" spellcheck="false" maxlength="80" required></label>
<p><button name="decision" value="approve">Connect this Mac</button> <button name="decision" value="deny" formnovalidate>Cancel</button></p></form>
<p>Permission: ${READ_SCOPE}. Authorization lasts up to 30 days. You can stop the helper or revoke this pairing at any time. Content already shared remains with the client.</p>
<p><a href="/privacy">Connection privacy</a> · <a href="https://www.lokalbot.com/terms">Terms</a> · <a href="https://www.lokalbot.com/support">Support</a></p></main></body></html>`;
}
async function issueCode(env: Env, deviceId: string, generation: string) {
  const code = secret(16);
  const expiresAt = Date.now() + 10 * 60 * 1000;
  await room(env, `pair:${await digest(code)}`).fetch("https://internal/pair/store", {
    method: "POST", body: JSON.stringify({ deviceId, generation, expiresAt }),
  });
  return { code: code.match(/.{4}/g)!.join("-"), expiresAt };
}

async function authorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  try {
    if (request.method === "GET") {
      const auth = await oauth.parseAuthRequest(request);
      // Enforce S256 for every client, including confidential clients.
      if (auth.codeChallengeMethod !== "S256" || !auth.codeChallenge) return json({ error: "PKCE S256 is required" }, 400);
      if (!auth.scope.includes(READ_SCOPE) || auth.scope.some(scope => scope !== READ_SCOPE && scope !== "offline_access")) return json({ error: "Request meetings:read and optionally offline_access" }, 400);
      const details = await oauth.describeConsent(auth);
      const consent = await oauth.beginConsent(auth);
      consent.headers.set("Content-Type", "text/html; charset=utf-8");
      consent.headers.set("Content-Security-Policy", "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
      consent.headers.set("Referrer-Policy", "no-referrer");
      return new Response(consentPage(details, consent.handle), { headers: consent.headers });
    }
    if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
    if (request.headers.get("Origin") !== env.PUBLIC_ORIGIN) return json({ error: "Invalid origin" }, 403);
    if (!request.headers.get("Content-Type")?.startsWith("application/x-www-form-urlencoded")) return json({ error: "Invalid form" }, 415);
    const form = new URLSearchParams(await boundedText(request, 4096));
    const handle = form.get("handle") ?? "";
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    // Consume the browser-bound CSRF handle before touching a pairing code.
    const approved = await oauth.approveConsent(request, handle);
    const code = normalizePairCode(form.get("code") ?? "");
    if (!code) return json({ error: "Invalid pairing code. Restart connection from ChatGPT." }, 400);
    const claimed = await room(env, `pair:${await digest(code)}`).fetch("https://internal/pair/consume", { method: "POST" });
    if (!claimed.ok) return json({ error: "Pairing code expired or already used. Generate a new code and reconnect." }, 400);
    const pairing = await claimed.json<Pairing>();
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request, userId: pairing.deviceId, metadata: {},
      scope: approved.request.scope, props: { deviceId: pairing.deviceId, generation: pairing.generation },
    });
    approved.headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (error) {
    if (error instanceof AuthorizationError || error instanceof CimdFetchError) return json({ error: "Authorization could not be verified. Restart the connection from your client." }, 400);
    throw error;
  }
}

const defaultHandler: ExportedHandler<Env> = { async fetch(request, env) {
  const path = new URL(request.url).pathname;
  if (request.method === "GET") {
    const page = publicPage(path);
    if (page) return page;
    if (path === "/.well-known/openai-apps-challenge" && env.OPENAI_DOMAIN_CHALLENGE) {
      return new Response(env.OPENAI_DOMAIN_CHALLENGE, { headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } });
    }
  }
  if (path === "/authorize") return authorize(request, env);
  if (path === "/health") return json({ service: "lokalbot-mcp-relay", status: "ok" });
  if (path === "/devices" && request.method === "POST") {
    const deviceId = crypto.randomUUID();
    const credential = secret();
    const generation = crypto.randomUUID();
    await room(env, deviceId).fetch("https://internal/init", {
      method: "POST", body: JSON.stringify({ secretHash: await digest(credential), generation }),
    });
    return json({ deviceId, credential, ...await issueCode(env, deviceId, generation) }, 201);
  }
  const match = /^\/devices\/([a-f0-9-]{36})\/(connect|code|revoke)$/.exec(path);
  if (!match || !uuid.test(match[1]!)) return json({ error: "Not found" }, 404);
  const [, deviceId, action] = match;
  const target = room(env, deviceId!);
  const headers = new Headers({ Authorization: request.headers.get("Authorization") ?? "" });
  if (action === "connect" && request.method === "GET" && request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
    headers.set("Upgrade", "websocket");
    return target.fetch("https://internal/connect", { headers });
  }
  if (action === "revoke" && request.method === "POST") return target.fetch("https://internal/revoke", { method: "POST", headers });
  if (action === "code" && request.method === "POST") {
    const identity = await target.fetch("https://internal/identity", { headers });
    if (!identity.ok) return identity;
    const { generation } = await identity.json<{ generation: string }>();
    return json(await issueCode(env, deviceId!, generation));
  }
  return json({ error: "Method not allowed" }, 405);
} };

const apiHandler: Required<Pick<ExportedHandler<Env>, "fetch">> = { async fetch(request, env, ctx) {
  if (new URL(request.url).pathname !== "/mcp") return json({ error: "Not found" }, 404);
  const auth = ctx as ExecutionContext & { props: unknown; auth: { scope: string[] } };
  const props = auth.props;
  if (!auth.auth.scope.includes(READ_SCOPE) || !isRecord(props) || typeof props.deviceId !== "string" || !uuid.test(props.deviceId) || typeof props.generation !== "string") return json({ error: "Insufficient scope" }, 403);
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  if (!request.headers.get("Content-Type")?.startsWith("application/json")) return json({ error: "Expected application/json" }, 415);
  const accept = request.headers.get("Accept") ?? "";
  if (!accept.includes("application/json") || !accept.includes("text/event-stream")) return json({ error: "Accept must include application/json and text/event-stream" }, 406);
  const protocol = request.headers.get("MCP-Protocol-Version");
  if (protocol && !PROTOCOL_VERSIONS.includes(protocol)) return json({ error: "Unsupported MCP protocol version" }, 400);
  let rpc: unknown;
  try { rpc = JSON.parse(await boundedText(request)); } catch { return json(rpcError(null, -32700, "Invalid or oversized request"), 400); }
  if (isRecord(rpc) && rpc.jsonrpc === "2.0" && !("id" in rpc) && ["notifications/initialized", "notifications/cancelled"].includes(String(rpc.method))) return new Response(null, { status: 202 });
  if (!isRPC(rpc)) return json(rpcError(null, -32600, "Unsupported MCP request"), 400);
  return room(env, props.deviceId).fetch("https://internal/rpc", {
    method: "POST", headers: { "X-Grant-Generation": props.generation }, body: JSON.stringify(rpc),
  });
} };

export default { async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  try {
    const origin = new URL(env.PUBLIC_ORIGIN);
    if (origin.protocol !== "https:" || origin.origin !== env.PUBLIC_ORIGIN || origin.hostname.endsWith(".invalid")) return json({ error: "Configure PUBLIC_ORIGIN before deploying" }, 503);
    const url = new URL(request.url);
    if (url.origin !== env.PUBLIC_ORIGIN) return json({ error: "Unknown host" }, 400);
    if (request.headers.has("Origin") && request.headers.get("Origin") !== env.PUBLIC_ORIGIN) return json({ error: "Invalid origin" }, 403);
    const pairing = url.pathname === "/devices" || url.pathname.endsWith("/code");
    if (pairing || url.pathname === "/authorize" || url.pathname.startsWith("/oauth/")) {
      const key = await digest(request.headers.get("CF-Connecting-IP") ?? "unknown");
      const limit = pairing ? env.PAIR_LIMIT : env.AUTH_LIMIT;
      if (!(await limit.limit({ key })).success) return json({ error: "Rate limit reached. Try again later." }, 429);
    }
    const provider = new OAuthProvider<Env>({
      apiRoute: "/mcp", apiHandler, defaultHandler,
      authorizeEndpoint: "/authorize", tokenEndpoint: "/oauth/token",
      clientRegistrationEndpoint: "/oauth/register", clientIdMetadataDocumentEnabled: true,
      scopesSupported: [READ_SCOPE, "offline_access"], requiredScopes: [READ_SCOPE],
      accessTokenTTL: 15 * 60, refreshTokenTTL: 30 * 24 * 60 * 60,
      resourceMetadata: { resource: `${env.PUBLIC_ORIGIN}/mcp`, authorization_servers: [env.PUBLIC_ORIGIN] },
      // Keep provider diagnostics out of logs too; preserve standard OAuth errors
      // and challenges without persisting redirect URLs or supplied identifiers.
      onError: ({ code, description, status, headers }) => Response.json(
        { error: code, error_description: description },
        { status, headers: { ...headers, "Cache-Control": "no-store" } },
      ),
    });
    return await provider.fetch(request, env, ctx);
  } catch {
    // Avoid persisting private tool payloads or credentials in application logs.
    return json({ error: "Relay temporarily unavailable" }, 503);
  }
} };
