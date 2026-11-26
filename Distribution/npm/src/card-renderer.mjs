const CARD_HOUR = 60 * 60 * 1000;
const CARD_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const CARD_THEMES = {
  dark: {
    ground: '#070c12',
    surface: '#0c141e',
    surfaceHi: '#0e1d24',
    well: '#0b131d',
    border: '#182534',
    borderHi: '#1f4a4f',
    text: '#ecf3f7',
    dim: '#9fb3c2',
    faint: '#72889a',
    teal: '#23c4ae',
    tealBright: '#5eead4',
    amber: '#fbbf24',
    slate: '#476176',
    cellEmpty: '#131f2c',
    cellEarlier: '#2e4559',
    ramp: ['#0e3c44', '#14696a', '#1da290', '#38e3ca'],
    cellPeak: '#fbbf24',
    barTrack: '#13202e',
    agentColors: ['#23c4ae', '#60a5fa', '#c084fc', '#fbbf24', '#476176'],
  },
  light: {
    ground: '#f4f7f7',
    surface: '#ffffff',
    surfaceHi: '#e7f6f3',
    well: '#ffffff',
    border: '#d5e0e2',
    borderHi: '#7ccbc0',
    text: '#0b1219',
    dim: '#3b4b56',
    faint: '#5f7280',
    teal: '#0b7a6e',
    tealBright: '#075f55',
    amber: '#c76805',
    slate: '#8ba2b2',
    cellEmpty: '#e7efef',
    cellEarlier: '#c2d2db',
    ramp: ['#ace8de', '#5ac8b7', '#169888', '#08685e'],
    cellPeak: '#d97706',
    barTrack: '#e6eeee',
    agentColors: ['#0b7a6e', '#2563eb', '#7c3aed', '#d97706', '#8ba2b2'],
  },
};

const CARD_SANS = `-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Inter', 'Segoe UI', system-ui, sans-serif`;
const CARD_MONO = `ui-monospace, 'SF Mono', SFMono-Regular, Menlo, 'Cascadia Mono', Consolas, 'DejaVu Sans Mono', monospace`;
const CARD_SANS_EM = 0.52;
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
  const theme = options.theme === 'light' ? 'light' : 'dark';
  const resolved = { ...options, theme };
  return layout === 'wide'
    ? renderWideCard(data, resolved)
    : renderPortraitCard(data, resolved);
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
  let start = Math.max(0, first - 3);
  let end = Math.min(totalDays - 1, last + 3);
  while (end - start + 1 < Math.min(42, totalDays)) {
    if (start > 0) start -= 1;
    else if (end < totalDays - 1) end += 1;
    else break;
  }
  return { start, end, zoomed: start > 0 || end < totalDays - 1 };
}

function buildKpiTiles(stats, { showApiValue = true } = {}) {
  const { totals } = stats;
  const tiles = [];

  const hrs = cardHours(totals.agentMs);
  const daysText = cardPlural(totals.activeDays, 'day');
  const parallelText = (totals.parallelMultiplier ?? 1) >= 1.2
    ? `${daysText} · ${cardMultiplier(totals.parallelMultiplier)} parallel`
    : `${daysText} active`;
  tiles.push({
    label: 'AGENT WORK',
    value: `${hrs} h`,
    sub: parallelText,
    highlight: true,
  });

  if (showApiValue && (totals.estimatedApiUsd ?? 0) >= 10) {
    const tokenSub = totals.tokens.total > 0
      ? `${cardCompact(totals.tokens.input)} read · ${cardCompact(totals.tokens.output)} written`
      : 'At public list rates';
    tiles.push({
      label: 'EST. API VALUE',
      value: `~${cardCurrency(totals.estimatedApiUsd)}`,
      sub: tokenSub,
    });
  } else if (totals.tokens.total > 0) {
    tiles.push({
      label: 'TOKENS READ',
      value: cardCompact(totals.tokens.input),
      sub: `${cardCompact(totals.tokens.output)} written`,
    });
  } else {
    tiles.push({
      label: 'SESSIONS',
      value: cardNumber(totals.sessions),
      sub: stats.longestRun ? `Longest ${cardDuration(stats.longestRun.ms)}` : 'Logged locally',
    });
  }

  const toolDisplay = totals.toolCalls >= 100000 ? cardCompact(totals.toolCalls) : cardNumber(totals.toolCalls);
  tiles.push({
    label: 'TOOL CALLS',
    value: toolDisplay,
    sub: `${cardNumber(totals.requests)} ${totals.requests === 1 ? 'request' : 'requests'}`,
  });

  if (totals.commits > 0 && totals.pullRequestsMerged > 0) {
    tiles.push({
      label: 'COMMITS',
      value: cardNumber(totals.commits),
      sub: `${cardNumber(totals.pullRequestsMerged)} merged ${totals.pullRequestsMerged === 1 ? 'PR' : 'PRs'}`,
    });
  } else if (totals.commits > 0) {
    tiles.push({
      label: 'COMMITS',
      value: cardNumber(totals.commits),
      sub: `${cardNumber(totals.filesChanged)} ${totals.filesChanged === 1 ? 'file' : 'files'} changed`,
    });
  } else {
    tiles.push({
      label: 'SESSIONS',
      value: cardNumber(totals.sessions),
      sub: stats.longestRun ? `Longest run ${cardDuration(stats.longestRun.ms)}` : 'On this computer',
    });
  }

  return tiles;
}

function drawKpiTile(x, y, w, h, tile, pal, { valueSize = 44, labelSize = 13, subSize = 16 } = {}) {
  const parts = [];
  const fill = tile.highlight ? pal.surfaceHi : pal.surface;
  const stroke = tile.highlight ? pal.borderHi : pal.border;
  const valFill = tile.highlight ? pal.tealBright : pal.text;
  const padX = 24;
  const maxW = w - padX * 2;

  parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="14" fill="${fill}" stroke="${stroke}" stroke-width="1.5"/>`);
  parts.push(svgText(x + padX, y + 32, tile.label, {
    family: 'mono',
    size: labelSize,
    fill: tile.highlight ? pal.teal : pal.faint,
    weight: 700,
    spacing: 1.2,
  }));

  const fittedVal = svgFit(tile.value, valueSize, maxW, 0.58);
  parts.push(svgText(x + padX, y + Math.round(h * 0.62), tile.value, {
    family: 'sans',
    size: fittedVal,
    fill: valFill,
    weight: 800,
    spacing: -1.1,
  }));

  const fittedSub = svgFit(tile.sub, subSize, maxW, CARD_SANS_EM);
  parts.push(svgText(x + padX, y + h - 20, tile.sub, {
    family: 'sans',
    size: fittedSub,
    fill: pal.dim,
    weight: 500,
  }));

  return parts;
}

function drawBadge(x, y, text, pal, { size = 15, padX = 16, height = 34 } = {}) {
  const spacing = 1.1;
  const estW = Math.round(text.length * (size * CARD_MONO_EM + spacing) + padX * 2);
  const radius = Math.round(height / 2);
  return [
    `<rect x="${x}" y="${y}" width="${estW}" height="${height}" rx="${radius}" ry="${radius}" fill="${pal.surfaceHi}" stroke="${pal.borderHi}" stroke-width="1.2"/>`,
    svgText(x + Math.round(estW / 2), y + Math.round(height * 0.66), text, {
      family: 'mono',
      size,
      fill: pal.tealBright,
      weight: 700,
      spacing,
      anchor: 'middle',
    }),
  ];
}

function dailyActivity(data) {
  const byDay = data.stats?.byDay;
  if (Array.isArray(byDay) && byDay.length === data.days) return byDay;
  const totals = new Float64Array(data.days);
  const { grid } = data;
  for (let day = 0; day < data.days; day += 1) {
    let sum = 0;
    for (let hour = 0; hour < 24; hour += 1) sum += grid[day * 24 + hour] ?? 0;
    totals[day] = sum;
  }
  return totals;
}

function drawContributionGraph(data, range, pal, { x, y, width, height, compact = false } = {}) {
  const { stats, months, earlierDays } = data;
  const busiest = stats.busiestDay;
  const byDay = dailyActivity(data);
  const parts = [];

  parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.well}" stroke="${pal.border}" stroke-width="1.4"/>`);

  const padX = compact ? 22 : 28;
  const padTop = compact ? 26 : 30;
  const labelW = compact ? 38 : 44;
  const gridX = x + padX + labelW;
  const maxGridW = width - padX * 2 - labelW;

  const jan1Dow = new Date(Date.UTC(data.year, 0, 1)).getUTCDay();
  const startWeek = Math.floor((jan1Dow + range.start) / 7);
  const endWeek = Math.floor((jan1Dow + range.end) / 7);
  const weeks = Math.max(1, endWeek - startWeek + 1);

  const rawStep = maxGridW / weeks;
  const maxStepByH = (height - padTop - (compact ? 74 : 84)) / 7;
  const maxStep = Math.min(compact ? 24 : 28, maxStepByH);
  const step = Math.min(rawStep, maxStep);
  const gap = Math.max(2.5, Math.min(4.8, step * 0.20));
  const cell = Math.max(6, step - gap);
  const radius = Math.max(2, Math.min(4.5, cell * 0.22));
  const actualGridW = weeks * step - gap;
  const offsetX = gridX + (weeks < 30 ? Math.round((maxGridW - actualGridW) / 2) : 0);
  const gridY = y + padTop + 22;

  const nonZero = [];
  for (let day = range.start; day <= range.end; day += 1) {
    if (byDay[day] > 0) nonZero.push(byDay[day]);
  }
  nonZero.sort((a, b) => a - b);
  const p88 = nonZero.length > 0 ? nonZero[Math.min(nonZero.length - 1, Math.floor(nonZero.length * 0.88))] : 4 * CARD_HOUR;
  const scaleRef = Math.max(1.5 * CARD_HOUR, p88);

  const levelFor = (ms) => {
    const ratio = ms / scaleRef;
    if (ratio <= 0.22) return 0;
    if (ratio <= 0.50) return 1;
    if (ratio <= 0.82) return 2;
    return 3;
  };

  let lastMonth = -1;
  let lastMonthX = -1000;
  for (let day = range.start; day <= range.end; day += 1) {
    const m = months[day];
    if (m === lastMonth) continue;
    lastMonth = m;
    const wk = Math.floor((jan1Dow + day) / 7) - startWeek;
    const mx = svgRound(offsetX + wk * step);
    if (mx - lastMonthX < (compact ? 42 : 52)) continue;
    lastMonthX = mx;
    parts.push(svgText(mx, gridY - 12, CARD_MONTHS[m], {
      family: 'mono',
      size: compact ? 13 : 14,
      fill: pal.faint,
      weight: 500,
    }));
  }

  for (const [dow, name] of [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']]) {
    const ly = svgRound(gridY + dow * step + cell * 0.76);
    parts.push(svgText(offsetX - 12, ly, name, {
      family: 'mono',
      size: compact ? 12 : 13,
      fill: pal.faint,
      anchor: 'end',
      weight: 500,
    }));
  }

  const cellR = svgRound(radius);
  const cellS = svgRound(cell);
  for (let day = range.start; day <= range.end; day += 1) {
    const wk = Math.floor((jan1Dow + day) / 7) - startWeek;
    const dow = (jan1Dow + day) % 7;
    const cx = svgRound(offsetX + wk * step);
    const cy = svgRound(gridY + dow * step);
    const ms = byDay[day] ?? 0;
    const isPeak = busiest && busiest.day === day && ms > 0;
    let fill = pal.cellEmpty;
    if (isPeak) {
      fill = pal.cellPeak;
    } else if (ms > 0) {
      fill = pal.ramp[levelFor(ms)];
    } else if (!range.zoomed && earlierDays && earlierDays[day] > 0) {
      fill = pal.cellEarlier;
    }
    parts.push(`<rect x="${cx}" y="${cy}" width="${cellS}" height="${cellS}" rx="${cellR}" fill="${fill}"/>`);
  }

  if (busiest && busiest.day >= range.start && busiest.day <= range.end) {
    const peakWk = Math.floor((jan1Dow + busiest.day) / 7) - startWeek;
    const centre = svgRound(offsetX + peakWk * step + cell / 2);
    const ty = gridY - 26;
    parts.push(`<path d="M${centre - 5} ${ty}h10l-5 7z" fill="${pal.amber}"/>`);
  }

  const footerY = y + height - (compact ? 20 : 22);
  const legSize = compact ? 12 : 14;
  const legGap = 4;
  const legSwatches = [pal.cellEmpty, ...pal.ramp];
  const legSwatchesW = legSwatches.length * legSize + (legSwatches.length - 1) * legGap;
  const moreLabelX = x + width - padX;
  const swatchesEndX = moreLabelX - (compact ? 42 : 46);
  const swatchesStartX = swatchesEndX - legSwatchesW;

  parts.push(svgText(swatchesStartX - 10, footerY, 'Less', {
    family: 'mono',
    size: compact ? 12 : 13,
    fill: pal.faint,
    anchor: 'end',
    weight: 500,
  }));
  legSwatches.forEach((fill, idx) => {
    const sx = swatchesStartX + idx * (legSize + legGap);
    parts.push(`<rect x="${sx}" y="${footerY - legSize + 2}" width="${legSize}" height="${legSize}" rx="3" fill="${fill}"/>`);
  });
  parts.push(svgText(moreLabelX, footerY, 'More', {
    family: 'mono',
    size: compact ? 12 : 13,
    fill: pal.faint,
    anchor: 'end',
    weight: 500,
  }));

  if (busiest) {
    const peakMaxW = Math.max(200, swatchesStartX - 58 - (x + padX));
    const peakText = compact
      ? `Peak · ${cardDayLabel(busiest.date)} · ${cardHours(busiest.agentMs)}h (${cardPlural(busiest.sessions, 'session')})`
      : `Peak · ${cardDayLabel(busiest.date)} · ${cardHours(busiest.agentMs)} agent hours across ${cardPlural(busiest.sessions, 'session')}`;
    parts.push(`<circle cx="${x + padX + 6}" cy="${footerY - 5}" r="5" fill="${pal.cellPeak}"/>`);
    parts.push(svgText(x + padX + 20, footerY, peakText, {
      family: 'mono',
      size: svgFit(peakText, compact ? 14 : 16, peakMaxW, CARD_MONO_EM),
      fill: pal.amber,
      weight: 600,
    }));
  }

  return parts;
}

function drawDailyRhythm(data, pal, { x, y, width, height }) {
  const { grid } = data;
  const byHour = new Float64Array(24);
  for (let day = 0; day < data.days; day += 1) {
    for (let hour = 0; hour < 24; hour += 1) {
      byHour[hour] += grid[day * 24 + hour] ?? 0;
    }
  }
  let peakHour = 0;
  let maxMs = 0;
  for (let h = 0; h < 24; h += 1) {
    if (byHour[h] > maxMs) {
      maxMs = byHour[h];
      peakHour = h;
    }
  }

  const parts = [];
  parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.4"/>`);

  const padX = 24;
  parts.push(svgText(x + padX, y + 32, 'DAILY RHYTHM', {
    family: 'mono',
    size: 13,
    fill: pal.faint,
    weight: 700,
    spacing: 1.2,
  }));
  if (maxMs > 0) {
    const peakLabel = `Most active around ${formatHourLabel(peakHour)}–${formatHourLabel((peakHour + 2) % 24)}`;
    parts.push(svgText(x + width - padX, y + 32, peakLabel, {
      family: 'mono',
      size: 14,
      fill: pal.dim,
      anchor: 'end',
      weight: 600,
    }));
  }

  const barAreaX = x + padX;
  const barAreaW = width - padX * 2;
  const barTop = y + 52;
  const barMaxH = height - 92;
  const slot = barAreaW / 24;
  const barW = svgRound(Math.max(8, slot - 8));

  for (let h = 0; h < 24; h += 1) {
    const ratio = maxMs > 0 ? byHour[h] / maxMs : 0;
    const bx = svgRound(barAreaX + h * slot + (slot - barW) / 2);
    parts.push(`<rect x="${bx}" y="${barTop}" width="${barW}" height="${barMaxH}" rx="4" fill="${pal.barTrack}"/>`);
    if (ratio > 0) {
      const bh = svgRound(Math.max(5, ratio * barMaxH));
      const by = svgRound(barTop + barMaxH - bh);
      const fill = ratio >= 0.85 ? pal.ramp[3] : (ratio >= 0.55 ? pal.ramp[2] : (ratio >= 0.25 ? pal.ramp[1] : pal.ramp[0]));
      parts.push(`<rect x="${bx}" y="${by}" width="${barW}" height="${bh}" rx="4" fill="${fill}"/>`);
    }
  }

  for (const [h, lbl] of [[0, '12a'], [6, '6a'], [12, '12p'], [18, '6p'], [23, '11p']]) {
    const lx = svgRound(barAreaX + h * slot + slot / 2);
    parts.push(svgText(lx, y + height - 16, lbl, {
      family: 'mono',
      size: 13,
      fill: pal.faint,
      anchor: 'middle',
      weight: 500,
    }));
  }
  return parts;
}

function formatHourLabel(hour) {
  const h = ((hour % 24) + 24) % 24;
  if (h === 0) return '12a';
  if (h < 12) return `${h}a`;
  if (h === 12) return '12p';
  return `${h - 12}p`;
}

function drawTopModelsPortrait(models, pal, { x, y, width, height }) {
  const list = models.slice(0, 5);
  const maxTokens = Math.max(1, list[0]?.total ?? 1);
  const parts = [];
  const padX = 24;

  parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.4"/>`);
  parts.push(svgText(x + padX, y + 32, 'TOP MODELS', {
    family: 'mono',
    size: 13,
    fill: pal.faint,
    weight: 700,
    spacing: 1.2,
  }));
  parts.push(svgText(x + width - padX, y + 32, 'TOKENS', {
    family: 'mono',
    size: 13,
    fill: pal.faint,
    anchor: 'end',
    weight: 700,
    spacing: 1.2,
  }));

  const startY = y + 66;
  const rowStep = list.length <= 4 ? 40 : 35;
  const nameX = x + padX + 34;
  const nameMaxW = 360;
  const barX = x + padX + 412;
  const valueW = 108;
  const barW = Math.max(120, width - padX * 2 - 412 - valueW);

  list.forEach((model, idx) => {
    const ry = startY + idx * rowStep;
    const isTop = idx === 0;
    const share = model.total / maxTokens;
    const fillW = svgRound(Math.max(8, share * barW));
    const barFill = isTop ? pal.teal : (idx === 1 ? pal.ramp[2] : pal.slate);

    parts.push(svgText(x + padX, ry, `${idx + 1}`, {
      family: 'mono',
      size: 15,
      fill: isTop ? pal.teal : pal.faint,
      weight: 700,
    }));
    const label = truncateText(model.name, 28);
    parts.push(svgText(nameX, ry, label, {
      family: 'mono',
      size: svgFit(label, 17, nameMaxW, CARD_MONO_EM),
      fill: isTop ? pal.text : pal.dim,
      weight: isTop ? 700 : 600,
    }));
    parts.push(`<rect x="${barX}" y="${ry - 10}" width="${barW}" height="10" rx="5" fill="${pal.barTrack}"/>`);
    parts.push(`<rect x="${barX}" y="${ry - 10}" width="${fillW}" height="10" rx="5" fill="${barFill}"/>`);
    parts.push(svgText(x + width - padX, ry, cardCompact(model.total), {
      family: 'mono',
      size: 17,
      fill: isTop ? pal.tealBright : pal.text,
      anchor: 'end',
      weight: 700,
    }));
  });

  return parts;
}

function drawTopModelsWide(models, pal, { x, y, width, height }) {
  const list = models.slice(0, 5);
  const maxTokens = Math.max(1, list[0]?.total ?? 1);
  const parts = [];
  const padX = 22;

  parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.4"/>`);
  parts.push(svgText(x + padX, y + 26, 'TOP MODELS', {
    family: 'mono',
    size: 12,
    fill: pal.faint,
    weight: 700,
    spacing: 1.2,
  }));
  parts.push(svgText(x + width - padX, y + 26, 'TOTAL TOKENS', {
    family: 'mono',
    size: 12,
    fill: pal.faint,
    anchor: 'end',
    weight: 700,
    spacing: 1.2,
  }));

  const gap = 14;
  const innerW = width - padX * 2;
  const cols = list.length;
  const colW = Math.floor((innerW - gap * (cols - 1)) / cols);
  const slotY = y + 38;
  const slotH = height - 50;

  list.forEach((model, idx) => {
    const cx = x + padX + idx * (colW + gap);
    const isTop = idx === 0;
    const share = model.total / maxTokens;
    const slotFill = isTop ? pal.surfaceHi : pal.ground;
    const slotStroke = isTop ? pal.borderHi : pal.border;
    const barFill = isTop ? pal.teal : (idx === 1 ? pal.ramp[2] : pal.slate);

    parts.push(`<rect x="${cx}" y="${slotY}" width="${colW}" height="${slotH}" rx="10" fill="${slotFill}" stroke="${slotStroke}" stroke-width="1.1"/>`);

    const label = truncateText(model.name, cols >= 5 ? 21 : 28);
    const labelText = `#${idx + 1} ${label}`;
    parts.push(svgText(cx + 14, slotY + 25, labelText, {
      family: 'mono',
      size: svgFit(labelText, 14, colW - 28, CARD_MONO_EM),
      fill: isTop ? pal.tealBright : pal.dim,
      weight: isTop ? 700 : 600,
    }));

    parts.push(svgText(cx + 14, slotY + 53, cardCompact(model.total), {
      family: 'sans',
      size: 23,
      fill: pal.text,
      weight: 800,
      spacing: -0.5,
    }));

    const barMaxW = colW - 28;
    const barW = svgRound(Math.max(8, share * barMaxW));
    parts.push(`<rect x="${cx + 14}" y="${slotY + slotH - 12}" width="${barMaxW}" height="5" rx="2.5" fill="${pal.barTrack}"/>`);
    parts.push(`<rect x="${cx + 14}" y="${slotY + slotH - 12}" width="${barW}" height="5" rx="2.5" fill="${barFill}"/>`);
  });

  return parts;
}

function truncateText(text, maxChars) {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars - 1)}…`;
}

function headerAgentLine(agents) {
  if (!Array.isArray(agents) || agents.length === 0) return '';
  if (agents.length <= 4) return agents.map((agent) => agent.name).join(' · ');
  return `${agents.slice(0, 4).map((agent) => agent.name).join(' · ')} · +${agents.length - 4}`;
}

function drawAgentSplitBar(timed, totalMs, pal, { x, y, width, maxNamed = 4, fontSize = 16 } = {}) {
  if (timed.length < 2 || totalMs <= 0) return [];
  const parts = [];

  if (timed.length === 2) {
    const share = timed[0].agentMs / totalMs;
    const split = Math.round(width * share);
    parts.push(`<rect x="${x}" y="${y}" width="${Math.max(6, split - 4)}" height="12" rx="6" fill="${pal.teal}"/>`);
    parts.push(`<rect x="${x + split + 4}" y="${y}" width="${Math.max(6, width - split - 4)}" height="12" rx="6" fill="${pal.slate}"/>`);
    parts.push(svgText(x, y + 36, `${timed[0].name} ${cardPercent(share)}`, { family: 'mono', size: fontSize, fill: pal.text, weight: 600 }));
    parts.push(svgText(x + width, y + 36, `${timed[1].name} ${cardPercent(timed[1].agentMs / totalMs)}`, { family: 'mono', size: fontSize, fill: pal.dim, anchor: 'end', weight: 600 }));
    return parts;
  }

  const palette = pal.agentColors ?? [pal.teal, pal.amber, pal.slate];
  const named = [];
  let otherMs = 0;
  for (const agent of timed) {
    const share = agent.agentMs / totalMs;
    if (named.length < maxNamed && share >= 0.01) {
      named.push({ name: agent.name, share, color: palette[named.length % (palette.length - 1)] });
    } else {
      otherMs += agent.agentMs;
    }
  }
  const segments = [...named];
  if (otherMs > 0) {
    const otherShare = otherMs / totalMs;
    if (otherShare >= 0.005 || segments.length < 2) {
      segments.push({ name: 'Other', share: otherShare, color: pal.slate });
    }
  }
  if (segments.length < 2) return [];

  const sumShare = segments.reduce((sum, seg) => sum + seg.share, 0) || 1;
  const rawPcts = segments.map((seg) => (seg.share / sumShare) * 100);
  const pcts = rawPcts.map((value) => Math.floor(value));
  let remainder = 100 - pcts.reduce((sum, p) => sum + p, 0);
  const order = rawPcts
    .map((value, idx) => ({ idx, frac: value - pcts[idx] }))
    .sort((a, b) => b.frac - a.frac);
  for (let i = 0; i < remainder && i < order.length; i += 1) {
    pcts[order[i].idx] += 1;
  }

  const gap = 5;
  const minW = 10;
  const availW = Math.max(segments.length * minW, width - gap * (segments.length - 1));
  const widths = segments.map((seg) => Math.max(minW, Math.round((seg.share / sumShare) * availW)));
  const diff = availW - widths.reduce((sum, w) => sum + w, 0);
  if (diff !== 0) {
    const widest = widths.indexOf(Math.max(...widths));
    widths[widest] = Math.max(minW, widths[widest] + diff);
  }

  let cursor = x;
  segments.forEach((seg, idx) => {
    parts.push(`<rect x="${cursor}" y="${y}" width="${widths[idx]}" height="12" rx="6" fill="${seg.color}"/>`);
    cursor += widths[idx] + gap;
  });

  const labels = segments.map((seg, idx) => `${seg.name} ${pcts[idx]}%`);
  let size = fontSize;
  let itemGap = 18;
  const dotBlock = 15;
  const measure = (s, g) => labels.reduce((sum, lbl) => sum + dotBlock + lbl.length * s * CARD_MONO_EM, 0) + g * (labels.length - 1);
  if (measure(size, itemGap) > width) itemGap = 12;
  while (size > 11 && measure(size, itemGap) > width) size -= 1;

  let lx = x;
  const ly = y + 36;
  segments.forEach((seg, idx) => {
    const label = labels[idx];
    parts.push(`<circle cx="${svgRound(lx + 4.5)}" cy="${ly - 5}" r="4.5" fill="${seg.color}"/>`);
    parts.push(svgText(svgRound(lx + dotBlock), ly, label, {
      family: 'mono',
      size,
      fill: idx === 0 ? pal.text : pal.dim,
      weight: idx === 0 ? 700 : 600,
    }));
    lx += dotBlock + label.length * size * CARD_MONO_EM + itemGap;
  });

  return parts;
}

function renderPortraitCard(data, { showProjects = false, showApiValue = true, window: windowOption = 'auto', theme = 'dark' } = {}) {
  const pal = CARD_THEMES[theme] ?? CARD_THEMES.dark;
  const { stats } = data;
  const WIDTH = 1200;
  const HEIGHT = 1500;
  const MARGIN = 72;
  const inner = WIDTH - 2 * MARGIN;
  const range = resolveRange(data, windowOption);
  const parts = [];

  parts.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${pal.ground}"/>`);

  parts.push(...drawBadge(MARGIN, 60, `AGENT WRAPPED ${stats.year}`, pal, { size: 15, padX: 16, height: 36 }));
  const agents = headerAgentLine(stats.agents);
  if (agents) {
    parts.push(svgText(WIDTH - MARGIN, 84, agents, {
      family: 'mono',
      size: svgFit(agents, 18, inner - 290, CARD_MONO_EM),
      fill: pal.faint,
      anchor: 'end',
      weight: 600,
    }));
  }

  const titleSize = svgFit(stats.persona.title, 96, inner, 0.54);
  parts.push(svgText(MARGIN - 2, 204, stats.persona.title, {
    family: 'sans',
    size: titleSize,
    fill: pal.text,
    weight: 800,
    spacing: -2.2,
  }));
  const lineSize = svgFit(stats.persona.line, 25, inner, CARD_SANS_EM);
  parts.push(svgText(MARGIN, 252, stats.persona.line, { family: 'sans', size: lineSize, fill: pal.dim, weight: 500 }));

  const tiles = buildKpiTiles(stats, { showApiValue });
  const gap = 20;
  const tileW = Math.floor((inner - gap) / 2);
  const tileH = 144;
  const gridY = 290;
  tiles.forEach((tile, idx) => {
    const col = idx % 2;
    const row = Math.floor(idx / 2);
    parts.push(...drawKpiTile(MARGIN + col * (tileW + gap), gridY + row * (tileH + gap), tileW, tileH, tile, pal, {
      valueSize: 50,
      labelSize: 14,
      subSize: 17,
    }));
  });

  const graphY = 610;
  const graphH = 252;
  parts.push(...drawContributionGraph(data, range, pal, {
    x: MARGIN,
    y: graphY,
    width: inner,
    height: graphH,
    compact: true,
  }));

  const earlier = stats.coverage?.earlier;
  let nextY = graphY + graphH + 20;
  if (range.zoomed) {
    const spanLabel = `${cardDayLabel(dayDate(data.year, range.start))} - ${cardDayLabel(dayDate(data.year, range.end))}`;
    const note = earlier
      ? `Zoomed to ${spanLabel} logs · plus ${cardPlural(earlier.days, 'earlier day')} counted by Claude Code.`
      : `Zoomed to active window (${spanLabel}).`;
    parts.push(svgText(MARGIN, nextY + 12, note, { family: 'sans', size: svgFit(note, 17, inner, CARD_SANS_EM), fill: pal.faint }));
    nextY += 34;
  } else if (earlier) {
    const note = `The marks under the year are ${cardPlural(earlier.days, 'earlier day')}: Claude Code deleted the logs and kept a count.`;
    parts.push(svgText(MARGIN, nextY + 12, note, { family: 'sans', size: svgFit(note, 17, inner, CARD_SANS_EM), fill: pal.faint }));
    nextY += 34;
  }

  const topModels = stats.topModels ?? [];
  const middleH = topModels.length > 0 ? 232 : 186;
  if (topModels.length > 0) {
    parts.push(...drawTopModelsPortrait(topModels, pal, {
      x: MARGIN,
      y: nextY + 4,
      width: inner,
      height: middleH,
    }));
  } else {
    parts.push(...drawDailyRhythm(data, pal, {
      x: MARGIN,
      y: nextY + 4,
      width: inner,
      height: middleH,
    }));
  }

  const timed = stats.agents.filter((agent) => agent.agentMs > 0);
  if (timed.length > 1 && stats.totals.agentMs > 0) {
    const barY = Math.min(nextY + middleH + 38, 1252);
    parts.push(...drawAgentSplitBar(timed, stats.totals.agentMs, pal, {
      x: MARGIN,
      y: barY,
      width: inner,
      maxNamed: 4,
      fontSize: 18,
    }));
  }

  if (showProjects && stats.projects.length > 0) {
    const names = stats.projects.slice(0, 3).map((project) => project.name);
    const listed = names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : names[0];
    const sentence = `Most hours went to ${listed}.`;
    parts.push(svgText(MARGIN, 1348, sentence, { family: 'sans', size: svgFit(sentence, 21, inner, CARD_SANS_EM), fill: pal.dim, weight: 500 }));
  }

  parts.push(`<line x1="${MARGIN}" y1="1384" x2="${WIDTH - MARGIN}" y2="1384" stroke="${pal.border}" stroke-width="1"/>`);
  parts.push(`<rect x="${MARGIN}" y="1408" width="194" height="44" rx="10" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.2"/>`);
  parts.push(svgText(MARGIN + 20, 1437, 'npx lokalbot', { family: 'mono', size: 21, fill: pal.text, weight: 700 }));
  parts.push(svgText(WIDTH - MARGIN, 1437, 'lokalbot.com/wrapped', { family: 'mono', size: 22, fill: pal.tealBright, anchor: 'end', weight: 700 }));
  parts.push(svgText(MARGIN, 1478, 'Counted locally from session logs. Nothing was uploaded.', { family: 'sans', size: 17, fill: pal.faint }));

  return wrapSvg(WIDTH, HEIGHT, stats, showApiValue, parts);
}

function renderWideCard(data, { showProjects = false, showApiValue = true, window: windowOption = 'auto', theme = 'dark' } = {}) {
  const pal = CARD_THEMES[theme] ?? CARD_THEMES.dark;
  const { stats } = data;
  const WIDTH = 1600;
  const HEIGHT = 900;
  const MARGIN = 64;
  const inner = WIDTH - 2 * MARGIN;
  const range = resolveRange(data, windowOption);
  const parts = [];

  parts.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${pal.ground}"/>`);

  parts.push(...drawBadge(MARGIN, 30, `AGENT WRAPPED ${stats.year}`, pal, { size: 14, padX: 15, height: 32 }));
  const agents = headerAgentLine(stats.agents);
  if (agents) {
    parts.push(svgText(WIDTH - MARGIN, 52, agents, {
      family: 'mono',
      size: svgFit(agents, 17, inner - 270, CARD_MONO_EM),
      fill: pal.faint,
      anchor: 'end',
      weight: 600,
    }));
  }
  parts.push(`<line x1="${MARGIN}" y1="78" x2="${WIDTH - MARGIN}" y2="78" stroke="${pal.border}" stroke-width="1"/>`);

  const titleMaxW = 900;
  const titleSize = svgFit(stats.persona.title, 62, titleMaxW, 0.54);
  parts.push(svgText(MARGIN - 2, 150, stats.persona.title, {
    family: 'sans',
    size: titleSize,
    fill: pal.text,
    weight: 800,
    spacing: -2.0,
  }));
  const subText = showProjects && stats.projects.length > 0
    ? `${stats.persona.line}  Most hours: ${stats.projects.slice(0, 3).map((p) => p.name).join(', ')}.`
    : stats.persona.line;
  parts.push(svgText(MARGIN, 186, subText, {
    family: 'sans',
    size: svgFit(subText, 20, titleMaxW, CARD_SANS_EM),
    fill: pal.dim,
    weight: 500,
  }));

  const timed = stats.agents.filter((agent) => agent.agentMs > 0);
  if (timed.length > 1 && stats.totals.agentMs > 0) {
    const barW = timed.length >= 3 ? 500 : 440;
    const barX = WIDTH - MARGIN - barW;
    const barY = 136;
    parts.push(...drawAgentSplitBar(timed, stats.totals.agentMs, pal, {
      x: barX,
      y: barY,
      width: barW,
      maxNamed: 3,
      fontSize: timed.length >= 3 ? 14 : 16,
    }));
  }

  const tiles = buildKpiTiles(stats, { showApiValue });
  const gap = 20;
  const tileW = Math.floor((inner - gap * (tiles.length - 1)) / tiles.length);
  const tileH = 122;
  const gridY = 212;
  tiles.forEach((tile, idx) => {
    parts.push(...drawKpiTile(MARGIN + idx * (tileW + gap), gridY, tileW, tileH, tile, pal, {
      valueSize: 42,
      labelSize: 13,
      subSize: 15,
    }));
  });

  const topModels = stats.topModels ?? [];
  const graphY = 352;
  const graphH = topModels.length > 0 ? 276 : 408;
  parts.push(...drawContributionGraph(data, range, pal, {
    x: MARGIN,
    y: graphY,
    width: inner,
    height: graphH,
    compact: topModels.length > 0,
  }));

  if (topModels.length > 0) {
    parts.push(...drawTopModelsWide(topModels, pal, {
      x: MARGIN,
      y: 644,
      width: inner,
      height: 132,
    }));
  }

  parts.push(`<line x1="${MARGIN}" y1="798" x2="${WIDTH - MARGIN}" y2="798" stroke="${pal.border}" stroke-width="1"/>`);
  parts.push(`<rect x="${MARGIN}" y="820" width="184" height="44" rx="10" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.2"/>`);
  parts.push(svgText(MARGIN + 19, 848, 'npx lokalbot', { family: 'mono', size: 20, fill: pal.text, weight: 700 }));
  parts.push(svgText(MARGIN + 208, 848, 'Counted locally from session logs. Nothing was uploaded.', { family: 'sans', size: 18, fill: pal.faint, weight: 500 }));
  parts.push(svgText(WIDTH - MARGIN, 848, 'lokalbot.com/wrapped', { family: 'mono', size: 21, fill: pal.tealBright, anchor: 'end', weight: 700 }));

  return wrapSvg(WIDTH, HEIGHT, stats, showApiValue, parts);
}

function svgText(x, y, value, { family, size, fill, weight, anchor, italic, spacing } = {}) {
  const attributes = [`x="${x}"`, `y="${y}"`, `class="${family}"`, `font-size="${size}"`, `fill="${fill}"`];
  if (spacing !== undefined) attributes.push(`letter-spacing="${spacing}"`);
  if (weight) attributes.push(`font-weight="${weight}"`);
  if (anchor) attributes.push(`text-anchor="${anchor}"`);
  if (italic) attributes.push('font-style="italic"');
  return `<text ${attributes.join(' ')}>${svgEscape(value)}</text>`;
}

function svgFit(value, size, maxWidth, em) {
  const natural = value.length * size * em;
  return natural <= maxWidth ? size : Math.max(13, Math.floor(maxWidth / Math.max(1, value.length * em)));
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
    `<style>.sans{font-family:${CARD_SANS}}.mono{font-family:${CARD_MONO}}</style>`,
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
  return `My ${stats.year} Agent Wrapped: ${stats.persona.title}\n${bits.join(' · ')}\n\nRun yours locally (zero uploads): npx lokalbot\nhttps://www.lokalbot.com/wrapped`;
}
