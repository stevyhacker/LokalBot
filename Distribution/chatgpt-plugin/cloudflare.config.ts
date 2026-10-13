import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/relay/index.ts" with { type: "cf-worker" };

export default defineConfig({
  accountId: "cfd3e739cdd3b76c04b5390bb9d5964f",
  worker: {
    name: "lokalbot-chatgpt-relay",
    domains: ["mcp.lokalbot.com"],
    workersDev: false,
    previewUrls: false,
    compatibilityDate: "2026-07-30",
    compatibilityFlags: ["global_fetch_strictly_public"],
    entrypoint,
    observability: { enabled: false },
    exports: { RelayRoom: exports.durableObject({ storage: "sqlite" }) },
    env: {
      PUBLIC_ORIGIN: bindings.text("https://mcp.lokalbot.com"),
      OAUTH_KV: bindings.kv(),
      ROOMS: bindings.durableObject({ worker: "lokalbot-chatgpt-relay", exportName: "RelayRoom" }),
      PAIR_LIMIT: bindings.rateLimit({ namespace: "1001", simple: { limit: 5, period: 60 } }),
      AUTH_LIMIT: bindings.rateLimit({ namespace: "1002", simple: { limit: 60, period: 60 } }),
    },
  },
});
