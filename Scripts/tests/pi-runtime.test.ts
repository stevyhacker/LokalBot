// Run with the checksum-pinned Bun against a fresh frozen-lockfile installation:
// LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/runtime /path/to/runtime/bun/bun test Scripts/tests/pi-runtime.test.ts
import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

const runtime = process.env.LOKALBOT_PINNED_RUNTIME_ROOT;
const repo = resolve(import.meta.dir, "../..");

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
