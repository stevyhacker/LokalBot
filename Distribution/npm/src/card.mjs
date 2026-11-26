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

const SANS = `-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Inter', 'Segoe UI', system-ui, sans-serif`;
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

function resolvePlatform(platform = process.platform) {
  if (platform === 'darwin') return 'darwin';
  if (platform === 'win32') return 'win32';
  return 'linux';
}

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

export function renderCard(result, options = {}) {
  return renderCardSvg(cardData(result), {
    layout: options.layout ?? 'portrait',
    theme: options.theme === 'light' ? 'light' : 'dark',
    showProjects: Boolean(options.showProjects),
    showApiValue: options.showApiValue !== false,
    window: options.window ?? 'auto',
  });
}

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

export function renderPage(result, options = {}) {
  const data = cardData(result);
  const { stats } = data;
  const initialLayout = options.layout === 'wide' ? 'wide' : 'portrait';
  const initialTheme = options.theme === 'light' ? 'light' : 'dark';
  const initialProjects = Boolean(options.showProjects);
  const initialApiValue = options.showApiValue !== false;
  const initialWindow = options.window ?? defaultWindowMode(stats);
  const initialPlatform = resolvePlatform(options.platform);
  const initialAgentTab = stats.agents[0]?.id === 'codex' ? 'codex' : 'claude-code';
  const zoomAvailable = canZoomWindow(stats);
  const hasProjects = initialProjects && stats.projects.length > 0;
  const hasApiValue = (stats.totals.estimatedApiUsd ?? 0) >= 10;

  const svg = renderCardSvg(data, {
    layout: initialLayout,
    theme: initialTheme,
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

  const brewCmd = 'brew install --cask stevyhacker/tap/lokalbot';
  const scoopCmd = 'scoop bucket add lokalbot https://github.com/stevyhacker/scoop-bucket && scoop install lokalbot/lokalbot';
  const debCmd = 'sudo apt install ./LokalBot-*-linux-amd64.deb';
  const rpmCmd = 'sudo dnf install ./LokalBot-*-linux-x86_64.rpm';
  const claudePluginCmd = '/plugin marketplace add stevyhacker/lokalbot\n/plugin install lokalbot@lokalbot';
  const claudeMcpCmd = 'claude mcp add lokalbot -- lokalbot-cli mcp';
  const codexPluginCmd = 'codex plugin marketplace add stevyhacker/lokalbot --sparse .agents/plugins --sparse Distribution/openai-plugin\ncodex plugin add lokalbot@lokalbot';
  const codexMcpCmd = 'codex mcp add lokalbot -- lokalbot-cli mcp';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent Wrapped ${stats.year}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: ${INK.ground}; color: ${INK.text}; font: 15px/1.55 ${SANS}; }
  main { max-width: 620px; margin: 0 auto; padding: 28px 18px 56px; }
  main.wide { max-width: 880px; }
  .toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
  .seg { display: inline-flex; background: ${INK.surface}; border: 1px solid ${INK.border}; border-radius: 10px; padding: 3px; gap: 2px; }
  .seg button { font: 600 13px/1 ${MONO}; color: ${INK.dim}; background: transparent; border: 0; border-radius: 7px; padding: 8px 12px; cursor: pointer; }
  .seg button[aria-pressed="true"] { color: #04141a; background: ${INK.teal}; }
  .toggles { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; font: 500 13px/1 ${MONO}; color: ${INK.dim}; }
  .toggles label { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; }
  .toggles input { accent-color: ${INK.teal}; width: 15px; height: 15px; cursor: pointer; }
  #stage { display: flex; justify-content: center; }
  #stage svg { display: block; width: 100%; height: auto; border-radius: 14px; border: 1px solid ${INK.border}; }
  .actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-top: 18px; }
  .btn { display: inline-flex; align-items: center; gap: 6px; font: 600 14px/1 ${MONO}; color: #04141a; background: ${INK.teal}; border: 0; border-radius: 9px; padding: 12px 16px; cursor: pointer; text-decoration: none; }
  .btn.quiet { color: ${INK.text}; background: #14202d; border: 1px solid ${INK.border}; }
  .btn:focus-visible, .seg button:focus-visible, .copy-cmd:focus-visible { outline: 2px solid ${INK.tealBright}; outline-offset: 2px; }
  .btn[hidden], [hidden] { display: none !important; }
  #status { color: ${INK.tealBright}; font: 500 14px/1.4 ${SANS}; margin-left: 4px; }
  .note { color: ${INK.faint}; font-size: 14px; margin: 14px 0 0; }
  .tip { margin-top: 22px; padding: 14px 16px; background: #12171f; border: 1px solid #352b14; border-left: 3px solid ${INK.amber}; border-radius: 10px; color: ${INK.dim}; font-size: 14px; }
  .tip strong { color: ${INK.amber}; font-weight: 600; }
  .tip code, .install-note code { font: 500 12.5px/1.4 ${MONO}; color: ${INK.text}; background: #0a1017; padding: 2px 6px; border-radius: 4px; }
  .promo { margin-top: 24px; padding: 20px 22px; background: ${INK.surface}; border: 1px solid ${INK.border}; border-radius: 12px; }
  .promo-eyebrow { font: 700 12px/1 ${MONO}; letter-spacing: 0.08em; text-transform: uppercase; color: ${INK.teal}; margin: 0 0 8px; }
  .promo h2 { margin: 0 0 8px; font: 700 21px/1.25 ${SANS}; letter-spacing: -0.02em; color: ${INK.text}; }
  .promo p { margin: 0 0 14px; color: ${INK.dim}; font-size: 15px; }
  .promo-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; margin: 14px 0 10px; }
  .promo-label { font: 700 12px/1 ${MONO}; letter-spacing: 0.06em; text-transform: uppercase; color: ${INK.faint}; }
  .install-stack { display: flex; flex-direction: column; gap: 8px; }
  .copy-cmd { display: flex; align-items: center; justify-content: space-between; gap: 12px; width: 100%; text-align: left; font: 500 13px/1.35 ${MONO}; color: ${INK.text}; background: #070d14; border: 1px solid ${INK.border}; border-radius: 8px; padding: 10px 14px; cursor: pointer; }
  .copy-cmd-text { display: flex; align-items: baseline; gap: 10px; min-width: 0; overflow-wrap: anywhere; }
  .cmd-tag { flex: 0 0 auto; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; color: ${INK.tealBright}; background: #0e1d24; border: 1px solid #1f4a4f; border-radius: 5px; padding: 2px 6px; }
  .copy-cmd span.hint { flex: 0 0 auto; color: ${INK.teal}; font-weight: 600; }
  .install-note { margin: 10px 0 0 !important; font-size: 13px !important; color: ${INK.faint} !important; line-height: 1.5; }
  .bridge-box { margin-top: 18px; padding-top: 16px; border-top: 1px solid ${INK.border}; }
  .links { display: flex; flex-wrap: wrap; gap: 16px; margin-top: 16px; padding-top: 14px; border-top: 1px solid ${INK.border}; font: 500 13px/1.4 ${MONO}; }
  a { color: ${INK.tealBright}; text-decoration: none; }
  a:hover { text-decoration: underline; }
  body.light { background: #eef3f3; color: #0b1219; }
  body.light .seg { background: #ffffff; border-color: #d5e0e2; }
  body.light .seg button { color: #3b4b56; }
  body.light .seg button[aria-pressed="true"] { color: #ffffff; background: #0b7a6e; }
  body.light .toggles { color: #3b4b56; }
  body.light .toggles input { accent-color: #0b7a6e; }
  body.light #stage svg { border-color: #d5e0e2; }
  body.light .btn { color: #ffffff; background: #0b7a6e; }
  body.light .btn.quiet { color: #0b1219; background: #ffffff; border-color: #d5e0e2; }
  body.light #status { color: #075f55; }
  body.light .note { color: #5f7280; }
  body.light .tip { background: #fffbf2; border-color: #ecd6a5; border-left-color: #d97706; color: #3b4b56; }
  body.light .tip strong { color: #9a4a00; }
  body.light .tip code, body.light .install-note code { color: #0b1219; background: #e8efef; }
  body.light .promo { background: #ffffff; border-color: #d5e0e2; }
  body.light .promo-eyebrow { color: #0b7a6e; }
  body.light .promo h2 { color: #0b1219; }
  body.light .promo p { color: #3b4b56; }
  body.light .promo-label, body.light .install-note { color: #5f7280 !important; }
  body.light .bridge-box, body.light .links { border-color: #d5e0e2; }
  body.light .copy-cmd { color: #f1f6f9; background: #0e1720; border-color: #0e1720; }
  body.light a { color: #075f55; }
</style>
</head>
<body class="${initialTheme === 'light' ? 'light' : ''}">
<main class="${initialLayout === 'wide' ? 'wide' : ''}">
  <div class="toolbar">
    <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;">
      <div class="seg" role="group" aria-label="Card layout">
        <button type="button" data-layout="portrait" aria-pressed="${initialLayout === 'portrait'}">Portrait 4:5</button>
        <button type="button" data-layout="wide" aria-pressed="${initialLayout === 'wide'}">Wide 16:9</button>
      </div>
      <div class="seg" role="group" aria-label="Color theme">
        <button type="button" data-theme="dark" aria-pressed="${initialTheme === 'dark'}">Dark</button>
        <button type="button" data-theme="light" aria-pressed="${initialTheme === 'light'}">Light</button>
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

  ${claudeLate ? `<div class="tip"><strong>Claude Code deletes session logs after 30 days.</strong> Add <code>"cleanupPeriodDays": 3650</code> to <code>~/.claude/settings.json</code> to keep next year's logs, or install LokalBot to archive your coding-agent history locally alongside your meetings.</div>` : ''}

  <section class="promo">
    <div class="promo-eyebrow">Built by LokalBot · Free &amp; Open Source (GPLv3)</div>
    <h2>Give Claude Code &amp; Codex memory of your meetings.</h2>
    <p>LokalBot records calls on your computer with no meeting bot, runs transcription and summaries locally, and lets Claude Code and Codex search what was decided over read-only MCP. macOS, Windows &amp; Linux.</p>

    <div class="promo-head">
      <span class="promo-label">1. Install LokalBot</span>
      <div class="seg" role="group" aria-label="Install LokalBot by operating system">
        <button type="button" data-os="darwin" aria-pressed="${initialPlatform === 'darwin'}">macOS</button>
        <button type="button" data-os="win32" aria-pressed="${initialPlatform === 'win32'}">Windows</button>
        <button type="button" data-os="linux" aria-pressed="${initialPlatform === 'linux'}">Linux</button>
      </div>
    </div>

    <div data-os-panel="darwin"${initialPlatform === 'darwin' ? '' : ' hidden'}>
      <div class="install-stack">
        <button id="copy-brew" type="button" class="copy-cmd" data-copy-cmd="${svgEscape(brewCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">Homebrew</span><span>${svgEscape(brewCmd)}</span></span><span class="hint">Copy</span></button>
      </div>
      <p class="install-note">Apple Silicon, macOS 15+. Or download the notarized <code>.dmg</code> from <a href="https://github.com/stevyhacker/LokalBot/releases/latest" target="_blank" rel="noopener noreferrer">GitHub Releases</a>.</p>
    </div>

    <div data-os-panel="win32"${initialPlatform === 'win32' ? '' : ' hidden'}>
      <div class="install-stack">
        <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(scoopCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">Scoop</span><span>${svgEscape(scoopCmd)}</span></span><span class="hint">Copy</span></button>
      </div>
      <p class="install-note">Windows 10 or 11 (x64, alpha). Or download the per-user <code>.exe</code> installer from <a href="https://github.com/stevyhacker/LokalBot/releases/latest" target="_blank" rel="noopener noreferrer">GitHub Releases</a>.</p>
    </div>

    <div data-os-panel="linux"${initialPlatform === 'linux' ? '' : ' hidden'}>
      <div class="install-stack">
        <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(debCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">.deb</span><span>${svgEscape(debCmd)}</span></span><span class="hint">Copy</span></button>
        <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(rpmCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">.rpm</span><span>${svgEscape(rpmCmd)}</span></span><span class="hint">Copy</span></button>
      </div>
      <p class="install-note">Download the <code>.deb</code> or <code>.rpm</code> from <a href="https://github.com/stevyhacker/LokalBot/releases/latest" target="_blank" rel="noopener noreferrer">GitHub Releases</a>. Both add <code>pkg.lokalbot.com</code> so <code>apt upgrade</code> and <code>dnf upgrade</code> keep LokalBot updated. Arch package and <code>.tar.gz</code> archive are in the same release.</p>
    </div>

    <div class="bridge-box">
      <div class="promo-head" style="margin-top:0;">
        <span class="promo-label">2. Connect your coding agent</span>
        <div class="seg" role="group" aria-label="Coding agent integration">
          <button type="button" data-agent-tab="claude-code" aria-pressed="${initialAgentTab === 'claude-code'}">Claude Code</button>
          <button type="button" data-agent-tab="codex" aria-pressed="${initialAgentTab === 'codex'}">Codex</button>
        </div>
      </div>

      <div data-agent-panel="claude-code"${initialAgentTab === 'claude-code' ? '' : ' hidden'}>
        <div class="install-stack">
          <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(claudePluginCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">Plugin</span><span>/plugin marketplace add stevyhacker/lokalbot<br>/plugin install lokalbot@lokalbot</span></span><span class="hint">Copy</span></button>
          <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(claudeMcpCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">MCP</span><span>${svgEscape(claudeMcpCmd)}</span></span><span class="hint">Copy</span></button>
        </div>
      </div>

      <div data-agent-panel="codex"${initialAgentTab === 'codex' ? '' : ' hidden'}>
        <div class="install-stack">
          <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(codexPluginCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">Plugin</span><span>codex plugin marketplace add stevyhacker/lokalbot --sparse .agents/plugins --sparse Distribution/openai-plugin<br>codex plugin add lokalbot@lokalbot</span></span><span class="hint">Copy</span></button>
          <button type="button" class="copy-cmd" data-copy-cmd="${svgEscape(codexMcpCmd)}"><span class="copy-cmd-text"><span class="cmd-tag">MCP</span><span>${svgEscape(codexMcpCmd)}</span></span><span class="hint">Copy</span></button>
        </div>
      </div>
    </div>

    <div class="links">
      <a href="https://www.lokalbot.com/wrapped" target="_blank" rel="noopener noreferrer">lokalbot.com/wrapped</a>
      <a href="https://www.lokalbot.com/claude-code-codex-plugins" target="_blank" rel="noopener noreferrer">Plugins &amp; MCP guide</a>
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
    theme: ${JSON.stringify(initialTheme)},
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
  const toggleProjects = document.getElementById('toggle-projects');
  const toggleApi = document.getElementById('toggle-api');
  const defaultFileName = ${JSON.stringify(defaultFile)};
  const baseName = ${JSON.stringify(baseName)};
  const scale = 2;

  function update() {
    document.body.classList.toggle('light', state.theme === 'light');
    main.classList.toggle('wide', state.layout === 'wide');
    stage.classList.toggle('wide', state.layout === 'wide');
    stage.innerHTML = renderCardSvg(data, state);
    for (const btn of document.querySelectorAll('[data-layout]')) {
      btn.setAttribute('aria-pressed', String(btn.dataset.layout === state.layout));
    }
    for (const btn of document.querySelectorAll('[data-theme]')) {
      btn.setAttribute('aria-pressed', String(btn.dataset.theme === state.theme));
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
  for (const btn of document.querySelectorAll('[data-theme]')) {
    btn.addEventListener('click', () => {
      state.theme = btn.dataset.theme;
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

  for (const btn of document.querySelectorAll('[data-os]')) {
    btn.addEventListener('click', () => {
      const target = btn.dataset.os;
      for (const tab of document.querySelectorAll('[data-os]')) {
        tab.setAttribute('aria-pressed', String(tab.dataset.os === target));
      }
      for (const panel of document.querySelectorAll('[data-os-panel]')) {
        panel.hidden = panel.dataset.osPanel !== target;
      }
    });
  }

  for (const btn of document.querySelectorAll('[data-agent-tab]')) {
    btn.addEventListener('click', () => {
      const target = btn.dataset.agentTab;
      for (const tab of document.querySelectorAll('[data-agent-tab]')) {
        tab.setAttribute('aria-pressed', String(tab.dataset.agentTab === target));
      }
      for (const panel of document.querySelectorAll('[data-agent-panel]')) {
        panel.hidden = panel.dataset.agentPanel !== target;
      }
    });
  }

  for (const btn of document.querySelectorAll('[data-copy-cmd]')) {
    btn.addEventListener('click', async () => {
      const cmd = btn.getAttribute('data-copy-cmd');
      const hint = btn.querySelector('.hint');
      try {
        await navigator.clipboard.writeText(cmd);
        if (hint) {
          hint.textContent = 'Copied';
          setTimeout(() => { hint.textContent = 'Copy'; }, 2000);
        }
      } catch {
      }
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
      const suffix = (state.layout === 'wide' ? '-wide' : '') + (state.theme === 'light' ? '-light' : '');
      link.download = suffix ? baseName + suffix + '.png' : defaultFileName;
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
        status.textContent = 'Image copied. Paste it into X, Slack, or LinkedIn.';
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
})();
</script>
</body>
</html>
`;
}
