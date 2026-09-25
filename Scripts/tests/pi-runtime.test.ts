// Run against a checksum-pinned, frozen-lockfile runtime:
// LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/runtime bash Scripts/tests/run-pi-runtime-tests.sh
import { expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import lokalbotExtension, { inferenceFetchForOrigin } from "../../LokalBot/Resources/pi/lokalbot-extension/index";

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
  call: (toolName: string, input: unknown) => Promise<any>;
  approvals: any[];
  provider: any;
}) => Promise<void>, baseUrl = "http://127.0.0.1:1234/v1") {
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
    let handler: any;
    let provider: any;
    lokalbotExtension({ registerProvider(_name: string, config: any) { provider = config; }, on(name: string, callback: any) {
      if (name === "tool_call") handler = callback;
    } } as any);
    const approvals: any[] = [];
    const call = (toolName: string, input: unknown) => handler({ toolName, input }, {
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

for (const approved of [false, true]) {
  test.skipIf(!runtime)(`Pi requires approval before writing; confirmed=${approved}`, async () => {
    const workspace = await mkdtemp(join(tmpdir(), "lokalbot-pi-upgrade-"));
    const output = join(workspace, "approved.txt");
    const requests: any[] = [];
    const server = Bun.serve({
      hostname: "127.0.0.1", port: 0,
      async fetch(req) {
        expect(new URL(req.url).pathname).toBe("/v1/chat/completions");
        const body = await req.json();
        requests.push(body);
        const toolResult = body.messages.find((message: any) => message.role === "tool");
        const delta = toolResult ? { content: "STUB-REPLY" } : {
          tool_calls: [{ index: 0, id: "write-test", type: "function", function: {
            name: "write", arguments: JSON.stringify({ path: output, content: "approved content" }),
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
      join(runtime!, "pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"),
      "--mode", "rpc", "--provider", "lokalbot", "--model", "stub-model",
      "--no-extensions", "-e", join(repo, "LokalBot/Resources/pi/lokalbot-extension"),
      "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve",
      "--session-dir", join(workspace, "sessions"), "--offline",
    ], {
      cwd: workspace, stdin: "pipe", stdout: "pipe", stderr: "pipe",
      env: { PATH: process.env.PATH, HOME: workspace,
        PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
        PI_CODING_AGENT_DIR: join(workspace, "pi-config"),
        LOKALBOT_LLM_BASE_URL: `http://127.0.0.1:${server.port}/v1`,
        LOKALBOT_LLM_MODEL: "stub-model", LOKALBOT_LLM_CTX: "16384" },
    });
    const send = (message: unknown) => { proc.stdin.write(JSON.stringify(message) + "\n"); proc.stdin.flush(); };
    const stderr = new Response(proc.stderr).text();
    let approvals = 0;
    let reply = false;
    const timeout = setTimeout(() => proc.kill(), 20_000);
    try {
      send({ type: "prompt", id: "test", message: "Write the requested file." });
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
            approvals++;
            expect(event.title).toBe("lokalbot_tool_approval");
            expect(await stat(output).catch(() => null)).toBeNull();
            send({ type: "extension_ui_response", id: event.id, confirmed: approved });
          }
          if (event.type === "message_end" && event.message.role === "assistant") {
            reply ||= event.message.content.some((part: any) => part.text === "STUB-REPLY");
          }
          if (event.type === "agent_end") break outer;
        }
      }
      expect(approvals).toBe(1);
      expect(reply).toBe(true);
      expect(requests).toHaveLength(2);
      if (approved) expect(await readFile(output, "utf8")).toBe("approved content");
      else expect(await stat(output).catch(() => null)).toBeNull();
    } finally {
      clearTimeout(timeout);
      proc.kill();
      await proc.exited;
      const errors = await stderr;
      if (errors.trim()) console.error(errors);
      server.stop(true);
      await rm(workspace, { recursive: true, force: true });
    }
  }, 25_000);
}
