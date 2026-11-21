import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'gemini-cli';
const EDIT_TOOLS = new Set(['write_file', 'replace', 'edit', 'edit_file', 'save_file']);
const SHELL_TOOLS = new Set(['run_shell_command', 'shell', 'bash']);
const SUBAGENT_TOOLS = new Set(['codebase_investigator', 'delegate_to_agent', 'subagent', 'task']);

export function geminiRoot(env, home) {
  return path.join(env.GEMINI_CLI_HOME || path.join(home, '.gemini'), 'tmp');
}

export function readGemini(root, collector, onProgress = () => {}) {
  if (!root) return;
  const files = [];
  for (const project of entries(root)) {
    if (!project.isDirectory()) continue;
    const projectDir = path.join(root, project.name);
    const chatsDir = path.join(projectDir, 'chats');
    const projectRoot = readProjectRoot(path.join(projectDir, '.project_root'));
    for (const entry of entries(chatsDir)) {
      if (!entry.isFile() || !/^session-.*\.json$/.test(entry.name)) continue;
      const file = path.join(chatsDir, entry.name);
      let stat;
      try {
        stat = fs.statSync(file);
      } catch {
        continue;
      }
      if (!stat.isFile() || stat.mtimeMs < collector.start) continue;
      if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
      files.push({ file, size: stat.size, projectRoot });
    }
  }

  let done = 0;
  for (const item of files) {
    try {
      readSession(item, collector);
      collector.filesRead += 1;
      collector.bytesRead += item.size;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, files.length);
  }
}

function entries(folder) {
  try {
    return fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return [];
  }
}

function readProjectRoot(file) {
  try {
    const text = fs.readFileSync(file, 'utf8').trim();
    return text.length > 0 ? text.split('\n')[0].trim() : null;
  } catch {
    return null;
  }
}

function readSession({ file, projectRoot }, collector) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!data || typeof data !== 'object' || !Array.isArray(data.messages)) return;
  const id = typeof data.sessionId === 'string' && data.sessionId.length > 0
    ? data.sessionId
    : path.basename(file, '.json');

  let session = null;
  const tally = emptyActions();

  const touch = (at) => {
    session ??= collector.session(AGENT, id);
    session.times.push(at);
    return session;
  };

  for (const msg of data.messages) {
    if (!msg || typeof msg !== 'object') continue;
    const at = Date.parse(msg.timestamp);
    if (!collector.inWindow(at)) continue;

    const current = touch(at);
    if (projectRoot) bump(current.folders, projectRoot);

    if (msg.type === 'user') {
      const raw = extractText(msg.content);
      const request = classifyPrompt(raw);
      if (!request) continue;
      if (request.kind === 'scheduled') {
        current.scheduledRuns += 1;
      } else {
        current.prompts += 1;
        current.promptWords += request.words;
        if (request.kind === 'command') current.slashCommands += 1;
        if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
      }
    } else if (msg.type === 'gemini') {
      const model = typeof msg.model === 'string' && msg.model.trim().length > 0 ? msg.model.trim() : null;
      if (model) bump(current.models, model);
      if (extractText(msg.content).trim().length > 0) current.replies += 1;

      const t = msg.tokens;
      if (t && typeof t === 'object') {
        const input = num(t.input);
        const cached = Math.min(input, num(t.cached));
        const output = num(t.output) + num(t.thoughts);
        if (input > 0 || output > 0) {
          current.tokens.input += input;
          current.tokens.cached += cached;
          current.tokens.output += output;
          addModelTokens(current, model, { input, cached, cacheWrite: 0, output });
        }
      }

      if (Array.isArray(msg.toolCalls)) {
        for (const tc of msg.toolCalls) {
          if (!tc || typeof tc !== 'object') continue;
          const tcAt = Date.parse(tc.timestamp);
          if (collector.inWindow(tcAt)) current.times.push(tcAt);
          const name = typeof tc.name === 'string' ? tc.name : '';
          const args = tc.args && typeof tc.args === 'object' ? tc.args : {};
          current.toolCalls += 1;
          bump(current.tools, toolLabel(name));

          if (EDIT_TOOLS.has(name)) {
            current.edits += 1;
            addFile(collector, args.file_path ?? args.path, projectRoot);
          } else if (SHELL_TOOLS.has(name)) {
            const command = args.command ?? args.cmd;
            if (typeof command === 'string' || Array.isArray(command)) {
              mergeActions(tally, actionsInCommand(command));
            }
          } else if (SUBAGENT_TOOLS.has(name)) {
            current.subagentCalls += 1;
          }
        }
      }
    }
  }

  if (session) addActions(session, tally);
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((block) => typeof block?.text === 'string')
    .map((block) => block.text)
    .join('\n');
}

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
