import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { openReadOnlyDatabase } from './sqlite.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'opencode';
const EDIT_TOOLS = new Set(['write', 'edit', 'patch', 'multiedit', 'apply_patch', 'Write', 'Edit']);
const SHELL_TOOLS = new Set(['bash', 'shell', 'Bash']);
const SUBAGENT_TOOLS = new Set(['task', 'subagent', 'Task']);

export function opencodeRoot(env, home) {
  const xdg = path.join(env.XDG_DATA_HOME || path.join(home, '.local', 'share'), 'opencode');
  if (process.platform === 'win32' && !fs.existsSync(path.join(xdg, 'opencode.db'))) {
    const local = path.join(env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'opencode');
    if (fs.existsSync(path.join(local, 'opencode.db'))) return local;
  }
  return xdg;
}

export async function readOpenCode(root, collector, onProgress = () => {}) {
  if (!root) return;
  const dbPath = root.endsWith('.db') ? root : path.join(root, 'opencode.db');
  let stat;
  try {
    stat = fs.statSync(dbPath);
  } catch {
    return;
  }
  if (!stat.isFile()) return;

  const { db, unsupported } = await openReadOnlyDatabase(dbPath);
  if (unsupported) {
    collector.sqliteSkipped += 1;
    return;
  }
  if (!db) {
    collector.unreadableFiles += 1;
    return;
  }

  try {
    const tables = new Set(
      db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((row) => row.name),
    );
    if (!tables.has('session') || !tables.has('message')) return;

    const sessionRows = db.prepare('SELECT id, parent_id, directory, model FROM session').all();
    const metaById = new Map();
    const parents = new Map();
    for (const row of sessionRows) {
      metaById.set(row.id, {
        id: row.id,
        parent: typeof row.parent_id === 'string' && row.parent_id.length > 0 ? row.parent_id : null,
        directory: typeof row.directory === 'string' && row.directory.length > 0 ? row.directory : null,
        model: typeof row.model === 'string' && row.model.length > 0 ? row.model : null,
      });
      if (row.parent_id) parents.set(row.id, row.parent_id);
    }
    const rootOf = (id) => {
      let current = id;
      for (let hops = 0; hops < 16 && parents.has(current); hops += 1) current = parents.get(current);
      return current;
    };

    const messages = db
      .prepare('SELECT id, session_id, time_created, data FROM message WHERE time_created >= ? AND time_created < ? ORDER BY time_created ASC')
      .all(collector.start, collector.end);

    if (messages.length === 0) {
      collector.filesRead += 1;
      collector.bytesRead += stat.size;
      onProgress(1, 1);
      return;
    }

    const userTextByMsg = new Map();
    const toolParts = [];
    if (tables.has('part')) {
      const parts = db
        .prepare('SELECT message_id, session_id, time_created, data FROM part WHERE time_created >= ? AND time_created < ?')
        .all(collector.start, collector.end);
      for (const row of parts) {
        let data;
        try {
          data = JSON.parse(row.data);
        } catch {
          continue;
        }
        if (!data || typeof data !== 'object') continue;
        if (data.type === 'text' && typeof data.text === 'string' && data.text.length > 0) {
          const list = userTextByMsg.get(row.message_id) ?? [];
          list.push(data.text);
          userTextByMsg.set(row.message_id, list);
        } else if (data.type === 'tool') {
          toolParts.push({ sessionId: row.session_id, created: row.time_created, data });
        }
      }
    }

    const launchedChildren = new Set();
    const actionsByRoot = new Map();
    const tallyFor = (rootId) => {
      let tally = actionsByRoot.get(rootId);
      if (!tally) {
        tally = emptyActions();
        actionsByRoot.set(rootId, tally);
      }
      return tally;
    };

    const touch = (rawSessionId, at) => {
      const meta = metaById.get(rawSessionId);
      const side = Boolean(meta?.parent);
      const rootId = side ? rootOf(meta.parent) : rawSessionId;
      const session = collector.session(AGENT, rootId);
      session.times.push(at);
      if (side && !launchedChildren.has(rawSessionId)) {
        launchedChildren.add(rawSessionId);
        session.subagentFiles += 1;
      }
      return { session, rootId, side, meta };
    };

    const totalWork = messages.length + toolParts.length;
    let done = 0;

    for (const row of messages) {
      done += 1;
      let data;
      try {
        data = JSON.parse(row.data);
      } catch {
        continue;
      }
      if (!data || typeof data !== 'object') continue;
      const created = num(data.time?.created) || num(row.time_created);
      if (!collector.inWindow(created)) continue;

      const { session, rootId, side, meta } = touch(row.session_id, created);
      const completed = num(data.time?.completed);
      if (completed > created && collector.inWindow(completed)) session.times.push(completed);

      const cwd = (typeof data.path?.cwd === 'string' && data.path.cwd) || meta?.directory || null;
      if (cwd && !side) bump(session.folders, cwd);

      if (data.role === 'user') {
        if (!side) {
          const texts = userTextByMsg.get(row.id);
          if (texts && texts.length > 0) {
            const request = classifyPrompt(texts.join('\n'));
            if (request) {
              if (request.kind === 'scheduled') {
                session.scheduledRuns += 1;
              } else {
                session.prompts += 1;
                session.promptWords += request.words;
                if (request.kind === 'command') session.slashCommands += 1;
                if (request.kind === 'terminal') mergeActions(tallyFor(rootId), actionsInCommand(request.command));
              }
            }
          } else {
            session.prompts += 1;
          }
        }
      } else if (data.role === 'assistant') {
        const model = nonEmpty(data.modelID) ?? nonEmpty(data.model) ?? meta?.model ?? null;
        if (model && !side) bump(session.models, model);
        if (!side) session.replies += 1;

        const t = data.tokens;
        if (t && typeof t === 'object') {
          const uncached = num(t.input);
          const cacheRead = num(t.cache?.read);
          const cacheWrite = num(t.cache?.write);
          const output = num(t.output) + num(t.reasoning);
          const input = uncached + cacheRead + cacheWrite;
          if (input > 0 || output > 0) {
            session.tokens.input += input;
            session.tokens.cached += cacheRead;
            session.tokens.output += output;
            addModelTokens(session, model, { input, cached: cacheRead, cacheWrite, output });
          }
        }
      }
      if (done % 50 === 0 || done === totalWork) onProgress(done, totalWork);
    }

    for (const part of toolParts) {
      done += 1;
      const state = part.data.state && typeof part.data.state === 'object' ? part.data.state : {};
      const startAt = num(state.time?.start) || num(part.created);
      if (!collector.inWindow(startAt)) continue;

      const { session, rootId, side, meta } = touch(part.sessionId, startAt);
      const endAt = num(state.time?.end);
      if (endAt > startAt && collector.inWindow(endAt)) session.times.push(endAt);

      const name = typeof part.data.tool === 'string' ? part.data.tool : '';
      const input = state.input && typeof state.input === 'object' ? state.input : {};
      const cwd = meta?.directory ?? null;
      session.toolCalls += 1;
      bump(session.tools, toolLabel(name));

      if (EDIT_TOOLS.has(name)) {
        session.edits += 1;
        addFile(collector, input.filePath ?? input.file_path ?? input.path, cwd);
      } else if (SHELL_TOOLS.has(name)) {
        const command = input.command ?? input.cmd;
        if (typeof command === 'string' || Array.isArray(command)) {
          mergeActions(tallyFor(rootId), actionsInCommand(command));
        }
      } else if (SUBAGENT_TOOLS.has(name) && !side) {
        session.subagentCalls += 1;
      }
      if (done % 50 === 0 || done === totalWork) onProgress(done, totalWork);
    }

    for (const [rootId, tally] of actionsByRoot) {
      const session = collector.sessions.get(`${AGENT}:${rootId}`);
      if (session) addActions(session, tally);
    }

    collector.filesRead += 1;
    collector.bytesRead += stat.size;
    onProgress(totalWork, totalWork);
  } catch {
    collector.unreadableFiles += 1;
  } finally {
    try {
      db.close();
    } catch {
    }
  }
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
