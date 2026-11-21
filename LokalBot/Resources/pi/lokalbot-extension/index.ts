import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { openAICompletionsApi, openAIResponsesApi } from "@earendil-works/pi-ai/compat";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const PREVIEWED_TOOLS = new Set(["read", "write", "edit", "bash"]);
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
const REASONING_DIALECTS = ["llama-server", "openai", "openrouter", "ollama", "generic"] as const;
type ReasoningDialect = typeof REASONING_DIALECTS[number];
const PROVIDER_APIS = ["openai-completions", "openai-responses"] as const;
type ProviderAPI = typeof PROVIDER_APIS[number];
const RESPONSES_MODEL_TRAITS = { reasoning: true, compat: { supportsMaxOutputTokens: false } } as const;
const REASONING_LEVELS = ["automatic", "off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type ReasoningLevel = typeof REASONING_LEVELS[number];
const THINKING_BUDGETS: Record<Exclude<ReasoningLevel, "automatic">, number> = {
  off: 0, minimal: 256, low: 512, medium: 4096, high: 8192, xhigh: 16384, max: 24576,
};
const MAX_APPROVAL_TEXT = 64 * 1024;
const API_KEY = Symbol.for("lokalbot.llmApiKey");

export function takeProviderAPIKey(): string {
  const store = globalThis as unknown as Record<symbol, string | undefined>;
  store[API_KEY] ??= process.env.LOKALBOT_LLM_API_KEY;
  delete process.env.LOKALBOT_LLM_API_KEY;
  return store[API_KEY] ?? "lokalbot";
}

export default function lokalbotExtension(pi: ExtensionAPI) {
  const protectedRoots = privateRoots();
  const apiKey = takeProviderAPIKey();
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
  const dialect = reasoningDialect(process.env.LOKALBOT_LLM_REASONING_DIALECT);
  const api = providerAPI(process.env.LOKALBOT_LLM_API);
  const servedBy = process.env.LOKALBOT_LLM_SERVED_BY || undefined;
  const reasoningFile = process.env.LOKALBOT_LLM_REASONING_FILE;
  const streams = api === "openai-responses" ? openAIResponsesApi() : openAICompletionsApi();
  const inferenceFetch = retryRejectedReasoning(inferenceFetchForOrigin(endpoint));

  pi.registerProvider("lokalbot", {
    baseUrl,
    api,
    streamSimple: (selectedModel, context, options) => streams.streamSimple(
      selectedModel, context, {
        ...options,
        fetch: inferenceFetch,
        onPayload: async (payload, payloadModel) => {
          const upstream = (await options?.onPayload?.(payload, payloadModel)) ?? payload;
          const level = readReasoningLevel(reasoningFile);
          return api === "openai-responses"
            ? applyResponsesReasoningLevel(upstream as Record<string, unknown>, level)
            : applyReasoningLevel(upstream as Record<string, unknown>, level, dialect, model);
        },
      },
    ),
    apiKey,
    models: [
      {
        id: model,
        contextWindow,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        ...(api === "openai-responses" ? RESPONSES_MODEL_TRAITS : {}),
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash") {
      const command = (event.input as Record<string, unknown> | undefined)?.command;
      if (typeof command !== "string" || command.length > MAX_APPROVAL_TEXT) {
        return { block: true, reason: "The shell command cannot be reviewed in full. Keep each command within 65,536 characters; this request was not run." };
      }
    }
    if (!PREVIEWED_TOOLS.has(event.toolName)) {
      const args = argumentsText(event.input);
      if (args === undefined || args.length > MAX_APPROVAL_TEXT) {
        return { block: true, reason: `The ${event.toolName} request cannot be reviewed in full. Keep its arguments within 65,536 characters; this request was not run.` };
      }
    }
    const toolCwd = ctx.cwd || process.cwd();
    if (!requiresApproval(event.toolName, event.input, protectedRoots, toolCwd)) return undefined;

    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify(approvalPayload(event.toolName, event.input, toolCwd)),
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

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.environment = environmentSection(
      new Date(), process.env.LOKALBOT_AGENT_WORKSPACE_KIND, model, endpoint, loopback, servedBy);
  });
}

export function environmentSection(
  now: Date,
  workspaceKind: string | undefined,
  model: string,
  endpoint: URL,
  local: boolean,
  servedBy?: string,
): string {
  const day = [now.getFullYear(), now.getMonth() + 1, now.getDate()]
    .map((part) => String(part).padStart(2, "0")).join("-");
  const weekday = now.toLocaleDateString("en-US", { weekday: "long" });
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const lines = [`Today is ${weekday}, ${day} (${zone}). Run \`date\` for the exact time.`];
  if (workspaceKind === "agent-workspace") {
    lines.push("The working folder is the Agent Workspace, a folder LokalBot keeps for these tasks. The user's own documents are elsewhere.");
  } else if (workspaceKind === "chosen-folder") {
    lines.push("The working folder is one the user chose for this task.");
  }
  const server = servedBy ? `by ${servedBy}` : local ? "on this computer" : `by ${endpoint.host}`;
  lines.push(`You run on the model ${model}, served ${server}.`);
  return lines.join("\n");
}

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

export function providerAPI(value: string | undefined): ProviderAPI {
  if (value === undefined || value === "") return "openai-completions";
  if (!(PROVIDER_APIS as readonly string[]).includes(value)) {
    throw new Error("Invalid model API in the LokalBot launch configuration");
  }
  return value as ProviderAPI;
}

export function reasoningDialect(value: string | undefined): ReasoningDialect {
  if (value === undefined || value === "") return "generic";
  if (!(REASONING_DIALECTS as readonly string[]).includes(value)) {
    throw new Error("Invalid reasoning dialect in the LokalBot launch configuration");
  }
  return value as ReasoningDialect;
}

export function readReasoningLevel(path: string | undefined): ReasoningLevel {
  if (!path) return "automatic";
  try {
    const level = (JSON.parse(readFileSync(path, "utf8")) as { level?: unknown }).level;
    return (REASONING_LEVELS as readonly unknown[]).includes(level) ? level as ReasoningLevel : "automatic";
  } catch {
    return "automatic";
  }
}

export function applyReasoningLevel(
  payload: Record<string, unknown>,
  level: ReasoningLevel,
  dialect: ReasoningDialect,
  model: string,
): Record<string, unknown> {
  if (level === "automatic") return payload;
  const effort = level === "off" ? "none" : level;
  switch (dialect) {
    case "llama-server": {
      const ceiling = payload.max_tokens ?? payload.max_completion_tokens;
      const budget = typeof ceiling === "number"
        ? Math.min(THINKING_BUDGETS[level], Math.floor(ceiling / 2))
        : THINKING_BUDGETS[level];
      const shaped: Record<string, unknown> = { ...payload, thinking_budget_tokens: budget };
      if (budget === 0) {
        const kwargs = (payload.chat_template_kwargs ?? {}) as Record<string, unknown>;
        shaped.chat_template_kwargs = { ...kwargs, enable_thinking: false };
      }
      return shaped;
    }
    case "openai":
      return /^(o1|o3|o4|gpt-5)/i.test(model) ? { ...payload, reasoning_effort: effort } : payload;
    case "openrouter":
      return { ...payload, reasoning: { effort } };
    case "ollama":
      return level === "off" || /gpt-oss/i.test(model) ? { ...payload, reasoning_effort: effort } : payload;
    case "generic":
      return { ...payload, reasoning_effort: effort };
  }
}

export function applyResponsesReasoningLevel(
  payload: Record<string, unknown>,
  level: ReasoningLevel,
): Record<string, unknown> {
  if (level === "automatic") return payload;
  const reasoning = (payload.reasoning ?? {}) as Record<string, unknown>;
  return { ...payload, reasoning: { ...reasoning, effort: level === "off" ? "none" : level } };
}

export function retryRejectedReasoning(implementation: typeof globalThis.fetch) {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const response = await implementation(input, init);
    if ((response.status !== 400 && response.status !== 422) || typeof init?.body !== "string") {
      return response;
    }
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(init.body) as Record<string, unknown>;
    } catch {
      return response;
    }
    const nested = body.reasoning as Record<string, unknown> | undefined;
    const effort = body.reasoning_effort ?? nested?.effort;
    if (typeof effort !== "string") return response;
    if (!/reasoning/i.test(await response.clone().text())) return response;
    const retried = { ...body };
    if (effort === "none") {
      if (body.reasoning_effort !== undefined) retried.reasoning_effort = "low";
      else retried.reasoning = { ...nested, effort: "low" };
    } else {
      delete retried.reasoning_effort;
      delete retried.reasoning;
    }
    return implementation(input, { ...init, body: JSON.stringify(retried) });
  };
}

function isIPv4Loopback(hostname: string): boolean {
  const octets = hostname.split(".");
  return octets.length === 4
    && octets.every((octet) => /^\d{1,3}$/.test(octet) && Number(octet) <= 255)
    && Number(octets[0]) === 127;
}

function normalizeToolPath(input: string, forTool: boolean): string {
  let normalized = input;
  if (forTool) {
    normalized = normalized.replace(UNICODE_SPACES, " ");
    if (normalized.startsWith("@")) normalized = normalized.slice(1);
  }
  const home = homedir();
  if (normalized === "~") return home;
  if (normalized.startsWith("~/")) return join(home, normalized.slice(2));
  if (/^file:\/\//.test(normalized)) return fileURLToPath(normalized);
  return normalized;
}

export function resolveToCwd(path: string, cwd: string): string {
  const normalized = normalizeToolPath(path, true);
  return isAbsolute(normalized)
    ? resolve(normalized)
    : resolve(normalizeToolPath(cwd, false), normalized);
}

export function resolveReadPath(path: string, cwd: string): string {
  const resolved = resolveToCwd(path, cwd);
  if (existsSync(resolved)) return resolved;
  const amPm = resolved.replace(/ (AM|PM)\./gi, "\u202F$1.");
  if (amPm !== resolved && existsSync(amPm)) return amPm;
  const nfd = resolved.normalize("NFD");
  if (nfd !== resolved && existsSync(nfd)) return nfd;
  const curly = resolved.replace(/'/g, "\u2019");
  if (curly !== resolved && existsSync(curly)) return curly;
  const nfdCurly = nfd.replace(/'/g, "\u2019");
  if (nfdCurly !== resolved && existsSync(nfdCurly)) return nfdCurly;
  return resolved;
}

function requestedPath(value: unknown, toolName: string, cwd: string): string | undefined {
  if (typeof value !== "string" || !value || value.includes("\0")) return undefined;
  try {
    return toolName === "read" ? resolveReadPath(value, cwd) : resolveToCwd(value, cwd);
  } catch {
    return undefined;
  }
}

function entryExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

function canonicalPath(value: unknown, toolName: string, cwd: string): string | undefined {
  const requested = requestedPath(value, toolName, cwd);
  return requested === undefined ? undefined : canonicalize(requested);
}

function canonicalize(requested: string): string | undefined {
  try {
    return realpathSync(requested);
  } catch {
    let ancestor = requested;
    const suffix: string[] = [];
    while (!entryExists(ancestor)) {
      const parent = dirname(ancestor);
      if (parent === ancestor) return undefined;
      suffix.unshift(basename(ancestor));
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
  return child === "" || (child !== ".." && !child.startsWith(`..${sep}`) && !isAbsolute(child));
}

function privateRoots(): string[] {
  const value: unknown = JSON.parse(process.env.LOKALBOT_AGENT_PRIVATE_ROOTS ?? "[]");
  if (!Array.isArray(value) || value.some((root) => typeof root !== "string" || !isAbsolute(root))) {
    throw new Error("Invalid private-library roots in the LokalBot launch configuration");
  }
  return value.map((root) => {
    const path = canonicalize(resolve(root));
    if (!path) throw new Error("Could not resolve a private-library root");
    return path;
  });
}

function requiresApproval(toolName: string, input: unknown, protectedRoots: string[], cwd: string): boolean {
  if (toolName !== "read") return true;
  const args = (input ?? {}) as Record<string, unknown>;
  const path = canonicalPath(args.path ?? args.file_path, "read", cwd);
  return !path || protectedRoots.some((root) => isInside(path, root))
    || !isInside(path, realpathSync(process.cwd()));
}

function argumentsText(input: unknown): string | undefined {
  try {
    return JSON.stringify(input ?? {}, null, 2);
  } catch {
    return undefined;
  }
}

function boundedText(value: unknown): { text: string; truncated: boolean } {
  const text = String(value ?? "");
  if (text.length <= MAX_APPROVAL_TEXT) return { text, truncated: false };
  return { text: text.slice(0, MAX_APPROVAL_TEXT), truncated: true };
}

function approvalPayload(toolName: string, input: unknown, cwd: string): Record<string, unknown> {
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
      payload.path = canonicalPath(args.path ?? args.file_path, toolName, cwd)
        ?? requestedPath(args.path ?? args.file_path, toolName, cwd);
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
      payload.path = canonicalPath(args.path ?? args.file_path, toolName, cwd)
        ?? requestedPath(args.path ?? args.file_path, toolName, cwd);
      payload.edits = edits.slice(0, 100);
      payload.truncated = wasTruncated || edits.length > 100;
      break;
    }
    case "read": {
      payload.path = canonicalPath(args.path ?? args.file_path, toolName, cwd)
        ?? requestedPath(args.path ?? args.file_path, toolName, cwd);
      break;
    }
    default:
      payload.arguments = argumentsText(input);
  }
  return payload;
}
