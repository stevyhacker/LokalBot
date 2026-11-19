// Pure, zero-import SVG card renderer shared by Node (`card.mjs`) and the
// self-contained browser share page. Keeps CLI rendering and live browser
// toggles byte-for-byte consistent with zero external dependencies.

const CARD_HOUR = 60 * 60 * 1000;
const CARD_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const CARD_INK = {
  ground: '#080d14',
  well: '#0c141d',
  border: '#172330',
  text: '#ecf3f7',
  dim: '#a2b4c2',
  faint: '#8ba2b0',
  teal: '#23c4ae',
  amber: '#fbbf24',
  slate: '#4f6b80',
};

const CARD_SERIF = `'Iowan Old Style', 'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif`;
const CARD_MONO = `ui-monospace, 'SF Mono', SFMono-Regular, Menlo, 'Cascadia Mono', Consolas, 'DejaVu Sans Mono', monospace`;
const CARD_SERIF_EM = 0.5;
const CARD_MONO_EM = 0.602;

export function cardDimensions(layout) {
  return layout === 'wide' ? { width: 1600, height: 900 } : { width: 1200, height: 1500 };
}

export function activeDaySpan(byDay) {
  if (!Array.isArray(byDay) || byDay.length === 0) return { first: -1, last: -1, span: 0 };
  let first = -1;
  let last = -1;
  for (let day = 0; day < byDay.length; day += 1) {
    if (byDay[day] > 0) {
      if (first === -1) first = day;
      last = day;
    }
  }
  return { first, last, span: first === -1 ? 0 : last - first + 1 };
}

export function defaultWindowMode(stats) {
  const { span } = activeDaySpan(stats.byDay);
  return span >= 3 && span <= 45 ? 'active' : 'year';
}

export function canZoomWindow(stats) {
  const { span } = activeDaySpan(stats.byDay);
  return span >= 3 && span <= 90;
}

export function renderCardSvg(data, options = {}) {
  const layout = options.layout === 'wide' ? 'wide' : 'portrait';
  return layout === 'wide'
    ? renderWideCard(data, options)
    : renderPortraitCard(data, options);
}

function resolveRange(data, windowOption) {
  const totalDays = data.days;
  const mode = windowOption === 'auto'
    ? defaultWindowMode(data.stats)
    : (windowOption === 'active' ? 'active' : 'year');
  if (mode !== 'active') {
    return { start: 0, end: totalDays - 1, zoomed: false };
  }
  const { first, last, span } = activeDaySpan(data.stats.byDay);
  if (first === -1 || span > 90) {
    return { start: 0, end: totalDays - 1, zoomed: false };
  }
  let start = Math.max(0, first - 1);
  let end = Math.min(totalDays - 1, last + 1);
  // Keep at least 14 columns so very short windows stay balanced.
  while (end - start + 1 < Math.min(14, totalDays)) {
    if (start > 0) start -= 1;
    else if (end < totalDays - 1) end += 1;
    else break;
  }
  return { start, end, zoomed: start > 0 || end < totalDays - 1 };
}

function renderPortraitCard(data, { showProjects = false, showApiValue = true, window: windowOption = 'auto' } = {}) {
  const { stats } = data;
  const WIDTH = 1200;
  const HEIGHT = 1500;
  const MARGIN = 80;
  const inner = WIDTH - 2 * MARGIN;
  const range = resolveRange(data, windowOption);
  const parts = [];

  parts.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${CARD_INK.ground}"/>`);

  // Header
  parts.push(svgText(MARGIN, 112, `Agent Wrapped ${stats.year}`, { family: 'mono', size: 26, fill: CARD_INK.text, weight: 600 }));
  const agents = stats.agents.map((agent) => agent.name).join(' and ');
  if (agents) parts.push(svgText(WIDTH - MARGIN, 112, agents, { family: 'mono', size: 22, fill: CARD_INK.faint, anchor: 'end' }));

  // Persona
  const titleSize = svgFit(stats.persona.title, 128, inner, CARD_SERIF_EM);
  parts.push(svgText(MARGIN - 4, 278, stats.persona.title, { family: 'serif', size: titleSize, fill: CARD_INK.text, spacing: -1.5 }));
  const lineSize = svgFit(stats.persona.line, 36, inner, CARD_SERIF_EM * 0.94);
  parts.push(svgText(MARGIN, 340, stats.persona.line, { family: 'serif', size: lineSize, fill: CARD_INK.dim, italic: true }));

  // Heatmap
  const chart = { x: 172, y: 416, width: WIDTH - MARGIN - 172, row: 15 };
  parts.push(...drawHeatmap(data, range, chart));

  if (stats.busiestDay) {
    const caption = `${cardDayLabel(stats.busiestDay.date)} was the busiest day: ${cardHours(stats.busiestDay.agentMs)} agent hours across ${cardPlural(stats.busiestDay.sessions, 'session')}.`;
    parts.push(svgText(MARGIN, 868, caption, { family: 'serif', size: svgFit(caption, 30, inner, CARD_SERIF_EM), fill: CARD_INK.amber }));
  }

  const earlier = stats.coverage?.earlier;
  if (range.zoomed) {
    const spanLabel = `${cardDayLabel(dayDate(data.year, range.start))} – ${cardDayLabel(dayDate(data.year, range.end))}`;
    const note = earlier
      ? `Zoomed to ${spanLabel} logs · plus ${cardPlural(earlier.days, 'earlier day')} counted by Claude Code.`
      : `Zoomed to active window (${spanLabel}).`;
    parts.push(svgText(MARGIN, 908, note, { family: 'serif', size: svgFit(note, 22, inner, CARD_SERIF_EM * 0.94), fill: CARD_INK.faint, italic: true }));
  } else if (earlier) {
    const note = `The marks under the year are ${cardPlural(earlier.days, 'earlier day')}: Claude Code deleted the logs and kept a count.`;
    parts.push(svgText(MARGIN, 908, note, { family: 'serif', size: svgFit(note, 22, inner, CARD_SERIF_EM * 0.94), fill: CARD_INK.faint, italic: true }));
  }

  // Fact lines
  let baseline = 968;
  for (const line of cardFactLines(stats, { showApiValue })) {
    parts.push(svgFactLine(MARGIN, baseline, line, inner, 40));
    baseline += 68;
  }

  // Agent split bar
  const timed = stats.agents.filter((agent) => agent.agentMs > 0);
  if (timed.length > 1 && stats.totals.agentMs > 0) {
    const share = timed[0].agentMs / stats.totals.agentMs;
    const split = Math.round(inner * share);
    parts.push(`<rect x="${MARGIN}" y="1262" width="${Math.max(4, split - 3)}" height="12" rx="2" fill="${CARD_INK.teal}"/>`);
    parts.push(`<rect x="${MARGIN + split + 3}" y="1262" width="${Math.max(4, inner - split - 3)}" height="12" rx="2" fill="${CARD_INK.slate}"/>`);
    parts.push(svgText(MARGIN, 1310, `${timed[0].name} ${cardPercent(share)}`, { family: 'mono', size: 22, fill: CARD_INK.dim }));
    const rest = timed.slice(1).map((agent) => `${agent.name} ${cardPercent(agent.agentMs / stats.totals.agentMs)}`).join(', ');
    parts.push(svgText(WIDTH - MARGIN, 1310, rest, { family: 'mono', size: 22, fill: CARD_INK.dim, anchor: 'end' }));
  }

  if (showProjects && stats.projects.length > 0) {
    const names = stats.projects.slice(0, 3).map((project) => project.name);
    const listed = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : names[0];
    const sentence = `Most hours went to ${listed}.`;
    parts.push(svgText(MARGIN, 1362, sentence, { family: 'serif', size: svgFit(sentence, 28, inner, CARD_SERIF_EM), fill: CARD_INK.dim }));
  }

  // Footer
  parts.push(`<line x1="${MARGIN}" y1="1386" x2="${WIDTH - MARGIN}" y2="1386" stroke="${CARD_INK.border}" stroke-width="1"/>`);
  parts.push(svgText(MARGIN, 1428, 'npx lokalbot', { family: 'mono', size: 26, fill: CARD_INK.text, weight: 600 }));
  parts.push(svgText(WIDTH - MARGIN, 1428, 'lokalbot.com', { family: 'mono', size: 24, fill: CARD_INK.teal, anchor: 'end', weight: 600 }));
  parts.push(svgText(MARGIN, 1464, 'Counted from the session logs on this computer. Nothing was uploaded.', { family: 'serif', size: 21, fill: CARD_INK.faint, italic: true }));

  return wrapSvg(WIDTH, HEIGHT, stats, showApiValue, parts);
}

function renderWideCard(data, { showProjects = false, showApiValue = true, window: windowOption = 'auto' } = {}) {
  const { stats } = data;
  const WIDTH = 1600;
  const HEIGHT = 900;
  const MARGIN = 64;
  const LEFT_W = 628;
  const RIGHT_X = 752;
  const CHART_X = RIGHT_X + 76;
  const CHART_W = WIDTH - MARGIN - CHART_X;
  const range = resolveRange(data, windowOption);
  const parts = [];

  parts.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${CARD_INK.ground}"/>`);

  // Header
  parts.push(svgText(MARGIN, 70, `Agent Wrapped ${stats.year}`, { family: 'mono', size: 22, fill: CARD_INK.text, weight: 600 }));
  const agents = stats.agents.map((agent) => agent.name).join(' and ');
  if (agents) parts.push(svgText(WIDTH - MARGIN, 70, agents, { family: 'mono', size: 20, fill: CARD_INK.faint, anchor: 'end' }));
  parts.push(`<line x1="${MARGIN}" y1="92" x2="${WIDTH - MARGIN}" y2="92" stroke="${CARD_INK.border}" stroke-width="1"/>`);

  // Left column: Persona
  const titleLines = wrapWords(stats.persona.title, 18, 2);
  const longestTitle = titleLines.reduce((best, line) => (line.length > best.length ? line : best), '');
  const titleSize = svgFit(longestTitle, titleLines.length > 1 ? 74 : 86, LEFT_W, CARD_SERIF_EM);
  let cursorY = 186;
  for (let idx = 0; idx < titleLines.length; idx += 1) {
    parts.push(svgText(MARGIN - 2, cursorY, titleLines[idx], { family: 'serif', size: titleSize, fill: CARD_INK.text, spacing: -1.2 }));
    if (idx < titleLines.length - 1) cursorY += Math.round(titleSize * 1.04);
  }

  cursorY += 46;
  const subLines = wrapWords(stats.persona.line, 44, 2);
  for (const line of subLines) {
    parts.push(svgText(MARGIN, cursorY, line, { family: 'serif', size: svgFit(line, 25, LEFT_W, CARD_SERIF_EM * 0.94), fill: CARD_INK.dim, italic: true }));
    cursorY += 34;
  }

  // Left column: Facts
  let factY = Math.max(cursorY + 34, 344);
  for (const line of cardFactLines(stats, { showApiValue })) {
    parts.push(svgFactLine(MARGIN, factY, line, LEFT_W, 29));
    factY += 54;
  }

  // Left column: Agent split
  const timed = stats.agents.filter((agent) => agent.agentMs > 0);
  if (timed.length > 1 && stats.totals.agentMs > 0) {
    const barY = Math.min(Math.max(factY + 18, 636), 690);
    const share = timed[0].agentMs / stats.totals.agentMs;
    const split = Math.round(LEFT_W * share);
    parts.push(`<rect x="${MARGIN}" y="${barY}" width="${Math.max(4, split - 3)}" height="11" rx="2" fill="${CARD_INK.teal}"/>`);
    parts.push(`<rect x="${MARGIN + split + 3}" y="${barY}" width="${Math.max(4, LEFT_W - split - 3)}" height="11" rx="2" fill="${CARD_INK.slate}"/>`);
    parts.push(svgText(MARGIN, barY + 40, `${timed[0].name} ${cardPercent(share)}`, { family: 'mono', size: 19, fill: CARD_INK.dim }));
    const rest = timed.slice(1).map((agent) => `${agent.name} ${cardPercent(agent.agentMs / stats.totals.agentMs)}`).join(', ');
    parts.push(svgText(MARGIN + LEFT_W, barY + 40, rest, { family: 'mono', size: 19, fill: CARD_INK.dim, anchor: 'end' }));
    factY = barY + 58;
  }

  if (showProjects && stats.projects.length > 0) {
    const names = stats.projects.slice(0, 3).map((project) => project.name);
    const listed = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : names[0];
    const sentence = `Most hours: ${listed}.`;
    parts.push(svgText(MARGIN, Math.min(factY + 26, 766), sentence, { family: 'serif', size: svgFit(sentence, 22, LEFT_W, CARD_SERIF_EM), fill: CARD_INK.dim }));
  }

  // Right column: Heatmap
  const chart = { x: CHART_X, y: 146, width: CHART_W, row: 21 };
  parts.push(...drawHeatmap(data, range, chart));

  const captionY = chart.y + 24 * chart.row + 74;
  if (stats.busiestDay) {
    const caption = `${cardDayLabel(stats.busiestDay.date)}: ${cardHours(stats.busiestDay.agentMs)} agent hours across ${cardPlural(stats.busiestDay.sessions, 'session')}.`;
    parts.push(svgText(CHART_X, captionY, caption, { family: 'serif', size: svgFit(caption, 24, CHART_W, CARD_SERIF_EM), fill: CARD_INK.amber }));
  }

  const earlier = stats.coverage?.earlier;
  if (range.zoomed) {
    const spanLabel = `${cardDayLabel(dayDate(data.year, range.start))} – ${cardDayLabel(dayDate(data.year, range.end))}`;
    const note = earlier
      ? `Zoomed to ${spanLabel} · plus ${cardPlural(earlier.days, 'earlier day')} from Claude summary.`
      : `Zoomed to active window (${spanLabel}).`;
    parts.push(svgText(CHART_X, captionY + 34, note, { family: 'serif', size: svgFit(note, 19, CHART_W, CARD_SERIF_EM * 0.94), fill: CARD_INK.faint, italic: true }));
  } else if (earlier) {
    const note = `Bottom ticks: ${cardPlural(earlier.days, 'earlier day')} from Claude summary.`;
    parts.push(svgText(CHART_X, captionY + 34, note, { family: 'serif', size: svgFit(note, 19, CHART_W, CARD_SERIF_EM * 0.94), fill: CARD_INK.faint, italic: true }));
  }

  // Footer
  parts.push(`<line x1="${MARGIN}" y1="802" x2="${WIDTH - MARGIN}" y2="802" stroke="${CARD_INK.border}" stroke-width="1"/>`);
  parts.push(svgText(MARGIN, 846, 'npx lokalbot', { family: 'mono', size: 24, fill: CARD_INK.text, weight: 600 }));
  parts.push(svgText(MARGIN + 206, 846, 'Counted locally from session logs. Nothing was uploaded.', { family: 'serif', size: 21, fill: CARD_INK.faint, italic: true }));
  parts.push(svgText(WIDTH - MARGIN, 846, 'lokalbot.com', { family: 'mono', size: 24, fill: CARD_INK.teal, anchor: 'end', weight: 600 }));

  return wrapSvg(WIDTH, HEIGHT, stats, showApiValue, parts);
}

function drawHeatmap(data, range, { x, y, width, row }) {
  const { stats, grid, months, earlierDays } = data;
  const busiest = stats.busiestDay;
  const parts = [];
  const count = Math.max(1, range.end - range.start + 1);
  const column = width / count;
  const height = row * 24;
  parts.push(`<rect x="${x - 6}" y="${y - 6}" width="${width + 12}" height="${height + 12}" rx="6" fill="${CARD_INK.well}"/>`);

  // Earlier-days summary strip under full-year view.
  if (!range.zoomed && earlierDays) {
    let most = 0;
    for (let day = range.start; day <= range.end; day += 1) {
      if (earlierDays[day] > most) most = earlierDays[day];
    }
    if (most > 0) {
      const marks = ['', '', ''];
      for (let day = range.start; day <= range.end; day += 1) {
        if (earlierDays[day] <= 0) continue;
        const level = Math.min(2, Math.floor(Math.sqrt(earlierDays[day] / most) * 3));
        const offset = day - range.start;
        marks[level] += `M${svgRound(x + offset * column)} ${y + height + 10}h${svgRound(column + 0.35)}v7h-${svgRound(column + 0.35)}z`;
      }
      ['#2c4152', CARD_INK.slate, '#7f9db3'].forEach((fill, level) => {
        if (marks[level]) parts.push(`<path d="${marks[level]}" fill="${fill}"/>`);
      });
    }
  }

  // Hour labels
  const hourLabels = [[0, '12 am'], [6, '6 am'], [12, '12 pm'], [18, '6 pm']];
  for (const [hour, label] of hourLabels) {
    parts.push(svgText(x - 18, y + hour * row + Math.round(row * 0.78), label, { family: 'mono', size: 17, fill: CARD_INK.faint, anchor: 'end' }));
  }

  // X-axis labels: months in full-year mode, evenly spaced dates in zoomed mode.
  if (range.zoomed) {
    const ticks = Math.min(6, count);
    const step = ticks > 1 ? (count - 1) / (ticks - 1) : 1;
    let lastX = -1000;
    for (let idx = 0; idx < ticks; idx += 1) {
      const offset = Math.round(idx * step);
      const day = range.start + offset;
      const px = svgRound(x + offset * column);
      if (px - lastX < 84) continue;
      lastX = px;
      const anchor = idx === ticks - 1 && px > x + width - 64 ? 'end' : undefined;
      const labelX = anchor === 'end' ? x + width : px;
      parts.push(svgText(labelX, y + height + 36, cardDayLabel(dayDate(data.year, day)), { family: 'mono', size: 17, fill: CARD_INK.faint, anchor }));
    }
  } else {
    let month = -1;
    for (let day = range.start; day <= range.end; day += 1) {
      if (months[day] === month) continue;
      month = months[day];
      parts.push(svgText(svgRound(x + (day - range.start) * column), y + height + 36, CARD_MONTHS[month], { family: 'mono', size: 17, fill: CARD_INK.faint }));
    }
  }

  // Cells grouped by colour into paths.
  const gap = column > 6 ? 1.5 : -0.35;
  const cellW = svgRound(Math.max(1.5, column - gap));
  const paths = new Map();
  for (let day = range.start; day <= range.end; day += 1) {
    const left = svgRound(x + (day - range.start) * column);
    for (let hour = 0; hour < 24; hour += 1) {
      const ms = grid[day * 24 + hour];
      if (!ms || ms <= 0) continue;
      const fill = busiest && busiest.day === day ? amberColor(ms) : tealColor(ms);
      paths.set(fill, `${paths.get(fill) ?? ''}M${left} ${y + hour * row}h${cellW}v${row - 1}h-${cellW}z`);
    }
  }
  for (const [fill, d] of paths) parts.push(`<path d="${d}" fill="${fill}"/>`);

  if (busiest && busiest.day >= range.start && busiest.day <= range.end) {
    const centre = svgRound(x + (busiest.day - range.start + 0.5) * column);
    parts.push(`<path d="M${centre - 7} ${y - 22}h14l-7 11z" fill="${CARD_INK.amber}"/>`);
  }
  return parts;
}

function tealColor(ms) {
  const level = Math.min(1, ms / CARD_HOUR);
  const step = Math.max(1, Math.ceil(Math.sqrt(level) * 6));
  const ramp = ['#113a43', '#145058', '#18706c', '#1d9486', '#23c4ae', '#6ef2dc'];
  if (ms > 1.5 * CARD_HOUR) return '#c9fff5';
  return ramp[step - 1];
}

function amberColor(ms) {
  const level = Math.min(1, ms / CARD_HOUR);
  const ramp = ['#6b4a12', '#a8771a', '#e0a41f', '#fbbf24'];
  return ramp[Math.max(1, Math.ceil(Math.sqrt(level) * 4)) - 1];
}

function svgFactLine(x, y, pieces, maxWidth, maxSize) {
  let size = maxSize;
  const width = () => pieces.reduce((sum, [value, figure]) => sum + value.length * size * (figure ? 0.9 * CARD_MONO_EM : CARD_SERIF_EM), 0);
  while (size > 20 && width() > maxWidth) size -= 1;
  const spans = pieces.map(([value, figure]) => (figure
    ? `<tspan class="mono" font-size="${Math.round(size * 0.9)}" font-weight="600" fill="${CARD_INK.text}">${svgEscape(value)}</tspan>`
    : `<tspan fill="${CARD_INK.dim}">${svgEscape(value)}</tspan>`));
  return `<text x="${x}" y="${y}" class="serif" font-size="${size}" xml:space="preserve">${spans.join('')}</text>`;
}

function svgText(x, y, value, { family, size, fill, weight, anchor, italic, spacing } = {}) {
  const attributes = [`x="${x}"`, `y="${y}"`, `class="${family}"`, `font-size="${size}"`, `fill="${fill}"`];
  if (weight) attributes.push(`font-weight="${weight}"`);
  if (anchor) attributes.push(`text-anchor="${anchor}"`);
  if (italic) attributes.push('font-style="italic"');
  if (spacing) attributes.push(`letter-spacing="${spacing}"`);
  return `<text ${attributes.join(' ')}>${svgEscape(value)}</text>`;
}

function svgFit(value, size, maxWidth, em) {
  const natural = value.length * size * em;
  return natural <= maxWidth ? size : Math.max(16, Math.floor(maxWidth / Math.max(1, value.length * em)));
}

function wrapWords(text, maxChars, maxLines) {
  if (text.length <= maxChars || maxLines <= 1) return [text];
  const words = text.split(/\s+/);
  const lines = [];
  let current = '';
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (candidate.length <= maxChars || !current) {
      current = candidate;
    } else if (lines.length + 1 < maxLines) {
      lines.push(current);
      current = word;
    } else {
      current = candidate;
    }
  }
  if (current) lines.push(current);
  return lines;
}

function svgRound(value) {
  return Math.round(value * 100) / 100;
}

export function svgEscape(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function wrapSvg(width, height, stats, showApiValue, parts) {
  const facts = cardFactLines(stats, { showApiValue }).map((line) => line.map(([value]) => value).join('')).join('. ');
  const alt = `Agent Wrapped ${stats.year}. ${stats.persona.title}: ${stats.persona.line} ${facts}.`;
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${svgEscape(alt)}">`,
    `<style>.serif{font-family:${CARD_SERIF}}.mono{font-family:${CARD_MONO}}</style>`,
    ...parts,
    '</svg>',
  ].join('\n');
}

function dayDate(year, day) {
  const date = new Date(Date.UTC(year, 0, 1 + day));
  const pad = (v) => String(v).padStart(2, '0');
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
}

function cardNumber(value) {
  return Math.round(value).toLocaleString('en-US');
}

function cardCompact(value) {
  const steps = [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];
  for (const [size, suffix] of steps) {
    if (value >= size) {
      const scaled = value / size;
      return `${scaled >= 100 ? Math.round(scaled) : Math.round(scaled * 10) / 10}${suffix}`;
    }
  }
  return cardNumber(value);
}

function cardHours(ms) {
  const value = ms / CARD_HOUR;
  return value >= 10 ? cardNumber(value) : String(Math.round(value * 10) / 10);
}

function cardDuration(ms) {
  const minutes = Math.round(ms / 60000);
  if (minutes < 60) return `${minutes} min`;
  const rest = minutes % 60;
  return rest === 0 ? `${cardNumber(minutes / 60)} h` : `${cardNumber(Math.floor(minutes / 60))} h ${rest} min`;
}

function cardDayLabel(date) {
  if (typeof date !== 'string') return '';
  const [, month, day] = date.split('-').map(Number);
  return `${CARD_MONTHS[month - 1]} ${day}`;
}

function cardPercent(share) {
  return `${Math.round(share * 100)}%`;
}

function cardCurrency(usd) {
  return `$${cardNumber(usd)}`;
}

function cardMultiplier(value) {
  const rounded = Math.round(value * 10) / 10;
  return `${rounded % 1 === 0 ? rounded.toFixed(0) : rounded.toFixed(1)}×`;
}

function cardPlural(count, one, many = `${one}s`) {
  return `${cardNumber(count)} ${count === 1 ? one : many}`;
}

export function cardFactLines(stats, { showApiValue = true } = {}) {
  const { totals } = stats;
  const worked = cardHours(totals.agentMs);
  const first = [
    [worked, true],
    [worked === '1' ? ' hour of agent work on ' : ' hours of agent work on '],
    [cardNumber(totals.activeDays), true],
    [totals.activeDays === 1 ? ' day' : ' days'],
  ];
  if ((totals.parallelMultiplier ?? 1) >= 1.2) {
    first.push([' · '], [cardMultiplier(totals.parallelMultiplier), true], [' parallel']);
  }
  const lines = [
    first,
    [[cardNumber(totals.requests), true], [totals.requests === 1 ? ' request from you, ' : ' requests from you, '], [cardNumber(totals.toolCalls), true], [' tool calls from them']],
  ];
  if (totals.tokens.total > 0) {
    const tokenLine = [[cardCompact(totals.tokens.input), true], [' tokens read, '], [cardCompact(totals.tokens.output), true], [' written']];
    if (showApiValue && (totals.estimatedApiUsd ?? 0) >= 10) {
      tokenLine.push([' (~'], [cardCurrency(totals.estimatedApiUsd), true], [' API value)']);
    }
    lines.push(tokenLine);
  }
  if (totals.commits > 0 && totals.pullRequestsMerged > 0) {
    lines.push([[cardNumber(totals.commits), true], [totals.commits === 1 ? ' commit and ' : ' commits and '], [cardNumber(totals.pullRequestsMerged), true], [totals.pullRequestsMerged === 1 ? ' merged pull request' : ' merged pull requests']]);
  } else if (totals.commits > 0) {
    lines.push([[cardNumber(totals.commits), true], [totals.commits === 1 ? ' commit across ' : ' commits across '], [cardNumber(totals.filesChanged), true], [totals.filesChanged === 1 ? ' changed file' : ' changed files']]);
  } else if (stats.longestRun) {
    lines.push([[cardNumber(totals.sessions), true], [totals.sessions === 1 ? ' session, the longest run ' : ' sessions, the longest run '], [cardDuration(stats.longestRun.ms), true]]);
  }
  return lines;
}

export function cardShareCaption(stats, { showApiValue = true } = {}) {
  const { totals } = stats;
  const bits = [`${cardHours(totals.agentMs)} agent hours on ${cardPlural(totals.activeDays, 'day')}`];
  if ((totals.parallelMultiplier ?? 1) >= 1.2) bits[0] += ` (${cardMultiplier(totals.parallelMultiplier)} parallel)`;
  if (totals.toolCalls > 0) bits.push(`${cardNumber(totals.toolCalls)} tool calls`);
  if (showApiValue && (totals.estimatedApiUsd ?? 0) >= 10) bits.push(`~${cardCurrency(totals.estimatedApiUsd)} API value`);
  if (totals.commits > 0) bits.push(cardPlural(totals.commits, 'commit'));
  return `My ${stats.year} Agent Wrapped: ${stats.persona.title}\n${bits.join(' · ')}\n\nRun yours locally (zero uploads): npx lokalbot`;
}
