// Reads the year's sessions from both agents and computes its figures.

import os from 'node:os';

import { claudeRoots, readClaude, readClaudeSummary } from './claude.mjs';
import { codexRoot, readCodex } from './codex.mjs';
import { createCollector } from './collector.mjs';
import { computeStats, yearWindow } from './stats.mjs';

/** January still looks back at the year that just ended. */
export function defaultYear(now = new Date()) {
  return now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
}

/**
 * `claudeDirs` and `codexDir` override where the logs are read from;
 * otherwise `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are honoured, then the
 * agents' default folders. `onProgress(agentName, done, total)` reports files.
 */
export function wrapped({
  year = defaultYear(),
  env = process.env,
  home = os.homedir(),
  claudeDirs,
  codexDir,
  userName = safeUserName(),
  onProgress = () => {},
} = {}) {
  const collector = createCollector(yearWindow(year));
  const claude = claudeDirs ?? claudeRoots(env, home);
  const codex = codexDir ?? codexRoot(env, home);
  readClaude(claude, collector, (done, total) => onProgress('Claude Code', done, total));
  readCodex(codex, collector, (done, total) => onProgress('Codex', done, total));
  const result = computeStats(collector, { year, userName, summaryDays: readClaudeSummary(claude) });
  result.stats.sources.claude = claude;
  result.stats.sources.codex = codex;
  return result;
}

function safeUserName() {
  try {
    return os.userInfo().username;
  } catch {
    return '';
  }
}
