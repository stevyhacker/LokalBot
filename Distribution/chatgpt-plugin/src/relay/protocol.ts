export const MAX_REQUEST_BYTES = 64 * 1024;
export const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
export const READ_SCOPE = "meetings:read";
export const PROTOCOL_VERSIONS = ["2025-03-26", "2025-06-18", "2025-11-25"];
export const METHODS = new Set([
  "initialize", "ping", "tools/list", "tools/call", "resources/list", "resources/read", "resources/templates/list",
]);
export type RPC = { jsonrpc: "2.0"; id: string | number; method: string; params?: Record<string, unknown> };
export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
export function isRPC(value: unknown): value is RPC {
  return isRecord(value) && value.jsonrpc === "2.0" &&
    (typeof value.id === "string" && value.id.length <= 200 || typeof value.id === "number" && Number.isSafeInteger(value.id)) &&
    typeof value.method === "string" && METHODS.has(value.method) &&
    (value.params === undefined || isRecord(value.params));
}
export function rpcError(id: string | number | null, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}
export async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, "0")).join("");
}
export function secret(bytes = 32): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(bytes)), byte => byte.toString(16).padStart(2, "0")).join("");
}
export function normalizePairCode(value: string): string | undefined {
  const normalized = value.replace(/[\s-]/g, "").toLowerCase();
  return /^[a-f0-9]{32}$/.test(normalized) ? normalized : undefined;
}
export async function boundedText(request: Request, maximum = MAX_REQUEST_BYTES): Promise<string> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      bytes += next.value.length;
      // Drain rejected input without retaining it. Leaving an HTTP/1 request
      // half-read can reset a later request on the client's pooled connection.
      if (bytes <= maximum) chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  if (bytes > maximum) throw new Error("Body too large");
  const body = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder().decode(body);
}
