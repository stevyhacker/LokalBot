// The image people share: an SVG drawn from the year's figures, and the
// page that shows it and saves it as a PNG. Both are self-contained; the
// page loads nothing from the network.
//
// The picture is the year itself: one column per day, one row per hour, so
// late nights and long weekends show as shapes. Words about the person are
// set in a serif, figures from the logs in a monospace.

import { dayLabel, factLines, hours, monthNames, percent, plural } from './format.mjs';

const WIDTH = 1200;
const HEIGHT = 1500;
const MARGIN = 80;
const HOUR = 60 * 60 * 1000;

const INK = {
  ground: '#080d14',
  well: '#0c141d',
  text: '#ecf3f7',
  dim: '#a2b4c2',
  faint: '#8ba2b0',
  teal: '#23c4ae',
  amber: '#fbbf24',
  slate: '#4f6b80',
};

const SERIF = `'Iowan Old Style', 'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif`;
const MONO = `ui-monospace, 'SF Mono', SFMono-Regular, Menlo, 'Cascadia Mono', Consolas, 'DejaVu Sans Mono', monospace`;
/** Average glyph widths in ems, for keeping a line inside the card without a layout engine. */
const SERIF_EM = 0.5;
const MONO_EM = 0.602;

/**
 * Project names can be client names, so the image leaves them out unless
 * `showProjects` is set.
 */
export function renderCard({ stats, grid, calendar, earlierDays }, { showProjects = false } = {}) {
  const parts = [];
  const inner = WIDTH - 2 * MARGIN;
  parts.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${INK.ground}"/>`);

  // What this is, and which agents it covers.
  parts.push(text(MARGIN, 112, `Agent Wrapped ${stats.year}`, { family: 'mono', size: 26, fill: INK.text, weight: 600 }));
  const agents = stats.agents.map((agent) => agent.name).join(' and ');
  if (agents) parts.push(text(WIDTH - MARGIN, 112, agents, { family: 'mono', size: 22, fill: INK.faint, anchor: 'end' }));

  // The person.
  const titleSize = fit(stats.persona.title, 128, inner, SERIF_EM);
  parts.push(text(MARGIN - 4, 278, stats.persona.title, { family: 'serif', size: titleSize, fill: INK.text, spacing: -1.5 }));
  const lineSize = fit(stats.persona.line, 36, inner, SERIF_EM * 0.94);
  parts.push(text(MARGIN, 340, stats.persona.line, { family: 'serif', size: lineSize, fill: INK.dim, italic: true }));

  // The year.
  const year = { x: 172, y: 416, width: WIDTH - MARGIN - 172, row: 15 };
  parts.push(...yearPicture(grid, calendar, stats.busiestDay, earlierDays, year));
  if (stats.busiestDay) {
    const caption = `${dayLabel(stats.busiestDay.date)} was the busiest day: ${hours(stats.busiestDay.agentMs)} agent hours across ${plural(stats.busiestDay.sessions, 'session')}.`;
    parts.push(text(MARGIN, 868, caption, { family: 'serif', size: fit(caption, 30, inner, SERIF_EM), fill: INK.amber }));
  }
  const earlier = stats.coverage?.earlier;
  if (earlier) {
    const note = `The marks under the year are ${plural(earlier.days, 'earlier day')}: Claude Code deleted the logs and kept a count.`;
    parts.push(text(MARGIN, 908, note, { family: 'serif', size: fit(note, 22, inner, SERIF_EM * 0.94), fill: INK.faint, italic: true }));
  }

  // The figures.
  let baseline = 968;
  for (const line of factLines(stats)) {
    parts.push(factLine(MARGIN, baseline, line, inner));
    baseline += 68;
  }

  // How the hours split between agents.
  const timed = stats.agents.filter((agent) => agent.agentMs > 0);
  if (timed.length > 1 && stats.totals.agentMs > 0) {
    const share = timed[0].agentMs / stats.totals.agentMs;
    const split = Math.round(inner * share);
    parts.push(`<rect x="${MARGIN}" y="1262" width="${split - 3}" height="12" rx="2" fill="${INK.teal}"/>`);
    parts.push(`<rect x="${MARGIN + split + 3}" y="1262" width="${inner - split - 3}" height="12" rx="2" fill="${INK.slate}"/>`);
    parts.push(text(MARGIN, 1310, `${timed[0].name} ${percent(share)}`, { family: 'mono', size: 22, fill: INK.dim }));
    const rest = timed.slice(1).map((agent) => `${agent.name} ${percent(agent.agentMs / stats.totals.agentMs)}`).join(', ');
    parts.push(text(WIDTH - MARGIN, 1310, rest, { family: 'mono', size: 22, fill: INK.dim, anchor: 'end' }));
  }
  if (showProjects && stats.projects.length > 0) {
    const names = stats.projects.slice(0, 3).map((project) => project.name);
    const listed = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.at(-1)}` : names[0];
    const sentence = `Most hours went to ${listed}.`;
    parts.push(text(MARGIN, 1362, sentence, { family: 'serif', size: fit(sentence, 28, inner, SERIF_EM), fill: INK.dim }));
  }

  // How to make your own, and where it came from.
  parts.push(text(MARGIN, 1424, 'npx lokalbot wrapped', { family: 'mono', size: 26, fill: INK.text, weight: 600 }));
  parts.push(text(WIDTH - MARGIN, 1424, 'github.com/stevyhacker/LokalBot', { family: 'mono', size: 22, fill: INK.faint, anchor: 'end' }));
  parts.push(text(MARGIN, 1462, 'Counted from the session logs on this computer. Nothing was uploaded.', { family: 'serif', size: 22, fill: INK.faint, italic: true }));

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}" role="img" aria-label="${escape(altText(stats))}">`,
    `<style>.serif{font-family:${SERIF}}.mono{font-family:${MONO}}</style>`,
    ...parts,
    '</svg>',
  ].join('\n');
}

/** One column per day, one row per hour, brighter where more agent time fell. */
function yearPicture(grid, calendar, busiest, earlierDays, { x, y, width, row }) {
  const parts = [];
  const column = width / calendar.days;
  const height = row * 24;
  parts.push(`<rect x="${x - 6}" y="${y - 6}" width="${width + 12}" height="${height + 12}" rx="6" fill="${INK.well}"/>`);

  // Days an agent counted but whose logs are gone have no hours to place
  // them by, so they sit in a strip under the year, brighter for busier days.
  let most = 0;
  for (const count of earlierDays ?? []) most = Math.max(most, count);
  if (most > 0) {
    const marks = ['', '', ''];
    for (let day = 0; day < calendar.days; day += 1) {
      if (earlierDays[day] <= 0) continue;
      const level = Math.min(2, Math.floor(Math.sqrt(earlierDays[day] / most) * 3));
      marks[level] += `M${round(x + day * column)} ${y + height + 10}h${round(column + 0.35)}v7h-${round(column + 0.35)}z`;
    }
    ['#2c4152', INK.slate, '#7f9db3'].forEach((fill, level) => {
      if (marks[level]) parts.push(`<path d="${marks[level]}" fill="${fill}"/>`);
    });
  }

  const hourLabels = [[0, '12 am'], [6, '6 am'], [12, '12 pm'], [18, '6 pm']];
  for (const [hour, label] of hourLabels) {
    parts.push(text(x - 24, y + hour * row + 13, label, { family: 'mono', size: 18, fill: INK.faint, anchor: 'end' }));
  }
  let month = -1;
  for (let day = 0; day < calendar.days; day += 1) {
    if (calendar.month(day) === month) continue;
    month = calendar.month(day);
    parts.push(text(round(x + day * column), y + height + 36, monthNames[month], { family: 'mono', size: 18, fill: INK.faint }));
  }

  // Cells of one colour are drawn as a single path, which keeps the file small.
  const paths = new Map();
  for (let day = 0; day < calendar.days; day += 1) {
    const left = round(x + day * column);
    const cellWidth = round(column + 0.35);
    for (let hour = 0; hour < 24; hour += 1) {
      const ms = grid[day * 24 + hour];
      if (ms <= 0) continue;
      const fill = busiest && busiest.day === day ? amberFor(ms) : tealFor(ms);
      paths.set(fill, `${paths.get(fill) ?? ''}M${left} ${y + hour * row}h${cellWidth}v${row - 1}h-${cellWidth}z`);
    }
  }
  for (const [fill, d] of paths) parts.push(`<path d="${d}" fill="${fill}"/>`);
  if (busiest) {
    const centre = round(x + (busiest.day + 0.5) * column);
    parts.push(`<path d="M${centre - 7} ${y - 22}h14l-7 11z" fill="${INK.amber}"/>`);
  }
  return parts;
}

/** A full hour of one agent is the brightest teal; several at once run hotter. */
function tealFor(ms) {
  const level = Math.min(1, ms / HOUR);
  const step = Math.max(1, Math.ceil(Math.sqrt(level) * 6));
  const ramp = ['#113a43', '#145058', '#18706c', '#1d9486', '#23c4ae', '#6ef2dc'];
  if (ms > 1.5 * HOUR) return '#c9fff5';
  return ramp[step - 1];
}

function amberFor(ms) {
  const level = Math.min(1, ms / HOUR);
  const ramp = ['#6b4a12', '#a8771a', '#e0a41f', '#fbbf24'];
  return ramp[Math.max(1, Math.ceil(Math.sqrt(level) * 4)) - 1];
}

/** A sentence whose figures are set in the monospace and whose words are quieter. */
function factLine(x, y, pieces, maxWidth) {
  let size = 40;
  const width = () => pieces.reduce((sum, [value, figure]) => sum + value.length * size * (figure ? 0.9 * MONO_EM : SERIF_EM), 0);
  while (size > 24 && width() > maxWidth) size -= 1;
  const spans = pieces.map(([value, figure]) => (figure
    ? `<tspan class="mono" font-size="${Math.round(size * 0.9)}" font-weight="600" fill="${INK.text}">${escape(value)}</tspan>`
    : `<tspan fill="${INK.dim}">${escape(value)}</tspan>`));
  return `<text x="${x}" y="${y}" class="serif" font-size="${size}" xml:space="preserve">${spans.join('')}</text>`;
}

function text(x, y, value, { family, size, fill, weight, anchor, italic, spacing }) {
  const attributes = [`x="${x}"`, `y="${y}"`, `class="${family}"`, `font-size="${size}"`, `fill="${fill}"`];
  if (weight) attributes.push(`font-weight="${weight}"`);
  if (anchor) attributes.push(`text-anchor="${anchor}"`);
  if (italic) attributes.push('font-style="italic"');
  if (spacing) attributes.push(`letter-spacing="${spacing}"`);
  return `<text ${attributes.join(' ')}>${escape(value)}</text>`;
}

/** The largest size, up to `size`, at which `value` fits in `maxWidth`. */
function fit(value, size, maxWidth, em) {
  const natural = value.length * size * em;
  return natural <= maxWidth ? size : Math.max(18, Math.floor(maxWidth / (value.length * em)));
}

function round(value) {
  return Math.round(value * 100) / 100;
}

export function escape(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function altText(stats) {
  const facts = factLines(stats).map((line) => line.map(([value]) => value).join('')).join('. ');
  return `Agent Wrapped ${stats.year}. ${stats.persona.title}: ${stats.persona.line} ${facts}.`;
}

/** The page that shows the image and saves or copies it as a PNG. */
export function renderPage(result, options = {}) {
  const { stats } = result;
  const svg = renderCard(result, options);
  const name = `agent-wrapped-${stats.year}.png`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent Wrapped ${stats.year}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #05080d; color: ${INK.text}; font: 16px/1.5 ${SERIF}; }
  main { max-width: 620px; margin: 0 auto; padding: 32px 16px 48px; }
  svg { display: block; width: 100%; height: auto; border-radius: 10px; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin-top: 20px; }
  button { font: 600 15px/1 ${MONO}; color: #04141a; background: ${INK.teal}; border: 0; border-radius: 6px; padding: 12px 16px; cursor: pointer; }
  button.quiet { color: ${INK.text}; background: #16212e; }
  button:focus-visible { outline: 2px solid #6ef2dc; outline-offset: 3px; }
  button[hidden] { display: none; }
  #status { color: ${INK.dim}; font-style: italic; }
  p { color: ${INK.faint}; margin: 18px 0 0; }
  a { color: #6ef2dc; }
</style>
</head>
<body>
<main>
${svg}
<div class="actions">
  <button id="save" type="button">Save image</button>
  <button id="copy" type="button" class="quiet" hidden>Copy image</button>
  <span id="status" role="status"></span>
</div>
<p>This page is a file on your computer. Saving or copying the image uploads nothing.</p>
<p>Agent Wrapped comes from <a href="https://github.com/stevyhacker/LokalBot">LokalBot</a>, a desktop app that shows each day's agent work on a timeline, next to your meetings.</p>
</main>
<script>
(() => {
  const svg = document.querySelector('svg');
  const status = document.getElementById('status');
  const save = document.getElementById('save');
  const copy = document.getElementById('copy');
  const scale = 2;

  async function png() {
    const xml = new XMLSerializer().serializeToString(svg);
    const url = URL.createObjectURL(new Blob([xml], { type: 'image/svg+xml' }));
    try {
      const image = new Image();
      await new Promise((resolve, reject) => {
        image.onload = resolve;
        image.onerror = reject;
        image.src = url;
      });
      const canvas = document.createElement('canvas');
      canvas.width = ${WIDTH} * scale;
      canvas.height = ${HEIGHT} * scale;
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      return await new Promise((resolve, reject) => {
        canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('no image'))), 'image/png');
      });
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  save.addEventListener('click', async () => {
    try {
      const link = document.createElement('a');
      link.href = URL.createObjectURL(await png());
      link.download = ${JSON.stringify(name)};
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
      status.textContent = 'Image saved.';
    } catch {
      status.textContent = 'The image could not be saved. Take a screenshot of the card instead.';
    }
  });

  if (navigator.clipboard && window.ClipboardItem) {
    copy.hidden = false;
    copy.addEventListener('click', async () => {
      try {
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': png() })]);
        status.textContent = 'Image copied.';
      } catch {
        status.textContent = 'The image could not be copied here. Save it instead.';
      }
    });
  }
})();
</script>
</body>
</html>
`;
}
