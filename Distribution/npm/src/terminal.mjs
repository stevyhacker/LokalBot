import { compact, dayLabel, duration, factLines, hours, monthNames, number, percent, plural } from './format.mjs';

const TEAL = [35, 196, 174];
const AMBER = [217, 150, 20];
const SHADES = ['░', '▒', '▓', '█'];
const BAND_LABELS = ['12a', ' 3a', ' 6a', ' 9a', '12p', ' 3p', ' 6p', ' 9p'];

export function renderTerminal({ stats, grid, calendar, earlierDays }, { color = false } = {}) {
  const paint = painter(color);
  const out = [''];
  const agents = stats.agents.map((agent) => agent.name);
  out.push(`  ${paint.bold(`Agent Wrapped ${stats.year}`)}   ${paint.dim(formatAgentList(agents))}`);
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
  if ((totals.cacheHitRate ?? 0) >= 0.1) extras.push(`${percent(totals.cacheHitRate)} prompt cache hit`);
  if ((totals.avgPromptWords ?? 0) > 0 && (totals.toolsPerRequest ?? 0) > 0) {
    extras.push(`avg ${plural(totals.avgPromptWords, 'word')}/prompt → ${totals.toolsPerRequest} tool calls`);
  }
  if (extras.length > 0) out.push(`  Also: ${extras.join(', ')}`);
  out.push('');
  const coverage = coverageNote(stats);
  if (coverage.length > 0) out.push(...coverage.map((line) => paint.dim(`  ${line}`)), '');
  const skipped = stats.sources?.compressedSkipped ?? 0;
  if (skipped > 0) {
    out.push(paint.dim(`  ${plural(skipped, 'compressed Codex log')} left out: reading them needs Node.js 22.15 or later.`), '');
  }
  const sqliteSkipped = stats.sources?.sqliteSkipped ?? 0;
  if (sqliteSkipped > 0) {
    out.push(paint.dim(`  ${plural(sqliteSkipped, 'SQLite session store')} left out: reading OpenCode/Cursor databases needs Node.js 22.5 or later.`), '');
  }

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
  if (stats.topModels?.length > 0) {
    out.push(`  Top models: ${stats.topModels.slice(0, 5).map((model) => `${model.name} ${compact(model.total)}`).join(', ')}`);
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

export function coverageNote(stats) {
  const { claudeLoggedFrom: loggedFrom = null, earlier } = stats.coverage;
  const usesClaude = stats.agents.some((agent) => agent.id === 'claude-code') || earlier !== null;
  const startsLate = loggedFrom !== null && loggedFrom > `${stats.year}-01-31`;
  if (!usesClaude || (!earlier && !startsLate)) return [];
  const lines = [];
  if (loggedFrom) lines.push(`Claude Code's session logs on this computer go back to ${dayLabel(loggedFrom)}.`);
  if (earlier) {
    lines.push(`Claude Code's own count adds ${plural(earlier.days, 'earlier day')} this year: ${plural(earlier.sessions, 'session')},`);
    lines.push(`${number(earlier.toolCalls)} tool calls. They are the marks under the picture.`);
  }
  lines.push('Claude Code deletes session logs after 30 days. To keep next year\'s, set');
  lines.push('"cleanupPeriodDays": 3650 in ~/.claude/settings.json.');
  return lines;
}

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
  if (earlierDays?.some((count) => count > 0)) {
    const marks = new Array(weeks).fill(' ');
    for (let day = 0; day < calendar.days; day += 1) {
      if (earlierDays[day] > 0) marks[Math.floor((calendar.firstWeekday + day) / 7)] = '▪';
    }
    rows.push(`       ${paint.dim(marks.join(''))}`);
  }
  return rows;
}

function formatAgentList(names) {
  if (names.length === 0) return 'no sessions found';
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  if (names.length <= 4) return `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
  return `${names.slice(0, 3).join(', ')} and ${names.length - 3} more`;
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
