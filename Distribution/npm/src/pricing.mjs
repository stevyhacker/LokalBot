const RATES = [
  { match: /opus[-._]?4[-._]?[5-9]|opus[-._]?[5-9]/i, rate: { input: 5, cacheRead: 0.5, cacheWrite: 6.25, output: 25 } },
  { match: /opus/i, rate: { input: 15, cacheRead: 1.5, cacheWrite: 18.75, output: 75 } },
  { match: /sonnet/i, rate: { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 } },
  { match: /haiku[-._]?(?:3[-._]?5|[4-9])/i, rate: { input: 1, cacheRead: 0.1, cacheWrite: 1.25, output: 5 } },
  { match: /haiku/i, rate: { input: 0.25, cacheRead: 0.03, cacheWrite: 0.3, output: 1.25 } },

  { match: /gpt[-._]?5[-._]?[2-9].*pro/i, rate: { input: 15, cacheRead: 1.5, cacheWrite: 15, output: 120 } },
  { match: /(?:gpt[-._]?5|codex).*mini/i, rate: { input: 0.25, cacheRead: 0.025, cacheWrite: 0.25, output: 2 } },
  { match: /gpt[-._]?5[-._]?[2-9]|gpt[-._]?[6-9]/i, rate: { input: 1.75, cacheRead: 0.175, cacheWrite: 1.75, output: 14 } },
  { match: /gpt[-._]?5|codex/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },
  { match: /o[34][-._]?mini/i, rate: { input: 1.1, cacheRead: 0.275, cacheWrite: 1.1, output: 4.4 } },
  { match: /\bo3\b|o3[-._]/i, rate: { input: 2, cacheRead: 0.5, cacheWrite: 2, output: 8 } },
  { match: /gpt[-._]?4\.1[-._]?mini/i, rate: { input: 0.4, cacheRead: 0.1, cacheWrite: 0.4, output: 1.6 } },
  { match: /gpt[-._]?4\.1/i, rate: { input: 2, cacheRead: 0.5, cacheWrite: 2, output: 8 } },
  { match: /gpt[-._]?4o[-._]?mini/i, rate: { input: 0.15, cacheRead: 0.075, cacheWrite: 0.15, output: 0.6 } },
  { match: /gpt[-._]?4o/i, rate: { input: 2.5, cacheRead: 1.25, cacheWrite: 2.5, output: 10 } },

  { match: /gemini.*flash[-._]?lite/i, rate: { input: 0.1, cacheRead: 0.01, cacheWrite: 0.1, output: 0.4 } },
  { match: /gemini.*flash/i, rate: { input: 0.3, cacheRead: 0.03, cacheWrite: 0.3, output: 2.5 } },
  { match: /gemini[-._]?[3-9]|gemini.*carbon/i, rate: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 12 } },
  { match: /gemini/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },

  { match: /composer/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },
  { match: /grok/i, rate: { input: 3, cacheRead: 0.75, cacheWrite: 3, output: 15 } },
  { match: /kimi/i, rate: { input: 0.6, cacheRead: 0.15, cacheWrite: 0.6, output: 2.5 } },
  { match: /deepseek/i, rate: { input: 0.28, cacheRead: 0.028, cacheWrite: 0.28, output: 0.42 } },
  { match: /qwen/i, rate: { input: 0.3, cacheRead: 0.06, cacheWrite: 0.3, output: 1.2 } },
];

const AGENT_FALLBACK = {
  'claude-code': { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 },
  codex: { input: 1.75, cacheRead: 0.175, cacheWrite: 1.75, output: 14 },
  cursor: { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 },
  pi: { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 },
  omp: { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 },
  opencode: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 10 },
  antigravity: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 12 },
  'gemini-cli': { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 },
};

const DEFAULT_RATE = { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 };

export function rateForModel(model, agentId) {
  if (typeof model === 'string' && model.length > 0) {
    for (const entry of RATES) {
      if (entry.match.test(model)) return entry.rate;
    }
  }
  return AGENT_FALLBACK[agentId] ?? DEFAULT_RATE;
}

export function tokenCostUsd({ input = 0, cached = 0, cacheWrite = 0, output = 0 }, model, agentId) {
  const rate = rateForModel(model, agentId);
  const uncached = Math.max(0, input - cached - cacheWrite);
  return (
    uncached * rate.input
    + cached * rate.cacheRead
    + cacheWrite * rate.cacheWrite
    + output * rate.output
  ) / 1_000_000;
}

export function sessionApiUsd(session) {
  if (session.modelTokens && session.modelTokens.size > 0) {
    let total = 0;
    for (const [model, usage] of session.modelTokens) {
      total += tokenCostUsd(usage, model, session.agent);
    }
    return total;
  }
  const topModel = [...(session.models?.entries() ?? [])]
    .sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
  return tokenCostUsd(session.tokens, topModel, session.agent);
}
