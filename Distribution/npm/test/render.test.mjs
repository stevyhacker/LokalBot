import assert from 'node:assert/strict';
import test from 'node:test';

import { renderCard, renderPage } from '../src/card.mjs';
import { demoYear } from '../src/demo.mjs';
import { compact, dayLabel, duration, hours } from '../src/format.mjs';
import { coverageNote, renderTerminal } from '../src/terminal.mjs';
import './helpers.mjs';

const ESCAPE = '\u001b';

test('figures are written the way a person would say them', () => {
  assert.equal(compact(999), '999');
  assert.equal(compact(1500), '1.5K');
  assert.equal(compact(148203), '148K');
  assert.equal(compact(34_400_000_000), '34.4B');
  assert.equal(hours(538.4 * 3600000), '538');
  assert.equal(hours(2.25 * 3600000), '2.3');
  assert.equal(duration(42 * 60000), '42 min');
  assert.equal(duration(372 * 60000), '6 h 12 min');
  assert.equal(duration(120 * 60000), '2 h');
  assert.equal(dayLabel('2026-10-14'), 'Oct 14');
});

test('the made-up year is the same every time', () => {
  assert.deepEqual(demoYear(2026).stats, demoYear(2026).stats);
  assert.notDeepEqual(demoYear(2026).stats.totals, demoYear(2025).stats.totals);
});

test('the terminal card states the year in plain text', () => {
  const result = demoYear(2026);
  const card = renderTerminal(result);
  assert.equal(card.includes(ESCAPE), false);
  assert.match(card, /Agent Wrapped 2026 {3}Claude Code and Codex/);
  assert.ok(card.includes(result.stats.persona.title));
  assert.match(card, /\d+ hours of agent work on \d+ days/);
  assert.match(card, /requests from you, [\d,]+ tool calls from them/);
  assert.match(card, /Busiest day: Oct \d+/);
  assert.match(card, /Most hours: harbor-app/);
  assert.match(card, /Nothing was uploaded\./);
  // Eight rows of the day under a row of months, each one column per week.
  const rows = card.split('\n').filter((line) => /^ {2}(12a| 3a| 6a| 9a|12p| 3p| 6p| 9p) {2}/.test(line));
  assert.equal(rows.length, 8);
  assert.ok(rows.every((row) => [...row].length === rows[0].length && [...row].length <= 62));
  assert.ok(renderTerminal(result, { color: true }).includes(ESCAPE));
});

test('the image leaves project names out unless asked', () => {
  const result = demoYear(2026);
  const quiet = renderCard(result);
  assert.ok(quiet.startsWith('<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1500"'));
  assert.ok(quiet.trimEnd().endsWith('</svg>'));
  assert.equal(quiet.includes('harbor-app'), false);
  assert.ok(quiet.includes('npx lokalbot wrapped'));
  assert.ok(quiet.includes('Nothing was uploaded.'));
  assert.equal((quiet.match(/<text /g) ?? []).length, (quiet.match(/<\/text>/g) ?? []).length);
  assert.ok(renderCard(result, { showProjects: true }).includes('Most hours went to harbor-app, tide-api and northwind-site.'));
});

test('names that look like markup are written as text', () => {
  const result = demoYear(2026);
  result.stats.projects[0].name = 'a<b>&"c"';
  result.stats.persona = { id: 'x', title: 'Tom & <Jerry>', line: 'A "quoted" line.' };
  const card = renderCard(result, { showProjects: true });
  assert.ok(card.includes('a&lt;b&gt;&amp;&quot;c&quot;'));
  assert.ok(card.includes('Tom &amp; &lt;Jerry&gt;'));
  assert.equal(card.includes('<Jerry>'), false);
});

test('a long title is set smaller, not cut off', () => {
  const result = demoYear(2026);
  result.stats.persona.title = 'The Air Traffic Controller';
  const size = Number(/font-size="(\d+)" fill="#ecf3f7" letter-spacing/.exec(renderCard(result))[1]);
  assert.ok(size < 128 && size >= 60, `size ${size}`);
  assert.ok(26 * size * 0.5 <= 1040);
});

test('days whose logs are gone are drawn and explained', () => {
  const result = demoYear(2026);
  assert.deepEqual(coverageNote(result.stats), []);
  result.stats.coverage = { loggedFrom: '2026-06-18', earlier: { days: 48, sessions: 186, toolCalls: 12080, from: '2026-01-16' }, daysWithAnAgent: 117 };
  result.earlierDays[20] = 300;
  const note = coverageNote(result.stats).join(' ');
  assert.match(note, /go back to Jun 18\./);
  assert.match(note, /48 earlier days this year: 186 sessions, 12,080 tool calls\./);
  assert.match(note, /"cleanupPeriodDays": 3650 in ~\/\.claude\/settings\.json/);
  assert.ok(renderTerminal(result).includes('▪'));
  assert.ok(renderCard(result).includes('The marks under the year are 48 earlier days'));

  // Logs that begin late with no earlier count still explain why.
  result.stats.coverage.earlier = null;
  assert.match(coverageNote(result.stats).join(' '), /deletes session logs after 30 days/);
  // A year of Codex alone has nothing to explain: Codex keeps its logs.
  result.stats.agents = result.stats.agents.filter((agent) => agent.id === 'codex');
  assert.deepEqual(coverageNote(result.stats), []);
});

test('the page is one file that loads nothing', () => {
  const page = renderPage(demoYear(2026));
  assert.ok(page.startsWith('<!doctype html>'));
  assert.ok(page.includes('<svg xmlns='));
  assert.ok(page.includes('>Save image</button>'));
  assert.ok(page.includes('>Copy image</button>'));
  assert.ok(page.includes('agent-wrapped-2026.png'));
  // No script, style sheet, image or font is fetched from anywhere.
  assert.equal(/<(script|img|link|iframe)[^>]+(src|href)=/.test(page), false);
  assert.equal(/url\(|@import|fetch\(|XMLHttpRequest/.test(page), false);
});

test('a year with one agent has no split to draw', () => {
  const result = demoYear(2026);
  result.stats.agents = result.stats.agents.slice(0, 1);
  assert.match(renderCard(demoYear(2026)), /Codex \d+%</);
  const card = renderCard(result);
  assert.equal(/Codex \d+%</.test(card), false);
  assert.equal(card.includes('Claude Code and Codex<'), false);
  assert.ok(renderTerminal(result).includes('Agent Wrapped 2026   Claude Code\n'));
});
