// Reads Cursor agent sessions from two local stores without double-counting:
//   1. Cursor's global SQLite store (`state.vscdb`, `cursorDiskKV` table) via
//      Node.js's built-in `node:sqlite` (Node 22.5+) — holds composer sessions,
//      exact bubble timestamps, models, subagents, tool calls, and token counts.
//   2. `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<id>/<id>.jsonl` —
//      catches Cursor Agent CLI / transcripts not in `state.vscdb`, and serves
//      as a fallback when running on Node.js < 22.5.
//
// No prompt or reply text is kept; only counts, timestamps, tool names, git
// actions, models, and token totals.

import fs from 'node:fs';
import path from 'node:path';

import { addActions, addFile, addModelTokens, bump, emptyActions, mergeActions, toolLabel } from './collector.mjs';
import { forEachLine } from './lines.mjs';
import { openReadOnlyDatabase } from './sqlite.mjs';
import { INACTIVITY_GAP } from './stats.mjs';
import { actionsInCommand, classifyPrompt } from './text.mjs';

const AGENT = 'cursor';
const PARSE_LIMIT = 16 * 1024 * 1024;
const EDIT_TOOLS = new Set([
  'edit_file', 'edit_file_v2', 'write_file', 'write', 'search_replace',
  'reapply', 'Edit', 'MultiEdit', 'Write', 'StrReplace', 'NotebookEdit',
]);
const SHELL_TOOLS = new Set([
  'run_terminal_cmd', 'run_terminal_command', 'run_terminal_command_v2',
  'Shell', 'Bash', 'bash', 'shell',
]);
const SUBAGENT_TOOLS = new Set(['task', 'Task', 'spawn_subagent', 'Agent']);

export function cursorRoots(env, home) {
  const projectsDir = path.join(home, '.cursor', 'projects');
  let stateDb;
  if (process.platform === 'darwin') {
    stateDb = path.join(home, 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb');
  } else if (process.platform === 'win32') {
    stateDb = path.join(env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'Cursor', 'User', 'globalStorage', 'state.vscdb');
  } else {
    stateDb = path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'Cursor', 'User', 'globalStorage', 'state.vscdb');
  }
  return { projectsDir, stateDb };
}

/**
 * `source` is either `{ projectsDir, stateDb }` (default) or a string folder
 * from `--cursor-dir` (looks for `state.vscdb` and/or `projects/` inside, or
 * treats the folder itself as `projects/`).
 */
export async function readCursor(source, collector, onProgress = () => {}) {
  if (!source) return;
  let projectsDir = null;
  let stateDb = null;
  if (typeof source === 'string') {
    if (source.endsWith('.vscdb') || source.endsWith('.db')) {
      stateDb = source;
    } else {
      const candidateDb = path.join(source, 'state.vscdb');
      if (fs.existsSync(candidateDb)) stateDb = candidateDb;
      const candidateProjects = path.join(source, 'projects');
      projectsDir = fs.existsSync(candidateProjects) ? candidateProjects : source;
    }
  } else {
    projectsDir = source.projectsDir ?? null;
    stateDb = source.stateDb ?? null;
  }

  const seenIds = new Set();
  if (stateDb) {
    await readStateDb(stateDb, collector, seenIds, onProgress);
  }
  if (projectsDir) {
    readTranscriptJsonls(projectsDir, collector, seenIds, onProgress);
  }
}

async function readStateDb(dbPath, collector, seenIds, onProgress) {
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
    const hasTable = db
      .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cursorDiskKV'")
      .get();
    if (!hasTable) return;

    const rows = db
      .prepare("SELECT key, value FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;'")
      .all();

    const matched = [];
    for (const row of rows) {
      if (typeof row.value !== 'string' || row.value.length > PARSE_LIMIT) continue;
      let data;
      try {
        data = JSON.parse(row.value);
      } catch {
        continue;
      }
      if (!data || typeof data !== 'object') continue;
      const id = nonEmpty(data.composerId) ?? row.key.slice('composerData:'.length);
      if (!id) continue;
      const created = num(data.createdAt);
      const updated = num(data.lastUpdatedAt) || created;
      // Keep composers whose lifetime overlaps the requested year window.
      if (updated > 0 && updated < collector.start) continue;
      if (created > 0 && created >= collector.end) continue;
      const parentId = nonEmpty(data.subagentInfo?.rootParentConversationId)
        ?? nonEmpty(data.subagentInfo?.parentComposerId);
      const defaultModel = nonEmpty(data.modelConfig?.modelName);
      const hintFolder = folderFromCreatedFiles(data.newlyCreatedFiles);
      matched.push({ id, parentId, defaultModel, hintFolder });
    }

    const bubbleStmt = db.prepare('SELECT value FROM cursorDiskKV WHERE key >= ? AND key < ?');
    let done = 0;

    for (const comp of matched) {
      done += 1;
      const side = Boolean(comp.parentId);
      const rootId = side ? comp.parentId : comp.id;
      const prefix = `bubbleId:${comp.id}:`;
      const bubbles = bubbleStmt.all(prefix, `${prefix}\uffff`);
      if (bubbles.length === 0) {
        if (done % 25 === 0 || done === matched.length) onProgress(done, matched.length);
        continue;
      }

      let session = null;
      let launched = false;
      let cwd = comp.hintFolder;
      const tally = emptyActions();
      let anyInWindow = false;

      const touch = (at) => {
        session ??= collector.session(AGENT, rootId);
        session.times.push(at);
        if (side && !launched) {
          launched = true;
          session.subagentFiles += 1;
        }
        return session;
      };

      for (const bRow of bubbles) {
        if (typeof bRow.value !== 'string' || bRow.value.length > PARSE_LIMIT) continue;
        let bubble;
        try {
          bubble = JSON.parse(bRow.value);
        } catch {
          continue;
        }
        if (!bubble || typeof bubble !== 'object') continue;
        const at = parseBubbleTime(bubble);
        if (!collector.inWindow(at)) continue;

        anyInWindow = true;
        const current = touch(at);
        if (cwd && !side) bump(current.folders, cwd);

        if (bubble.type === 1) {
          if (!side) {
            const request = classifyPrompt(bubble.text);
            if (request) {
              if (request.kind === 'scheduled') {
                current.scheduledRuns += 1;
              } else {
                current.prompts += 1;
                current.promptWords += request.words;
                if (request.kind === 'command') current.slashCommands += 1;
                if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
              }
            }
          }
        } else if (bubble.type === 2) {
          const model = nonEmpty(bubble.modelInfo?.modelName) ?? comp.defaultModel;
          if (model && !side && model.toLowerCase() !== 'default') bump(current.models, model);

          const inTok = num(bubble.tokenCount?.inputTokens);
          const outTok = num(bubble.tokenCount?.outputTokens);
          if (inTok > 0 || outTok > 0) {
            current.tokens.input += inTok;
            current.tokens.output += outTok;
            addModelTokens(current, model, { input: inTok, cached: 0, cacheWrite: 0, output: outTok });
          }

          const tf = bubble.toolFormerData;
          if (tf && typeof tf === 'object' && typeof tf.name === 'string' && tf.name.length > 0) {
            const name = tf.name;
            const args = parseJsonObject(tf.params) ?? parseJsonObject(tf.rawArgs) ?? {};
            current.toolCalls += 1;
            bump(current.tools, toolLabel(name));

            if (EDIT_TOOLS.has(name)) {
              current.edits += 1;
              addFile(collector, args.relativeWorkspacePath ?? args.target_file ?? args.file_path ?? args.path, cwd);
            } else if (SHELL_TOOLS.has(name)) {
              if (typeof args.cwd === 'string' && args.cwd.length > 0) {
                cwd = args.cwd;
                if (!side) bump(current.folders, cwd);
              }
              const command = args.command ?? args.cmd;
              if (typeof command === 'string' || Array.isArray(command)) {
                mergeActions(tally, actionsInCommand(command));
              }
            } else if (SUBAGENT_TOOLS.has(name) && !side) {
              current.subagentCalls += 1;
            }
          } else if (!side && typeof bubble.text === 'string' && bubble.text.trim().length > 0) {
            current.replies += 1;
          }
        }
      }

      if (anyInWindow) {
        seenIds.add(comp.id);
        if (session) addActions(session, tally);
      }
      if (done % 25 === 0 || done === matched.length) onProgress(done, matched.length);
    }

    collector.filesRead += 1;
    collector.bytesRead += stat.size;
  } catch {
    collector.unreadableFiles += 1;
  } finally {
    try {
      db.close();
    } catch {
      // Ignore close error.
    }
  }
}

function readTranscriptJsonls(projectsDir, collector, seenIds, onProgress) {
  const candidates = [];
  for (const project of entries(projectsDir)) {
    if (!project.isDirectory()) continue;
    const transcriptsDir = path.join(projectsDir, project.name, 'agent-transcripts');
    for (const item of entries(transcriptsDir)) {
      let file = null;
      let id = null;
      if (item.isFile() && item.name.endsWith('.jsonl')) {
        file = path.join(transcriptsDir, item.name);
        id = item.name.slice(0, -'.jsonl'.length);
      } else if (item.isDirectory()) {
        const nested = path.join(transcriptsDir, item.name, `${item.name}.jsonl`);
        if (fs.existsSync(nested)) {
          file = nested;
          id = item.name;
        }
      }
      if (!file || !id || seenIds.has(id)) continue;
      let stat;
      try {
        stat = fs.statSync(file);
      } catch {
        continue;
      }
      if (!stat.isFile() || stat.mtimeMs < collector.start) continue;
      if (stat.birthtimeMs > 0 && stat.birthtimeMs >= collector.end) continue;
      candidates.push({
        file,
        id,
        projectSlug: project.name,
        born: stat.birthtimeMs > 0 ? stat.birthtimeMs : stat.mtimeMs,
        mtime: stat.mtimeMs,
      });
    }
  }

  let done = 0;
  for (const item of candidates) {
    try {
      readJsonlTranscript(item, collector);
      collector.filesRead += 1;
    } catch {
      collector.unreadableFiles += 1;
    }
    done += 1;
    onProgress(done, candidates.length);
  }
}

function readJsonlTranscript({ file, id, projectSlug, born, mtime }, collector) {
  // Cursor JSONL files omit per-line timestamps; anchor conservatively on file
  // creation/modification time within the year so hours are never inflated.
  const times = [];
  if (collector.inWindow(mtime)) {
    if (collector.inWindow(born) && born < mtime && mtime - born <= INACTIVITY_GAP) {
      times.push(born);
    }
    times.push(mtime);
  } else if (collector.inWindow(born)) {
    times.push(born);
  }
  if (times.length === 0) return;

  let session = null;
  const tally = emptyActions();
  const folder = decodeCursorProjectSlug(projectSlug);

  const ensure = () => {
    if (!session) {
      session = collector.session(AGENT, id);
      session.times.push(...times);
      if (folder) bump(session.folders, folder);
    }
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
    const role = record?.role;
    const content = record?.message?.content;
    if (role === 'user') {
      const raw = extractText(content);
      const request = classifyPrompt(raw);
      if (!request) return;
      const current = ensure();
      if (request.kind === 'scheduled') {
        current.scheduledRuns += 1;
      } else {
        current.prompts += 1;
        current.promptWords += request.words;
        if (request.kind === 'command') current.slashCommands += 1;
        if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
      }
    } else if (role === 'assistant' && Array.isArray(content)) {
      const current = ensure();
      let countedReply = false;
      for (const block of content) {
        if (!block || typeof block !== 'object') continue;
        if (block.type === 'text' && !countedReply && typeof block.text === 'string' && block.text.trim().length > 0) {
          current.replies += 1;
          countedReply = true;
        } else if (block.type === 'tool_use' || block.type === 'toolCall') {
          const name = typeof block.name === 'string' ? block.name : '';
          const args = block.input && typeof block.input === 'object' ? block.input : {};
          current.toolCalls += 1;
          bump(current.tools, toolLabel(name));
          if (EDIT_TOOLS.has(name)) {
            current.edits += 1;
            addFile(collector, args.path ?? args.file_path ?? args.target_file, folder);
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
  });

  if (session) addActions(session, tally);
}

function entries(folder) {
  try {
    return fs.readdirSync(folder, { withFileTypes: true });
  } catch {
    return [];
  }
}

function parseBubbleTime(bubble) {
  if (typeof bubble.createdAt === 'string') {
    const parsed = Date.parse(bubble.createdAt);
    if (Number.isFinite(parsed)) return parsed;
  }
  if (typeof bubble.createdAt === 'number' && Number.isFinite(bubble.createdAt)) return bubble.createdAt;
  const start = bubble.timingInfo?.clientStartTime;
  if (typeof start === 'number' && Number.isFinite(start)) return start;
  return NaN;
}

function folderFromCreatedFiles(files) {
  if (!Array.isArray(files) || files.length === 0) return null;
  for (const item of files) {
    const uri = item?.uri;
    const raw = typeof uri === 'string' ? uri : (uri?.fsPath ?? uri?.path);
    if (typeof raw === 'string' && raw.length > 0) {
      const cleaned = raw.replace(/^file:\/\//, '');
      return path.posix.dirname(cleaned.replaceAll('\\', '/'));
    }
  }
  return null;
}

/** `Users-alice-Documents-GitHub-LokalBot` -> `/Users/alice/Documents/GitHub/LokalBot` (best-effort leaf). */
function decodeCursorProjectSlug(slug) {
  if (typeof slug !== 'string' || slug.length === 0) return null;
  const match = /(?:GitHub|github|repos|repositories|projects|code|dev|workspace|workspaces)-(.+)$/.exec(slug);
  return match ? `/${match[1]}` : null;
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((block) => block?.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('\n');
}

function parseJsonObject(raw) {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) return raw;
  if (typeof raw !== 'string' || !raw.startsWith('{')) return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function num(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}
