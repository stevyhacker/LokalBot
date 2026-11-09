// How figures are written, shared by the terminal card and the image.

const HOUR = 60 * 60 * 1000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export const monthNames = MONTHS;

/** `148203` as `148,203`. */
export function number(value) {
  return Math.round(value).toLocaleString('en-US');
}

/** `2140000000` as `2.1B`; small numbers are written in full. */
export function compact(value) {
  const steps = [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];
  for (const [size, suffix] of steps) {
    if (value >= size) {
      const scaled = value / size;
      return `${scaled >= 100 ? Math.round(scaled) : Math.round(scaled * 10) / 10}${suffix}`;
    }
  }
  return number(value);
}

/** Whole hours for a year's total: `1,248`. Under ten hours keeps one decimal. */
export function hours(ms) {
  const value = ms / HOUR;
  return value >= 10 ? number(value) : String(Math.round(value * 10) / 10);
}

/** A single stretch of time: `6 h 12 min`, `42 min`. */
export function duration(ms) {
  const minutes = Math.round(ms / 60000);
  if (minutes < 60) return `${minutes} min`;
  const rest = minutes % 60;
  return rest === 0 ? `${number(minutes / 60)} h` : `${number(Math.floor(minutes / 60))} h ${rest} min`;
}

/** `2026-10-14` as `Oct 14`. */
export function dayLabel(date) {
  if (typeof date !== 'string') return '';
  const [, month, day] = date.split('-').map(Number);
  return `${MONTHS[month - 1]} ${day}`;
}

export function percent(share) {
  return `${Math.round(share * 100)}%`;
}

/** `1` → `1 day`, `3` → `3 days`. */
export function plural(count, one, many = `${one}s`) {
  return `${number(count)} ${count === 1 ? one : many}`;
}

/** The facts both cards state, as `[figure, words]` pieces per line. */
export function factLines(stats) {
  const { totals } = stats;
  const worked = hours(totals.agentMs);
  const lines = [
    [[worked, true], [worked === '1' ? ' hour of agent work on ' : ' hours of agent work on '], [number(totals.activeDays), true], [totals.activeDays === 1 ? ' day' : ' days']],
    [[number(totals.requests), true], [totals.requests === 1 ? ' request from you, ' : ' requests from you, '], [number(totals.toolCalls), true], [' tool calls from them']],
  ];
  if (totals.tokens.total > 0) {
    lines.push([[compact(totals.tokens.input), true], [' tokens read, '], [compact(totals.tokens.output), true], [' written']]);
  }
  if (totals.commits > 0 && totals.pullRequestsMerged > 0) {
    lines.push([[number(totals.commits), true], [totals.commits === 1 ? ' commit and ' : ' commits and '], [number(totals.pullRequestsMerged), true], [totals.pullRequestsMerged === 1 ? ' merged pull request' : ' merged pull requests']]);
  } else if (totals.commits > 0) {
    lines.push([[number(totals.commits), true], [totals.commits === 1 ? ' commit across ' : ' commits across '], [number(totals.filesChanged), true], [totals.filesChanged === 1 ? ' changed file' : ' changed files']]);
  } else if (stats.longestRun) {
    lines.push([[number(totals.sessions), true], [totals.sessions === 1 ? ' session, the longest run ' : ' sessions, the longest run '], [duration(stats.longestRun.ms), true]]);
  }
  return lines;
}
