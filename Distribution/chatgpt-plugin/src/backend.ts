import { access, constants } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolResultSchema, type CallToolResult } from "@modelcontextprotocol/sdk/types.js";

// No generic tool proxy: adding a capability requires an explicit product decision.
export const LIBRARY_TOOLS = [
  "list_meetings", "search_meetings", "get_meeting",
  "get_action_items", "list_people", "get_person",
] as const;
export type LibraryTool = typeof LIBRARY_TOOLS[number];

export interface LibraryBackend {
  call(name: LibraryTool, args: Record<string, unknown>, signal?: AbortSignal): Promise<CallToolResult>;
  close(): Promise<void>;
}

export function cliEnvironment(source: NodeJS.ProcessEnv): Record<string, string> {
  const env: Record<string, string> = {};
  // In particular, never forward Agent Mode capabilities or tunnel/API credentials.
  for (const key of ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TZ", "LOKALBOT_STORAGE_ROOT"]) {
    if (source[key]) env[key] = source[key];
  }
  return env;
}

export async function connectLibrary(env: NodeJS.ProcessEnv = process.env): Promise<LibraryBackend> {
  const command = env.LOKALBOT_CLI_PATH ?? "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli";
  if (!isAbsolute(command)) throw new Error("LOKALBOT_CLI_PATH must be an absolute executable path.");
  try {
    await access(command, constants.X_OK);
  } catch {
    throw new Error("Install LokalBot in /Applications or set LOKALBOT_CLI_PATH to its embedded helper.");
  }
  const transport = new StdioClientTransport({
    command, args: ["mcp"], env: cliEnvironment(env), stderr: "ignore",
  });
  const client = new Client({ name: "lokalbot-chatgpt-plugin", version: "0.1.0" });
  try {
    await client.connect(transport, { timeout: 5_000 });
    const { tools } = await client.listTools({}, { timeout: 5_000 });
    if (LIBRARY_TOOLS.some(name => !tools.some(tool => tool.name === name))) {
      throw new Error("Update LokalBot: this helper is missing required meeting tools.");
    }
  } catch {
    await transport.close();
    throw new Error("Could not connect to LokalBot. Check the helper path and update the installed app.");
  }
  return {
    async call(name, args, signal) {
      if (!LIBRARY_TOOLS.includes(name)) throw new Error("Unsupported library tool.");
      return CallToolResultSchema.parse(await client.callTool(
        { name, arguments: args }, CallToolResultSchema, { signal, timeout: 15_000 },
      ));
    },
    close: () => client.close(),
  };
}
