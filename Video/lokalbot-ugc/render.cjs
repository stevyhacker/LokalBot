// Renders comp.html frame by frame with headless Chromium.
//
//   node render.cjs frames <out-dir> [--from s] [--to s] [--workers n]
//   node render.cjs stills <out-dir> t1 t2 ...
//
// Each frame calls window.__seek(t) and screenshots the stage, so the result
// is the same however long a frame takes. The page is 1080 × 1920.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT || 'playwright');

const ROOT = __dirname;
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.css': 'text/css',
  '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.png': 'image/png' };

function serve() {
  return new Promise(resolve => {
    const server = http.createServer((req, res) => {
      const file = path.join(ROOT, decodeURIComponent(new URL(req.url, 'http://x').pathname));
      if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
      fs.createReadStream(file).pipe(res);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

async function page(browser, port) {
  const p = await browser.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: 1 });
  p.on('pageerror', e => console.error('page error:', e.message));
  p.on('console', m => { if (m.type() === 'error') console.error('console:', m.text()); });
  await p.goto(`http://127.0.0.1:${port}/comp.html`);
  await p.waitForFunction(() => window.__ready === true, null, { timeout: 120000 });
  return p;
}

async function main() {
  const [mode, out, ...rest] = process.argv.slice(2);
  const opt = (name, fallback) => { const i = rest.indexOf('--' + name); return i >= 0 ? Number(rest[i + 1]) : fallback; };
  const server = await serve();
  const port = server.address().port;
  const browser = await chromium.launch({ args: ['--force-color-profile=srgb'] });
  try {
    fs.mkdirSync(out, { recursive: true });
    if (mode === 'stills') {
      const p = await page(browser, port);
      for (const t of rest.map(Number)) {
        await p.evaluate(t => window.__seek(t), t);
        await p.screenshot({ path: path.join(out, `t${t.toFixed(2).padStart(5, '0')}.png`) });
        console.log('still', t);
      }
      return;
    }
    const probe = await page(browser, port);
    const fps = await probe.evaluate(() => window.__fps), duration = await probe.evaluate(() => window.__duration);
    await probe.close();
    const first = Math.round(opt('from', 0) * fps), last = Math.min(Math.round(opt('to', duration) * fps), Math.round(duration * fps)) - 1;
    const workers = opt('workers', 3);
    const started = Date.now();
    let done = 0;
    await Promise.all(Array.from({ length: workers }, async (_, w) => {
      const p = await page(browser, port);
      // Contiguous ranges keep each worker's footage cache warm.
      const span = Math.ceil((last - first + 1) / workers);
      for (let f = first + w * span; f <= Math.min(last, first + (w + 1) * span - 1); f++) {
        await p.evaluate(t => window.__seek(t), f / fps);
        await p.screenshot({ path: path.join(out, `${String(f + 1).padStart(5, '0')}.png`) });
        if (++done % 30 === 0) console.log(`${done}/${last - first + 1} frames, ${((Date.now() - started) / done).toFixed(0)} ms each`);
      }
    }));
  } finally {
    await browser.close();
    server.close();
  }
}
main().catch(e => { console.error(e); process.exit(1); });
