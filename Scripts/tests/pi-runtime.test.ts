// Run against a checksum-pinned, frozen-lockfile runtime:
// LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/runtime bash Scripts/tests/run-pi-runtime-tests.sh
import { expect, test } from "bun:test";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import lokalbotExtension, {
  applyReasoningLevel, applyResponsesReasoningLevel, environmentSection, inferenceFetchForOrigin, providerAPI,
  readReasoningLevel, retryRejectedReasoning,
} from "../../LokalBot/Resources/pi/lokalbot-extension/index";
import * as boundary from "../../LokalBot/Resources/pi/lokalbot-extension/index";

const runtime = process.env.LOKALBOT_PINNED_RUNTIME_ROOT;
const repo = resolve(import.meta.dir, "../..");

test("Agent fetch rejects unapproved origins and URL credentials before sending", async () => {
  let requests = 0;
  const transport = inferenceFetchForOrigin(new URL("https://approved.example/v1"), (async () => {
    requests++; return new Response("fixture");
  }) as typeof fetch);
  for (const target of [
    "https://other.example/v1/chat", "http://approved.example/v1/chat",
    "https://approved.example:8443/v1/chat", "https://user:secret@approved.example/v1/chat",
  ]) {
    await expect(transport(target)).rejects.toThrow("approved origin");
  }
  expect(requests).toBe(0);
  await transport(new Request("https://approved.example/v1/chat"));
  expect(requests).toBe(1);
});

for (const status of [301, 302, 303, 307, 308]) {
  test(`Agent fetch never replays a POST through a ${status} redirect`, async () => {
    let targetRequests = 0;
    const target = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch() { targetRequests++; return new Response("unexpected"); },
    });
    const observed: string[] = [];
    const source = Bun.serve({ hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        observed.push(await request.text());
        expect(request.headers.get("authorization")).toBe("Bearer synthetic-token");
        return new Response(null, { status, headers: { location: `http://127.0.0.1:${target.port}/receive` } });
      },
    });
    try {
      const endpoint = new URL(`http://127.0.0.1:${source.port}/v1`);
      const transport = inferenceFetchForOrigin(endpoint);
      await expect(transport(endpoint, {
        method: "POST", body: "synthetic-private-context",
        headers: { authorization: "Bearer synthetic-token" }, redirect: "follow",
      })).rejects.toThrow();
      expect(observed).toEqual(["synthetic-private-context"]);
      expect(targetRequests).toBe(0);
    } finally {
      source.stop(true); target.stop(true);
    }
  });
}

test("Agent fetch rejects same-origin redirects and preserves normal response streaming", async () => {
  const paths: string[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      paths.push(path);
      if (path === "/redirect") return new Response(null, { status: 307, headers: { location: "/stream" } });
      return new Response("data: synthetic-token\n\ndata: [DONE]\n\n", {
        headers: { "content-type": "text/event-stream" },
      });
    },
  });
  try {
    const endpoint = new URL(`http://127.0.0.1:${server.port}/`);
    const transport = inferenceFetchForOrigin(endpoint);
    await expect(transport(new URL("/redirect", endpoint))).rejects.toThrow();
    expect(paths).toEqual(["/redirect"]);
    const response = await transport(new URL("/stream", endpoint));
    expect(await response.text()).toBe("data: synthetic-token\n\ndata: [DONE]\n\n");
  } finally { server.stop(true); }
});

// Exercise the actual extension hook without a model, library, or tool runner.
// Returning undefined is what allows Pi to execute, so a blocking result must
// be returned even if the fake UI would approve every request.
async function withExtensionFixture(run: (fixture: {
  root: string; workspace: string; library: string;
  // `cwd` is the session folder pi resolves tool paths against (ctx.cwd).
  call: (toolName: string, input: unknown, cwd?: string) => Promise<any>;
  approvals: any[];
  provider: any;
}) => Promise<void>, baseUrl = "http://127.0.0.1:1234/v1", extraEnvironment: Record<string, string> = {}) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-agent-boundary-")));
  const workspace = join(root, "workspace");
  const library = join(root, "private-library");
  await mkdir(workspace); await mkdir(library);
  const originalCWD = process.cwd();
  const environment = { ...process.env };
  try {
    process.chdir(workspace);
    process.env.LOKALBOT_LLM_BASE_URL = baseUrl;
    process.env.LOKALBOT_LLM_MODEL = "fixture";
    process.env.LOKALBOT_LLM_API_KEY = "synthetic-token";
    process.env.LOKALBOT_AGENT_PRIVATE_ROOTS = JSON.stringify([library]);
    Object.assign(process.env, extraEnvironment);
    let handler: any;
    let provider: any;
    lokalbotExtension({ registerProvider(_name: string, config: any) { provider = config; }, on(name: string, callback: any) {
      if (name === "tool_call") handler = callback;
    } } as any);
    const approvals: any[] = [];
    const call = (toolName: string, input: unknown, cwd?: string) => handler({ toolName, input }, {
      cwd,
      ui: { confirm: async (_title: string, message: string) => {
        approvals.push(JSON.parse(message)); return true;
      } },
    });
    await run({ root, workspace, library, call, approvals, provider });
  } finally {
    process.chdir(originalCWD);
    for (const key of Object.keys(process.env)) if (!(key in environment)) delete process.env[key];
    Object.assign(process.env, environment);
    await rm(root, { recursive: true, force: true });
  }
}

for (const status of [307, 308]) {
  test(`registered pinned Agent provider rejects ${status} without replaying context`, async () => {
    let targetRequests = 0;
    const target = Bun.serve({ hostname: "127.0.0.1", port: 0,
      fetch() { targetRequests++; return new Response("unexpected"); },
    });
    const observed: string[] = [];
    const source = Bun.serve({ hostname: "127.0.0.1", port: 0,
      async fetch(request) {
        observed.push(await request.text());
        expect(request.headers.get("authorization")).toBe("Bearer synthetic-token");
        return new Response(null, { status, headers: { location: `http://127.0.0.1:${target.port}/receive` } });
      },
    });
    try {
      const baseUrl = `http://127.0.0.1:${source.port}/v1`;
      await withExtensionFixture(async ({ provider }) => {
        const model = { ...provider.models[0], provider: "lokalbot", api: provider.api,
          baseUrl, maxTokens: 128, name: "Fixture", reasoning: false };
        let callerFetchUsed = false;
        const stream = provider.streamSimple(model, {
          messages: [{ role: "user", content: "synthetic-private-context", timestamp: Date.now() }],
        }, { apiKey: "synthetic-token", maxRetries: 0, timeoutMs: 2_000,
          fetch: () => { callerFetchUsed = true; throw new Error("must use scoped transport"); },
        });
        const events: any[] = [];
        for await (const event of stream) events.push(event);
        expect(events.at(-1)?.type).toBe("error");
        expect(callerFetchUsed).toBe(false);
        expect(observed).toHaveLength(1);
        expect(observed[0]).toContain("synthetic-private-context");
        expect(targetRequests).toBe(0);
      }, baseUrl);
    } finally { source.stop(true); target.stop(true); }
  });
}

test("the provider key never reaches the environment shell commands inherit", async () => {
  await withExtensionFixture(async ({ provider }) => {
    expect(provider.apiKey).toBe("synthetic-token");
    expect(process.env.LOKALBOT_LLM_API_KEY).toBeUndefined();
    // pi's bash tool spawns each command with a copy of process.env.
    const shell = Bun.spawnSync(["/usr/bin/env"], { env: { ...process.env } });
    expect(shell.stdout.toString()).not.toContain("synthetic-token");
    // pi evaluates the extension again for a new session.
    let renewed: any;
    lokalbotExtension({ registerProvider(_name: string, config: any) { renewed = config; }, on() {} } as any);
    expect(renewed.apiKey).toBe("synthetic-token");
  });
});

test("default workspace reads do not implicitly authorize the private library", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await writeFile(join(workspace, "draft.txt"), "synthetic draft");
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    expect(await call("read", { path: "draft.txt" })).toBeUndefined();
    expect(approvals).toHaveLength(0);
    await call("read", { path: join(library, "transcript.txt") });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "transcript.txt"));
  });
});

test("selecting a parent workspace still gates private-library reads", async () => {
  await withExtensionFixture(async ({ root, library, call, approvals }) => {
    process.chdir(root);
    await call("read", { path: join(library, "journal.md") });
    expect(approvals).toHaveLength(1);
  });
});

test("workspace symlinks do not turn private-library reads into implicit access", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await symlink(library, join(workspace, "linked-library"));
    await call("read", { path: "linked-library/meeting.md" });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "meeting.md"));
  });
});

// pi's file tools rewrite a requested path before opening it (pi 1.3.0
// utils/paths.js and core/tools/path-utils.js). Checked as typed, each of
// these named a missing file inside the workspace and ran without asking.

test("a leading @ is removed before the boundary check, as pi removes it", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    await writeFile(join(workspace, "notes.txt"), "synthetic notes");
    await call("read", { path: "@" + join(library, "transcript.txt") });
    await call("read", { path: "@../private-library/transcript.txt" });
    expect(approvals.map(approval => approval.path)).toEqual([
      join(library, "transcript.txt"), join(library, "transcript.txt"),
    ]);
    expect(await call("read", { path: "@notes.txt" })).toBeUndefined();
    expect(approvals).toHaveLength(2);
  });
});

test("~ and @~ reach the home folder, as pi expands them", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const home = await realpath(homedir());
    for (const path of ["~/lokalbot-agent-synthetic-missing.txt", "@~/lokalbot-agent-synthetic-missing.txt", "@~"]) {
      await call("read", { path });
    }
    expect(approvals.map(approval => approval.path)).toEqual([
      join(home, "lokalbot-agent-synthetic-missing.txt"), join(home, "lokalbot-agent-synthetic-missing.txt"), home,
    ]);
  });
});

test("file URLs are checked as the file pi opens", async () => {
  await withExtensionFixture(async ({ library, call, approvals }) => {
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    const url = pathToFileURL(join(library, "transcript.txt")).href;
    await call("read", { path: url });
    await call("read", { path: "@" + url });
    expect(approvals.map(approval => approval.path)).toEqual([
      join(library, "transcript.txt"), join(library, "transcript.txt"),
    ]);
    // A path pi cannot resolve is never treated as a workspace name.
    await call("read", { path: "file://remote.example/etc/hosts" });
    expect(approvals).toHaveLength(3);
  });
});

test("Unicode spaces are checked as the plain spaces pi opens", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await writeFile(join(workspace, "two words.txt"), "synthetic");
    expect(await call("read", { path: "two\u00A0words.txt" })).toBeUndefined();
    expect(approvals).toHaveLength(0);
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    await symlink(library, join(workspace, "linked library"));
    await call("read", { path: "linked\u00A0library/transcript.txt" });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "transcript.txt"));
    await call("write", { path: "new\u2009file.txt", content: "x" });
    expect(approvals.at(-1).path).toBe(join(workspace, "new file.txt"));
  });
});

test("a missing name is checked as the look-alike file pi opens instead", async () => {
  await withExtensionFixture(async ({ workspace, library, call, approvals }) => {
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    // pi retries a missing name with a narrow no-break space before AM/PM,
    // in NFD, and with curly apostrophes.
    await symlink(library, join(workspace, "it\u2019s"));
    await symlink(library, join(workspace, "Shot 9.41\u202FAM.d"));
    await call("read", { path: "it's/transcript.txt" });
    await call("read", { path: "Shot 9.41 AM.d/transcript.txt" });
    expect(approvals.map(approval => approval.path)).toEqual([
      join(library, "transcript.txt"), join(library, "transcript.txt"),
    ]);
    await writeFile(join(library, "Capture d\u2019ecran.txt"), "synthetic");
    await call("read", { path: "it's/Capture d'ecran.txt" });
    expect(approvals.at(-1).path).toBe(join(library, "Capture d\u2019ecran.txt"));
  });
});

test("relative paths resolve against pi's session folder", async () => {
  await withExtensionFixture(async ({ root, library, call, approvals }) => {
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    // pi resolves against ctx.cwd: a resumed session keeps the folder it was saved with.
    await call("read", { path: "private-library/transcript.txt" }, root);
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "transcript.txt"));
  });
});

test("a differently cased library path is still the private library", async () => {
  await withExtensionFixture(async ({ root, library, call, approvals }) => {
    await writeFile(join(library, "transcript.txt"), "synthetic transcript");
    const variant = join(root, "PRIVATE-LIBRARY", "transcript.txt");
    // On a case-sensitive volume pi cannot open the variant either.
    if (!existsSync(variant)) return;
    process.chdir(root);
    await call("read", { path: variant });
    expect(approvals).toHaveLength(1);
    expect(approvals[0].path).toBe(join(library, "transcript.txt"));
  });
});

test.skipIf(!runtime)("the boundary resolves paths exactly as the pinned pi does", async () => {
  const pi = await import(join(runtime!, "pi/node_modules/@earendil-works/pi-coding-agent/dist/core/tools/path-utils.js"));
  await withExtensionFixture(async ({ workspace, library }) => {
    await writeFile(join(workspace, "it\u2019s.txt"), "x");
    await writeFile(join(workspace, "Shot 9.41\u202FAM.png"), "x");
    await writeFile(join(workspace, "cafe\u0301.txt"), "x");
    const inputs = ["notes.txt", "@notes.txt", "@@notes.txt", "@/etc/hosts", "~", "~/x", "@~/x", "@~", "~x",
      "../x", "@../x", "/a/../x", "file:///tmp/x", "@file:///tmp/x", "a\u00A0b\u3000c", "@\u2009x",
      "it's.txt", "Shot 9.41 AM.png", "caf\u00E9.txt", join(library, "x")];
    for (const cwd of [workspace, library]) {
      for (const input of inputs) {
        expect([input, boundary.resolveReadPath(input, cwd)]).toEqual([input, pi.resolveReadPath(input, cwd)]);
        expect([input, boundary.resolveToCwd(input, cwd)]).toEqual([input, pi.resolveToCwd(input, cwd)]);
      }
    }
  });
});

test("the entire shell command at the length boundary is sent for approval", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const command = "#".repeat(65_536);
    expect(await call("bash", { command })).toBeUndefined();
    expect(approvals).toHaveLength(1);
    expect(approvals[0].command).toBe(command);
    expect(approvals[0].truncated).toBe(false);
  });
});

for (const command of ["#".repeat(65_536) + "; hidden suffix", "😀".repeat(32_768) + "x"]) {
  test(`oversized shell request (${command.length} UTF-16 units) is blocked before approval`, async () => {
    await withExtensionFixture(async ({ call, approvals }) => {
      expect((await call("bash", { command })).block).toBe(true);
      expect(approvals).toHaveLength(0);
    });
  });
}

test("malformed shell requests cannot obtain approval through a fallback preview", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    for (const input of [undefined, {}, { cmd: "hidden alias" }, { command: 1 }]) {
      expect((await call("bash", input)).block).toBe(true);
    }
    expect(approvals).toHaveLength(0);
  });
});

test("every tool outside the allowlist asks with its exact arguments", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const input = { path: "/tmp/anywhere", nested: { text: "synthetic" } };
    const tools = ["mcp__stub__touch", "codemode", "tool_search", "grep", "future_tool"];
    for (const toolName of tools) expect(await call(toolName, input)).toBeUndefined();
    expect(approvals.map(approval => approval.tool)).toEqual(tools);
    for (const approval of approvals) expect(approval.arguments).toBe(JSON.stringify(input, null, 2));
  });
});

test("arguments of a tool without a preview must fit in full before approval", async () => {
  await withExtensionFixture(async ({ call, approvals }) => {
    const wrapper = JSON.stringify({ code: "" }, null, 2).length;
    expect(await call("codemode", { code: "#".repeat(65_536 - wrapper) })).toBeUndefined();
    expect((await call("codemode", { code: "#".repeat(65_536 - wrapper + 1) })).block).toBe(true);
    expect(approvals).toHaveLength(1);
    expect(approvals[0].arguments).toHaveLength(65_536);
  });
});

// One Pi RPC turn against a stub model that requests `toolCall` and then
// replies STUB-REPLY. Every approval prompt is answered with `approved`.
/// A Responses event stream as OpenAI sends it: each output item added, its
/// text, the item done, then the completed response.
function responsesStream(items: any[]): string {
  const events: any[] = [{ type: "response.created", response: { id: "resp-test", status: "in_progress" } }];
  items.forEach((item, index) => {
    events.push({ type: "response.output_item.added", output_index: index,
      item: item.type === "message" ? { ...item, content: [] } : { ...item, arguments: "" } });
    if (item.type === "message") {
      events.push({ type: "response.output_text.delta", output_index: index, delta: item.content[0].text });
    }
    events.push({ type: "response.output_item.done", output_index: index, item });
  });
  events.push({ type: "response.completed", response: { id: "resp-test", status: "completed", output: items,
    usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } });
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

/// What LokalBot's ChatGPT plan relay passes back: encrypted reasoning and a
/// tool call, then the answer once the tool's output comes in.
function responsesTurn(body: any, toolCall: { name: string; arguments: unknown }): string {
  if (body.input.some((item: any) => item.type === "function_call_output")) {
    return responsesStream([{ type: "message", id: "msg-test", role: "assistant", status: "completed",
      content: [{ type: "output_text", text: "STUB-REPLY", annotations: [] }] }]);
  }
  return responsesStream([
    { type: "reasoning", id: "rs-test", summary: [], encrypted_content: "SYNTHETIC-ENCRYPTED" },
    { type: "function_call", id: "fc-test", call_id: "call-test", status: "completed",
      name: toolCall.name, arguments: JSON.stringify(toolCall.arguments) },
  ]);
}

async function piTurn(options: {
  workspace: string; toolCall: { name: string; arguments: unknown }; approved: boolean;
  extensions?: string[]; piConfig?: string; beforeAnswer?: (payload: any) => Promise<void>;
  home?: string; tmp?: string; privateRoots?: string[];
  launchArguments?: string[]; environment?: Record<string, string>;
  api?: "openai-completions" | "openai-responses";
}) {
  const requests: any[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(req) {
      if (options.api === "openai-responses") {
        expect(new URL(req.url).pathname).toBe("/v1/responses");
        const body = await req.json();
        requests.push(body);
        return new Response(responsesTurn(body, options.toolCall), { headers: { "content-type": "text/event-stream" } });
      }
      expect(new URL(req.url).pathname).toBe("/v1/chat/completions");
      const body = await req.json();
      requests.push(body);
      const toolResult = body.messages.find((message: any) => message.role === "tool");
      const delta = toolResult ? { content: "STUB-REPLY" } : {
        tool_calls: [{ index: 0, id: "tool-test", type: "function", function: {
          name: options.toolCall.name, arguments: JSON.stringify(options.toolCall.arguments),
        } }],
      };
      const base = { id: "stub", object: "chat.completion.chunk", model: "stub-model" };
      const chunks = [
        { ...base, choices: [{ index: 0, delta: { role: "assistant" } }] },
        { ...base, choices: [{ index: 0, delta }] },
        { ...base, choices: [{ index: 0, delta: {}, finish_reason: toolResult ? "stop" : "tool_calls" }] },
      ];
      return new Response(chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } });
    },
  });
  const proc = Bun.spawn([
    join(runtime!, "bun/bun"),
    join(runtime!, "pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
    "--mode", "rpc", "--provider", "lokalbot", "--model", "stub-model",
    "--no-extensions", "-e", join(repo, "LokalBot/Resources/pi/lokalbot-extension"),
    ...(options.extensions ?? []).flatMap(extension => ["-e", extension]),
    "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve",
    "--session-dir", join(options.workspace, "sessions"), "--offline",
    ...(options.launchArguments ?? []),
  ], {
    cwd: options.workspace, stdin: "pipe", stdout: "pipe", stderr: "pipe",
    env: { ...options.environment, PATH: process.env.PATH, HOME: options.home ?? options.workspace,
      ...(options.tmp ? { TMPDIR: options.tmp } : {}),
      PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
      // As in PiLaunchPlanner: no compiled copies outside the runtime.
      BUN_RUNTIME_TRANSPILER_CACHE_PATH: "0", NODE_DISABLE_COMPILE_CACHE: "1", JITI_FS_CACHE: "false",
      PI_CODING_AGENT_DIR: options.piConfig ?? join(options.workspace, "pi-config"),
      LOKALBOT_AGENT_PRIVATE_ROOTS: JSON.stringify(options.privateRoots ?? []),
      LOKALBOT_LLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
      LOKALBOT_LLM_MODEL: "stub-model", LOKALBOT_LLM_CTX: "16384",
      LOKALBOT_LLM_API: options.api ?? "openai-completions" },
  });
  const send = (message: unknown) => { proc.stdin.write(JSON.stringify(message) + "\n"); proc.stdin.flush(); };
  const stderr = new Response(proc.stderr).text();
  const approvals: any[] = [];
  let reply = false;
  const timeout = setTimeout(() => proc.kill(), 20_000);
  try {
    send({ type: "prompt", id: "test", message: "Run the requested tool." });
    let pending = "";
    const decoder = new TextDecoder();
    outer: for await (const bytes of proc.stdout) {
      pending += decoder.decode(bytes, { stream: true });
      let newline: number;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        if (!line.trim()) continue;
        const event = JSON.parse(line);
        if (event.type === "extension_error") throw new Error(JSON.stringify(event));
        if (event.type === "response" && !event.success) throw new Error(event.error);
        if (event.type === "extension_ui_request" && event.method === "confirm") {
          expect(event.title).toBe("lokalbot_tool_approval");
          const payload = JSON.parse(event.message);
          approvals.push(payload);
          await options.beforeAnswer?.(payload);
          send({ type: "extension_ui_response", id: event.id, confirmed: options.approved });
        }
        if (event.type === "message_end" && event.message.role === "assistant") {
          reply ||= event.message.content.some((part: any) => part.text === "STUB-REPLY");
        }
        if (event.type === "agent_end") break outer;
      }
    }
    return { approvals, reply, requests };
  } finally {
    clearTimeout(timeout);
    proc.kill();
    await proc.exited;
    const errors = await stderr;
    if (errors.trim()) console.error(errors);
    server.stop(true);
  }
}

for (const approved of [false, true]) {
  test.skipIf(!runtime)(`Pi requires approval before writing; confirmed=${approved}`, async () => {
    const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-upgrade-"));
    const output = join(workspace, "approved.txt");
    try {
      const turn = await piTurn({
        workspace, approved,
        toolCall: { name: "write", arguments: { path: output, content: "approved content" } },
        beforeAnswer: async () => { expect(await stat(output).catch(() => null)).toBeNull(); },
      });
      expect(turn.approvals).toHaveLength(1);
      expect(turn.reply).toBe(true);
      expect(turn.requests).toHaveLength(2);
      if (approved) expect(await readFile(output, "utf8")).toBe("approved content");
      else expect(await stat(output).catch(() => null)).toBeNull();
    } finally {
      await rm(workspace, { recursive: true, force: true });
    }
  }, 25_000);
}

// Pi's MCP client is a built-in extension that Agent Mode's --no-extensions
// leaves off. Loading it explicitly proves its tools still pass the gate.
const STUB_MCP_SERVER = String.raw`
import { writeFileSync } from "node:fs";
let pending = "";
const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  pending += chunk;
  let newline;
  while ((newline = pending.indexOf("\n")) !== -1) {
    const line = pending.slice(0, newline).trim();
    pending = pending.slice(newline + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    if (message.id === undefined) continue;
    if (message.method === "initialize") send({ id: message.id, result: {
      protocolVersion: message.params.protocolVersion, capabilities: { tools: {} },
      serverInfo: { name: "stub", version: "1.0.0" } } });
    else if (message.method === "tools/list") send({ id: message.id, result: { tools: [{ name: "touch",
      description: "Create a file.", inputSchema: { type: "object", properties: { path: { type: "string" } } } }] } });
    else if (message.method === "tools/call") {
      writeFileSync(message.params.arguments.path, "touched by MCP");
      send({ id: message.id, result: { content: [{ type: "text", text: "done" }] } });
    } else send({ id: message.id, error: { code: -32601, message: "method not found" } });
  }
});
`;

for (const approved of [false, true]) {
  test.skipIf(!runtime)(`an MCP tool call requires approval; confirmed=${approved}`, async () => {
    const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-mcp-"));
    const output = join(workspace, "touched.txt");
    const piConfig = join(workspace, "pi-config");
    try {
      await mkdir(piConfig);
      await writeFile(join(workspace, "stub-mcp.js"), STUB_MCP_SERVER);
      await writeFile(join(piConfig, "mcp.json"), JSON.stringify({ mcpServers: { stub: {
        command: join(runtime!, "bun/bun"), args: [join(workspace, "stub-mcp.js")], exposure: "direct",
      } } }));
      const turn = await piTurn({
        workspace, approved, piConfig, extensions: ["builtin:mcp"],
        toolCall: { name: "mcp__stub__touch", arguments: { path: output } },
        beforeAnswer: async () => { expect(await stat(output).catch(() => null)).toBeNull(); },
      });
      expect(turn.requests[0].tools.map((tool: any) => tool.function.name)).toContain("mcp__stub__touch");
      expect(turn.approvals).toHaveLength(1);
      expect(turn.approvals[0].tool).toBe("mcp__stub__touch");
      expect(JSON.parse(turn.approvals[0].arguments)).toEqual({ path: output });
      expect(turn.reply).toBe(true);
      if (approved) expect(await readFile(output, "utf8")).toBe("touched by MCP");
      else expect(await stat(output).catch(() => null)).toBeNull();
    } finally {
      await rm(workspace, { recursive: true, force: true });
    }
  }, 25_000);
}

test.skipIf(!runtime)("Pi asks before an @ path reads outside the workspace or the private library", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-pi-read-")));
  const workspace = join(root, "workspace");
  const library = join(workspace, "library");
  const home = join(root, "home");
  try {
    await mkdir(library, { recursive: true });
    await mkdir(join(home, ".ssh"), { recursive: true });
    await writeFile(join(home, ".ssh", "id_rsa"), "SYNTHETIC-KEY");
    await writeFile(join(root, "outside.txt"), "SYNTHETIC-OUTSIDE");
    await writeFile(join(library, "transcript.txt"), "SYNTHETIC-TRANSCRIPT");
    for (const [path, file, secret] of [
      ["@~/.ssh/id_rsa", join(home, ".ssh", "id_rsa"), "SYNTHETIC-KEY"],
      ["@" + join(root, "outside.txt"), join(root, "outside.txt"), "SYNTHETIC-OUTSIDE"],
      ["@library/transcript.txt", join(library, "transcript.txt"), "SYNTHETIC-TRANSCRIPT"],
    ]) {
      const turn = await piTurn({ workspace, home, privateRoots: [library], approved: false,
        toolCall: { name: "read", arguments: { path } } });
      expect(turn.approvals.map(approval => approval.path)).toEqual([file]);
      expect(turn.reply).toBe(true);
      expect(JSON.stringify(turn.requests)).not.toContain(secret);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 75_000);

test.skipIf(!runtime)("Pi keeps no compiled copies of itself or the extension outside the runtime", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-pi-cache-")));
  const workspace = join(root, "workspace");
  const home = join(root, "home");
  const tmp = join(root, "tmp");
  try {
    await mkdir(workspace); await mkdir(home); await mkdir(tmp);
    await writeFile(join(workspace, "notes.txt"), "synthetic notes");
    const turn = await piTurn({ workspace, home, tmp, approved: true,
      toolCall: { name: "read", arguments: { path: "notes.txt" } } });
    expect(turn.approvals).toHaveLength(0);
    expect(turn.reply).toBe(true);
    // Otherwise Bun's transpiler cache is written to ~/Library/Caches/bun, and
    // pi's compile cache and jiti's extension cache to the temporary folder.
    expect(await readdir(home)).toEqual([]);
    expect(await readdir(tmp)).toEqual([]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 25_000);

const systemPromptFile = join(repo, "LokalBot/Resources/pi/system-prompt.md");
const promptArguments = [
  "--skill", join(repo, "LokalBot/Resources/pi/lokalbot-cli-skill"), "--system-prompt", systemPromptFile,
];

test("the environment section names the day, the working folder and the model", () => {
  const now = new Date(2026, 9, 22, 23, 59);
  const local = environmentSection(now, "agent-workspace", "qwen3.5-4b", new URL("http://127.0.0.1:17872/v1"), true);
  expect(local).toStartWith("Today is Thursday, 2026-10-22 (");
  expect(local).toContain("The working folder is the Agent Workspace");
  expect(local).toEndWith("You run on the model qwen3.5-4b, served on this computer.");
  const remote = environmentSection(
    new Date(2027, 0, 3, 0, 0), "chosen-folder", "claude-opus-5-5", new URL("https://api.anthropic.com/v1"), false);
  expect(remote).toStartWith("Today is Sunday, 2027-01-03 (");
  expect(remote).toContain("The working folder is one the user chose for this task.");
  expect(remote).toEndWith("served by api.anthropic.com.");
  const relayed = environmentSection(now, "agent-workspace", "gpt-6.1-sol", new URL("http://127.0.0.1:5123/v1"), true,
    "OpenAI on the user's ChatGPT plan");
  expect(relayed).toEndWith("You run on the model gpt-6.1-sol, served by OpenAI on the user's ChatGPT plan.");
  // Launched without a kind (an older host): say nothing about the folder.
  expect(environmentSection(now, undefined, "m", new URL("http://127.0.0.1/v1"), true)).not.toContain("working folder");
});

test.skipIf(!runtime)("Pi sends LokalBot's prompt, skill and environment instead of its coding prompt", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-pi-prompt-")));
  try {
    await writeFile(join(workspace, "notes.txt"), "synthetic notes");
    const turn = await piTurn({ workspace, approved: true,
      toolCall: { name: "read", arguments: { path: "notes.txt" } },
      launchArguments: promptArguments,
      environment: { LOKALBOT_AGENT_WORKSPACE_KIND: "agent-workspace" } });
    expect(turn.reply).toBe(true);
    const prompt = (await readFile(systemPromptFile, "utf8")).trimEnd();
    for (const request of turn.requests) {
      const systems = request.messages.filter((message: any) => message.role === "system");
      expect(systems).toHaveLength(1);
      expect(request.messages[0]).toBe(systems[0]);
      const text: string = systems[0].content;
      expect(text.startsWith(prompt)).toBe(true);
      expect(text).not.toContain("coding agent harness");
      expect(text).not.toContain("Pi documentation");
      expect(text).toContain("<name>lokalbot-library</name>");
      expect(text).toContain(`<cwd>\n${workspace}\n</cwd>`);
      expect(text).toMatch(/<environment>\nToday is [A-Z][a-z]+day, \d{4}-\d\d-\d\d \(/);
      expect(text).toContain("The working folder is the Agent Workspace");
      expect(text).toEndWith("You run on the model stub-model, served on this computer.\n</environment>");
    }
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}, 25_000);

test.skipIf(!runtime)("a task saved with Pi's coding prompt resumes with LokalBot's prompt as its only system message", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-pi-prompt-resume-")));
  try {
    await writeFile(join(workspace, "notes.txt"), "synthetic notes");
    const toolCall = { name: "read", arguments: { path: "notes.txt" } };
    const before = await piTurn({ workspace, approved: true, toolCall });
    expect(before.requests[0].messages[0].content).toContain("Pi documentation");
    const after = await piTurn({ workspace, approved: true, toolCall,
      launchArguments: ["--continue", ...promptArguments],
      environment: { LOKALBOT_AGENT_WORKSPACE_KIND: "chosen-folder" } });
    expect(after.reply).toBe(true);
    const request = after.requests[0];
    // Small local models' chat templates reject a system message after the
    // first; Pi folds the changed prompt into the leading one instead.
    expect(request.messages.filter((message: any) => message.role === "system")).toHaveLength(1);
    expect(request.messages[0].role).toBe("system");
    const text: string = request.messages[0].content;
    expect(text.startsWith((await readFile(systemPromptFile, "utf8")).trimEnd())).toBe(true);
    expect(text).not.toContain("Pi documentation");
    expect(text).toContain("The working folder is one the user chose for this task.");
    expect(JSON.stringify(request.messages)).toContain("synthetic notes");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}, 50_000);

test("Pi resumes append-only context edits without overwriting visible history", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-context-upgrade-"));
  try {
    const sessions = join(workspace, "sessions");
    const manager = SessionManager.create(workspace, sessions);
    const original = manager.appendMessage({ role: "user", content: "Original synthetic context", timestamp: 1 });
    manager.appendContextEdit(original, { content: "Condensed synthetic context" });
    manager.appendMessage({ role: "user", content: "Continue the task", timestamp: 2 });
    const file = manager.getSessionFile();
    expect(file).toBeDefined();
    const resumed = SessionManager.open(file!, sessions);
    expect(resumed.buildSessionContext().messages.map(message => message.content))
      .toEqual(["Condensed synthetic context", "Continue the task"]);
    expect(await readFile(file!, "utf8")).toContain("Original synthetic context");
    expect(resumed.getEntries().some(entry => entry.type === "context_edit")).toBe(true);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("a reasoning level becomes each server's own request fields", () => {
  const base = { model: "m", max_completion_tokens: 2_000 };
  expect(applyReasoningLevel(base, "automatic", "generic", "m")).toBe(base);
  expect(applyReasoningLevel(base, "off", "generic", "qwen-3.8-27b").reasoning_effort).toBe("none");
  expect(applyReasoningLevel(base, "xhigh", "openai", "gpt-5.4-mini").reasoning_effort).toBe("xhigh");
  expect(applyReasoningLevel(base, "high", "openai", "gpt-4.1").reasoning_effort).toBeUndefined();
  expect(applyReasoningLevel(base, "max", "openrouter", "z-ai/glm-5.3-flash").reasoning).toEqual({ effort: "max" });
  expect(applyReasoningLevel(base, "high", "ollama", "gpt-oss:20b").reasoning_effort).toBe("high");
  expect(applyReasoningLevel(base, "off", "ollama", "qwen3:8b").reasoning_effort).toBe("none");
  expect(applyReasoningLevel(base, "high", "ollama", "qwen3:8b").reasoning_effort).toBeUndefined();
  const medium = applyReasoningLevel(base, "medium", "llama-server", "qwen3.5-4b");
  expect(medium.thinking_budget_tokens).toBe(1_000);
  expect(medium.reasoning_effort).toBeUndefined();
  const off = applyReasoningLevel({ ...base, chat_template_kwargs: { keep: 1 } }, "off", "llama-server", "q");
  expect(off.thinking_budget_tokens).toBe(0);
  expect(off.chat_template_kwargs).toEqual({ keep: 1, enable_thinking: false });
});

test("the level file is read fresh and anything unreadable is Automatic", async () => {
  const root = await mkdtemp(join(tmpdir(), "lokalbot-reasoning-"));
  try {
    const file = join(root, "level.json");
    expect(readReasoningLevel(undefined)).toBe("automatic");
    expect(readReasoningLevel(file)).toBe("automatic");
    await writeFile(file, JSON.stringify({ level: "low" }));
    expect(readReasoningLevel(file)).toBe("low");
    await writeFile(file, JSON.stringify({ level: "extreme" }));
    expect(readReasoningLevel(file)).toBe("automatic");
    await writeFile(file, "not json");
    expect(readReasoningLevel(file)).toBe("automatic");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("a rejected reasoning level is retried once without blocking the request", async () => {
  const bodies: any[] = [];
  const reply = (status: number, text: string) => new Response(text, { status });
  const replies = [reply(400, "reasoning_effort 'none' is not supported"), reply(200, "ok")];
  const fetchOnce = retryRejectedReasoning((async (_input: any, init: any) => {
    bodies.push(JSON.parse(init.body)); return replies.shift()!;
  }) as typeof fetch);
  expect((await fetchOnce("https://x/v1/chat/completions", {
    method: "POST", body: JSON.stringify({ model: "gpt-oss-120b", reasoning_effort: "none" }),
  })).status).toBe(200);
  expect(bodies.map((body) => body.reasoning_effort)).toEqual(["none", "low"]);

  bodies.length = 0;
  replies.push(reply(422, "unknown field reasoning"), reply(200, "ok"));
  await fetchOnce("https://x/v1", { method: "POST", body: JSON.stringify({ reasoning: { effort: "high" } }) });
  expect(bodies[1].reasoning).toBeUndefined();

  bodies.length = 0;
  replies.push(reply(400, "context length exceeded"));
  expect((await fetchOnce("https://x/v1", {
    method: "POST", body: JSON.stringify({ reasoning_effort: "low" }),
  })).status).toBe(400);
  expect(bodies).toHaveLength(1);
});

test("the registered provider sends the level LokalBot writes, and follows a change", async () => {
  const bodies: any[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      bodies.push(await request.json());
      const chunk = (delta: object, finish: string | null) =>
        `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 0, model: "fixture",
          choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
      return new Response(chunk({ role: "assistant", content: "ok" }, null) + chunk({}, "stop") + "data: [DONE]\n\n",
        { headers: { "content-type": "text/event-stream" } });
    },
  });
  const root = await mkdtemp(join(tmpdir(), "lokalbot-reasoning-"));
  const file = join(root, "level.json");
  try {
    const baseUrl = `http://127.0.0.1:${server.port}/v1`;
    await withExtensionFixture(async ({ provider }) => {
      const model = { ...provider.models[0], provider: "lokalbot", api: provider.api,
        baseUrl, maxTokens: 128, name: "Fixture", reasoning: false };
      const ask = async () => {
        const stream = provider.streamSimple(model, {
          messages: [{ role: "user", content: "hi", timestamp: Date.now() }],
        }, { apiKey: "synthetic-token", maxRetries: 0, timeoutMs: 2_000 });
        for await (const _ of stream) {}
      };
      await ask();
      await writeFile(file, JSON.stringify({ level: "low" }));
      await ask();
      await writeFile(file, JSON.stringify({ level: "off" }));
      await ask();
    }, baseUrl, { LOKALBOT_LLM_REASONING_DIALECT: "generic", LOKALBOT_LLM_REASONING_FILE: file });
    expect(bodies.map((body) => body.reasoning_effort)).toEqual([undefined, "low", "none"]);
    expect(bodies[0].messages[0].role).not.toBe("developer");
  } finally {
    server.stop(true);
    await rm(root, { recursive: true, force: true });
  }
});

test("the provider speaks the Responses API only when LokalBot asks for it", async () => {
  await withExtensionFixture(async ({ provider }) => {
    expect(provider.api).toBe("openai-completions");
    expect(provider.models[0].reasoning).toBeUndefined();
  });
  await withExtensionFixture(async ({ provider }) => {
    expect(provider.api).toBe("openai-responses");
    // Instructions go out as a developer message, and no output cap.
    expect(provider.models[0].reasoning).toBe(true);
    expect(provider.models[0].compat.supportsMaxOutputTokens).toBe(false);
  }, undefined, { LOKALBOT_LLM_API: "openai-responses" });
  expect(providerAPI(undefined)).toBe("openai-completions");
  expect(() => providerAPI("anthropic-messages")).toThrow("Invalid model API");
});

test("the Responses API takes a level as reasoning.effort", () => {
  const base = { model: "gpt-6.1-sol", reasoning: { effort: "medium", summary: "auto" } };
  expect(applyResponsesReasoningLevel(base, "automatic")).toBe(base);
  expect(applyResponsesReasoningLevel(base, "high").reasoning).toEqual({ effort: "high", summary: "auto" });
  expect(applyResponsesReasoningLevel(base, "off").reasoning).toEqual({ effort: "none", summary: "auto" });
  expect(applyResponsesReasoningLevel({ model: "m" }, "low").reasoning).toEqual({ effort: "low" });
});

test("the Responses provider sends developer instructions and LokalBot's level, without an output cap", async () => {
  const bodies: any[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      expect(new URL(request.url).pathname).toBe("/v1/responses");
      expect(request.headers.get("authorization")).toBe("Bearer synthetic-token");
      bodies.push(await request.json());
      return new Response(responsesStream([{ type: "message", id: "msg-test", role: "assistant", status: "completed",
        content: [{ type: "output_text", text: "ok", annotations: [] }] }]),
      { headers: { "content-type": "text/event-stream" } });
    },
  });
  const root = await mkdtemp(join(tmpdir(), "lokalbot-responses-"));
  const file = join(root, "level.json");
  try {
    await writeFile(file, JSON.stringify({ level: "high" }));
    const baseUrl = `http://127.0.0.1:${server.port}/v1`;
    await withExtensionFixture(async ({ provider }) => {
      const model = { ...provider.models[0], provider: "lokalbot", api: provider.api,
        baseUrl, maxTokens: 128, name: "Fixture" };
      const stream = provider.streamSimple(model, { messages: [
        { role: "system", content: "Synthetic instructions.", timestamp: 0 },
        { role: "user", content: "hi", timestamp: Date.now() },
      ] }, { apiKey: "synthetic-token", maxRetries: 0, timeoutMs: 2_000, reasoning: "medium" });
      const events: any[] = [];
      for await (const event of stream) events.push(event);
      expect(events.at(-1)?.type).toBe("done");
    }, baseUrl, { LOKALBOT_LLM_API: "openai-responses", LOKALBOT_LLM_REASONING_FILE: file });
    expect(bodies).toHaveLength(1);
    expect(bodies[0].input[0]).toEqual({ role: "developer", content: "Synthetic instructions." });
    expect(bodies[0].reasoning.effort).toBe("high");
    expect(bodies[0].include).toEqual(["reasoning.encrypted_content"]);
    expect(bodies[0].max_output_tokens).toBeUndefined();
    expect(bodies[0].store).toBe(false);
  } finally {
    server.stop(true);
    await rm(root, { recursive: true, force: true });
  }
});

test.skipIf(!runtime)("Pi runs a tool turn over the Responses API, as the ChatGPT plan relay serves it", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "lokalbot-pi-responses-")));
  try {
    await writeFile(join(workspace, "notes.txt"), "synthetic notes");
    const turn = await piTurn({ workspace, approved: true, api: "openai-responses",
      toolCall: { name: "read", arguments: { path: "notes.txt" } } });
    expect(turn.reply).toBe(true);
    expect(turn.approvals).toHaveLength(0);
    expect(turn.requests).toHaveLength(2);
    const [first, second] = turn.requests;
    expect(first.store).toBe(false);
    expect(first.max_output_tokens).toBeUndefined();
    expect(first.input[0].role).toBe("developer");
    expect(first.tools.map((tool: any) => tool.name)).toContain("read");
    // store: false keeps nothing on OpenAI's side, so pi replays the
    // encrypted reasoning with the call and its output.
    expect(second.input).toContainEqual(expect.objectContaining({
      type: "reasoning", encrypted_content: "SYNTHETIC-ENCRYPTED" }));
    expect(second.input).toContainEqual(expect.objectContaining({ type: "function_call", call_id: "call-test" }));
    const output = second.input.find((item: any) => item.type === "function_call_output");
    expect(output.call_id).toBe("call-test");
    expect(JSON.stringify(output.output)).toContain("synthetic notes");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}, 25_000);
