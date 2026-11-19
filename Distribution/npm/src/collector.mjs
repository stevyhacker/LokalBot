// What the readers gather for one year: per-session counts and event
// times. Request and reply text is counted and dropped; nothing here holds
// what was said.

import path from 'node:path';

export const AGENTS = {
  'claude-code': 'Claude Code',
  codex: 'Codex',
  cursor: 'Cursor',
  pi: 'Pi',
  omp: 'OMP',
  opencode: 'OpenCode',
  antigravity: 'Antigravity',
  'gemini-cli': 'Gemini CLI',
};

/** `start` and `end` are epoch milliseconds; `end` is exclusive. */
export function createCollector({ start, end }) {
  const sessions = new Map();
  return {
    start,
    end,
    sessions,
    /** Unique absolute paths of files an agent changed. */
    files: new Set(),
    /** Record ids already counted: a forked or resumed session copies its history. */
    seenRecords: new Set(),
    filesRead: 0,
    bytesRead: 0,
    unreadableFiles: 0,
    /** Compressed logs this Node.js cannot decompress. */
    compressedSkipped: 0,
    /** SQLite databases this Node.js cannot open (needs Node.js 22.5+). */
    sqliteSkipped: 0,
    inWindow(at) {
      return at >= start && at < end;
    },
    session(agent, id) {
      const key = `${agent}:${id}`;
      let session = sessions.get(key);
      if (!session) {
        session = newSession(agent, id);
        sessions.set(key, session);
      }
      return session;
    },
  };
}

function newSession(agent, id) {
  return {
    agent,
    id,
    /** A helper thread with no known parent: its tokens count, its hours do not. */
    hidden: false,
    times: [],
    prompts: 0,
    promptWords: 0,
    slashCommands: 0,
    scheduledRuns: 0,
    replies: 0,
    toolCalls: 0,
    edits: 0,
    subagentFiles: 0,
    subagentCalls: 0,
    tools: new Map(),
    models: new Map(),
    modelTokens: new Map(),
    folders: new Map(),
    tokens: { input: 0, cached: 0, output: 0 },
    commits: new Set(),
    pullRequestsOpened: new Set(),
    mergedNumbers: new Set(),
    mergedUnnumbered: 0,
    releases: new Set(),
    pushes: 0,
    testRuns: 0,
  };
}

export function bump(map, key, by = 1) {
  map.set(key, (map.get(key) ?? 0) + by);
}

export function addModelTokens(session, model, { input = 0, cached = 0, cacheWrite = 0, output = 0 }) {
  if (input === 0 && output === 0) return;
  const key = typeof model === 'string' && model.length > 0 ? model : '';
  const bucket = session.modelTokens.get(key) ?? { input: 0, cached: 0, cacheWrite: 0, output: 0 };
  bucket.input += input;
  bucket.cached += cached;
  bucket.cacheWrite += cacheWrite;
  bucket.output += output;
  session.modelTokens.set(key, bucket);
}

export function emptyActions() {
  return { commits: [], pullRequestsOpened: [], pullRequestsMerged: [], releases: [], pushes: 0, testRuns: 0 };
}

/** Folds one command's actions (from `actionsInCommand`) into a running tally. */
export function mergeActions(into, actions) {
  into.commits.push(...actions.commits);
  into.pullRequestsOpened.push(...actions.pullRequestsOpened);
  into.pullRequestsMerged.push(...actions.pullRequestsMerged);
  into.releases.push(...actions.releases);
  if (actions.pushed) into.pushes += 1;
  if (actions.ranTests) into.testRuns += 1;
}

export function addActions(session, tally) {
  for (const message of tally.commits) session.commits.add(message);
  for (const title of tally.pullRequestsOpened) session.pullRequestsOpened.add(title);
  for (const number of tally.pullRequestsMerged) {
    if (number === '') session.mergedUnnumbered += 1;
    else session.mergedNumbers.add(number);
  }
  for (const tag of tally.releases) session.releases.add(tag);
  session.pushes += tally.pushes;
  session.testRuns += tally.testRuns;
}

/** Records a changed file by its absolute path, so one file counts once. */
export function addFile(collector, file, workingDirectory) {
  if (typeof file !== 'string' || file.length === 0) return;
  const absolute = file.startsWith('/') || /^[A-Za-z]:[\\/]/.test(file) || file.startsWith('\\\\');
  if (absolute || !workingDirectory) {
    collector.files.add(file);
    return;
  }
  // The log may come from another system, so the folder's own style decides.
  const style = workingDirectory.includes('\\') && !workingDirectory.includes('/') ? path.win32 : path.posix;
  collector.files.add(style.join(workingDirectory, file));
}

/** `mcp__github__create_issue` (and Antigravity/Cursor MCP tool names) are tallied as `<server> (MCP)`. */
export function toolLabel(name) {
  if (typeof name !== 'string' || name.length === 0) return 'unknown';
  const mcp = /^mcp__(.+?)__/.exec(name)
    ?? /^mcp_([a-z0-9][a-z0-9-]*?)_/.exec(name)
    ?? /^mcp-([a-z0-9][a-z0-9]*?)-/.exec(name);
  return mcp ? `${mcp[1]} (MCP)` : name;
}
