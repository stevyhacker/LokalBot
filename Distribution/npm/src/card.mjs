// The image people share: an SVG drawn from the year's figures, and the
// self-contained page that previews it with live layout/privacy toggles,
// saves or copies a 2x PNG, and prepares a post caption. Both load nothing
// from the network.

import fs from 'node:fs';

import {
  canZoomWindow,
  cardDimensions,
  cardShareCaption,
  defaultWindowMode,
  renderCardSvg,
  svgEscape,
} from './card-renderer.mjs';

const RENDERER_SOURCE = fs
  .readFileSync(new URL('./card-renderer.mjs', import.meta.url), 'utf8')
  .replace(/^export /gm, '');

const SERIF = `'Iowan Old Style', 'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif`;
const MONO = `ui-monospace, 'SF Mono', SFMono-Regular, Menlo, 'Cascadia Mono', Consolas, 'DejaVu Sans Mono', monospace`;
const INK = {
  ground: '#05080d',
  surface: '#0c141d',
  border: '#1b2836',
  text: '#ecf3f7',
  dim: '#a2b4c2',
  faint: '#8ba2b0',
  teal: '#23c4ae',
  tealBright: '#6ef2dc',
  amber: '#fbbf24',
};

export const escape = svgEscape;

/** Normalizes `{ stats, grid, calendar, earlierDays }` into the plain shape shared with the page. */
function cardData({ stats, grid, calendar, earlierDays }) {
  const months = new Array(calendar.days);
  for (let day = 0; day < calendar.days; day += 1) months[day] = calendar.month(day);
  return {
    year: calendar.year,
    days: calendar.days,
    months,
    stats,
    grid,
    earlierDays: earlierDays ?? null,
  };
}

/**
 * Project names can be client names, so the image leaves them out unless
 * `showProjects` is set.
 */
export function renderCard(result, options = {}) {
  return renderCardSvg(cardData(result), {
    layout: options.layout ?? 'portrait',
    showProjects: Boolean(options.showProjects),
    showApiValue: options.showApiValue !== false,
    window: options.window ?? 'auto',
  });
}

/** Packs sparse grid & earlierDays arrays so the standalone HTML file stays small. */
function serializePayload(data, { includeProjects = false } = {}) {
  const gridCells = [];
  for (let index = 0; index < data.grid.length; index += 1) {
    const ms = data.grid[index];
    if (ms > 0) gridCells.push([index, Math.round(ms)]);
  }
  const earlierCells = [];
  if (data.earlierDays) {
    for (let day = 0; day < data.earlierDays.length; day += 1) {
      const count = data.earlierDays[day];
      if (count > 0) earlierCells.push([day, count]);
    }
  }
  const safeStats = includeProjects ? data.stats : { ...data.stats, projects: [] };
  const json = JSON.stringify({
    year: data.year,
    days: data.days,
    months: data.months,
    stats: safeStats,
    gridCells,
    earlierCells,
  });
  return json
    .replaceAll('<', '\\u003c')
    .replaceAll('>', '\\u003e')
    .replaceAll('&', '\\u0026');
}

/** The standalone page that previews, customizes, and saves/copies the card as a 2x PNG. */
export function renderPage(result, options = {}) {
  const data = cardData(result);
  const { stats } = data;
  const initialLayout = options.layout === 'wide' ? 'wide' : 'portrait';
  const initialProjects = Boolean(options.showProjects);
  const initialApiValue = options.showApiValue !== false;
  const initialWindow = options.window ?? defaultWindowMode(stats);
  const zoomAvailable = canZoomWindow(stats);
  const hasProjects = initialProjects && stats.projects.length > 0;
  const hasApiValue = (stats.totals.estimatedApiUsd ?? 0) >= 10;

  const svg = renderCardSvg(data, {
    layout: initialLayout,
    showProjects: initialProjects,
    showApiValue: initialApiValue,
    window: initialWindow,
  });
  const baseName = `agent-wrapped-${stats.year}`;
  const defaultFile = `${baseName}.png`;
  const initialCaption = cardShareCaption(stats, { showApiValue: initialApiValue });
  const xIntentHref = `https://x.com/intent/tweet?text=${encodeURIComponent(initialCaption)}`;

  const claudeLate = (() => {
    const { claudeLoggedFrom = null, earlier = null } = stats.coverage ?? {};
    const usesClaude = stats.agents.some((agent) => agent.id === 'claude-code') || earlier !== null;
    const startsLate = claudeLoggedFrom !== null && claudeLoggedFrom > `${stats.year}-01-31`;
    return usesClaude && (earlier !== null || startsLate);
  })();

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent Wrapped ${stats.year}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: ${INK.ground}; color: ${INK.text}; font: 16px/1.55 ${SERIF}; }
  main { max-width: 620px; margin: 0 auto; padding: 28px 18px 56px; }
  main.wide { max-width: 860px; }
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
  .seg { display: inline-flex; background: ${INK.surface}; border: 1px solid ${INK.border}; border-radius: 8px; padding: 3px; gap: 2px; }
  .seg button { font: 600 13px/1 ${MONO}; color: ${INK.dim}; background: transparent; border: 0; border-radius: 6px; padding: 8px 12px; cursor: pointer; }
  .seg button[aria-pressed="true"] { color: #04141a; background: ${INK.teal}; }
  .toggles { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; font: 500 13px/1 ${MONO}; color: ${INK.dim}; }
  .toggles label { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; }
  .toggles input { accent-color: ${INK.teal}; width: 15px; height: 15px; cursor: pointer; }
  #stage { display: flex; justify-content: center; }
  #stage svg { display: block; width: 100%; height: auto; border-radius: 10px; border: 1px solid ${INK.border}; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-top: 18px; }
  .btn { display: inline-flex; align-items: center; gap: 6px; font: 600 14px/1 ${MONO}; color: #04141a; background: ${INK.teal}; border: 0; border-radius: 7px; padding: 12px 16px; cursor: pointer; text-decoration: none; }
  .btn.quiet { color: ${INK.text}; background: #14202d; border: 1px solid ${INK.border}; }
  .btn:focus-visible, .seg button:focus-visible, .copy-cmd:focus-visible { outline: 2px solid ${INK.tealBright}; outline-offset: 2px; }
  .btn[hidden] { display: none; }
  #status { color: ${INK.tealBright}; font: italic 15px/1.4 ${SERIF}; margin-left: 4px; }
  .note { color: ${INK.faint}; font-size: 14px; margin: 14px 0 0; }
  .tip { margin-top: 22px; padding: 14px 16px; background: #12171f; border: 1px solid #352b14; border-left: 3px solid ${INK.amber}; border-radius: 8px; color: ${INK.dim}; font-size: 15px; }
  .tip strong { color: ${INK.amber}; font-weight: 600; }
  .tip code { font: 500 13px/1.4 ${MONO}; color: ${INK.text}; background: #0a1017; padding: 2px 6px; border-radius: 4px; }
  .promo { margin-top: 24px; padding: 20px 22px; background: ${INK.surface}; border: 1px solid ${INK.border}; border-radius: 10px; }
  .promo-eyebrow { font: 600 12px/1 ${MONO}; letter-spacing: 0.08em; text-transform: uppercase; color: ${INK.teal}; margin: 0 0 8px; }
  .promo h2 { margin: 0 0 8px; font: 600 22px/1.25 ${SERIF}; color: ${INK.text}; }
  .promo p { margin: 0 0 14px; color: ${INK.dim}; font-size: 15px; }
  .install-row { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
  .copy-cmd { display: inline-flex; align-items: center; gap: 10px; font: 500 13px/1.2 ${MONO}; color: ${INK.text}; background: #070d14; border: 1px solid ${INK.border}; border-radius: 7px; padding: 10px 14px; cursor: pointer; }
  .copy-cmd span.hint { color: ${INK.teal}; font-weight: 600; }
  .links { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 12px; font: 500 13px/1 ${MONO}; }
  a { color: ${INK.tealBright}; text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>
</head>
<body>
<main class="${initialLayout === 'wide' ? 'wide' : ''}">
  <div class="toolbar">
    <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;">
      <div class="seg" role="group" aria-label="Card layout">
        <button type="button" data-layout="portrait" aria-pressed="${initialLayout === 'portrait'}">Portrait 4:5</button>
        <button type="button" data-layout="wide" aria-pressed="${initialLayout === 'wide'}">Wide 16:9</button>
      </div>
      ${zoomAvailable ? `<div class="seg" role="group" aria-label="Time range">
        <button type="button" data-window="active" aria-pressed="${initialWindow === 'active'}">Active window</button>
        <button type="button" data-window="year" aria-pressed="${initialWindow === 'year'}">Full year</button>
      </div>` : ''}
    </div>
    <div class="toggles">
      ${hasProjects ? `<label><input id="toggle-projects" type="checkbox"${initialProjects ? ' checked' : ''}> Top projects</label>` : ''}
      ${hasApiValue ? `<label><input id="toggle-api" type="checkbox"${initialApiValue ? ' checked' : ''}> API value</label>` : ''}
    </div>
  </div>

  <div id="stage" class="${initialLayout === 'wide' ? 'wide' : ''}">
${svg}
  </div>

  <div class="actions">
    <button id="save" type="button" class="btn">Save image</button>
    <button id="copy" type="button" class="btn quiet" hidden>Copy image</button>
    <a id="post-x" class="btn quiet" href="${svgEscape(xIntentHref)}" target="_blank" rel="noopener noreferrer">Post on X</a>
    <button id="copy-caption" type="button" class="btn quiet">Copy caption</button>
    <span id="status" role="status"></span>
  </div>
  <p class="note">This page is a local file on your computer. Saving, copying, or toggling options uploads nothing.</p>

  ${claudeLate ? `<div class="tip"><strong>Claude Code deletes session logs after 30 days.</strong> Add <code>"cleanupPeriodDays": 3650</code> to <code>~/.claude/settings.json</code> to keep next year's logs—or install LokalBot to archive your coding-agent history locally alongside your meetings.</div>` : ''}

  <section class="promo">
    <div class="promo-eyebrow">Built by LokalBot · Free &amp; Open Source (GPLv3)</div>
    <h2>Give Claude Code &amp; Codex memory of your meetings.</h2>
    <p>LokalBot records calls on your computer with no meeting bot, runs transcription and summaries locally, and lets Claude Code and Codex search what was decided over read-only MCP. macOS, Windows &amp; Linux.</p>
    <div class="install-row">
      <button id="copy-brew" type="button" class="copy-cmd"><span>brew install --cask stevyhacker/tap/lokalbot</span><span class="hint">Copy</span></button>
    </div>
    <div class="links">
      <a href="https://www.lokalbot.com/" target="_blank" rel="noopener noreferrer">lokalbot.com</a>
      <a href="https://github.com/stevyhacker/LokalBot" target="_blank" rel="noopener noreferrer">GitHub repository</a>
      <a href="https://github.com/stevyhacker/LokalBot/releases/latest" target="_blank" rel="noopener noreferrer">Download for Mac, Windows &amp; Linux</a>
    </div>
  </section>
</main>

<script id="wrapped-data" type="application/json">${serializePayload(data, { includeProjects: initialProjects })}</script>
<script>
(() => {
${RENDERER_SOURCE}

  const raw = JSON.parse(document.getElementById('wrapped-data').textContent);
  const grid = new Float64Array(raw.days * 24);
  for (const [index, ms] of raw.gridCells) grid[index] = ms;
  const earlierDays = raw.earlierCells.length > 0 ? new Float64Array(raw.days) : null;
  if (earlierDays) {
    for (const [day, count] of raw.earlierCells) earlierDays[day] = count;
  }
  const data = {
    year: raw.year,
    days: raw.days,
    months: raw.months,
    stats: raw.stats,
    grid,
    earlierDays,
  };

  const state = {
    layout: ${JSON.stringify(initialLayout)},
    window: ${JSON.stringify(initialWindow)},
    showProjects: ${JSON.stringify(initialProjects)},
    showApiValue: ${JSON.stringify(initialApiValue)},
  };

  const main = document.querySelector('main');
  const stage = document.getElementById('stage');
  const status = document.getElementById('status');
  const save = document.getElementById('save');
  const copy = document.getElementById('copy');
  const postX = document.getElementById('post-x');
  const copyCaption = document.getElementById('copy-caption');
  const copyBrew = document.getElementById('copy-brew');
  const toggleProjects = document.getElementById('toggle-projects');
  const toggleApi = document.getElementById('toggle-api');
  const defaultFileName = ${JSON.stringify(defaultFile)};
  const baseName = ${JSON.stringify(baseName)};
  const scale = 2;

  function update() {
    main.classList.toggle('wide', state.layout === 'wide');
    stage.classList.toggle('wide', state.layout === 'wide');
    stage.innerHTML = renderCardSvg(data, state);
    for (const btn of document.querySelectorAll('[data-layout]')) {
      btn.setAttribute('aria-pressed', String(btn.dataset.layout === state.layout));
    }
    for (const btn of document.querySelectorAll('[data-window]')) {
      btn.setAttribute('aria-pressed', String(btn.dataset.window === state.window));
    }
    const caption = cardShareCaption(data.stats, { showApiValue: state.showApiValue });
    postX.href = 'https://x.com/intent/tweet?text=' + encodeURIComponent(caption);
  }

  for (const btn of document.querySelectorAll('[data-layout]')) {
    btn.addEventListener('click', () => {
      state.layout = btn.dataset.layout;
      update();
      status.textContent = '';
    });
  }
  for (const btn of document.querySelectorAll('[data-window]')) {
    btn.addEventListener('click', () => {
      state.window = btn.dataset.window;
      update();
      status.textContent = '';
    });
  }
  if (toggleProjects) {
    toggleProjects.addEventListener('change', () => {
      state.showProjects = toggleProjects.checked;
      update();
    });
  }
  if (toggleApi) {
    toggleApi.addEventListener('change', () => {
      state.showApiValue = toggleApi.checked;
      update();
    });
  }

  async function png() {
    const svg = stage.querySelector('svg');
    const dims = cardDimensions(state.layout);
    const xml = new XMLSerializer().serializeToString(svg);
    const objectUrl = URL.createObjectURL(new Blob([xml], { type: 'image/svg+xml' }));
    try {
      const image = new Image();
      await new Promise((resolve, reject) => {
        image.onload = resolve;
        image.onerror = reject;
        image.src = objectUrl;
      });
      const canvas = document.createElement('canvas');
      canvas.width = dims.width * scale;
      canvas.height = dims.height * scale;
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      return await new Promise((resolve, reject) => {
        canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('no image'))), 'image/png');
      });
    } finally {
      URL.revokeObjectURL(objectUrl);
    }
  }

  save.addEventListener('click', async () => {
    try {
      const link = document.createElement('a');
      link.href = URL.createObjectURL(await png());
      link.download = state.layout === 'wide' ? baseName + '-wide.png' : defaultFileName;
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
        status.textContent = 'Image copied — paste it into X, Slack, or LinkedIn.';
      } catch {
        status.textContent = 'The image could not be copied here. Save it instead.';
      }
    });
  }

  copyCaption.addEventListener('click', async () => {
    const caption = cardShareCaption(data.stats, { showApiValue: state.showApiValue });
    try {
      await navigator.clipboard.writeText(caption);
      status.textContent = 'Caption copied.';
    } catch {
      status.textContent = 'Could not copy caption.';
    }
  });

  copyBrew.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText('brew install --cask stevyhacker/tap/lokalbot');
      copyBrew.querySelector('.hint').textContent = 'Copied';
      setTimeout(() => { copyBrew.querySelector('.hint').textContent = 'Copy'; }, 2000);
    } catch {
      // Ignore clipboard error on restricted browser contexts.
    }
  });
})();
</script>
</body>
</html>
`;
}
