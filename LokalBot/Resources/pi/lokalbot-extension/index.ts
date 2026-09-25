// LokalBot pi extension: registers the app-configured local LLM as a
// provider and gates mutating tools behind the host UI.
//
// Runs inside pi (RPC mode) under Bun. The env contract comes from
// PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
// extension_ui_request on stdout, answered over stdin.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { openAICompletionsApi } from "@earendil-works/pi-ai/compat";
import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { homedir } from "node:os";

const MUTATING_TOOLS = new Set(["write", "edit", "bash"]);
const MAX_APPROVAL_TEXT = 64 * 1024;

export default function lokalbotExtension(pi: ExtensionAPI) {
  const protectedRoots = privateRoots();
  const baseUrl = process.env.LOKALBOT_LLM_BASE_URL;
  const model = process.env.LOKALBOT_LLM_MODEL;
  if (!baseUrl || !model) {
    throw new Error(
      "LOKALBOT_LLM_BASE_URL and LOKALBOT_LLM_MODEL must be set (launched outside LokalBot?)",
    );
  }
  const parsedContextWindow = Number(process.env.LOKALBOT_LLM_CTX ?? "16384");
  const contextWindow = Number.isSafeInteger(parsedContextWindow)
    && parsedContextWindow >= 1024
    && parsedContextWindow <= 1_048_576
    ? parsedContextWindow
    : 16384;
  const endpoint = new URL(baseUrl);
  const loopback = endpoint.hostname === "localhost"
    || endpoint.hostname.endsWith(".localhost")
    || isIPv4Loopback(endpoint.hostname)
    || endpoint.hostname === "[::1]"
    || endpoint.hostname === "::1";
  if (!loopback && endpoint.protocol !== "https:") {
    throw new Error("Remote LokalBot LLM endpoints must use HTTPS");
  }
  const completions = openAICompletionsApi();
  const inferenceFetch = inferenceFetchForOrigin(endpoint);

  pi.registerProvider("lokalbot", {
    baseUrl,
    api: "openai-completions",
    // Pi has its own HTTP client: the host's URLSession redirect policy does
    // not cover it. Inject only this provider's supported transport hook.
    streamSimple: (selectedModel, context, options) => completions.streamSimple(
      selectedModel, context, { ...options, fetch: inferenceFetch },
    ),
    // llama.cpp ignores the key; Ollama/LM Studio may want one.
    apiKey: process.env.LOKALBOT_LLM_API_KEY ?? "lokalbot",
    models: [
      {
        id: model,
        contextWindow,
        // Required: pi's registerProvider path does NOT default `input`
        // (unlike its models.json path), and pi-ai's openai-completions
        // dereferences model.input unguarded — omitting this crashes every
        // completion with "undefined is not an object".
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    // The exact shell command must fit in the approval payload. Never ask for
    // approval of a prefix and then execute the unchanged, longer request.
    if (event.toolName === "bash") {
      const command = (event.input as Record<string, unknown> | undefined)?.command;
      if (typeof command !== "string" || command.length > MAX_APPROVAL_TEXT) {
        return { block: true, reason: "The shell command cannot be reviewed in full. Keep each command within 65,536 characters; this request was not run." };
      }
    }
    if (!requiresApproval(event.toolName, event.input, protectedRoots)) return undefined;

    // Machine-parseable payload: the host renders exact commands and file
    // changes, rather than relying on a model-authored summary.
    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify(approvalPayload(event.toolName, event.input)),
    );
    if (!approved) {
      return {
        block: true,
        reason:
          "The user denied this request in LokalBot. Nothing changed. Do not retry it or suggest changing approval settings unless the user explicitly asks.",
      };
    }
    return undefined;
  });
}

/// A launched Agent task has approval for one origin. Reject redirects before
/// the HTTP client can replay context or credentials, including same-origin
/// redirects: configure the final inference endpoint instead.
export function inferenceFetchForOrigin(endpoint: URL, implementation = globalThis.fetch) {
  if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password) {
    throw new Error("Agent inference requires an HTTP(S) endpoint without URL credentials");
  }
  const approvedOrigin = endpoint.origin;
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin !== approvedOrigin || url.username || url.password) {
      throw new Error("Agent inference request left the task's approved origin");
    }
    return implementation(input, { ...init, redirect: "error" });
  };
}

function isIPv4Loopback(hostname: string): boolean {
  const octets = hostname.split(".");
  return octets.length === 4
    && octets.every((octet) => /^\d{1,3}$/.test(octet) && Number(octet) <= 255)
    && Number(octets[0]) === 127;
}

function requestedPath(value: unknown): string | undefined {
  const path = String(value ?? "");
  if (!path) return undefined;
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
  return resolve(process.cwd(), path);
}

function canonicalPath(value: unknown): string | undefined {
  const requested = requestedPath(value);
  if (!requested) return undefined;
  try {
    return realpathSync(requested);
  } catch {
    // Canonicalize the nearest existing ancestor so a path through a symlink
    // cannot escape merely because its final component does not exist yet.
    let ancestor = requested;
    const suffix: string[] = [];
    while (!existsSync(ancestor)) {
      const parent = dirname(ancestor);
      if (parent === ancestor) return undefined;
      suffix.unshift(ancestor.slice(parent.length).replace(/^\//, ""));
      ancestor = parent;
    }
    try {
      return resolve(realpathSync(ancestor), ...suffix);
    } catch {
      return undefined;
    }
  }
}

function isInside(path: string, root: string): boolean {
  const child = relative(root, path);
  return child === "" || (child !== ".." && !child.startsWith("../") && !isAbsolute(child));
}

function privateRoots(): string[] {
  const value: unknown = JSON.parse(process.env.LOKALBOT_AGENT_PRIVATE_ROOTS ?? "[]");
  if (!Array.isArray(value) || value.some((root) => typeof root !== "string" || !isAbsolute(root))) {
    throw new Error("Invalid private-library roots in the LokalBot launch configuration");
  }
  return value.map((root) => {
    const path = canonicalPath(root);
    if (!path) throw new Error("Could not resolve a private-library root");
    return path;
  });
}

function requiresApproval(toolName: string, input: unknown, protectedRoots: string[]): boolean {
  if (MUTATING_TOOLS.has(toolName)) return true;
  if (toolName !== "read") return false;
  const args = (input ?? {}) as Record<string, unknown>;
  const path = canonicalPath(args.path ?? args.file_path);
  // Missing/unresolvable paths are never silently treated as in-workspace.
  // Choosing Home or another ancestor as a workspace does not silently make
  // the private library, server credentials, or Agent history normal files.
  return !path || protectedRoots.some((root) => isInside(path, root))
    || !isInside(path, realpathSync(process.cwd()));
}

function boundedText(value: unknown): { text: string; truncated: boolean } {
  const text = String(value ?? "");
  if (text.length <= MAX_APPROVAL_TEXT) return { text, truncated: false };
  return { text: text.slice(0, MAX_APPROVAL_TEXT), truncated: true };
}

function approvalPayload(toolName: string, input: unknown): Record<string, unknown> {
  const args = (input ?? {}) as Record<string, unknown>;
  const payload: Record<string, unknown> = {
    tool: toolName,
    workspace: process.cwd(),
    truncated: false,
  };

  switch (toolName) {
    case "bash": {
      const bounded = boundedText(args.command ?? args.cmd ?? JSON.stringify(args));
      payload.command = bounded.text;
      payload.truncated = bounded.truncated;
      break;
    }
    case "write": {
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      const bounded = boundedText(args.content);
      payload.content = bounded.text;
      payload.truncated = bounded.truncated;
      break;
    }
    case "edit": {
      let wasTruncated = false;
      const edits = Array.isArray(args.edits)
        ? args.edits.map((value) => {
            const edit = (value ?? {}) as Record<string, unknown>;
            const oldText = boundedText(edit.oldText ?? edit.old_text);
            const newText = boundedText(edit.newText ?? edit.new_text);
            wasTruncated ||= oldText.truncated || newText.truncated;
            return {
              oldText: oldText.text,
              newText: newText.text,
            };
          })
        : [];
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      payload.edits = edits.slice(0, 100);
      payload.truncated = wasTruncated || edits.length > 100;
      break;
    }
    case "read": {
      payload.path = canonicalPath(args.path ?? args.file_path) ?? requestedPath(args.path ?? args.file_path);
      break;
    }
  }
  return payload;
}
