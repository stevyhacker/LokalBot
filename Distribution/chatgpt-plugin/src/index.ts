import { readFile } from "node:fs/promises";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { connectLibrary } from "./backend.js";
import { createPlugin } from "./server.js";

try {
  const [html, icon] = await Promise.all([
    readFile(new URL("./app.html", import.meta.url), "utf8"),
    readFile(new URL("../assets/icon.svg", import.meta.url), "utf8"),
  ]);
  const backend = await connectLibrary();
  const server = createPlugin(backend, html, icon);
  const transport = new StdioServerTransport();
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    await backend.close();
    await server.close();
  };
  process.once("SIGINT", () => void close());
  process.once("SIGTERM", () => void close());
  server.server.onclose = () => void close();
  await server.connect(transport);
  process.stdin.once("end", () => void close());
} catch {
  // Never echo environment values, storage locations, or meeting data to a host log.
  process.stderr.write("LokalBot plugin could not start. Check Node 22.12+ and use a LokalBot helper with working interactive MCP support. LOKALBOT_CLI_PATH may select a source-built helper. Keep the complete companion folder together.\n");
  process.exitCode = 1;
}
