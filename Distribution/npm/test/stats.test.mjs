import assert from 'node:assert/strict';
import test from 'node:test';

import { createCollector } from '../src/collector.mjs';
import { computeStats, newCalendar, persona, yearWindow } from '../src/stats.mjs';
import { at, YEAR } from './helpers.mjs';

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

function collector() {
  return createCollector(yearWindow(YEAR));
}

/** A session with an event every minute from `start` for `minutes`. */
function work(into, agent, id, start, minutes, extra = {}) {
  const session = into.session(agent, id);
  const from = Date.parse(start);
  for (let minute = 0; minute <= minutes; minute += 1) session.times.push(from + minute * MINUTE);
  session.prompts += 1;
  Object.assign(session, extra);
  return session;
}

test('agent hours cap a pause at five minutes and end a run after ten', () => {
  const data = collector();
  const session = data.session('claude-code', 'a');
  const start = Date.parse(at(3, 2, 10, 0));
  // +1 min, +1 min, a 7 minute pause (counts 5), then silence for 30 minutes and one more event.
  session.times.push(start, start + MINUTE, start + 2 * MINUTE, start + 9 * MINUTE, start + 39 * MINUTE);
  session.prompts = 1;
  const { stats } = computeStats(data, { year: YEAR });
  assert.equal(stats.totals.agentMs, 7 * MINUTE);
  assert.equal(stats.totals.wallClockMs, 9 * MINUTE);
  assert.equal(stats.longestRun.ms, 9 * MINUTE);
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.activeDays, 1);
});

test('events are sorted before they are timed', () => {
  const data = collector();
  const session = data.session('codex', 'a');
  const start = Date.parse(at(3, 2, 10, 0));
  session.times.push(start + 2 * MINUTE, start, start + MINUTE);
  session.prompts = 1;
  assert.equal(computeStats(data, { year: YEAR }).stats.totals.agentMs, 2 * MINUTE);
});

test('two agents at once count twice in agent hours, once on the clock', () => {
  const data = collector();
  work(data, 'claude-code', 'a', at(5, 4, 9, 0), 60);
  work(data, 'codex', 'b', at(5, 4, 9, 30), 60);
  work(data, 'claude-code', 'c', at(5, 4, 9, 45), 10);
  const { stats } = computeStats(data, { year: YEAR });
  assert.equal(stats.totals.agentMs, 130 * MINUTE);
  assert.equal(stats.totals.wallClockMs, 90 * MINUTE);
  assert.deepEqual(stats.mostAtOnce, { count: 3, date: `${YEAR}-05-04` });
  assert.equal(stats.busiestDay.date, `${YEAR}-05-04`);
  assert.equal(stats.busiestDay.sessions, 3);
  assert.deepEqual(stats.agents.map((agent) => [agent.id, agent.sessions, agent.agentMs]), [
    ['claude-code', 2, 70 * MINUTE],
    ['codex', 1, 60 * MINUTE],
  ]);
});

test('hours land in the day and hour they were worked', () => {
  const data = collector();
  work(data, 'claude-code', 'late', at(2, 10, 23, 30), 60);
  const { stats, grid, calendar } = computeStats(data, { year: YEAR });
  const first = calendar.dayOf(Date.parse(at(2, 10, 23, 30)));
  assert.equal(grid[first * 24 + 23], 30 * MINUTE);
  assert.equal(grid[(first + 1) * 24], 30 * MINUTE);
  assert.equal(stats.byHour[23], 30 * MINUTE);
  assert.equal(stats.byMonth[1], HOUR);
  assert.equal(stats.totals.activeDays, 2);
  assert.equal(stats.shares.night, 1);
});

test('the longest streak is the longest run of days in a row', () => {
  const data = collector();
  for (const day of [1, 2, 3, 5, 6, 7, 8, 20]) work(data, 'claude-code', `d${day}`, at(6, day, 10, 0), 5);
  const { stats } = computeStats(data, { year: YEAR });
  assert.deepEqual(stats.streak, { days: 4, start: `${YEAR}-06-05`, end: `${YEAR}-06-08` });
  assert.equal(stats.totals.activeDays, 8);
});

test('days an agent only counted extend the streak and nothing else', () => {
  const data = collector();
  work(data, 'claude-code', 'a', at(6, 5, 10, 0), 30, { toolCalls: 12 });
  const summaryDays = new Map([
    [`${YEAR}-06-03`, { sessions: 2, toolCalls: 40 }],
    [`${YEAR}-06-04`, { sessions: 1, toolCalls: 10 }],
    // The logs already cover this day, so its count is not added again.
    [`${YEAR}-06-05`, { sessions: 9, toolCalls: 900 }],
    [`${YEAR - 1}-12-31`, { sessions: 5, toolCalls: 50 }],
  ]);
  const { stats, earlierDays, calendar } = computeStats(data, { year: YEAR, summaryDays });
  assert.deepEqual(stats.coverage, {
    loggedFrom: `${YEAR}-06-05`,
    earlier: { days: 2, sessions: 3, toolCalls: 50, from: `${YEAR}-06-03` },
    daysWithAnAgent: 3,
  });
  assert.deepEqual(stats.streak, { days: 3, start: `${YEAR}-06-03`, end: `${YEAR}-06-05` });
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.toolCalls, 12);
  assert.equal(stats.totals.activeDays, 1);
  assert.equal(earlierDays[calendar.dayOf(Date.parse(at(6, 3)))], 40);
  assert.equal(earlierDays[calendar.dayOf(Date.parse(at(6, 5)))], 0);
});

test('a helper thread adds tokens and tool calls but no session or hours', () => {
  const data = collector();
  work(data, 'codex', 'person', at(4, 1, 10, 0), 10, { toolCalls: 5, tokens: { input: 100, cached: 0, output: 10 } });
  const reviewer = work(data, 'codex', 'reviewer', at(4, 1, 10, 0), 10, { toolCalls: 2, tokens: { input: 50, cached: 0, output: 5 } });
  reviewer.hidden = true;
  const { stats } = computeStats(data, { year: YEAR });
  assert.equal(stats.totals.sessions, 1);
  assert.equal(stats.totals.requests, 1);
  assert.equal(stats.totals.agentMs, 10 * MINUTE);
  assert.equal(stats.totals.toolCalls, 7);
  assert.deepEqual(stats.totals.tokens, { input: 150, cached: 0, output: 15, total: 165 });
});

test('time is credited to projects by where the session ran', () => {
  const data = collector();
  const session = work(data, 'claude-code', 'a', at(4, 1, 10, 0), 60);
  session.folders.set('/Users/maya/code/harbor-app', 3);
  session.folders.set('/Users/maya/code/harbor-app/.claude/worktrees/quiet-fox', 1);
  session.folders.set('/Users/maya', 4);
  const { stats } = computeStats(data, { year: YEAR, userName: 'maya' });
  assert.deepEqual(stats.projects, [{ name: 'harbor-app', agentMs: 30 * MINUTE }]);
  assert.equal(stats.projectCount, 1);
});

test('recorded actions and subagents are totalled across sessions', () => {
  const data = collector();
  const first = work(data, 'claude-code', 'a', at(4, 1, 10, 0), 5, { subagentFiles: 3, subagentCalls: 1, pushes: 2, testRuns: 4 });
  first.commits.add('one').add('two');
  first.mergedNumbers.add('12');
  first.mergedUnnumbered = 1;
  const second = work(data, 'codex', 'b', at(4, 2, 10, 0), 5, { subagentCalls: 2 });
  second.commits.add('one');
  second.pullRequestsOpened.add('A pull request');
  second.releases.add('v1.0.0');
  data.files.add('/a').add('/b');
  const { totals } = computeStats(data, { year: YEAR }).stats;
  assert.equal(totals.commits, 3);
  assert.equal(totals.pullRequestsOpened, 1);
  assert.equal(totals.pullRequestsMerged, 2);
  assert.equal(totals.releases, 1);
  assert.equal(totals.pushes, 2);
  assert.equal(totals.testRuns, 4);
  assert.equal(totals.subagents, 5);
  assert.equal(totals.filesChanged, 2);
});

test('the title names the trait that stands out most', () => {
  const night = collector();
  for (let day = 1; day <= 5; day += 1) work(night, 'claude-code', `n${day}`, at(9, day, 23, 0), 120);
  assert.equal(computeStats(night, { year: YEAR }).stats.persona.id, 'night-shift');

  const office = collector();
  for (let day = 7; day <= 9; day += 1) work(office, 'claude-code', `o${day}`, at(9, day, 10, 0), 120);
  const steady = computeStats(office, { year: YEAR }).stats.persona;
  assert.equal(steady.id, 'steady-hand');
  assert.match(steady.line, /^\d+% of your agent hours/);

  assert.equal(computeStats(collector(), { year: YEAR }).stats.persona.id, 'first-steps');
});

test('a persona line never promises more than its figures', () => {
  const data = collector();
  for (let index = 0; index < 8; index += 1) work(data, 'claude-code', `p${index}`, at(8, 12, 10, 0), 90);
  const { stats } = computeStats(data, { year: YEAR });
  assert.equal(stats.persona.id, 'air-traffic');
  assert.equal(stats.persona.line, 'You had 8 agents working at the same moment.');
  assert.deepEqual(persona(stats), stats.persona);
});

test('a year has every day once, including the days that change the clocks', () => {
  const before = process.env.TZ;
  process.env.TZ = 'Europe/Podgorica';
  try {
    const calendar = newCalendar(2026);
    assert.equal(calendar.days, 365);
    const { start, end } = yearWindow(2026);
    assert.equal(calendar.cellOf(start), 0);
    assert.equal(calendar.cellOf(end - 1), 365 * 24 - 1);
    // 29 March 2026 has 23 hours there; 25 October has 25.
    const spring = new Date(2026, 2, 29, 12).getTime();
    assert.equal(calendar.date(calendar.dayOf(spring)), '2026-03-29');
    const autumn = new Date(2026, 9, 25, 23, 59).getTime();
    assert.equal(calendar.date(calendar.dayOf(autumn)), '2026-10-25');
    assert.equal(calendar.cellOf(autumn) % 24, 23);
    assert.equal(newCalendar(2028).days, 366);
  } finally {
    process.env.TZ = before;
  }
});
