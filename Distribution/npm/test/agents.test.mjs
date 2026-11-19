import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

import { readAntigravity } from '../src/antigravity.mjs';
import { renderCard, renderPage } from '../src/card.mjs';
import { createCollector, toolLabel } from '../src/collector.mjs';
import { readCursor } from '../src/cursor.mjs';
import { readGemini } from '../src/gemini.mjs';
import { readOpenCode } from '../src/opencode.mjs';
import { ompRoot, piRoot, readOmp, readPi } from '../src/pi.mjs';
import { computeStats, normalizeModelName, yearWindow } from '../src/stats.mjs';
import { renderTerminal } from '../src/terminal.mjs';
import { at, temporaryFolder, writeLines, YEAR } from './helpers.mjs';

function collector() {
  return createCollector(yearWindow(YEAR));
}

async function openWritableSqlite(dbPath) {
  try {
    const { DatabaseSync } = await import('node:sqlite');
    return new DatabaseSync(dbPath);
  } catch {
    return null;
  }
}

test('Pi sessions count requests, tool calls, tokens, git actions, and dedup forks', (t) => {
  const root = temporaryFolder(t);
  const project = path.join(root, '--Users-maya-code-kiln--');
  const firstFile = path.join(project, '2026-03-04T10-00-00Z_11111111-1111-1111-1111-111111111111.jsonl');
  const forkFile = path.join(project, '2026-03-04T11-00-00Z_22222222-2222-2222-2222-222222222222.jsonl');

  const sharedUser = {
    type: 'message',
    id: 'msg-u1',
    timestamp: at(3, 4, 10, 0),
    message: { role: 'user', content: [{ type: 'text', text: 'fix the cache loader' }] },
  };
  const sharedAssistant = {
    type: 'message',
    id: 'msg-a1',
    timestamp: at(3, 4, 10, 2),
    message: {
      role: 'assistant',
      provider: 'openai-codex',
      model: 'gpt-5.4',
      usage: { input: 1000, output: 200, cacheRead: 4000, cacheWrite: 500, totalTokens: 5700 },
      content: [
        { type: 'text', text: 'Updating loader now.' },
        { type: 'toolCall', id: 'tc1', name: 'edit', arguments: { path: 'src/cache.ts' } },
        { type: 'toolCall', id: 'tc2', name: 'bash', arguments: { command: 'npm test && git commit -m "fix cache"' } },
      ],
    },
  };

  writeLines(firstFile, [
    { type: 'session', version: 3, id: '11111111-1111-1111-1111-111111111111', timestamp: at(3, 4, 10, 0), cwd: '/Users/maya/code/kiln' },
    { type: 'model_change', timestamp: at(3, 4, 10, 0), provider: 'openai-codex', modelId: 'gpt-5.4' },
    sharedUser,
    sharedAssistant,
    { type: 'message', id: 'msg-tr1', timestamp: at(3, 4, 10, 3), message: { role: 'toolResult', toolName: 'bash', content: [] } },
  ]);
  // Forked transcript copies shared records and adds one new reply.
  writeLines(forkFile, [
    { type: 'session', version: 3, id: '22222222-2222-2222-2222-222222222222', timestamp: at(3, 4, 11, 0), cwd: '/Users/maya/code/kiln' },
    sharedUser,
    sharedAssistant,
    {
      type: 'message',
      id: 'msg-a2',
      timestamp: at(3, 4, 11, 5),
      message: {
        role: 'assistant',
        model: 'openai-codex/gpt-5.4',
        usage: { input: 500, output: 100, cacheRead: 0, cacheWrite: 0, totalTokens: 600 },
        content: [{ type: 'text', text: 'Done.' }],
      },
    },
  ]);

  const data = collector();
  readPi(root, data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['Pi']);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.toolCalls, 2);
  assert.equal(stats.totals.edits, 1);
  assert.equal(stats.totals.commits, 1);
  assert.equal(stats.totals.testRuns, 1);
  assert.equal(stats.totals.tokens.input, 6000);
  assert.equal(stats.totals.tokens.cached, 4000);
  assert.equal(stats.totals.tokens.output, 300);
  assert.equal(stats.topModels[0].name, 'gpt-5.4');
  assert.equal(stats.topModels[0].total, 6300);
  assert.ok(data.files.has('/Users/maya/code/kiln/src/cache.ts'));
  assert.equal(piRoot({ PI_CODING_AGENT_DIR: '/custom/pi' }, '/Users/maya'), path.join('/custom/pi', 'sessions'));
});

test('OMP rolls nested subagent transcripts into parent and normalizes Bedrock model names', (t) => {
  const root = temporaryFolder(t);
  const parentUuid = '01a023dc-72d5-7259-b5c9-3f4dc66f6f8a';
  const stem = `2026-08-21T10-27-25-013Z_${parentUuid}`;
  const project = path.join(root, '-Documents-GitHub-LokalBot');

  writeLines(path.join(project, `${stem}.jsonl`), [
    { type: 'title', v: 1, title: '' },
    { type: 'session', version: 3, id: parentUuid, timestamp: at(8, 21, 10, 27), cwd: '/Users/maya/GitHub/LokalBot' },
    { type: 'message', id: 'u1', timestamp: at(8, 21, 10, 27), message: { role: 'user', content: [{ type: 'text', text: 'update cask formula' }] } },
    {
      type: 'message',
      id: 'a1',
      timestamp: at(8, 21, 10, 29),
      message: {
        role: 'assistant',
        provider: 'amazon-bedrock',
        model: 'us.anthropic.claude-opus-4-8',
        usage: { input: 2000, output: 300, cacheRead: 8000, cacheWrite: 0 },
        content: [{ type: 'toolCall', name: 'task', arguments: { description: 'cask' } }],
      },
    },
  ]);
  writeLines(path.join(project, stem, 'CaskAgent.jsonl'), [
    { type: 'title', v: 1, title: '' },
    { type: 'message', id: 'su1', timestamp: at(8, 21, 10, 28), message: { role: 'user', content: [{ type: 'text', text: 'subagent task prompt' }] } },
    {
      type: 'message',
      id: 'sa1',
      timestamp: at(8, 21, 10, 30),
      message: {
        role: 'assistant',
        model: 'anthropic/claude-opus-4-8',
        usage: { input: 500, output: 100, cacheRead: 1500, cacheWrite: 0 },
        content: [{ type: 'toolCall', name: 'write', arguments: { path: '/Users/maya/GitHub/LokalBot/Casks/lokalbot.rb' } }],
      },
    },
  ]);

  const data = collector();
  readOmp(root, data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['OMP']);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1); // Subagent user message never inflates requests.
  assert.equal(stats.totals.subagents, 1);
  assert.equal(stats.totals.toolCalls, 2);
  assert.equal(stats.totals.edits, 1);
  assert.equal(stats.totals.tokens.input, 12000);
  assert.equal(stats.totals.tokens.cached, 9500);
  assert.equal(stats.totals.tokens.output, 400);
  assert.equal(stats.topModels.length, 1);
  assert.equal(stats.topModels[0].name, 'claude-opus-4-8');
  assert.equal(stats.topModels[0].total, 12400);
  assert.equal(ompRoot({ OMP_CODING_AGENT_DIR: '/custom/omp' }, '/Users/maya'), path.join('/custom/omp', 'sessions'));
});

test('OpenCode reads SQLite sessions, child subagents, messages, and tool parts', async (t) => {
  const dir = temporaryFolder(t);
  const dbPath = path.join(dir, 'opencode.db');
  const db = await openWritableSqlite(dbPath);
  if (!db) {
    t.skip('node:sqlite is unavailable on this Node.js version');
    return;
  }

  db.exec(`
    CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, model TEXT, time_created INTEGER, time_updated INTEGER);
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
  `);
  const t0 = Date.parse(at(5, 10, 14, 0));
  const t1 = Date.parse(at(5, 10, 14, 2));
  const t2 = Date.parse(at(5, 10, 14, 4));
  db.prepare('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?)').run('s1', null, '/Users/maya/code/harbor', 'gemini-3-flash-preview', t0, t2);
  db.prepare('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?)').run('s1_child', 's1', '/Users/maya/code/harbor', 'gemini-3-flash-preview', t1, t2);

  db.prepare('INSERT INTO message VALUES (?, ?, ?, ?)').run('m1', 's1', t0, JSON.stringify({ role: 'user', time: { created: t0 } }));
  db.prepare('INSERT INTO message VALUES (?, ?, ?, ?)').run('m2', 's1', t1, JSON.stringify({
    role: 'assistant',
    modelID: 'google/gemini-3-flash-preview',
    tokens: { input: 1000, output: 150, reasoning: 50, cache: { read: 2000, write: 100 } },
    time: { created: t1, completed: t2 },
  }));
  db.prepare('INSERT INTO message VALUES (?, ?, ?, ?)').run('m3', 's1_child', t1, JSON.stringify({
    role: 'assistant',
    modelID: 'google/gemini-3-flash-preview',
    tokens: { input: 500, output: 100, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: t1, completed: t2 },
  }));

  db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?)').run('p1', 'm1', 's1', t0, JSON.stringify({ type: 'text', text: 'run the test suite and fix failing lint' }));
  db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?)').run('p2', 'm2', 's1', t1, JSON.stringify({
    type: 'tool',
    tool: 'bash',
    state: { status: 'completed', input: { command: 'cargo test && git push' }, time: { start: t1, end: t2 } },
  }));
  db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?)').run('p3', 'm3', 's1_child', t1, JSON.stringify({
    type: 'tool',
    tool: 'write',
    state: { status: 'completed', input: { filePath: '/Users/maya/code/harbor/src/main.rs' }, time: { start: t1, end: t2 } },
  }));
  db.close();

  const data = collector();
  await readOpenCode(dir, data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['OpenCode']);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.subagents, 1);
  assert.equal(stats.totals.toolCalls, 2);
  assert.equal(stats.totals.edits, 1);
  assert.equal(stats.totals.testRuns, 1);
  assert.equal(stats.totals.pushes, 1);
  assert.equal(stats.totals.tokens.input, 3600);
  assert.equal(stats.totals.tokens.cached, 2000);
  assert.equal(stats.totals.tokens.output, 300);
  assert.equal(stats.topModels[0].name, 'gemini-3-flash-preview');
});

test('Antigravity reads transcripts, token cache math, MCP tools, edits, and subagents', (t) => {
  const brain = temporaryFolder(t);
  const transcript = path.join(brain, 'conv-abc', '.system_generated', 'logs', 'transcript.jsonl');
  writeLines(transcript, [
    { step_index: 0, source: 'USER_EXPLICIT', type: 'USER_INPUT', created_at: at(6, 12, 9, 0), content: 'ship the build fix' },
    {
      step_index: 1,
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      created_at: at(6, 12, 9, 2),
      model: 'gemini-4-carbon-high',
      input_tokens: 10000,
      cache_read_tokens: 30000,
      output_tokens: 500,
      content: 'Editing and running tests.',
      tool_calls: [
        { name: 'edit_file', args: { Path: '/Users/maya/GitHub/LokalBot/src/app.swift' } },
        { name: 'run_command', args: { Cwd: '/Users/maya/GitHub/LokalBot', CommandLine: 'swift test && git commit -m "fix build"' } },
        { name: 'invoke_subagent', args: { Subagents: [{ name: 'a' }, { name: 'b' }] } },
        { name: 'mcp_t3-code_preview_status', args: {} },
      ],
    },
    {
      step_index: 2,
      source: 'MODEL',
      type: 'CHECKPOINT',
      created_at: at(6, 12, 9, 4),
      input_tokens: 1000,
      cache_read_tokens: 40000,
      output_tokens: 200,
    },
  ]);

  const data = collector();
  readAntigravity([brain], data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['Antigravity']);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.toolCalls, 4);
  assert.equal(stats.totals.edits, 1);
  assert.equal(stats.totals.subagents, 2);
  assert.equal(stats.totals.commits, 1);
  assert.equal(stats.totals.testRuns, 1);
  assert.equal(stats.totals.tokens.input, 81000);
  assert.equal(stats.totals.tokens.cached, 70000);
  assert.equal(stats.totals.tokens.output, 700);
  assert.equal(stats.topModels[0].name, 'gemini-4-carbon-high');
  assert.equal(toolLabel('mcp_t3-code_preview_status'), 't3-code (MCP)');
  assert.equal(toolLabel('mcp-playwright-browser_navigate'), 'playwright (MCP)');
});

test('Cursor reads state.vscdb and JSONL transcripts without double-counting shared IDs', async (t) => {
  const dir = temporaryFolder(t);
  const dbPath = path.join(dir, 'state.vscdb');
  const db = await openWritableSqlite(dbPath);
  const sharedId = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb';
  const cliOnlyId = 'cccccccc-4444-5555-6666-dddddddddddd';

  // Write both a shared transcript and a CLI-only transcript under projects/.
  const projDir = path.join(dir, 'projects', 'Users-maya-GitHub-LokalBot', 'agent-transcripts');
  const jsonlBody = [
    { role: 'user', message: { content: [{ type: 'text', text: 'check git status' }] } },
    { role: 'assistant', message: { content: [{ type: 'text', text: 'Checking.' }, { type: 'tool_use', name: 'Shell', input: { command: 'git commit -m "cli commit"' } }] } },
  ];
  const sharedFile = path.join(projDir, sharedId, `${sharedId}.jsonl`);
  const cliFile = path.join(projDir, cliOnlyId, `${cliOnlyId}.jsonl`);
  writeLines(sharedFile, jsonlBody);
  writeLines(cliFile, jsonlBody);
  const ts = new Date(at(7, 15, 11, 0));
  fs.utimesSync(sharedFile, ts, ts);
  fs.utimesSync(cliFile, ts, ts);

  if (db) {
    db.exec('CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);');
    const cAt = Date.parse(at(7, 15, 10, 0));
    const uAt = Date.parse(at(7, 15, 10, 4));
    db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(`composerData:${sharedId}`, JSON.stringify({
      composerId: sharedId,
      createdAt: cAt,
      lastUpdatedAt: uAt,
      modelConfig: { modelName: 'composer-2' },
    }));
    db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(`composerData:sub-1`, JSON.stringify({
      composerId: 'sub-1',
      createdAt: cAt + 60000,
      lastUpdatedAt: uAt,
      subagentInfo: { rootParentConversationId: sharedId },
    }));
    db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(`bubbleId:${sharedId}:b1`, JSON.stringify({
      type: 1,
      text: 'refactor parser',
      createdAt: at(7, 15, 10, 0),
    }));
    db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(`bubbleId:${sharedId}:b2`, JSON.stringify({
      type: 2,
      text: '',
      modelInfo: { modelName: 'composer-2' },
      tokenCount: { inputTokens: 3000, outputTokens: 400 },
      createdAt: at(7, 15, 10, 2),
      toolFormerData: {
        name: 'run_terminal_command_v2',
        params: JSON.stringify({ command: 'npm test', cwd: '/Users/maya/GitHub/LokalBot' }),
      },
    }));
    db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)').run(`bubbleId:sub-1:sb1`, JSON.stringify({
      type: 2,
      createdAt: at(7, 15, 10, 3),
      toolFormerData: {
        name: 'edit_file_v2',
        params: JSON.stringify({ relativeWorkspacePath: 'src/parser.ts' }),
      },
    }));
    db.close();
  }

  const data = collector();
  await readCursor(dir, data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['Cursor']);
  if (db) {
    // 1 composer from state.vscdb (deduping sharedId JSONL) + 1 CLI-only JSONL = 2 sessions.
    assert.equal(stats.totals.sessions, 2);
    assert.equal(stats.totals.subagents, 1);
    assert.equal(stats.totals.toolCalls, 3);
    assert.equal(stats.totals.edits, 1);
    assert.equal(stats.totals.testRuns, 1);
    assert.equal(stats.totals.commits, 1);
    assert.equal(stats.totals.tokens.input, 3000);
    assert.equal(stats.totals.tokens.output, 400);
    assert.equal(stats.topModels[0].name, 'composer-2');
  } else {
    assert.equal(stats.totals.sessions, 2);
  }
});

test('Gemini CLI reads session JSON, project root, cached input without double counting, and thoughts', (t) => {
  const root = temporaryFolder(t);
  const proj = path.join(root, 'alpha');
  fs.mkdirSync(path.join(proj, 'chats'), { recursive: true });
  fs.writeFileSync(path.join(proj, '.project_root'), '/Users/maya/code/harbor\n');
  const sessionFile = path.join(proj, 'chats', 'session-2026-04-02T12-00-abcd.json');
  fs.writeFileSync(sessionFile, JSON.stringify({
    sessionId: 'gem-1',
    startTime: at(4, 2, 12, 0),
    lastUpdated: at(4, 2, 12, 5),
    messages: [
      { id: 'u1', timestamp: at(4, 2, 12, 0), type: 'user', content: [{ text: 'add unit tests' }] },
      {
        id: 'g1',
        timestamp: at(4, 2, 12, 3),
        type: 'gemini',
        model: 'gemini-2.5-pro',
        content: 'Added tests.',
        tokens: { input: 4469, output: 46, cached: 2988, thoughts: 38, tool: 0, total: 4553 },
        toolCalls: [
          { name: 'replace', args: { file_path: 'test/a.test.js' }, timestamp: at(4, 2, 12, 2) },
          { name: 'run_shell_command', args: { command: 'node --test && git commit -m "add tests"' }, timestamp: at(4, 2, 12, 3) },
          { name: 'codebase_investigator', args: { objective: 'find callers' }, timestamp: at(4, 2, 12, 1) },
        ],
      },
    ],
  }));
  const ts = new Date(at(4, 2, 12, 5));
  fs.utimesSync(sessionFile, ts, ts);

  const data = collector();
  readGemini(root, data);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.agents.map((a) => a.name), ['Gemini CLI']);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.toolCalls, 3);
  assert.equal(stats.totals.edits, 1);
  assert.equal(stats.totals.subagents, 1);
  assert.equal(stats.totals.commits, 1);
  assert.equal(stats.totals.testRuns, 1);
  // `input` already includes `cached`; `output` includes `thoughts`.
  assert.equal(stats.totals.tokens.input, 4469);
  assert.equal(stats.totals.tokens.cached, 2988);
  assert.equal(stats.totals.tokens.output, 84);
  assert.equal(stats.totals.tokens.total, 4553);
  assert.equal(stats.topModels[0].name, 'gemini-2.5-pro');
});

test('normalizeModelName merges provider, Bedrock, routing tag, and dated model variants', () => {
  assert.equal(normalizeModelName('anthropic/claude-opus-4-8'), 'claude-opus-4-8');
  assert.equal(normalizeModelName('us.anthropic.claude-opus-4-8-20260401-v1:0'), 'claude-opus-4-8');
  assert.equal(normalizeModelName('openai-codex/gpt-5.4'), 'gpt-5.4');
  assert.equal(normalizeModelName('openrouter/moonshotai/kimi-k2:free'), 'kimi-k2');
  assert.equal(normalizeModelName('default'), '');
  assert.equal(normalizeModelName('<synthetic>'), '');
});

test('cards and terminal render 6 agents cleanly with a multi-segment split bar', () => {
  const data = collector();
  const specs = [
    ['codex', 'gpt-5.4', 180],
    ['claude-code', 'claude-opus-4-8', 120],
    ['omp', 'us.anthropic.claude-opus-4-8', 60],
    ['cursor', 'composer-2', 45],
    ['antigravity', 'gemini-4-carbon-high', 30],
    ['pi', 'gpt-5.4', 20],
  ];
  specs.forEach(([agent, model, mins], idx) => {
    const s = data.session(agent, `s-${idx}`);
    const start = Date.parse(at(5, 1 + idx, 10, 0));
    for (let m = 0; m <= mins; m += 1) s.times.push(start + m * 60000);
    s.prompts = 5;
    s.toolCalls = 30;
    s.models.set(model, 5);
    s.tokens = { input: 500_000, cached: 300_000, output: 50_000 };
    s.modelTokens.set(model, { input: 500_000, cached: 300_000, cacheWrite: 0, output: 50_000 });
  });

  const result = computeStats(data, { year: YEAR });
  assert.equal(result.stats.agents.length, 6);

  const term = renderTerminal(result);
  assert.match(term, /Codex, Claude Code, OMP and 3 more/);

  for (const layout of ['wide', 'portrait']) {
    for (const theme of ['dark', 'light']) {
      const svg = renderCard(result, { layout, theme });
      assert.ok(svg.includes('+2'), `${layout}/${theme} header summarizes extra agents`);
      assert.ok(svg.includes('<circle '), `${layout}/${theme} draws colored legend dots`);
      assert.ok(svg.includes('Other '), `${layout}/${theme} folds trailing agents into Other`);
      assert.equal((svg.match(/<text /g) ?? []).length, (svg.match(/<\/text>/g) ?? []).length);
    }
  }
  const page = renderPage(result, { layout: 'wide' });
  assert.equal(/url\(|@import|fetch\(|XMLHttpRequest/.test(page), false);
});
