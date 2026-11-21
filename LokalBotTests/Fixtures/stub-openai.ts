type Match = { callIndex?: number; systemIncludes?: string; nth?: number };
type Behaviour =
  | { kind: "reply"; content: string; chunks?: number; finishReason?: string }
  | { kind: "http"; status: number; retryAfter?: number; message?: string }
  | { kind: "truncate"; content: string; keep?: number }
  | { kind: "reasoning"; content: string; reasoningTokens: number }
  | { kind: "malformed"; variant: "invalid-json" | "missing-fields" | "code-fence"; content?: string }
  | { kind: "slow"; content: string; firstByteMs?: number; chunkMs?: number; chunks?: number }
  | { kind: "drop" };
type Rule = { match: Match; behaviour: Behaviour; times?: number; used?: number };
type Logged = { index: number; body: any; receivedAt: number };

let rules: Rule[] | null = null;
let requests: Logged[] = [];
const encoder = new TextEncoder();
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const tokens = (text: string) => Math.ceil(text.length / 4);

function systemOf(body: any): string {
  const message = (body?.messages ?? []).find((m: any) => m.role === "system");
  return typeof message?.content === "string" ? message.content : "";
}

function select(body: any, index: number): Rule | undefined {
  const system = systemOf(body);
  for (const rule of rules ?? []) {
    if (rule.times !== undefined && (rule.used ?? 0) >= rule.times) continue;
    const m = rule.match ?? {};
    if (m.callIndex !== undefined && m.callIndex !== index) continue;
    if (m.systemIncludes !== undefined && !system.includes(m.systemIncludes)) continue;
    if (m.nth !== undefined) {
      const seen = requests.filter((r) =>
        m.systemIncludes === undefined || systemOf(r.body).includes(m.systemIncludes)).length;
      if (seen + 1 !== m.nth) continue;
    }
    rule.used = (rule.used ?? 0) + 1;
    return rule;
  }
  return undefined;
}

function completion(body: any, content: string, finishReason: string, reasoning = 0) {
  return {
    id: "stub", object: "chat.completion", model: body?.model ?? "stub-model",
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: finishReason }],
    usage: { prompt_tokens: 0, completion_tokens: reasoning + tokens(content),
             completion_tokens_details: { reasoning_tokens: reasoning } },
  };
}

function stream(body: any, content: string, finishReason: string, options: {
  chunks?: number; firstByteMs?: number; chunkMs?: number; dropAfterFirst?: boolean } = {}) {
  const pieces = Math.max(1, options.chunks ?? 3);
  const size = Math.ceil(content.length / pieces) || 1;
  const base = { id: "stub", object: "chat.completion.chunk", model: body?.model ?? "stub-model" };
  const line = (payload: unknown) => encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
  return new Response(new ReadableStream({
    async start(controller) {
      if (options.firstByteMs) await sleep(options.firstByteMs);
      controller.enqueue(line({ ...base, choices: [{ index: 0, delta: { role: "assistant" } }] }));
      for (let offset = 0; offset < content.length; offset += size) {
        controller.enqueue(line({ ...base, choices: [{ index: 0, delta: { content: content.slice(offset, offset + size) } }] }));
        if (options.dropAfterFirst) { controller.error(new Error("dropped")); return; }
        if (options.chunkMs) await sleep(options.chunkMs);
      }
      controller.enqueue(line({ ...base, choices: [{ index: 0, delta: {}, finish_reason: finishReason }] }));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

async function respond(body: any, behaviour: Behaviour): Promise<Response> {
  const streaming = body?.stream === true;
  const budget = body?.max_tokens ?? body?.max_completion_tokens ?? 4096;
  const send = (content: string, finish: string, reasoning = 0) =>
    streaming ? stream(body, content, finish) : Response.json(completion(body, content, finish, reasoning));
  switch (behaviour.kind) {
    case "reply":
      return streaming
        ? stream(body, behaviour.content, behaviour.finishReason ?? "stop", { chunks: behaviour.chunks })
        : Response.json(completion(body, behaviour.content, behaviour.finishReason ?? "stop"));
    case "http": {
      const headers: Record<string, string> = {};
      if (behaviour.retryAfter !== undefined) headers["Retry-After"] = String(behaviour.retryAfter);
      return Response.json({ error: { message: behaviour.message ?? "Provider returned error" } },
                           { status: behaviour.status, headers });
    }
    case "truncate": {
      const keep = Math.floor(behaviour.content.length * (behaviour.keep ?? 0.5));
      return send(behaviour.content.slice(0, keep), "length");
    }
    case "reasoning": {
      const left = budget - behaviour.reasoningTokens;
      if (left >= tokens(behaviour.content)) return send(behaviour.content, "stop", behaviour.reasoningTokens);
      return send(behaviour.content.slice(0, Math.max(0, left) * 4), "length", behaviour.reasoningTokens);
    }
    case "malformed": {
      const content = behaviour.variant === "invalid-json" ? '{"task": "unterminated'
        : behaviour.variant === "missing-fields" ? "{}"
        : "```json\n" + (behaviour.content ?? "{}") + "\n```";
      return send(content, "stop");
    }
    case "slow":
      if (streaming) {
        return stream(body, behaviour.content, "stop", {
          chunks: behaviour.chunks, firstByteMs: behaviour.firstByteMs, chunkMs: behaviour.chunkMs });
      }
      await sleep(behaviour.firstByteMs ?? 0);
      return Response.json(completion(body, behaviour.content, "stop"));
    case "drop":
      return stream(body, "partial answer that never finishes", "stop", { chunks: 4, dropAfterFirst: true });
  }
}

function legacyReply(): Response {
  const base = { id: "stub", object: "chat.completion.chunk", model: "stub-model" };
  const line = (payload: unknown) => encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(line({ ...base, choices: [{ index: 0, delta: { role: "assistant" } }] }));
      controller.enqueue(line({ ...base, choices: [{ index: 0, delta: { content: "STUB-REPLY" } }] }));
      controller.enqueue(line({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/__scenario" && req.method === "POST") {
      const payload = await req.json();
      rules = (payload.rules ?? []).map((rule: Rule) => ({ ...rule, used: 0 }));
      requests = [];
      return Response.json({ ok: true, rules: rules.length });
    }
    if (url.pathname === "/__requests") return Response.json(requests);
    if (url.pathname === "/__reset" && req.method === "POST") {
      rules = null;
      requests = [];
      return Response.json({ ok: true });
    }
    if (url.pathname === "/v1/models") {
      return Response.json({ object: "list", data: [{ id: "stub-model", object: "model" }] });
    }
    if (url.pathname !== "/v1/chat/completions") return new Response("not found", { status: 404 });
    const body = await req.json().catch(() => ({}));
    const index = requests.length + 1;
    if (rules === null) {
      requests.push({ index, body, receivedAt: Date.now() });
      return legacyReply();
    }
    const rule = select(body, index);
    requests.push({ index, body, receivedAt: Date.now() });
    if (!rule) return Response.json({ error: { message: "no scenario rule" } }, { status: 500 });
    return respond(body, rule.behaviour);
  },
});
console.log(String(server.port));
