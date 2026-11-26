import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { canReadZstd, forEachLineAsync, isZstd } from './lines.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'codex';
const PARSE_LIMIT = 16 * 1024 * 1024;
const PATCHED_FILE = /\*\*\* (?:Update|Add) File: ([^\n\\"]+)/g;

export function codexRoot(env, home) {
  return env.CODEX_HOME || path.join(home, '.codex');
}

export async function readCodex(root, collector, onProgress = () => {}) {
  const files = [];
  for (const folder of ['sessions', 'archived_sessions']) walk(path.join(root, folder), files);
  const chosen = new Map();
  for (const file of files) {
    let stat;
    try {
      stat = fs.statSync(file);
    } catch {
      continue;
    }
    if (!stat.isFile() || stat.mtimeMs < collector.start) continue;
    if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
    const key = isZstd(file) ? file.slice(0, -'.zst'.length) : file;
    const other = chosen.get(key);
    if (!other || stat.mtimeMs > other.mtimeMs) chosen.set(key, { file, mtimeMs: stat.mtimeMs });
  }
  const rollouts = [];
  for (const { file } of chosen.values()) {
    if (isZstd(file) && !canReadZstd) {
      collector.compressedSkipped += 1;
      continue;
    }
    rollouts.push({ file, meta: await sessionMeta(file) });
  }
  rollouts.sort((a, b) => (a.file < b.file ? -1 : 1));

  const parents = new Map();
  for (const { meta } of rollouts) {
    if (meta.id && meta.parent) parents.set(meta.id, meta.parent);
  }
  const rootOf = (id) => {
    let current = id;
    for (let hops = 0; hops < 16 && parents.has(current); hops += 1) current = parents.get(current);
    return current;
  };

  let done = 0;
  for (const { file, meta } of rollouts) {
    try {
      await readRollout(file, meta, meta.parent ? rootOf(meta.parent) : null, collector);
      collector.filesRead += 1;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, rollouts.length);
  }
}

function walk(folder, into, depth = 0) {
  let entries;
  try {
    entries = fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.name.startsWith('.')) continue;
    const full = path.join(folder, entry.name);
    if (entry.isDirectory() && depth < 6) walk(full, into, depth + 1);
    else if (entry.isFile() && (entry.name.endsWith('.jsonl') || entry.name.endsWith('.jsonl.zst'))) into.push(full);
  }
}

async function sessionMeta(file) {
  const fallback = { id: idFromName(file), parent: null, helper: false, cwd: null };
  let first = null;
  try {
    await forEachLineAsync(file, (line) => {
      first = line.length <= PARSE_LIMIT ? line.toString('utf8') : '';
      throw STOP;
    });
  } catch (error) {
    if (error !== STOP) return fallback;
  }
  if (!first) return fallback;
  try {
    const record = JSON.parse(first);
    if (record?.type !== 'session_meta' || !record.payload) return fallback;
    const payload = record.payload;
    const meta = { ...fallback, id: typeof payload.id === 'string' ? payload.id : fallback.id };
    if (typeof payload.cwd === 'string') meta.cwd = payload.cwd;
    const subagent = payload.source && typeof payload.source === 'object' ? payload.source.subagent : null;
    if (subagent) {
      const parent = subagent.thread_spawn?.parent_thread_id;
      if (typeof parent === 'string' && parent.length > 0) meta.parent = parent;
      else meta.helper = true;
    }
    return meta;
  } catch {
    return fallback;
  }
}

const STOP = Symbol('stop');

function idFromName(file) {
  const name = path.basename(isZstd(file) ? file.slice(0, -'.zst'.length) : file, '.jsonl');
  const uuid = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.exec(name);
  return uuid ? uuid[0] : name;
}

async function readRollout(file, meta, parent, collector) {
  const side = parent !== null;
  let session = null;
  let launched = false;
  let workingDirectory = meta.cwd;
  let currentModel = null;
  const asked = { actions: emptyActions(), edits: 0 };
  const done = { actions: emptyActions(), edits: 0, commands: false, changes: false };
  const totals = { token_count: newRunningTotal(), token_usage_record: newRunningTotal() };

  const touch = (at) => {
    if (!session) {
      session = collector.session(AGENT, side ? parent : meta.id);
      if (meta.helper) session.hidden = true;
    }
    session.times.push(at);
    if (side && !launched) {
      launched = true;
      session.subagentFiles += 1;
    }
    return session;
  };

  collector.bytesRead += await forEachLineAsync(file, (line) => {
    if (line.length > PARSE_LIMIT) return;
    let record;
    try {
      record = JSON.parse(line.toString('utf8'));
    } catch {
      return;
    }
    const payload = record?.payload;
    if (!payload || typeof payload !== 'object') return;
    const type = record.type;
    if (type === 'session_meta') return;
    const at = Date.parse(record.timestamp);
    const inWindow = collector.inWindow(at);
    if (type === 'token_usage_record') {
      advance(totals.token_usage_record, payload.thread_token_usage, inWindow, currentModel);
    } else if (type === 'event_msg' && payload.type === 'token_count') {
      advance(totals.token_count, payload.info?.total_token_usage, inWindow, currentModel);
    }
    if (!inWindow) return;
    const current = touch(at);
    if (type === 'turn_context') {
      if (typeof payload.cwd === 'string') workingDirectory = payload.cwd;
      if (typeof payload.model === 'string' && payload.model.length > 0) currentModel = payload.model;
      if (side || meta.helper) return;
      if (typeof payload.model === 'string' && payload.model.length > 0) bump(current.models, payload.model);
      if (workingDirectory) bump(current.folders, workingDirectory);
    } else if (type === 'response_item') {
      countResponseItem(current, payload, { quiet: side || meta.helper, asked, workingDirectory, collector });
    } else if (type === 'event_msg' && payload.type === 'item_completed' && payload.item) {
      countCompletedItem(current, payload.item, { done, workingDirectory, collector, quiet: side || meta.helper });
    }
  });

  if (!session) return;
  const used = totals.token_count.seen ? totals.token_count : totals.token_usage_record;
  session.tokens.input += used.input;
  session.tokens.cached += used.cached;
  session.tokens.output += used.output;
  for (const [model, tokens] of modelShares(used)) addModelTokens(session, model, tokens);
  addActions(session, done.commands ? done.actions : asked.actions);
  session.edits += done.changes ? done.edits : asked.edits;
}

function countResponseItem(session, payload, { quiet, asked, workingDirectory, collector }) {
  switch (payload.type) {
    case 'message': {
      if (quiet || !Array.isArray(payload.content)) return;
      const texts = payload.content
        .filter((item) => (item?.type === 'input_text' || item?.type === 'output_text') && typeof item.text === 'string')
        .map((item) => item.text);
      if (payload.role === 'user') {
        const requests = texts.map(classifyPrompt).filter(Boolean);
        if (requests.length === 0) return;
        if (requests.every((request) => request.kind === 'scheduled')) {
          session.scheduledRuns += 1;
          return;
        }
        session.prompts += 1;
        session.promptWords += requests.reduce((sum, request) => sum + request.words, 0);
        if (requests.some((request) => request.kind === 'command')) session.slashCommands += 1;
      } else if (payload.role === 'assistant' && texts.some((text) => text.trim().length > 0)) {
        session.replies += 1;
      }
      return;
    }
    case 'function_call':
    case 'custom_tool_call':
    case 'local_shell_call': {
      session.toolCalls += 1;
      const name = payload.type === 'local_shell_call' ? 'shell' : payload.name;
      bump(session.tools, toolLabel(name));
      const body = payload.arguments ?? payload.input;
      if (typeof body === 'string') {
        for (const match of body.matchAll(PATCHED_FILE)) {
          asked.edits += 1;
          addFile(collector, match[1].trim(), workingDirectory);
        }
        const command = shellCommand(body);
        if (command) mergeActions(asked.actions, actionsInCommand(command));
      }
      const argv = payload.action?.command;
      if (argv) mergeActions(asked.actions, actionsInCommand(argv));
      return;
    }
    default:
  }
}

function countCompletedItem(session, item, { done, workingDirectory, collector, quiet }) {
  switch (item.type) {
    case 'CommandExecution':
      done.commands = true;
      mergeActions(done.actions, actionsInCommand(item.command));
      return;
    case 'FileChange':
      if (item.changes && typeof item.changes === 'object') {
        done.changes = true;
        for (const file of Object.keys(item.changes)) {
          done.edits += 1;
          addFile(collector, file, workingDirectory);
        }
      }
      return;
    case 'CollabAgentToolCall':
      if (!quiet && typeof item.tool === 'string' && /spawn/i.test(item.tool)) session.subagentCalls += 1;
      return;
    default:
  }
}

function shellCommand(body) {
  if (!body.startsWith('{')) return null;
  try {
    const args = JSON.parse(body);
    const command = args?.cmd ?? args?.command;
    if (typeof command === 'string') return command;
    if (Array.isArray(command) && typeof command.at(-1) === 'string') return command.at(-1);
  } catch {
  }
  return null;
}

function newRunningTotal() {
  return { seen: false, last: null, input: 0, cached: 0, output: 0, byModel: new Map() };
}

function modelShares(running) {
  const shares = new Map(running.byModel);
  const unknown = shares.get('');
  const first = [...shares.keys()].find((model) => model !== '');
  if (unknown && first !== undefined) {
    const into = shares.get(first);
    shares.set(first, { input: into.input + unknown.input, cached: into.cached + unknown.cached, output: into.output + unknown.output });
    shares.delete('');
  }
  return shares;
}

function advance(running, reading, inWindow, model) {
  if (!reading || typeof reading !== 'object') return;
  const now = {
    input: number(reading.input_tokens),
    cached: number(reading.cached_input_tokens),
    output: number(reading.output_tokens),
  };
  const before = running.last;
  const restarted = before !== null && now.input + now.output < before.input + before.output;
  const base = before === null || restarted ? { input: 0, cached: 0, output: 0 } : before;
  running.last = now;
  if (!inWindow) return;
  running.seen = true;
  const delta = {
    input: Math.max(0, now.input - base.input),
    cached: Math.max(0, now.cached - base.cached),
    output: Math.max(0, now.output - base.output),
  };
  running.input += delta.input;
  running.cached += delta.cached;
  running.output += delta.output;
  const key = typeof model === 'string' && model.length > 0 ? model : '';
  const bucket = running.byModel.get(key) ?? { input: 0, cached: 0, output: 0 };
  bucket.input += delta.input;
  bucket.cached += delta.cached;
  bucket.output += delta.output;
  running.byModel.set(key, bucket);
}

function number(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
