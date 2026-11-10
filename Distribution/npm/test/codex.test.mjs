import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';

import { readCodex } from '../src/codex.mjs';
import { createCollector } from '../src/collector.mjs';
import { yearWindow } from '../src/stats.mjs';
import { at, temporaryFolder, writeLines, YEAR } from './helpers.mjs';

const CWD = '/Users/maya/code/tide-api';
const PARENT = '11111111-1111-4111-8111-111111111111';
const CHILD = '22222222-2222-4222-8222-222222222222';
const GRANDCHILD = '33333333-3333-4333-8333-333333333333';
const REVIEWER = '44444444-4444-4444-8444-444444444444';

const line = (timestamp, type, payload) => ({ timestamp, type, payload });
const meta = (timestamp, sessionId, source = 'cli') => line(timestamp, 'session_meta', { id: sessionId, cwd: CWD, originator: 'codex_cli', source });
const tokens = (timestamp, input, cached, output) => line(timestamp, 'event_msg', {
  type: 'token_count',
  info: { total_token_usage: { input_tokens: input, cached_input_tokens: cached, output_tokens: output, total_tokens: input + output } },
});
const rollout = (root, sessionId) => path.join(root, 'sessions', String(YEAR), '03', '14', `rollout-${YEAR}-03-14T09-00-00-${sessionId}.jsonl`);

function collect(root) {
  const collector = createCollector(yearWindow(YEAR));
  readCodex(root, collector);
  return collector;
}

test('a rollout counts requests, tool calls, tokens and what the commands did', (t) => {
  const root = temporaryFolder(t);
  const lastYear = new Date(Date.UTC(YEAR - 1, 11, 31, 22)).toISOString();
  writeLines(rollout(root, PARENT), [
    meta(lastYear, PARENT),
    // A running total from before the year is the baseline, not this year's use.
    tokens(lastYear, 1000, 800, 100),
    line(at(3, 14, 9, 0), 'turn_context', { cwd: CWD, model: 'gpt-6-astra' }),
    line(at(3, 14, 9, 0, 1), 'response_item', {
      type: 'message', role: 'user',
      content: [
        { type: 'input_text', text: '<environment_context>\n<cwd>/Users/maya/code/tide-api</cwd>\n</environment_context>' },
        { type: 'input_text', text: 'make the importer idempotent' },
      ],
    }),
    line(at(3, 14, 9, 0, 2), 'event_msg', { type: 'item_completed', item: { type: 'UserMessage', id: 'u1', content: [] } }),
    line(at(3, 14, 9, 0, 5), 'response_item', { type: 'reasoning', id: 'r1', summary: [], encrypted_content: 'zzz' }),
    // The edit is logged as a patch and again as a file change: one edit.
    line(at(3, 14, 9, 1), 'response_item', {
      type: 'custom_tool_call', name: 'apply_patch', call_id: 'c1',
      input: '*** Begin Patch\n*** Update File: src/importer.rs\n@@\n-old\n+new\n*** End Patch',
    }),
    line(at(3, 14, 9, 1, 5), 'event_msg', { type: 'item_completed', item: { type: 'FileChange', id: 'f1', changes: { 'src/importer.rs': { diff: '…' } } } }),
    // The command is logged when asked for and again when it has run: one commit.
    line(at(3, 14, 9, 2), 'response_item', {
      type: 'function_call', name: 'shell', call_id: 'c2',
      arguments: JSON.stringify({ command: ['/bin/zsh', '-lc', 'cargo test && git commit -m "Make the importer idempotent"'] }),
    }),
    line(at(3, 14, 9, 2, 30), 'event_msg', {
      type: 'item_completed',
      item: { type: 'CommandExecution', id: 'x1', command: ['/bin/zsh', '-lc', 'cargo test && git commit -m "Make the importer idempotent"'], aggregated_output: 'ok' },
    }),
    line(at(3, 14, 9, 2, 40), 'response_item', { type: 'function_call_output', call_id: 'c2', output: 'ok' }),
    line(at(3, 14, 9, 3), 'response_item', { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Done.' }] }),
    tokens(at(3, 14, 9, 3, 1), 5000, 4000, 300),
    tokens(at(3, 14, 9, 3, 2), 9000, 7000, 500),
  ]);

  const collector = collect(root);
  assert.equal(collector.sessions.size, 1);
  const session = collector.sessions.get(`codex:${PARENT}`);
  assert.equal(session.prompts, 1);
  assert.equal(session.promptWords, 4);
  assert.equal(session.replies, 1);
  assert.equal(session.toolCalls, 2);
  assert.equal(session.edits, 1);
  assert.deepEqual([...session.commits], ['Make the importer idempotent']);
  assert.equal(session.testRuns, 1);
  assert.deepEqual(session.tokens, { input: 8000, cached: 6200, output: 400 });
  assert.deepEqual([...session.models.entries()], [['gpt-6-astra', 1]]);
  assert.deepEqual([...collector.files], [`${CWD}/src/importer.rs`]);
  assert.equal(session.hidden, false);
});

test('a rollout with no record of what ran falls back to what was asked for', (t) => {
  const root = temporaryFolder(t);
  writeLines(rollout(root, PARENT), [
    meta(at(3, 14, 9, 0), PARENT),
    line(at(3, 14, 9, 1), 'response_item', {
      type: 'function_call', name: 'shell', call_id: 'c1',
      arguments: JSON.stringify({ command: ['bash', '-lc', 'apply_patch <<EOF\n*** Begin Patch\n*** Add File: notes.md\n+hi\n*** End Patch\nEOF'] }),
    }),
    line(at(3, 14, 9, 2), 'response_item', { type: 'local_shell_call', call_id: 'c2', action: { command: ['bash', '-lc', 'git push'] } }),
  ]);
  const session = collect(root).sessions.get(`codex:${PARENT}`);
  assert.equal(session.toolCalls, 2);
  assert.equal(session.edits, 1);
  assert.equal(session.pushes, 1);
});

test('subagent threads add to the session a person started', (t) => {
  const root = temporaryFolder(t);
  writeLines(rollout(root, PARENT), [
    meta(at(3, 14, 9, 0), PARENT),
    line(at(3, 14, 9, 0, 1), 'response_item', { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'split this into two tasks' }] }),
    line(at(3, 14, 9, 0, 5), 'event_msg', { type: 'item_completed', item: { type: 'CollabAgentToolCall', id: 'a1', tool: 'spawn_agent', prompt: 'do half' } }),
    tokens(at(3, 14, 9, 0, 6), 100, 0, 10),
  ]);
  const spawned = (parent) => ({ subagent: { thread_spawn: { parent_thread_id: parent, depth: 1, agent_nickname: 'x' } } });
  writeLines(rollout(root, CHILD), [
    meta(at(3, 14, 9, 1), CHILD, spawned(PARENT)),
    line(at(3, 14, 9, 1, 1), 'turn_context', { cwd: CWD, model: 'gpt-6-luna' }),
    line(at(3, 14, 9, 1, 2), 'response_item', { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'do half' }] }),
    line(at(3, 14, 9, 1, 5), 'response_item', { type: 'function_call', name: 'shell', call_id: 'c1', arguments: '{"command":"ls"}' }),
    tokens(at(3, 14, 9, 1, 6), 2000, 0, 200),
  ]);
  // A subagent's own subagent is still credited to the person's session.
  writeLines(rollout(root, GRANDCHILD), [
    meta(at(3, 14, 9, 2), GRANDCHILD, spawned(CHILD)),
    line(at(3, 14, 9, 2, 5), 'response_item', { type: 'function_call', name: 'shell', call_id: 'c1', arguments: '{"command":"ls"}' }),
    tokens(at(3, 14, 9, 2, 6), 300, 0, 30),
  ]);
  // An approval reviewer has no parent: its tokens count, its hours do not.
  writeLines(rollout(root, REVIEWER), [
    meta(at(3, 14, 9, 3), REVIEWER, { subagent: { other: 'guardian' } }),
    line(at(3, 14, 9, 3, 1), 'turn_context', { cwd: CWD, model: 'codex-auto-review' }),
    line(at(3, 14, 9, 3, 2), 'response_item', { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'review this command' }] }),
    tokens(at(3, 14, 9, 3, 3), 50, 0, 5),
  ]);

  const collector = collect(root);
  assert.deepEqual([...collector.sessions.keys()].sort(), [`codex:${PARENT}`, `codex:${REVIEWER}`]);
  const session = collector.sessions.get(`codex:${PARENT}`);
  assert.equal(session.prompts, 1);
  assert.equal(session.toolCalls, 2);
  assert.equal(session.subagentFiles, 2);
  assert.equal(session.subagentCalls, 1);
  assert.equal(session.tokens.output, 240);
  assert.equal(session.models.size, 0, 'a subagent model is not the model the person chose');
  const reviewer = collector.sessions.get(`codex:${REVIEWER}`);
  assert.equal(reviewer.hidden, true);
  assert.equal(reviewer.prompts, 0);
  assert.equal(reviewer.models.size, 0);
  assert.equal(reviewer.tokens.output, 5);
});

test('a running total that starts again is counted in full', (t) => {
  const root = temporaryFolder(t);
  writeLines(rollout(root, PARENT), [
    meta(at(3, 14, 9, 0), PARENT),
    tokens(at(3, 14, 9, 1), 1000, 0, 100),
    tokens(at(3, 14, 9, 2), 3000, 0, 300),
    // Resumed in a new process: the total begins again.
    tokens(at(3, 15, 9, 0), 500, 0, 50),
  ]);
  assert.deepEqual(collect(root).sessions.get(`codex:${PARENT}`).tokens, { input: 3500, cached: 0, output: 350 });
});
