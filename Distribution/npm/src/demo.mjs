// A made-up year, for screenshots and for trying the cards without logs.
// The same seed always produces the same year.

import { createCollector } from './collector.mjs';
import { computeStats, yearWindow } from './stats.mjs';

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const PROJECTS = ['harbor-app', 'tide-api', 'northwind-site', 'lantern-docs', 'kiln'];

export function demoYear(year, seed = 7) {
  const random = mulberry32(seed + year);
  const window = yearWindow(year);
  const collector = createCollector(window);
  const days = Math.round((window.end - window.start) / (24 * HOUR));
  let session = 0;

  for (let day = 0; day < days; day += 1) {
    const date = new Date(year, 0, 1 + day);
    const weekend = date.getDay() === 0 || date.getDay() === 6;
    // A two-week break in August, and a year that gets busier.
    if (date.getMonth() === 7 && date.getDate() >= 8 && date.getDate() <= 21) continue;
    const appetite = 0.45 + 0.5 * (day / days);
    if (random() > (weekend ? 0.35 : 0.9) * appetite + 0.1) continue;
    const sprint = date.getMonth() === 9 && date.getDate() >= 12 && date.getDate() <= 16;
    const sessions = sprint ? 6 + Math.floor(random() * 3) : 1 + Math.floor(random() * 3 * appetite + (weekend ? 0 : 0.6));
    for (let index = 0; index < sessions; index += 1) {
      const agent = random() < 0.68 ? 'claude-code' : 'codex';
      const evening = random() < 0.42;
      const startHour = sprint ? 9 + random() * 13 : evening ? 20 + random() * 4.5 : 9 + random() * 8;
      const minutes = sprint ? 120 + random() * 240 : 20 + random() * random() * 200;
      session += 1;
      addSession(collector, {
        agent,
        id: `demo-${session}`,
        start: date.getTime() + startHour * HOUR,
        minutes,
        project: PROJECTS[Math.floor(random() * random() * PROJECTS.length)],
        random,
      });
    }
  }
  return computeStats(collector, { year, generatedAt: new Date(year, 11, 31, 12) });
}

function addSession(collector, { agent, id, start, minutes, project, random }) {
  const session = collector.session(agent, id);
  const end = Math.min(start + minutes * MINUTE, collector.end - 1);
  let at = start;
  let steps = 0;
  while (at < end && at >= collector.start) {
    session.times.push(at);
    at += (20 + random() * 200) * 1000;
    // Waiting on the person now and then.
    if (random() < 0.03) at += (4 + random() * 9) * MINUTE;
    steps += 1;
  }
  session.folders.set(`/Users/demo/code/${project}`, steps);
  session.prompts = 1 + Math.floor(steps / 14);
  session.promptWords = session.prompts * (12 + Math.floor(random() * 30));
  session.replies = session.prompts;
  session.toolCalls = Math.floor(steps * 0.8);
  session.edits = Math.floor(steps * 0.12);
  session.tokens.input = steps * (60000 + Math.floor(random() * 90000));
  session.tokens.cached = Math.floor(session.tokens.input * 0.9);
  session.tokens.output = steps * (500 + Math.floor(random() * 900));
  session.models.set(agent === 'codex' ? 'gpt-6-astra' : 'claude-fable-5', session.prompts);
  for (const [tool, share] of [['Bash', 0.4], ['Read', 0.3], ['Edit', 0.2], ['Grep', 0.1]]) {
    session.tools.set(tool, Math.floor(session.toolCalls * share));
  }
  for (let index = 0; index < session.edits; index += 1) {
    collector.files.add(`/Users/demo/code/${project}/src/file-${Math.floor(random() * 400)}.ts`);
  }
  if (random() < 0.55) session.commits.add(`${id} commit`);
  if (random() < 0.2) session.commits.add(`${id} second commit`);
  if (random() < 0.16) session.pullRequestsOpened.add(`${id} pull request`);
  if (random() < 0.12) session.mergedNumbers.add(id);
  if (random() < 0.3) session.testRuns += 1 + Math.floor(random() * 4);
  if (random() < 0.1) session.subagentCalls += 1 + Math.floor(random() * 5);
}

function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = state;
    mixed = Math.imul(mixed ^ (mixed >>> 15), mixed | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}
