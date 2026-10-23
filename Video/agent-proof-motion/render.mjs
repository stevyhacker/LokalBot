import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const root = process.cwd();
const types = { '.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript', '.css':'text/css', '.json':'application/json', '.png':'image/png' };
const server = http.createServer((req,res)=>{
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(root, url === '/' ? 'index.html' : url);
  if (!file.startsWith(root)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err,data)=>{
    if (err) { res.writeHead(404); return res.end('missing'); }
    res.writeHead(200, {'content-type': types[path.extname(file)] || 'application/octet-stream'});
    res.end(data);
  });
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const port = server.address().port;
const frames = path.join(root,'frames');
fs.mkdirSync(frames,{recursive:true});

const browser = await chromium.launch({ channel:'chrome', headless:true, args:['--use-angle=metal','--ignore-gpu-blocklist','--enable-webgl'] });
const page = await browser.newPage({ viewport:{width:1920,height:1080}, deviceScaleFactor:1 });
page.on('console', m=>{ if (m.type()==='error') console.log('PAGE', m.text()); });
page.on('pageerror', e=>console.log('PAGEERR', e.message));
await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil:'networkidle' });
await page.waitForFunction('window.ready === true', null, { timeout: 30000 });

const fps = 30, seconds = 12, total = fps*seconds;
for (let f=0; f<total; f++) {
  await page.evaluate(t => window.renderAt(t), f/fps);
  await page.screenshot({ path: path.join(frames, String(f).padStart(4,'0')+'.png') });
  if (f % 60 === 0) console.log('frame', f);
}
await browser.close();
server.close();
console.log('done', total);
