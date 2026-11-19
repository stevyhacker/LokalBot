// Reads the year's sessions from all supported local coding agents and
// computes its figures. Nothing is sent over the network.

import os from 'node:os';

import { antigravityRoots, readAntigravity } from './antigravity.mjs';
import { claudeRoots, readClaude, readClaudeSummary } from './claude.mjs';
import { codexRoot, readCodex } from './codex.mjs';
import { createCollector } from './collector.mjs';
import { cursorRoots, readCursor } from './cursor.mjs';
import { geminiRoot, readGemini } from './gemini.mjs';
import { opencodeRoot, readOpenCode } from './opencode.mjs';
import { ompRoot, piRoot, readOmp, readPi } from './pi.mjs';
import { computeStats, yearWindow } from './stats.mjs';

/** January still looks back at the year that just ended. */
export function defaultYear(now = new Date()) {
  return now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
}

/**
 * Dir options override where each agent's logs are read from; pass `null` to
 * skip an agent, or omit/`undefined` to honour its environment variable and
 * default folder. `onProgress(agentName, done, total)` reports progress.
 */
export async function wrapped({
  year = defaultYear(),
  env = process.env,
  home = os.homedir(),
  claudeDirs,
  codexDir,
  piDir,
  ompDir,
  opencodeDir,
  cursorDir,
  antigravityDirs,
  geminiDir,
  userName = safeUserName(),
  onProgress = () => {},
} = {}) {
  const collector = createCollector(yearWindow(year));

  const claude = claudeDirs === null ? [] : (claudeDirs ?? claudeRoots(env, home));
  const codex = codexDir === null ? null : (codexDir ?? codexRoot(env, home));
  const pi = piDir === null ? null : (piDir ?? piRoot(env, home));
  const omp = ompDir === null ? null : (ompDir ?? ompRoot(env, home));
  const opencode = opencodeDir === null ? null : (opencodeDir ?? opencodeRoot(env, home));
  const cursor = cursorDir === null ? null : (cursorDir ?? cursorRoots(env, home));
  const antigravity = antigravityDirs === null ? [] : (antigravityDirs ?? antigravityRoots(env, home));
  const gemini = geminiDir === null ? null : (geminiDir ?? geminiRoot(env, home));

  if (claude.length > 0) {
    readClaude(claude, collector, (done, total) => onProgress('Claude Code', done, total));
  }
  if (codex) {
    await readCodex(codex, collector, (done, total) => onProgress('Codex', done, total));
  }
  if (cursor) {
    await readCursor(cursor, collector, (done, total) => onProgress('Cursor', done, total));
  }
  if (pi) {
    readPi(pi, collector, (done, total) => onProgress('Pi', done, total));
  }
  if (omp) {
    readOmp(omp, collector, (done, total) => onProgress('OMP', done, total));
  }
  if (opencode) {
    await readOpenCode(opencode, collector, (done, total) => onProgress('OpenCode', done, total));
  }
  if (antigravity.length > 0) {
    readAntigravity(antigravity, collector, (done, total) => onProgress('Antigravity', done, total));
  }
  if (gemini) {
    readGemini(gemini, collector, (done, total) => onProgress('Gemini CLI', done, total));
  }

  const summaryDays = claude.length > 0 ? readClaudeSummary(claude) : new Map();
  const result = computeStats(collector, { year, userName, summaryDays });
  result.stats.sources.claude = claude;
  result.stats.sources.codex = codex;
  result.stats.sources.cursor = cursor;
  result.stats.sources.pi = pi;
  result.stats.sources.omp = omp;
  result.stats.sources.opencode = opencode;
  result.stats.sources.antigravity = antigravity;
  result.stats.sources.gemini = gemini;
  return result;
}

function safeUserName() {
  try {
    return os.userInfo().username;
  } catch {
    return '';
  }
}
