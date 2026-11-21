import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { forEachLine } from './lines.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const PARSE_LIMIT = 16 * 1024 * 1024;
const UUID_SUFFIX = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EDIT_TOOLS = new Set([
  'write', 'edit', 'multi_edit', 'multiedit', 'patch', 'apply_patch',
  'Write', 'Edit', 'MultiEdit', 'NotebookEdit',
]);
const SHELL_TOOLS = new Set(['bash', 'shell', 'exec', 'Bash']);
const SUBAGENT_TOOLS = new Set(['task', 'subagent', 'Task', 'Agent']);

export function piRoot(env, home) {
  return env.PI_CODING_AGENT_DIR
    ? path.join(env.PI_CODING_AGENT_DIR, 'sessions')
    : path.join(home, '.pi', 'agent', 'sessions');
}

export function ompRoot(env, home) {
  return env.OMP_CODING_AGENT_DIR
    ? path.join(env.OMP_CODING_AGENT_DIR, 'sessions')
    : path.join(home, '.omp', 'agent', 'sessions');
}

export function readPi(root, collector, onProgress = () => {}) {
  readPiFamily('pi', root, collector, onProgress);
}

export function readOmp(root, collector, onProgress = () => {}) {
  readPiFamily('omp', root, collector, onProgress);
}

function readPiFamily(agent, root, collector, onProgress) {
  if (!root) return;
  const mainFiles = [];
  const subFiles = [];
  for (const project of entries(root)) {
    if (!project.isDirectory()) continue;
    const projectDir = path.join(root, project.name);
    for (const entry of entries(projectDir)) {
      if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        mainFiles.push({
          file: path.join(projectDir, entry.name),
          fallbackId: idFromStem(entry.name.slice(0, -'.jsonl'.length)),
          subagent: false,
          parentId: null,
        });
      } else if (entry.isDirectory()) {
        const parentId = idFromStem(entry.name);
        collectSubagents(path.join(projectDir, entry.name), parentId, subFiles);
      }
    }
  }

  const main = candidates(mainFiles, collector).sort((a, b) => a.born - b.born || (a.file < b.file ? -1 : 1));
  const side = candidates(subFiles, collector);
  const total = main.length + side.length;
  let done = 0;
  for (const candidate of [...main, ...side]) {
    try {
      readTranscript(agent, candidate, collector);
      collector.filesRead += 1;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, total);
  }
}

function collectSubagents(folder, parentId, into, depth = 0) {
  for (const entry of entries(folder)) {
    const full = path.join(folder, entry.name);
    if (entry.isFile() && entry.name.endsWith('.jsonl')) {
      into.push({ file: full, fallbackId: parentId, subagent: true, parentId });
    } else if (entry.isDirectory() && depth < 3) {
      collectSubagents(full, parentId, into, depth + 1);
    }
  }
}

function entries(folder) {
  try {
    return fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return [];
  }
}

function idFromStem(stem) {
  const match = UUID_SUFFIX.exec(stem);
  return match ? match[0] : stem;
}

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
    const born = stat.birthtimeMs > 0 ? stat.birthtimeMs : stat.mtimeMs;
    if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
    kept.push({ ...candidate, born });
  }
  return kept;
}

function readTranscript(agent, { file, fallbackId, subagent, parentId }, collector) {
  let sessionId = subagent ? parentId : fallbackId;
  let session = null;
  let launched = false;
  let cwd = null;
  let currentModel = null;
  const tally = emptyActions();

  const touch = (at) => {
    session ??= collector.session(agent, sessionId);
    session.times.push(at);
    if (subagent && !launched) {
      launched = true;
      session.subagentFiles += 1;
    }
    return session;
  };

  const admit = (id) => {
    if (typeof id !== 'string' || id.length === 0) return true;
    const key = `${agent}:${id}`;
    if (collector.seenRecords.has(key)) return false;
    collector.seenRecords.add(key);
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
    if (type === 'session') {
      if (!subagent && typeof record.id === 'string' && record.id.length > 0 && !session) {
        sessionId = record.id;
      }
      if (typeof record.cwd === 'string' && record.cwd.length > 0) cwd = record.cwd;
      return;
    }
    if (type === 'model_change') {
      const m = nonEmpty(record.modelId) ?? nonEmpty(record.model);
      if (m) currentModel = m;
      return;
    }
    if (type !== 'message') return;

    const message = record.message;
    if (!message || typeof message !== 'object') return;
    const at = parseTimestamp(record.timestamp, message.timestamp);
    if (!collector.inWindow(at) || !admit(record.id)) return;

    const current = touch(at);
    if (cwd && !subagent) bump(current.folders, cwd);

    if (message.role === 'user') {
      if (!subagent) countRequest(current, message.content, tally);
    } else if (message.role === 'assistant') {
      countReply(current, message, {
        side: subagent,
        fallbackModel: currentModel,
        workingDirectory: cwd,
        tally,
        collector,
      });
    }
  });

  if (session) addActions(session, tally);
}

function countRequest(session, content, tally) {
  const raw = extractText(content);
  if (!raw) return;
  const request = classifyPrompt(raw);
  if (!request) return;
  if (request.kind === 'scheduled') {
    session.scheduledRuns += 1;
    return;
  }
  session.prompts += 1;
  session.promptWords += request.words;
  if (request.kind === 'command') session.slashCommands += 1;
  if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
}

function countReply(session, message, { side, fallbackModel, workingDirectory, tally, collector }) {
  const model = nonEmpty(message.model) ?? fallbackModel;
  if (model && !side) bump(session.models, model);

  const usage = message.usage;
  if (usage && typeof usage === 'object') {
    const uncached = num(usage.input);
    const cacheRead = num(usage.cacheRead);
    const cacheWrite = num(usage.cacheWrite);
    const output = num(usage.output);
    const input = uncached + cacheRead + cacheWrite;
    if (input > 0 || output > 0) {
      session.tokens.input += input;
      session.tokens.cached += cacheRead;
      session.tokens.output += output;
      addModelTokens(session, model, { input, cached: cacheRead, cacheWrite, output });
    }
  }

  if (!Array.isArray(message.content)) return;
  let countedReply = false;
  for (const block of message.content) {
    if (!block || typeof block !== 'object') continue;
    if (block.type === 'text') {
      if (!side && !countedReply && typeof block.text === 'string' && block.text.trim().length > 0) {
        session.replies += 1;
        countedReply = true;
      }
    } else if (block.type === 'toolCall' || block.type === 'tool_use') {
      const name = typeof block.name === 'string' ? block.name : '';
      const args = parseArgsObject(block.arguments ?? block.input);
      session.toolCalls += 1;
      bump(session.tools, toolLabel(name));
      if (EDIT_TOOLS.has(name)) {
        session.edits += 1;
        addFile(collector, args.path ?? args.file_path ?? args.filePath, workingDirectory);
      } else if (SHELL_TOOLS.has(name)) {
        const command = args.command ?? args.cmd;
        if (typeof command === 'string' || Array.isArray(command)) {
          mergeActions(tally, actionsInCommand(command));
        }
      } else if (SUBAGENT_TOOLS.has(name) && !side) {
        session.subagentCalls += 1;
      }
    }
  }
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((block) => block?.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('\n');
}

function parseArgsObject(raw) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw;
  if (typeof raw === 'string' && raw.startsWith('{')) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
    } catch {
    }
  }
  return {};
}

function parseTimestamp(iso, fallbackEpoch) {
  const parsed = typeof iso === 'string' ? Date.parse(iso) : NaN;
  if (Number.isFinite(parsed)) return parsed;
  if (typeof fallbackEpoch === 'number' && Number.isFinite(fallbackEpoch)) return fallbackEpoch;
  return NaN;
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
