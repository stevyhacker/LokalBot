import assert from 'node:assert/strict';
import test from 'node:test';

import { renderCard, renderPage } from '../src/card.mjs';
import { cardShareCaption } from '../src/card-renderer.mjs';
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
  assert.ok(quiet.includes('npx lokalbot'));
  assert.ok(quiet.includes('>lokalbot.com/wrapped</text>'));
  assert.ok(quiet.includes('Nothing was uploaded.'));
  assert.equal((quiet.match(/<text /g) ?? []).length, (quiet.match(/<\/text>/g) ?? []).length);
  assert.ok(renderCard(result, { showProjects: true }).includes('Most hours went to harbor-app, tide-api and northwind-site.'));

  const wide = renderCard(result, { layout: 'wide' });
  assert.ok(wide.startsWith('<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"'));
  assert.ok(wide.includes('npx lokalbot'));
  assert.ok(wide.includes('>lokalbot.com/wrapped</text>'));
  assert.ok(wide.includes('>Mon</text>'));
  assert.ok(wide.includes('>Less</text>'));
  assert.ok(wide.includes('>More</text>'));
  assert.equal((wide.match(/<text /g) ?? []).length, (wide.match(/<\/text>/g) ?? []).length);

  const wideLight = renderCard(result, { layout: 'wide', theme: 'light' });
  assert.ok(wideLight.includes('fill="#f4f7f7"'));
  assert.ok(wideLight.includes('fill="#0b1219"'));
  assert.ok(wideLight.includes('TOP MODELS'));
  assert.ok(wideLight.includes('claude-fable-5'));
  assert.equal((wideLight.match(/<text /g) ?? []).length, (wideLight.match(/<\/text>/g) ?? []).length);

  const portraitLight = renderCard(result, { layout: 'portrait', theme: 'light' });
  assert.ok(portraitLight.includes('fill="#f4f7f7"'));
  assert.ok(portraitLight.includes('TOP MODELS'));
  assert.equal((portraitLight.match(/<text /g) ?? []).length, (portraitLight.match(/<\/text>/g) ?? []).length);
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
  result.stats.coverage = { loggedFrom: '2026-06-18', claudeLoggedFrom: '2026-06-18', earlier: { days: 48, sessions: 186, toolCalls: 12080, from: '2026-01-16' }, daysWithAnAgent: 117 };
  result.earlierDays[20] = 300;
  const note = coverageNote(result.stats).join(' ');
  assert.match(note, /Claude Code's session logs on this computer go back to Jun 18\./);
  assert.match(note, /48 earlier days this year: 186 sessions, 12,080 tool calls\./);
  assert.match(note, /"cleanupPeriodDays": 3650 in ~\/\.claude\/settings\.json/);
  assert.ok(renderTerminal(result).includes('▪'));
  assert.ok(renderCard(result).includes('The marks under the year are 48 earlier days'));

  result.stats.coverage.earlier = null;
  assert.match(coverageNote(result.stats).join(' '), /deletes session logs after 30 days/);
  result.stats.agents = result.stats.agents.filter((agent) => agent.id === 'codex');
  assert.deepEqual(coverageNote(result.stats), []);
});

test('the page is one file that loads nothing', () => {
  const page = renderPage(demoYear(2026));
  assert.ok(page.startsWith('<!doctype html>'));
  assert.ok(page.includes('<svg xmlns='));
  assert.ok(page.includes('>Save image</button>'));
  assert.ok(page.includes('>Copy image</button>'));
  assert.ok(page.includes('>Post on X</a>'));
  assert.ok(page.includes('>Copy caption</button>'));
  assert.ok(page.includes('Wide 16:9'));
  assert.ok(page.includes('Give Claude Code &amp; Codex memory of your meetings.'));
  assert.ok(page.includes('agent-wrapped-2026.png'));
  assert.equal(/<(script|img|link|iframe)[^>]+(src|href)=/.test(page), false);
  assert.equal(/url\(|@import|fetch\(|XMLHttpRequest/.test(page), false);
});

test('short logged windows auto-zoom so 30-day Claude logs look full', () => {
  const result = demoYear(2026);
  const startDay = 290;
  for (let day = 0; day < result.calendar.days; day += 1) {
    if (day < startDay || day > startDay + 19) {
      result.stats.byDay[day] = 0;
      for (let hour = 0; hour < 24; hour += 1) result.grid[day * 24 + hour] = 0;
    }
  }
  result.stats.coverage = {
    loggedFrom: '2026-10-18',
    claudeLoggedFrom: '2026-10-18',
    earlier: { days: 120, sessions: 310, toolCalls: 24000, from: '2026-01-12' },
    daysWithAnAgent: 140,
  };
  const zoomed = renderCard(result);
  assert.match(zoomed, /Zoomed to .* plus 120 earlier days counted by Claude Code/);
  const fullYear = renderCard(result, { window: 'year' });
  assert.match(fullYear, /The marks under the year are 120 earlier days/);
  const page = renderPage(result);
  assert.ok(page.includes('Active window'));
  assert.ok(page.includes('Full year'));
  assert.ok(page.includes('cleanupPeriodDays'));
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

test('the terminal card says when compressed Codex logs were left out', () => {
  const result = demoYear(2026);
  assert.ok(!renderTerminal(result).includes('compressed Codex'));
  result.stats.sources = { ...result.stats.sources, compressedSkipped: 3 };
  assert.match(renderTerminal(result), /3 compressed Codex logs left out: reading them needs Node\.js 22\.15 or later\./);
});

test('share caption includes both npx lokalbot and the wrapped URL', () => {
  const { stats } = demoYear(2026);
  const withValue = cardShareCaption(stats, { showApiValue: true });
  assert.ok(withValue.includes('npx lokalbot'));
  assert.ok(withValue.includes('https://www.lokalbot.com/wrapped'));
  assert.ok(withValue.includes('API value'));

  const withoutValue = cardShareCaption(stats, { showApiValue: false });
  assert.ok(withoutValue.includes('npx lokalbot'));
  assert.ok(withoutValue.includes('https://www.lokalbot.com/wrapped'));
  assert.equal(withoutValue.includes('API value'), false);
});

test('local share page renders OS-aware install tabs and MCP bridge commands', () => {
  const result = demoYear(2026);

  const macPage = renderPage(result, { platform: 'darwin' });
  assert.ok(macPage.includes('data-os="darwin" aria-pressed="true"'));
  assert.ok(macPage.includes('data-os="win32" aria-pressed="false"'));
  assert.ok(macPage.includes('data-os="linux" aria-pressed="false"'));
  assert.ok(macPage.includes('<div data-os-panel="darwin">'));
  assert.ok(macPage.includes('<div data-os-panel="win32" hidden>'));
  assert.ok(macPage.includes('<div data-os-panel="linux" hidden>'));
  assert.ok(macPage.includes('brew install --cask stevyhacker/tap/lokalbot'));

  const winPage = renderPage(result, { platform: 'win32' });
  assert.ok(winPage.includes('data-os="win32" aria-pressed="true"'));
  assert.ok(winPage.includes('<div data-os-panel="win32">'));
  assert.ok(winPage.includes('<div data-os-panel="darwin" hidden>'));
  assert.ok(winPage.includes('<div data-os-panel="linux" hidden>'));
  assert.ok(winPage.includes('scoop bucket add lokalbot https://github.com/stevyhacker/scoop-bucket'));
  assert.ok(winPage.includes('scoop install lokalbot/lokalbot'));

  const linuxPage = renderPage(result, { platform: 'linux' });
  assert.ok(linuxPage.includes('data-os="linux" aria-pressed="true"'));
  assert.ok(linuxPage.includes('<div data-os-panel="linux">'));
  assert.ok(linuxPage.includes('<div data-os-panel="darwin" hidden>'));
  assert.ok(linuxPage.includes('<div data-os-panel="win32" hidden>'));
  assert.ok(linuxPage.includes('pkg.lokalbot.com'));
  assert.ok(linuxPage.includes('.deb'));
  assert.ok(linuxPage.includes('.rpm'));
  assert.ok(linuxPage.includes('https://github.com/stevyhacker/LokalBot/releases/latest'));

  assert.ok(macPage.includes('/plugin marketplace add stevyhacker/lokalbot'));
  assert.ok(macPage.includes('/plugin install lokalbot@lokalbot'));
  assert.ok(macPage.includes('claude mcp add lokalbot -- lokalbot-cli mcp'));
  assert.ok(macPage.includes('codex plugin marketplace add stevyhacker/lokalbot'));
  assert.ok(macPage.includes('codex mcp add lokalbot -- lokalbot-cli mcp'));
});
