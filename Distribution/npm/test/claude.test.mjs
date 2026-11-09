import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import { claudeRoots, readClaude, readClaudeSummary } from '../src/claude.mjs';
import { createCollector } from '../src/collector.mjs';
import { yearWindow } from '../src/stats.mjs';
import { at, id, temporaryFolder, writeLines, YEAR } from './helpers.mjs';

const CWD = '/Users/maya/code/harbor-app';

function user(content, timestamp, extra = {}) {
  return { parentUuid: null, isSidechain: false, type: 'user', message: { role: 'user', content }, uuid: id('user'), timestamp, cwd: CWD, ...extra };
}

function toolResult(timestamp, output = 'ok') {
  return user([{ tool_use_id: 'toolu_1', type: 'tool_result', content: output }], timestamp);
}

function assistant(messageId, content, usage, timestamp, extra = {}) {
  return {
    parentUuid: null, isSidechain: false,
    message: { model: 'claude-fable-5', id: messageId, type: 'message', role: 'assistant', content, usage },
    type: 'assistant', uuid: id('assistant'), timestamp, cwd: CWD, ...extra,
  };
}

const usage = (input, output, cacheRead = 0, cacheWrite = 0) => ({
  input_tokens: input, output_tokens: output, cache_read_input_tokens: cacheRead, cache_creation_input_tokens: cacheWrite,
});

function collect(root) {
  const collector = createCollector(yearWindow(YEAR));
  readClaude([root], collector);
  return collector;
}

test('a session counts requests, tool calls, tokens and recorded actions', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  writeLines(path.join(root, '-Users-maya-code-harbor-app', 'session-a.jsonl'), [
    { type: 'custom-title', customTitle: 'Upload retries', sessionId: 'session-a' },
    user('add a retry to the upload job', at(3, 14, 9, 0)),
    // One API message written as two records: its usage counts once.
    assistant('msg_1', [{ type: 'text', text: 'I will add it.' }], usage(100, 5, 1000, 50), at(3, 14, 9, 0, 10)),
    assistant('msg_1', [{ type: 'tool_use', name: 'Edit', input: { file_path: `${CWD}/src/upload.ts` } }], usage(100, 40, 1000, 50), at(3, 14, 9, 0, 20)),
    toolResult(at(3, 14, 9, 0, 30)),
    assistant('msg_2', [
      { type: 'tool_use', name: 'Bash', input: { command: 'npm test && git commit -m "Retry failed uploads" && git push' } },
      { type: 'tool_use', name: 'mcp__github__create_issue', input: {} },
    ], usage(200, 60), at(3, 14, 9, 1)),
    // Harness text in the person's turn is not a request.
    user('<system-reminder>Be brief.</system-reminder>', at(3, 14, 9, 1, 30)),
    user('injected by the harness', at(3, 14, 9, 1, 40), { isMeta: true }),
    // Last year's work is out of the window.
    user('an old request', new Date(Date.UTC(YEAR - 1, 11, 31, 23)).toISOString()),
  ]);

  const collector = collect(root);
  assert.equal(collector.sessions.size, 1);
  const session = collector.sessions.get('claude-code:session-a');
  assert.equal(session.prompts, 1);
  assert.equal(session.promptWords, 7);
  assert.equal(session.replies, 1);
  assert.equal(session.toolCalls, 3);
  assert.equal(session.edits, 1);
  assert.deepEqual([...session.tools.entries()].sort(), [['Bash', 1], ['Edit', 1], ['github (MCP)', 1]]);
  assert.deepEqual(session.tokens, { input: 100 + 1000 + 50 + 200, cached: 1000, output: 40 + 60 });
  assert.deepEqual([...session.commits], ['Retry failed uploads']);
  assert.equal(session.pushes, 1);
  assert.equal(session.testRuns, 1);
  assert.deepEqual([...session.models.entries()], [['claude-fable-5', 2]]);
  assert.deepEqual([...session.folders.keys()], [CWD]);
  assert.deepEqual([...collector.files], [`${CWD}/src/upload.ts`]);
  // The prompt, three assistant records, the tool result and the reminder; not the meta or last year's.
  assert.equal(session.times.length, 6);
  assert.equal(collector.filesRead, 1);
});

test('history copied into a forked session is counted once', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  const folder = path.join(root, '-Users-maya-code-harbor-app');
  const first = user('the original request', at(4, 2, 10, 0));
  const reply = assistant('msg_1', [{ type: 'text', text: 'Done.' }], usage(10, 5), at(4, 2, 10, 0, 30));
  const original = writeLines(path.join(folder, 'original.jsonl'), [first, reply]);
  writeLines(path.join(folder, 'fork.jsonl'), [first, reply, user('a follow-up in the fork', at(4, 2, 11, 0))]);
  // The original was created first, so its records are credited to it.
  const earlier = new Date(Date.now() - 60000);
  fs.utimesSync(original, earlier, new Date());

  const collector = collect(root);
  const total = [...collector.sessions.values()].reduce((sum, session) => sum + session.prompts, 0);
  assert.equal(total, 2);
  const tokens = [...collector.sessions.values()].reduce((sum, session) => sum + session.tokens.output, 0);
  assert.equal(tokens, 5);
});

test('a subagent adds time, tokens and tool calls to its parent, never requests', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  const folder = path.join(root, '-Users-maya-code-harbor-app');
  writeLines(path.join(folder, 'parent.jsonl'), [
    user('survey the codebase', at(5, 6, 14, 0)),
    assistant('msg_1', [{ type: 'tool_use', name: 'Agent', input: { prompt: 'look around' } }], usage(10, 5), at(5, 6, 14, 0, 5)),
  ]);
  for (const name of ['subagents/agent-one.jsonl', 'subagents/workflows/wf_1/agent-two.jsonl']) {
    writeLines(path.join(folder, 'parent', name), [
      user('look around', at(5, 6, 14, 1)),
      assistant(id('msg'), [
        { type: 'text', text: 'Looking.' },
        { type: 'tool_use', name: 'Bash', input: { command: 'git commit -m "Notes from the survey"' } },
      ], usage(1000, 100), at(5, 6, 14, 2), { model: 'claude-haiku-5' }),
    ]);
  }

  const collector = collect(root);
  assert.equal(collector.sessions.size, 1);
  const session = collector.sessions.get('claude-code:parent');
  assert.equal(session.prompts, 1);
  assert.equal(session.replies, 0);
  assert.equal(session.toolCalls, 3);
  assert.equal(session.subagentFiles, 2);
  assert.equal(session.subagentCalls, 1);
  assert.equal(session.tokens.output, 205);
  assert.deepEqual([...session.commits], ['Notes from the survey']);
  assert.equal(session.times.length, 6);
});

test('a tool result adds its time and nothing else, however large', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  writeLines(path.join(root, 'project', 'big.jsonl'), [
    user('read the log', at(6, 1, 8, 0)),
    toolResult(at(6, 1, 8, 5), 'x'.repeat(3 * 1024 * 1024)),
    // Records that are neither a turn nor a tool result are not activity.
    { type: 'api-request-blob', hash: 'h', message: { role: 'system', content: 'y'.repeat(200000) } },
    { type: 'attachment', attachment: { type: 'hook_success', stdout: 'q'.repeat(150000) }, uuid: id('attachment'), timestamp: at(6, 1, 8, 6) },
  ]);
  const session = collect(root).sessions.get('claude-code:big');
  assert.equal(session.prompts, 1);
  assert.deepEqual(session.times, [Date.parse(at(6, 1, 8, 0)), Date.parse(at(6, 1, 8, 5))]);
});

test('large turns are counted like small ones', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  writeLines(path.join(root, 'project', 'mixed.jsonl'), [
    user('write the fixture file', at(6, 2, 8, 0)),
    assistant('msg_1', [{ type: 'tool_use', name: 'Write', input: { file_path: `${CWD}/fixture.json`, content: 'z'.repeat(150000) } }], usage(500, 9000, 20000), at(6, 2, 8, 1)),
    toolResult(at(6, 2, 8, 2), 'w'.repeat(150000)),
    // A request with a pasted screenshot is still a request.
    user([{ type: 'text', text: 'now commit it' }, { type: 'image', source: { type: 'base64', data: 'A'.repeat(150000) } }], at(6, 2, 8, 3)),
    assistant('msg_2', [{ type: 'tool_use', name: 'Bash', input: { command: 'git commit -m "Add the fixture"' } }], usage(700, 30, 20500), at(6, 2, 8, 4)),
    toolResult(at(6, 2, 8, 5)),
  ]);
  const collector = collect(root);
  const session = collector.sessions.get('claude-code:mixed');
  assert.equal(session.prompts, 2);
  assert.equal(session.promptWords, 7);
  assert.equal(session.toolCalls, 2);
  assert.equal(session.edits, 1);
  assert.equal(session.times.length, 6);
  assert.deepEqual(session.tokens, { input: 500 + 20000 + 700 + 20500, cached: 40500, output: 9030 });
  assert.deepEqual([...session.commits], ['Add the fixture']);
  assert.deepEqual([...collector.files], [`${CWD}/fixture.json`]);
});

test('a file that cannot be read as JSON lines does not stop the scan', (t) => {
  const root = path.join(temporaryFolder(t), 'projects');
  writeLines(path.join(root, 'project', 'broken.jsonl'), ['not json at all', '{"type":"user"']);
  writeLines(path.join(root, 'project', 'fine.jsonl'), [user('hello there', at(7, 1))]);
  const collector = collect(root);
  assert.equal(collector.sessions.size, 1);
  assert.equal(collector.sessions.get('claude-code:fine').prompts, 1);
});

test('the config folder can be moved', () => {
  const home = path.join(path.sep, 'home', 'maya');
  assert.deepEqual(claudeRoots({}, home), [path.join(home, '.claude', 'projects'), path.join(home, '.config', 'claude', 'projects')]);
  assert.deepEqual(claudeRoots({ XDG_CONFIG_HOME: path.join(home, 'cfg') }, home)[1], path.join(home, 'cfg', 'claude', 'projects'));
  assert.deepEqual(claudeRoots({ CLAUDE_CONFIG_DIR: 'a, b' }, home), [path.join('a', 'projects'), path.join('b', 'projects')]);
});

test("Claude Code's own daily count is read from beside the projects folder", (t) => {
  const base = temporaryFolder(t);
  fs.writeFileSync(path.join(base, 'stats-cache.json'), JSON.stringify({
    version: 5,
    dailyActivity: [
      { date: `${YEAR}-01-16`, messageCount: 40, sessionCount: 2, toolCallCount: 30 },
      { date: 'not a date', sessionCount: 9 },
    ],
  }));
  const days = readClaudeSummary([path.join(base, 'projects'), path.join(base, 'missing', 'projects')]);
  assert.deepEqual([...days.entries()], [[`${YEAR}-01-16`, { sessions: 2, toolCalls: 30 }]]);
});
