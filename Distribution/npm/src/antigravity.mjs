// Reads Antigravity conversation transcripts from:
//   - `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
//   - `~/.gemini/antigravity-cli/brain/<id>/...`
//   - `~/.gemini/antigravity-ide/brain/<id>/...`
//   - `~/.t3/userdata/providers/antigravity/<hash>/antigravity-acp/brain/<id>/...`
//
// Each line is one step (`USER_INPUT`, `PLANNER_RESPONSE`, `CHECKPOINT`, or a
// tool step). `input_tokens` is uncached input; `cache_read_tokens` is cached
// input read from prompt cache. No prompt or reply text is kept.

import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { forEachLine } from './lines.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'antigravity';
const PARSE_LIMIT = 16 * 1024 * 1024;
const EDIT_TOOLS = new Set([
  'write_file', 'edit_file', 'write_to_file',
  'replace_file_content', 'multi_replace_file_content',
]);
const SHELL_TOOLS = new Set(['run_command', 'bash', 'shell']);
const SUBAGENT_TOOLS = new Set(['invoke_subagent', 'swarm']);

export function antigravityRoots(env, home) {
  if (env.ANTIGRAVITY_HOME) {
    return [path.join(env.ANTIGRAVITY_HOME, 'brain'), env.ANTIGRAVITY_HOME];
  }
  const roots = [
    path.join(home, '.gemini', 'antigravity', 'brain'),
    path.join(home, '.gemini', 'antigravity-cli', 'brain'),
    path.join(home, '.gemini', 'antigravity-ide', 'brain'),
  ];
  const t3Providers = path.join(home, '.t3', 'userdata', 'providers', 'antigravity');
  for (const entry of entries(t3Providers)) {
    if (!entry.isDirectory()) continue;
    const brain = path.join(t3Providers, entry.name, 'antigravity-acp', 'brain');
    if (fs.existsSync(brain)) roots.push(brain);
  }
  return roots;
}

export function readAntigravity(roots, collector, onProgress = () => {}) {
  if (!Array.isArray(roots) || roots.length === 0) return;

  // Deduplicate by conversation id in case two roots point at the same brain.
  const byId = new Map();
  for (const root of roots) {
    for (const conv of entries(root)) {
      if (!conv.isDirectory()) continue;
      const transcript = path.join(root, conv.name, '.system_generated', 'logs', 'transcript.jsonl');
      let stat;
      try {
        stat = fs.statSync(transcript);
      } catch {
        continue;
      }
      if (!stat.isFile() || stat.mtimeMs < collector.start) continue;
      if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
      const existing = byId.get(conv.name);
      if (!existing || stat.mtimeMs > existing.mtimeMs) {
        byId.set(conv.name, { id: conv.name, file: transcript, mtimeMs: stat.mtimeMs });
      }
    }
  }

  const list = [...byId.values()].sort((a, b) => (a.file < b.file ? -1 : 1));
  let done = 0;
  for (const item of list) {
    try {
      readTranscript(item, collector);
      collector.filesRead += 1;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, list.length);
  }
}

function entries(folder) {
  try {
    return fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return [];
  }
}

function readTranscript({ id, file }, collector) {
  let session = null;
  let lastModel = null;
  let lastCwd = null;
  const tally = emptyActions();

  const touch = (at) => {
    session ??= collector.session(AGENT, id);
    session.times.push(at);
    return session;
  };

  collector.bytesRead += forEachLine(file, (line) => {
    if (line.length > PARSE_LIMIT) return;
    let record;
    try {
      record = JSON.parse(line.toString('utf8'));
    } catch {
      return;
    }
    const at = Date.parse(record?.created_at);
    if (!collector.inWindow(at)) return;

    const current = touch(at);
    const type = record.type;

    if (type === 'USER_INPUT') {
      if (record.source === 'SYSTEM') return;
      const request = classifyPrompt(record.content);
      if (!request) return;
      if (request.kind === 'scheduled') {
        current.scheduledRuns += 1;
      } else {
        current.prompts += 1;
        current.promptWords += request.words;
        if (request.kind === 'command') current.slashCommands += 1;
        if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
      }
      return;
    }

    if (type === 'PLANNER_RESPONSE' || type === 'CHECKPOINT') {
      const model = nonEmpty(record.model) ?? lastModel;
      if (nonEmpty(record.model)) lastModel = nonEmpty(record.model);

      if (type === 'PLANNER_RESPONSE') {
        if (model) bump(current.models, model);
        if (typeof record.content === 'string' && record.content.trim().length > 0) {
          current.replies += 1;
        }
      }

      const uncached = num(record.input_tokens);
      const cacheRead = num(record.cache_read_tokens);
      const output = num(record.output_tokens);
      const input = uncached + cacheRead;
      if (input > 0 || output > 0) {
        current.tokens.input += input;
        current.tokens.cached += cacheRead;
        current.tokens.output += output;
        addModelTokens(current, model, { input, cached: cacheRead, cacheWrite: 0, output });
      }

      if (Array.isArray(record.tool_calls)) {
        for (const call of record.tool_calls) {
          const name = typeof call?.name === 'string' ? call.name : '';
          const args = call?.args && typeof call.args === 'object' ? call.args : {};
          current.toolCalls += 1;
          bump(current.tools, toolLabel(name));

          if (EDIT_TOOLS.has(name)) {
            current.edits += 1;
            const target = args.Path ?? args.TargetFile ?? args.file_path ?? args.path;
            addFile(collector, target, lastCwd);
            const inferred = inferFolder(target);
            if (inferred) {
              lastCwd ??= inferred;
              bump(current.folders, inferred);
            }
          } else if (SHELL_TOOLS.has(name)) {
            if (typeof args.Cwd === 'string' && args.Cwd.length > 0) {
              lastCwd = args.Cwd;
              bump(current.folders, lastCwd);
            }
            const command = args.CommandLine ?? args.command;
            if (typeof command === 'string' || Array.isArray(command)) {
              mergeActions(tally, actionsInCommand(command));
            }
          } else if (SUBAGENT_TOOLS.has(name)) {
            const spawned = Array.isArray(args.Subagents) ? Math.max(1, args.Subagents.length) : 1;
            current.subagentCalls += spawned;
          } else if (!lastCwd) {
            const candidate = args.DirectoryPath ?? args.SearchPath ?? args.Path ?? args.AbsolutePath;
            const inferred = inferFolder(candidate);
            if (inferred) bump(current.folders, inferred);
          }
        }
      }
    }
  });

  if (session) addActions(session, tally);
}

/** Extracts a plausible project folder from a file path, ignoring agent-internal state folders. */
function inferFolder(target) {
  if (typeof target !== 'string' || target.length === 0) return null;
  if (target.includes('/.gemini/') || target.includes('/.t3/') || target.includes('\\.gemini\\') || target.includes('\\.t3\\')) {
    return null;
  }
  const normalized = target.replaceAll('\\', '/');
  // If path contains a common checkout root (`GitHub/<repo>/...` or `code/<repo>/...`), stop at `<repo>`.
  const repoMatch = /^((?:[A-Za-z]:)?\/.*?\/(?:GitHub|github|repos|repositories|projects|code|dev|workspace|workspaces)\/[^/]+)/.exec(normalized);
  if (repoMatch) return repoMatch[1];
  return path.posix.dirname(normalized);
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
