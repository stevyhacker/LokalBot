// Turns what the readers gathered into the year's figures.
//
// "Agent hours" uses the same definition as LokalBot's timeline
// (CodingAgentBurstBuilder): a run of work ends after ten minutes with no
// activity, and a pause longer than five minutes inside a run counts as
// five. Two agents working at once count twice.

import { AGENTS } from './collector.mjs';
import { projectName } from './text.mjs';

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
/** A longer silence ends a run of work. */
export const INACTIVITY_GAP = 10 * MINUTE;
/** Longer pauses inside a run count as waiting, not work. */
export const ACTIVE_GAP_CAP = 5 * MINUTE;
/** Shorter runs are not "an agent working" for the at-once count. */
const PARALLEL_MINIMUM = MINUTE;

/** The year's first instant and the next year's, in this computer's time zone. */
export function yearWindow(year) {
  return { start: new Date(year, 0, 1).getTime(), end: new Date(year + 1, 0, 1).getTime() };
}

/**
 * Returns `{ stats, grid, calendar, earlierDays }`. `stats` is plain data,
 * safe to print as JSON. `grid` holds agent milliseconds for every hour of
 * every day, for drawing.
 *
 * `summaryDays` maps a date to the counts an agent kept for a day whose logs
 * it has since deleted. Those days have no hours, so they stay out of every
 * figure taken from the logs; they are reported on their own under
 * `coverage`, extend the streak, and come back in `earlierDays` (tool calls
 * per day of the year) for drawing.
 */
export function computeStats(collector, { year, userName = '', generatedAt = new Date(), summaryDays = new Map() } = {}) {
  const calendar = newCalendar(year);
  const grid = new Float64Array(calendar.days * 24);
  const dayTouched = new Uint8Array(calendar.days);
  const sessionsOnDay = new Uint32Array(calendar.days);
  const runs = [];
  const projects = new Map();
  const tools = new Map();
  const agents = new Map(Object.keys(AGENTS).map((id) => [id, newAgent(id)]));
  const totals = {
    sessions: 0, requests: 0, requestWords: 0, slashCommands: 0, scheduledRuns: 0, replies: 0,
    toolCalls: 0, subagents: 0, edits: 0, filesChanged: collector.files.size,
    agentMs: 0, wallClockMs: 0, activeDays: 0,
    tokens: { input: 0, cached: 0, output: 0, total: 0 },
    commits: 0, pullRequestsOpened: 0, pullRequestsMerged: 0, releases: 0, pushes: 0, testRuns: 0,
  };

  for (const session of collector.sessions.values()) {
    const agent = agents.get(session.agent) ?? agents.set(session.agent, newAgent(session.agent)).get(session.agent);
    // Every thread's tokens, tool calls and recorded actions count.
    for (const key of ['input', 'cached', 'output']) {
      agent.tokens[key] += session.tokens[key];
      totals.tokens[key] += session.tokens[key];
    }
    agent.toolCalls += session.toolCalls;
    totals.toolCalls += session.toolCalls;
    totals.edits += session.edits;
    totals.commits += session.commits.size;
    totals.pullRequestsOpened += session.pullRequestsOpened.size;
    totals.pullRequestsMerged += session.mergedNumbers.size + session.mergedUnnumbered;
    totals.releases += session.releases.size;
    totals.pushes += session.pushes;
    totals.testRuns += session.testRuns;
    for (const [name, count] of session.tools) tools.set(name, (tools.get(name) ?? 0) + count);
    for (const [model, count] of session.models) agent.models.set(model, (agent.models.get(model) ?? 0) + count);
    if (session.hidden) continue;

    totals.subagents += Math.max(session.subagentFiles, session.subagentCalls);
    totals.requests += session.prompts;
    totals.requestWords += session.promptWords;
    totals.slashCommands += session.slashCommands;
    totals.scheduledRuns += session.scheduledRuns;
    totals.replies += session.replies;
    agent.requests += session.prompts;
    if (session.prompts + session.scheduledRuns + session.toolCalls + session.replies > 0) {
      agent.sessions += 1;
      totals.sessions += 1;
    }

    const sessionMs = addSessionTime(session, { calendar, grid, dayTouched, sessionsOnDay, runs });
    agent.agentMs += sessionMs;
    totals.agentMs += sessionMs;
    creditProjects(session, sessionMs, projects, userName);
  }
  totals.tokens.total = totals.tokens.input + totals.tokens.output;

  const byDay = new Array(calendar.days).fill(0);
  const byHour = new Array(24).fill(0);
  const byWeekday = new Array(7).fill(0);
  const byMonth = new Array(12).fill(0);
  for (let day = 0; day < calendar.days; day += 1) {
    for (let hour = 0; hour < 24; hour += 1) {
      const ms = grid[day * 24 + hour];
      if (ms === 0) continue;
      byDay[day] += ms;
      byHour[hour] += ms;
      byWeekday[calendar.weekday(day)] += ms;
      byMonth[calendar.month(day)] += ms;
    }
    if (dayTouched[day]) totals.activeDays += 1;
  }
  totals.wallClockMs = unionMs(runs);

  const earlierDays = new Float64Array(calendar.days);
  const earlier = { days: 0, sessions: 0, toolCalls: 0, from: null };
  const anyDay = Uint8Array.from(dayTouched);
  for (const [date, counts] of [...summaryDays.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    const [summaryYear, month, dayOfMonth] = date.split('-').map(Number);
    if (summaryYear !== year) continue;
    const day = calendar.dayOf(new Date(year, month - 1, dayOfMonth, 12).getTime());
    if (dayTouched[day] || anyDay[day] || counts.sessions + counts.toolCalls === 0) continue;
    anyDay[day] = 1;
    // A day with sessions but no tool calls still gets a mark.
    earlierDays[day] = Math.max(1, counts.toolCalls);
    earlier.days += 1;
    earlier.sessions += counts.sessions;
    earlier.toolCalls += counts.toolCalls;
    earlier.from ??= date;
  }
  const firstLogged = dayTouched.indexOf(1);

  const agentList = [...agents.values()]
    .filter((agent) => agent.sessions > 0 || agent.tokens.input + agent.tokens.output > 0)
    .map((agent) => ({
      id: agent.id,
      name: AGENTS[agent.id] ?? agent.id,
      sessions: agent.sessions,
      requests: agent.requests,
      toolCalls: agent.toolCalls,
      agentMs: agent.agentMs,
      tokens: { ...agent.tokens, total: agent.tokens.input + agent.tokens.output },
      topModel: top(agent.models, 1)[0]?.name ?? null,
    }))
    .sort((a, b) => b.agentMs - a.agentMs || b.sessions - a.sessions);

  const projectList = [...projects.entries()]
    .filter(([, ms]) => ms >= 10 * MINUTE)
    .map(([name, ms]) => ({ name, agentMs: Math.round(ms) }))
    .sort((a, b) => b.agentMs - a.agentMs);

  const stats = {
    schema: 1,
    year,
    generatedAt: generatedAt.toISOString(),
    agents: agentList,
    totals: roundMs(totals),
    coverage: {
      loggedFrom: firstLogged === -1 ? null : calendar.date(firstLogged),
      earlier: earlier.days > 0 ? earlier : null,
      daysWithAnAgent: totals.activeDays + earlier.days,
    },
    streak: longestStreak(anyDay, calendar),
    busiestDay: busiestDay(byDay, sessionsOnDay, calendar),
    longestRun: longestRun(runs, calendar),
    mostAtOnce: mostAtOnce(runs, calendar),
    shares: shares(grid, calendar, totals.agentMs),
    byHour: byHour.map(Math.round),
    byWeekday: byWeekday.map(Math.round),
    byMonth: byMonth.map(Math.round),
    byDay: byDay.map(Math.round),
    topTools: top(tools, 5),
    projects: projectList.slice(0, 5),
    projectCount: projectList.length,
    sources: {
      filesRead: collector.filesRead,
      bytesRead: collector.bytesRead,
      unreadableFiles: collector.unreadableFiles,
    },
  };
  stats.persona = persona(stats);
  return { stats, grid, calendar, earlierDays };
}

function newAgent(id) {
  return { id, sessions: 0, requests: 0, toolCalls: 0, agentMs: 0, tokens: { input: 0, cached: 0, output: 0 }, models: new Map() };
}

/**
 * Day and hour lookups for one year in local time, tolerant of the days
 * that are 23 or 25 hours long.
 */
export function newCalendar(year) {
  const { start } = yearWindow(year);
  const days = Math.round((Date.UTC(year + 1, 0, 1) - Date.UTC(year, 0, 1)) / DAY);
  const dayStarts = new Float64Array(days + 1);
  const months = new Uint8Array(days);
  for (let day = 0; day <= days; day += 1) {
    const date = new Date(year, 0, 1 + day);
    dayStarts[day] = date.getTime();
    if (day < days) months[day] = date.getMonth();
  }
  // Monday is 0, as the week is drawn.
  const firstWeekday = (new Date(year, 0, 1).getDay() + 6) % 7;
  const dayOf = (at) => {
    let day = Math.floor((at - start) / DAY);
    if (day < 0) day = 0;
    if (day > days - 1) day = days - 1;
    while (day > 0 && at < dayStarts[day]) day -= 1;
    while (day < days - 1 && at >= dayStarts[day + 1]) day += 1;
    return day;
  };
  return {
    year,
    days,
    firstWeekday,
    dayOf,
    cellOf(at) {
      const day = dayOf(at);
      const hour = Math.min(23, Math.max(0, Math.floor((at - dayStarts[day]) / HOUR)));
      return day * 24 + hour;
    },
    weekday: (day) => (firstWeekday + day) % 7,
    month: (day) => months[day],
    /** `2026-10-14` */
    date(day) {
      const date = new Date(year, 0, 1 + day);
      const pad = (value) => String(value).padStart(2, '0');
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
    },
  };
}

/** Adds one session's work to the grid and its runs to `runs`. Returns its agent milliseconds. */
function addSessionTime(session, { calendar, grid, dayTouched, sessionsOnDay, runs }) {
  if (session.times.length === 0) return 0;
  const times = Float64Array.from(session.times).sort();
  let total = 0;
  let runStart = times[0];
  let runMs = 0;
  let lastDay = -1;
  const close = (end) => {
    runs.push({ start: runStart, end, agentMs: runMs, agent: session.agent });
  };
  for (let index = 0; index < times.length; index += 1) {
    const at = times[index];
    const cell = calendar.cellOf(at);
    const day = (cell - (cell % 24)) / 24;
    if (day !== lastDay) {
      dayTouched[day] = 1;
      sessionsOnDay[day] += 1;
      lastDay = day;
    }
    if (index === 0) continue;
    const previous = times[index - 1];
    const gap = at - previous;
    if (gap > INACTIVITY_GAP) {
      close(previous);
      runStart = at;
      runMs = 0;
      continue;
    }
    const worked = Math.min(gap, ACTIVE_GAP_CAP);
    grid[calendar.cellOf(previous)] += worked;
    runMs += worked;
    total += worked;
  }
  close(times[times.length - 1]);
  return total;
}

/** Splits a session's time among the folders its records ran in. */
function creditProjects(session, sessionMs, projects, userName) {
  if (sessionMs <= 0) return;
  let records = 0;
  for (const count of session.folders.values()) records += count;
  if (records === 0) return;
  for (const [folder, count] of session.folders) {
    const name = projectName(folder, userName);
    if (name) projects.set(name, (projects.get(name) ?? 0) + (sessionMs * count) / records);
  }
}

function top(map, limit) {
  return [...map.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count || (a.name < b.name ? -1 : 1))
    .slice(0, limit);
}

function roundMs(totals) {
  return { ...totals, agentMs: Math.round(totals.agentMs), wallClockMs: Math.round(totals.wallClockMs) };
}

/** Time with at least one agent working. */
function unionMs(runs) {
  const ordered = runs.filter((run) => run.end > run.start).sort((a, b) => a.start - b.start);
  let total = 0;
  let start = null;
  let end = null;
  for (const run of ordered) {
    if (end === null || run.start > end) {
      if (end !== null) total += end - start;
      start = run.start;
      end = run.end;
    } else if (run.end > end) {
      end = run.end;
    }
  }
  if (end !== null) total += end - start;
  return total;
}

function longestStreak(dayTouched, calendar) {
  let best = { days: 0, start: null, end: null };
  let length = 0;
  for (let day = 0; day < calendar.days; day += 1) {
    length = dayTouched[day] ? length + 1 : 0;
    if (length > best.days) best = { days: length, start: calendar.date(day - length + 1), end: calendar.date(day) };
  }
  return best;
}

function busiestDay(byDay, sessionsOnDay, calendar) {
  let best = -1;
  for (let day = 0; day < byDay.length; day += 1) {
    if (byDay[day] > 0 && (best === -1 || byDay[day] > byDay[best])) best = day;
  }
  if (best === -1) return null;
  return { date: calendar.date(best), day: best, agentMs: Math.round(byDay[best]), sessions: sessionsOnDay[best] };
}

function longestRun(runs, calendar) {
  let best = null;
  for (const run of runs) {
    if (run.end - run.start > (best ? best.end - best.start : 0)) best = run;
  }
  if (!best) return null;
  return { ms: Math.round(best.end - best.start), date: calendar.date(calendar.dayOf(best.start)), agent: best.agent };
}

/** The most runs of work under way at the same moment. */
function mostAtOnce(runs, calendar) {
  const edges = [];
  for (const run of runs) {
    if (run.end - run.start < PARALLEL_MINIMUM) continue;
    edges.push([run.start, 1], [run.end, -1]);
  }
  edges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  let current = 0;
  let best = { count: 0, date: null };
  for (const [at, change] of edges) {
    current += change;
    if (current > best.count) best = { count: current, date: calendar.date(calendar.dayOf(at)) };
  }
  return best;
}

/** How the year's agent hours split by time of day and week. */
function shares(grid, calendar, agentMs) {
  let night = 0;
  let early = 0;
  let weekend = 0;
  let office = 0;
  for (let day = 0; day < calendar.days; day += 1) {
    const weekday = calendar.weekday(day);
    for (let hour = 0; hour < 24; hour += 1) {
      const ms = grid[day * 24 + hour];
      if (ms === 0) continue;
      if (hour >= 22 || hour < 5) night += ms;
      if (hour >= 5 && hour < 9) early += ms;
      if (weekday >= 5) weekend += ms;
      else if (hour >= 9 && hour < 18) office += ms;
    }
  }
  const share = (ms) => (agentMs > 0 ? Math.round((ms / agentMs) * 1000) / 1000 : 0);
  return { night: share(night), early: share(early), weekend: share(weekend), office: share(office) };
}

// MARK: - Persona

/**
 * The one trait that stands out most. Each candidate has a bar to clear;
 * the one that clears its bar by the widest margin wins, so the title says
 * something true of this year in particular.
 */
export function persona(stats) {
  const { totals, shares: share, agents } = stats;
  const hours = totals.agentMs / HOUR;
  if (hours < 1) {
    return { id: 'first-steps', title: 'The Newcomer', line: 'A quiet first year. The logs are ready when you are.' };
  }
  const percent = (value) => `${Math.round(value * 100)}%`;
  const second = agents[1];
  const split = second && totals.agentMs > 0 ? second.agentMs / totals.agentMs : 0;
  const perDay = totals.activeDays > 0 ? totals.commits / totals.activeDays : 0;
  const candidates = [
    {
      id: 'night-shift', title: 'The Night Shift', score: share.night / 0.3,
      line: `${percent(share.night)} of your agent hours ran between 10 pm and 5 am.`,
    },
    {
      id: 'air-traffic', title: 'The Air Traffic Controller', score: stats.mostAtOnce.count / 6,
      line: `You had ${stats.mostAtOnce.count} agents working at the same moment.`,
    },
    {
      id: 'weekend', title: 'The Weekend Regular', score: share.weekend / 0.36,
      line: `${percent(share.weekend)} of your agent hours fell on a Saturday or Sunday.`,
    },
    {
      id: 'first-light', title: 'The First Light', score: share.early / 0.28,
      line: `${percent(share.early)} of your agent hours ran before 9 am.`,
    },
    {
      id: 'long-hauler', title: 'The Long Hauler', score: (stats.longestRun?.ms ?? 0) / (8 * HOUR),
      line: `Your longest run without a break lasted ${Math.round((stats.longestRun?.ms ?? 0) / HOUR)} hours.`,
    },
    {
      id: 'switch-hitter', title: 'The Switch Hitter', score: split / 0.3,
      line: second
        ? `You split the year between ${agents[0].name} and ${second.name}, ${percent(1 - split)} to ${percent(split)}.`
        : '',
    },
    {
      id: 'release-train', title: 'The Release Train', score: Math.max(perDay / 6, totals.pullRequestsMerged / 150),
      line: `${totals.commits.toLocaleString('en-US')} commits and ${totals.pullRequestsMerged.toLocaleString('en-US')} merged pull requests.`,
    },
    {
      id: 'daily-driver', title: 'The Daily Driver', score: stats.streak.days / 45,
      line: `${stats.streak.days} days in a row with an agent at work.`,
    },
  ];
  const winner = candidates.filter((candidate) => candidate.score >= 1).sort((a, b) => b.score - a.score)[0];
  if (winner) return { id: winner.id, title: winner.title, line: winner.line };
  return {
    id: 'steady-hand', title: 'The Steady Hand',
    line: `${percent(share.office)} of your agent hours ran on weekdays between 9 and 6.`,
  };
}
