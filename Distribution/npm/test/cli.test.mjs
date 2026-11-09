import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { at, temporaryFolder, writeLines, YEAR } from './helpers.mjs';

const BIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'lokalbot.mjs');

function run(args, env = {}) {
  const result = spawnSync(process.execPath, [BIN, ...args], {
    encoding: 'utf8',
    // The real ~/.claude and ~/.codex are never read: every run names its folders.
    env: { PATH: process.env.PATH, TZ: 'UTC', NO_COLOR: '1', ...env },
  });
  return { code: result.status, out: result.stdout, err: result.stderr };
}

test('help explains the one command and what it reads', () => {
  for (const args of [[], ['--help'], ['help']]) {
    const { code, out } = run(args);
    assert.equal(code, 0);
    assert.match(out, /npx lokalbot wrapped \[options\]/);
    assert.match(out, /makes no network requests/);
  }
  assert.match(run(['--version']).out, /^\d+\.\d+\.\d+\n$/);
});

test('a command this package does not have points to the app', () => {
  const { code, err } = run(['search', 'database']);
  assert.equal(code, 2);
  assert.match(err, /"search" is not a command here/);
  assert.match(err, /github\.com\/stevyhacker\/LokalBot/);
  assert.equal(run(['wrapped', '--year', 'soon']).code, 2);
  assert.equal(run(['wrapped', '--no-such-flag']).code, 2);
});

test('the made-up year prints as a card and as JSON', () => {
  const card = run(['wrapped', '--demo', '--year', '2026']);
  assert.equal(card.code, 0);
  assert.match(card.out, /Agent Wrapped 2026/);
  assert.match(card.out, /npx lokalbot wrapped --share/);
  assert.equal(card.out.includes('\u001b'), false);

  const json = run(['wrapped', '--demo', '--year', '2026', '--json']);
  assert.equal(json.code, 0);
  const stats = JSON.parse(json.out);
  assert.equal(stats.schema, 1);
  assert.equal(stats.year, 2026);
  assert.equal(stats.byDay.length, 365);
  assert.ok(stats.totals.agentMs > 0);
});

test('real folders are read from where the flags point', (t) => {
  const folder = temporaryFolder(t);
  const claude = path.join(folder, 'claude', 'projects');
  const codex = path.join(folder, 'codex');
  writeLines(path.join(claude, 'project', 'one.jsonl'), [
    { type: 'user', message: { role: 'user', content: 'tidy the changelog' }, uuid: 'u1', timestamp: at(2, 3, 10, 0), cwd: '/Users/maya/code/kiln' },
    { message: { model: 'claude-fable-5', id: 'm1', role: 'assistant', content: [{ type: 'tool_use', name: 'Read', input: {} }], usage: { input_tokens: 10, output_tokens: 4 } }, type: 'assistant', uuid: 'a1', timestamp: at(2, 3, 10, 3), cwd: '/Users/maya/code/kiln' },
  ]);
  const { code, out } = run(['wrapped', '--year', String(YEAR), '--json', '--claude-dir', claude, '--codex-dir', codex]);
  assert.equal(code, 0);
  const stats = JSON.parse(out);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.toolCalls, 1);
  assert.equal(stats.totals.agentMs, 3 * 60 * 1000);
  assert.deepEqual(stats.agents.map((agent) => agent.name), ['Claude Code']);
  assert.deepEqual(stats.sources.claude, [claude]);
});

test('a computer with no sessions says where it looked', (t) => {
  const folder = temporaryFolder(t);
  const { code, out, err } = run(['wrapped', '--year', String(YEAR), '--claude-dir', path.join(folder, 'a'), '--codex-dir', path.join(folder, 'b')]);
  assert.equal(code, 1);
  assert.equal(out, '');
  assert.match(err, new RegExp(`No Claude Code or Codex sessions from ${YEAR} were found`));
  assert.ok(err.includes(path.join(folder, 'a')) && err.includes(path.join(folder, 'b')));
});

test('--share writes the page and --no-open leaves the browser alone', (t) => {
  const file = path.join(temporaryFolder(t), 'card.html');
  const { code, out } = run(['wrapped', '--demo', '--year', '2026', '--share', '--no-open', '--out', file]);
  assert.equal(code, 0);
  assert.ok(out.includes('Your image is on this page: file://'));
  const page = fs.readFileSync(file, 'utf8');
  assert.ok(page.includes('<svg xmlns='));
  assert.equal(page.includes('harbor-app'), false);

  run(['wrapped', '--demo', '--year', '2026', '--share', '--no-open', '--projects', '--out', file]);
  assert.ok(fs.readFileSync(file, 'utf8').includes('harbor-app'));
});
