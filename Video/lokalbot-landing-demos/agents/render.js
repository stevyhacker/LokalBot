// Renders an asciinema cast to PNG frames with xterm.js in headless Chromium.
//   node render.js <cast> <outdir> <W> <H> <dark|light> [fps=30]
// Writes frames as %05d.png (one per distinct picture) and frames.txt, an ffmpeg concat list.
const fs = require('fs'), path = require('path');
const { chromium } = require('playwright');
const [cast, out, W, H, theme, fpsArg] = process.argv.slice(2);
const fps = +(fpsArg || 30);
const lines = fs.readFileSync(cast, 'utf8').trim().split('\n');
const header = JSON.parse(lines[0]);
const events = lines.slice(1).map(l => JSON.parse(l)).filter(e => e[1] === 'o');
const here = process.env.RENDER_ROOT || __dirname;
const palettes = {
  dark: { background: '#0b1119', foreground: '#e6edf3', cursor: '#6ef2dc', cursorAccent: '#0b1119',
    black: '#3b4652', red: '#ff7b72', green: '#6ef2dc', yellow: '#fbbf24', blue: '#79c0ff', magenta: '#d2a8ff', cyan: '#56d4dd', white: '#c9d4dd',
    brightBlack: '#8ba2b0', brightRed: '#ffa198', brightGreen: '#9cf7e6', brightYellow: '#fcd34d', brightBlue: '#a5d6ff', brightMagenta: '#e2c5ff', brightCyan: '#a5f3fc', brightWhite: '#ffffff' },
  light: { background: '#fbfcfc', foreground: '#1f2328', cursor: '#0c8275', cursorAccent: '#ffffff',
    black: '#1f2328', red: '#c62f2f', green: '#0c8275', yellow: '#a06a00', blue: '#1f62c9', magenta: '#8250df', cyan: '#0f7f8c', white: '#6e7781',
    brightBlack: '#6e7781', brightRed: '#d9534f', brightGreen: '#0f9b8a', brightYellow: '#b57f00', brightBlue: '#3a7bd5', brightMagenta: '#9a6ae3', brightCyan: '#1794a3', brightWhite: '#24292f' },
};
(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: +W, height: +H }, deviceScaleFactor: +(process.env.DPR || 2) });
  const css = fs.readFileSync(path.join(here, 'node_modules/@xterm/xterm/css/xterm.css'), 'utf8');
  const fontRegular = fs.readFileSync(path.join(here, 'node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2')).toString('base64');
  const fontBold = fs.readFileSync(path.join(here, 'node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-700-normal.woff2')).toString('base64');
  await page.setContent(`<!doctype html><html><head><style>${css}
    @font-face{font-family:JBM;src:url(data:font/woff2;base64,${fontRegular}) format('woff2');font-weight:400}
    @font-face{font-family:JBM;src:url(data:font/woff2;base64,${fontBold}) format('woff2');font-weight:700}
    html,body{margin:0;height:100%;background:${palettes[theme].background};overflow:hidden}
    #t{position:absolute;left:${process.env.PAD||32}px;top:${process.env.PADY||process.env.PAD||28}px}
    .xterm-viewport{overflow:hidden!important;background:transparent!important}
    .xterm-cursor-layer,.xterm .composition-view{display:block}
    </style></head><body><div id="t"></div></body></html>`);
  await page.addScriptTag({ path: path.join(here, 'node_modules/@xterm/xterm/lib/xterm.js') });
  await page.evaluate(async ({ cols, rows, theme, fontSize }) => {
    await document.fonts.load('400 14px JBM'); await document.fonts.load('700 14px JBM');
    const term = new window.Terminal({ cols, rows, fontFamily: 'JBM, "DejaVu Sans Mono", "Noto Sans Symbols 2", monospace', fontSize, lineHeight: 1.16, letterSpacing: 0, theme, allowProposedApi: true, cursorBlink: false, cursorStyle: 'block', scrollback: 0, customGlyphs: true, drawBoldTextInBrightColors: false });
    term.open(document.getElementById('t'));
    window.term = term;
    window.feed = d => new Promise(r => term.write(d, r));
  }, { cols: header.width, rows: header.height, theme: palettes[theme], fontSize: +(process.env.FONT || 15) });
  await page.waitForTimeout(200);
  // Time map: "t0:t1:speed,..." keeps ranges at a speed; anything outside is dropped.
  const segs = (process.env.SEGS || `0:${events[events.length - 1][0]}:1`).split(',').map(s => s.split(':').map(Number));
  const outTimes = [];
  let base = 0; for (const [a, b, v] of segs) { outTimes.push({ a, b, v, base }); base += (b - a) / v; }
  const total = base;
  const srcAt = t => { for (const s of outTimes) { const span = (s.b - s.a) / s.v; if (t <= s.base + span) return s.a + (t - s.base) * s.v; } return segs[segs.length - 1][1]; };
  let e = 0, n = 0, last = null;
  const list = [];
  const count = Math.round(total * fps);
  for (let f = 0; f < count; f++) {
    const src = srcAt(f / fps);
    let data = '';
    while (e < events.length && events[e][0] <= src) data += events[e++][2].split('\x1b[100m').join(theme === 'dark' ? '\x1b[48;2;26;38;52m' : '\x1b[48;2;232;238;240m');
    if (data) await page.evaluate(d => window.feed(d), data);
    if (data || !last) {
      n++; last = path.join(out, String(n).padStart(5, '0') + '.png');
      await page.screenshot({ path: last, scale: 'device' });
    }
    list.push(`file '${path.basename(last)}'\nduration ${(1 / fps).toFixed(6)}`);
  }
  list.push(`file '${path.basename(last)}'`);
  fs.writeFileSync(path.join(out, 'frames.txt'), list.join('\n') + '\n');
  console.log(`frames ${count}, distinct ${n}, seconds ${total.toFixed(2)}`);
  await browser.close();
})();
