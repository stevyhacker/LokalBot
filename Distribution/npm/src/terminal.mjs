// The card printed in the terminal.

import { compact, dayLabel, duration, factLines, hours, monthNames, number, percent, plural } from './format.mjs';

const TEAL = [35, 196, 174];
const AMBER = [217, 150, 20];
const SHADES = ['░', '▒', '▓', '█'];
const BAND_LABELS = ['12a', ' 3a', ' 6a', ' 9a', '12p', ' 3p', ' 6p', ' 9p'];

/**
 * `stats`, `grid` and `calendar` come from `computeStats`. Project names are
 * the person's own and are shown here, on their own screen.
 */
export function renderTerminal({ stats, grid, calendar, earlierDays }, { color = false } = {}) {
  const paint = painter(color);
  const out = [''];
  const agents = stats.agents.map((agent) => agent.name);
  out.push(`  ${paint.bold(`Agent Wrapped ${stats.year}`)}   ${paint.dim(agents.length > 0 ? agents.join(' and ') : 'no sessions found')}`);
  out.push('');
  out.push(`  ${paint.bold(paint.teal(stats.persona.title))}`);
  out.push(`  ${stats.persona.line}`);
  out.push('');
  out.push(...yearGrid(grid, calendar, stats.busiestDay, earlierDays, paint));
  out.push('');

  for (const line of factLines(stats)) {
    out.push(`  ${line.map(([text, figure]) => (figure ? paint.bold(text) : text)).join('')}`);
  }
  const { totals } = stats;
  if (stats.busiestDay) {
    out.push(`  Busiest day: ${paint.amber(dayLabel(stats.busiestDay.date))}, ${paint.bold(hours(stats.busiestDay.agentMs))} agent hours across ${plural(stats.busiestDay.sessions, 'session')}`);
  }
  if (stats.longestRun) {
    out.push(`  Longest run without a break: ${paint.bold(duration(stats.longestRun.ms))} on ${dayLabel(stats.longestRun.date)}`);
  }
  if (stats.mostAtOnce.count > 1) {
    out.push(`  Most at once: ${paint.bold(String(stats.mostAtOnce.count))} agents on ${dayLabel(stats.mostAtOnce.date)}`);
  }
  if (stats.streak.days > 1) {
    out.push(`  Longest streak: ${paint.bold(String(stats.streak.days))} days, ${dayLabel(stats.streak.start)} to ${dayLabel(stats.streak.end)}`);
  }
  const extras = [];
  if (totals.subagents > 0) extras.push(`${plural(totals.subagents, 'subagent')} launched`);
  if (totals.testRuns > 0) extras.push(`${plural(totals.testRuns, 'test run')}`);
  if (totals.scheduledRuns > 0) extras.push(`${plural(totals.scheduledRuns, 'scheduled run')}`);
  if (extras.length > 0) out.push(`  Also: ${extras.join(', ')}`);
  out.push('');
  const coverage = coverageNote(stats);
  if (coverage.length > 0) out.push(...coverage.map((line) => paint.dim(`  ${line}`)), '');

  if (stats.agents.length > 0) {
    const nameWidth = Math.max(...stats.agents.map((agent) => agent.name.length));
    for (const agent of stats.agents) {
      const share = totals.agentMs > 0 ? agent.agentMs / totals.agentMs : 0;
      const filled = Math.round(share * 24);
      const bar = paint.teal('█'.repeat(filled)) + paint.dim('░'.repeat(24 - filled));
      const details = [percent(share).padStart(4), plural(agent.sessions, 'session'), `${compact(agent.tokens.total)} tokens`];
      if (agent.topModel) details.push(agent.topModel);
      out.push(`  ${agent.name.padEnd(nameWidth)}  ${bar}  ${details.join(paint.dim('  '))}`);
    }
    out.push('');
  }
  if (stats.projects.length > 0) {
    out.push(`  Most hours: ${stats.projects.slice(0, 3).map((project) => `${project.name} ${hours(project.agentMs)} h`).join(', ')}`);
  }
  if (stats.topTools.length > 0) {
    out.push(`  Most used tools: ${stats.topTools.slice(0, 4).map((tool) => `${tool.name} ${number(tool.count)}`).join(', ')}`);
  }
  if (stats.projects.length > 0 || stats.topTools.length > 0) out.push('');

  out.push(paint.dim('  Counted from the session logs on this computer. Nothing was uploaded.'));
  return out.join('\n');
}

/**
 * Why the picture may start late in the year, and how to keep next year's
 * logs. Empty when the logs cover the year.
 */
export function coverageNote(stats) {
  const { loggedFrom, earlier } = stats.coverage;
  const usesClaude = stats.agents.some((agent) => agent.id === 'claude-code') || earlier !== null;
  const startsLate = loggedFrom !== null && loggedFrom > `${stats.year}-01-31`;
  if (!usesClaude || (!earlier && !startsLate)) return [];
  const lines = [];
  if (loggedFrom) lines.push(`The session logs on this computer go back to ${dayLabel(loggedFrom)}.`);
  if (earlier) {
    lines.push(`Claude Code's own count adds ${plural(earlier.days, 'earlier day')} this year: ${plural(earlier.sessions, 'session')},`);
    lines.push(`${number(earlier.toolCalls)} tool calls. They are the marks under the picture.`);
  }
  lines.push('Claude Code deletes session logs after 30 days. To keep next year\'s, set');
  lines.push('"cleanupPeriodDays": 3650 in ~/.claude/settings.json.');
  return lines;
}

/** One column per week, one row per three hours of the day. */
function yearGrid(grid, calendar, busiest, earlierDays, paint) {
  const weeks = Math.ceil((calendar.firstWeekday + calendar.days) / 7);
  const cells = Array.from({ length: 8 }, () => new Float64Array(weeks));
  let max = 0;
  for (let day = 0; day < calendar.days; day += 1) {
    const week = Math.floor((calendar.firstWeekday + day) / 7);
    for (let hour = 0; hour < 24; hour += 1) {
      const ms = grid[day * 24 + hour];
      if (ms === 0) continue;
      const band = Math.floor(hour / 3);
      cells[band][week] += ms;
      if (cells[band][week] > max) max = cells[band][week];
    }
  }
  const busiestWeek = busiest ? Math.floor((calendar.firstWeekday + busiest.day) / 7) : -1;

  const labels = new Array(weeks).fill(' ');
  let month = -1;
  for (let day = 0; day < calendar.days; day += 1) {
    if (calendar.month(day) === month) continue;
    month = calendar.month(day);
    const week = Math.floor((calendar.firstWeekday + day) / 7);
    const name = monthNames[month];
    if (week + name.length <= weeks) {
      for (let index = 0; index < name.length; index += 1) labels[week + index] = name[index];
    }
  }

  const rows = [`       ${paint.dim(labels.join(''))}`];
  for (let band = 0; band < 8; band += 1) {
    let row = '';
    for (let week = 0; week < weeks; week += 1) {
      const ms = cells[band][week];
      if (ms === 0) {
        row += paint.dim('·');
        continue;
      }
      const shade = SHADES[Math.min(3, Math.floor(Math.sqrt(ms / max) * 4))];
      row += week === busiestWeek ? paint.amber(shade) : paint.teal(shade);
    }
    rows.push(`  ${paint.dim(BAND_LABELS[band])}  ${row}`);
  }
  // Days an agent counted but whose logs are gone: no hours to place them by.
  if (earlierDays?.some((count) => count > 0)) {
    const marks = new Array(weeks).fill(' ');
    for (let day = 0; day < calendar.days; day += 1) {
      if (earlierDays[day] > 0) marks[Math.floor((calendar.firstWeekday + day) / 7)] = '▪';
    }
    rows.push(`       ${paint.dim(marks.join(''))}`);
  }
  return rows;
}

function painter(color) {
  if (!color) {
    const plain = (text) => text;
    return { bold: plain, dim: plain, teal: plain, amber: plain };
  }
  const rgb = ([r, g, b]) => (text) => `\x1b[38;2;${r};${g};${b}m${text}\x1b[39m`;
  return {
    bold: (text) => `\x1b[1m${text}\x1b[22m`,
    dim: (text) => `\x1b[2m${text}\x1b[22m`,
    teal: rgb(TEAL),
    amber: rgb(AMBER),
  };
}
