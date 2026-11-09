// Reads Claude Code sessions from `<config>/projects/<folder>/<id>.jsonl`
// and the subagent transcripts beside them, in
// `<config>/projects/<folder>/<id>/subagents/`.
//
// The rules follow LokalBot's own reader (ClaudeCodeSessionReader.swift):
// a tool result contributes only its time, and meta records and compaction
// summaries are skipped. Subagent work adds to its parent session's time,
// tokens and tool calls, never to its requests.
//
// Every line is decoded. Judging lines by their opening bytes instead was
// measured on 5.3 GB of real logs and saved no time, so it is not worth a
// second way of reading that could disagree with the first.

import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { forEachLine } from './lines.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'claude-code';
const EDIT_TOOLS = new Set(['Edit', 'MultiEdit', 'Write', 'NotebookEdit']);
const SUBAGENT_TOOLS = new Set(['Task', 'Agent']);
/** A longer line is a tool result with a file or an image in it; nothing counted is that large. */
const PARSE_LIMIT = 16 * 1024 * 1024;

/** Where Claude Code keeps its projects: `CLAUDE_CONFIG_DIR` (a list), else the two defaults. */
export function claudeRoots(env, home) {
  const configured = (env.CLAUDE_CONFIG_DIR ?? '').split(',').map((entry) => entry.trim()).filter(Boolean);
  const bases = configured.length > 0
    ? configured
    : [path.join(home, '.claude'), path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'claude')];
  return bases.map((base) => path.join(base, 'projects'));
}

/**
 * Claude Code deletes session logs after 30 days unless `cleanupPeriodDays`
 * says otherwise, but keeps a count per day in `stats-cache.json` beside the
 * projects folder. Returns those counts by date (`2026-02-03`), for the days
 * whose logs are gone. The file holds numbers only.
 */
export function readClaudeSummary(roots) {
  const days = new Map();
  for (const root of roots) {
    let cache;
    try {
      cache = JSON.parse(fs.readFileSync(path.join(path.dirname(root), 'stats-cache.json'), 'utf8'));
    } catch {
      continue;
    }
    if (!Array.isArray(cache?.dailyActivity)) continue;
    for (const entry of cache.dailyActivity) {
      if (typeof entry?.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(entry.date)) continue;
      const day = days.get(entry.date) ?? { sessions: 0, toolCalls: 0 };
      day.sessions += count(entry.sessionCount);
      day.toolCalls += count(entry.toolCallCount);
      days.set(entry.date, day);
    }
  }
  return days;
}

/** Reads every session with activity in the collector's window. */
export function readClaude(roots, collector, onProgress = () => {}) {
  const sessions = [];
  const subagents = [];
  for (const root of roots) {
    for (const project of entries(root)) {
      if (!project.isDirectory()) continue;
      const folder = path.join(root, project.name);
      for (const entry of entries(folder)) {
        if (entry.isFile() && entry.name.endsWith('.jsonl')) {
          sessions.push({ file: path.join(folder, entry.name), id: entry.name.slice(0, -'.jsonl'.length) });
        } else if (entry.isDirectory()) {
          collectTranscripts(path.join(folder, entry.name, 'subagents'), entry.name, subagents);
        }
      }
    }
  }
  // A fork or resumed session copies earlier records under their original
  // ids. Reading older files first credits that history where it happened.
  const main = candidates(sessions, collector).sort((a, b) => a.born - b.born || (a.file < b.file ? -1 : 1));
  const side = candidates(subagents, collector);
  const total = main.length + side.length;
  let done = 0;
  for (const candidate of [...main, ...side]) {
    try {
      readTranscript(candidate, collector);
      collector.filesRead += 1;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, total);
  }
}

function entries(folder) {
  try {
    return fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return [];
  }
}

function collectTranscripts(folder, parent, into, depth = 0) {
  for (const entry of entries(folder)) {
    if (entry.isFile() && entry.name.endsWith('.jsonl')) {
      into.push({ file: path.join(folder, entry.name), id: parent, subagent: true });
    } else if (entry.isDirectory() && depth < 4) {
      collectTranscripts(path.join(folder, entry.name), parent, into, depth + 1);
    }
  }
}

/** Files written since the window began and created before it ended. */
function candidates(files, collector) {
  const kept = [];
  for (const candidate of files) {
    let stat;
    try {
      stat = fs.statSync(candidate.file);
    } catch {
      continue;
    }
    if (!stat.isFile() || stat.mtimeMs < collector.start) continue;
    // Some filesystems report no creation time.
    const born = stat.birthtimeMs > 0 ? stat.birthtimeMs : stat.mtimeMs;
    if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
    kept.push({ ...candidate, born });
  }
  return kept;
}

function readTranscript({ file, id, subagent = false }, collector) {
  let session = null;
  let launched = false;
  /** Usage by API message id: one message is written as several records. */
  const usage = new Map();
  const tally = emptyActions();

  const touch = (at) => {
    session ??= collector.session(AGENT, id);
    session.times.push(at);
    if (subagent && !launched) {
      launched = true;
      session.subagentFiles += 1;
    }
    return session;
  };
  const admit = (uuid) => {
    if (typeof uuid !== 'string' || uuid.length === 0) return true;
    if (collector.seenRecords.has(uuid)) return false;
    collector.seenRecords.add(uuid);
    return true;
  };

  collector.bytesRead += forEachLine(file, (line) => {
    if (line.length > PARSE_LIMIT) return;
    let record;
    try {
      record = JSON.parse(line.toString('utf8'));
    } catch {
      return;
    }
    const type = record?.type;
    if (type !== 'user' && type !== 'assistant') return;
    if (record.isMeta === true || record.isCompactSummary === true) return;
    const at = Date.parse(record.timestamp);
    if (!collector.inWindow(at) || !admit(record.uuid)) return;
    const current = touch(at);
    // Older versions wrote subagent turns into the session's own file.
    const side = subagent || record.isSidechain === true;
    const workingDirectory = typeof record.cwd === 'string' ? record.cwd : null;
    if (workingDirectory && !side) bump(current.folders, workingDirectory);
    const message = record.message;
    if (type === 'user') {
      if (!side) countRequest(current, message?.content, tally);
    } else if (message && typeof message === 'object') {
      countReply(current, message, { side, workingDirectory, usage, tally, collector });
    }
  });

  if (!session) return;
  for (const used of usage.values()) {
    session.tokens.input += used.input + used.cacheWrite + used.cacheRead;
    session.tokens.cached += used.cacheRead;
    session.tokens.output += used.output;
  }
  addActions(session, tally);
}

function countRequest(session, content, tally) {
  let raw;
  if (typeof content === 'string') {
    raw = content;
  } else if (Array.isArray(content)) {
    raw = content.filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text).join('\n');
  } else {
    return;
  }
  const request = classifyPrompt(raw);
  if (!request) return;
  if (request.kind === 'scheduled') {
    session.scheduledRuns += 1;
    return;
  }
  session.prompts += 1;
  session.promptWords += request.words;
  if (request.kind === 'command') session.slashCommands += 1;
  // A command the person ran in the agent's terminal mode is still their work.
  if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
}

function countReply(session, message, { side, workingDirectory, usage, tally, collector }) {
  const model = typeof message.model === 'string' && message.model !== '<synthetic>' ? message.model : null;
  const id = typeof message.id === 'string' ? message.id : null;
  // The model a person chose, not the one a subagent was handed.
  if (model && !side && (!id || !usage.has(id))) bump(session.models, model);
  if (message.usage && typeof message.usage === 'object') {
    const key = id ?? `record-${usage.size}`;
    const seen = usage.get(key) ?? { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };
    seen.input = Math.max(seen.input, count(message.usage.input_tokens));
    seen.cacheWrite = Math.max(seen.cacheWrite, count(message.usage.cache_creation_input_tokens));
    seen.cacheRead = Math.max(seen.cacheRead, count(message.usage.cache_read_input_tokens));
    seen.output = Math.max(seen.output, count(message.usage.output_tokens));
    usage.set(key, seen);
  }
  if (!Array.isArray(message.content)) return;
  for (const block of message.content) {
    if (block?.type === 'text') {
      if (!side && typeof block.text === 'string' && block.text.trim().length > 0) session.replies += 1;
    } else if (block?.type === 'tool_use') {
      const name = typeof block.name === 'string' ? block.name : '';
      const input = block.input && typeof block.input === 'object' ? block.input : {};
      session.toolCalls += 1;
      bump(session.tools, toolLabel(name));
      if (EDIT_TOOLS.has(name)) {
        session.edits += 1;
        addFile(collector, input.file_path ?? input.notebook_path, workingDirectory);
      } else if (name === 'Bash' && typeof input.command === 'string') {
        mergeActions(tally, actionsInCommand(input.command));
      } else if (SUBAGENT_TOOLS.has(name) && !side) {
        session.subagentCalls += 1;
      }
    }
  }
}

function count(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
