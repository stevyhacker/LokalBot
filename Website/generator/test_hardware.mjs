import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const hw = require(path.join(ROOT, 'Website', 'public', 'hardware.js'));

test('hardware calculator covers Mac, Windows, and Linux tiers cleanly', () => {
  const mac8 = hw.evaluateStack({ os: 'mac', ramGb: 8, profile: 'auto' });
  assert.equal(mac8.budgetGb, 4);
  assert.ok(['comfortable', 'lru'].includes(mac8.status), `expected comfortable/lru on 8 GB Mac, got ${mac8.status}`);
  assert.equal(mac8.rows.find((r) => r.roleKey === 'llm').model.id, 'qwen3.5-0.8b');
  assert.equal(mac8.rows.find((r) => r.roleKey === 'auto').model.id, 'lfm2.5-1.2b');

  const mac16 = hw.evaluateStack({ os: 'mac', ramGb: 16, profile: 'auto' });
  assert.equal(mac16.budgetGb, 8);
  assert.equal(mac16.status, 'lru');
  assert.equal(mac16.rows.find((r) => r.roleKey === 'stt').model.id, 'qwen3-asr-1.7b');
  assert.equal(mac16.rows.find((r) => r.roleKey === 'llm').model.id, 'qwen3.5-4b');
  assert.equal(mac16.rows.find((r) => r.roleKey === 'auto').model.id, 'gemma4-e2b-q6');

  const mac24 = hw.evaluateStack({ os: 'mac', ramGb: 24, profile: 'auto' });
  assert.equal(mac24.budgetGb, 12);
  assert.equal(mac24.status, 'comfortable');

  const mac48 = hw.evaluateStack({ os: 'mac', ramGb: 48, profile: 'quality' });
  assert.equal(mac48.rows.find((r) => r.roleKey === 'llm').model.id, 'qwen3.6-35b-a3b');
  assert.ok(['comfortable', 'lru'].includes(mac48.status));

  const bad16 = hw.evaluateStack({
    os: 'mac',
    ramGb: 16,
    profile: 'balanced',
    overrides: { llm: 'qwen3.6-35b-a3b' }
  });
  assert.equal(bad16.status, 'exceeds');

  const winGpu = hw.evaluateStack({ os: 'windows', ramGb: 16, vramGb: 8, profile: 'auto' });
  assert.equal(winGpu.gpuSummary.mode, 'full-vram');
  assert.equal(winGpu.rows.find((r) => r.roleKey === 'stt').model.id, 'qwen3-asr-0.6b');

  const linuxCpu = hw.evaluateStack({ os: 'linux', ramGb: 32, vramGb: 0, profile: 'auto' });
  assert.equal(linuxCpu.gpuSummary.mode, 'cpu');
  assert.equal(linuxCpu.status, 'comfortable');
});

test('URL state serialization and Markdown export round-trip cleanly', () => {
  const input = {
    os: 'windows',
    chip: 'x64',
    ramGb: 32,
    vramGb: 12,
    profile: 'quality',
    workloads: { stt: true, diar: true, llm: true, search: true, auto: true, files: true, tts: false },
    overrides: { llm: 'gemma4-12b' }
  };
  const qs = hw.serializeState(input);
  const parsed = hw.parseState(`?${qs}`);
  assert.deepEqual(parsed, input);

  const res = hw.evaluateStack(parsed);
  const md = hw.buildMarkdownReport(parsed, res);
  assert.match(md, /Windows x64 \(32 GB RAM, 12 GB VRAM\)/);
  assert.match(md, /Gemma 4 12B/);
  assert.match(md, /https:\/\/www\.lokalbot\.com\/hardware\?/);
});

test('every benchHash in hardware.js matches a real suite in benchmarks.json', () => {
  const bdata = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'Website', 'public', 'benchmarks.json'), 'utf8')
  );
  const suiteIds = new Set(bdata.categories.flatMap((c) => c.suites.map((s) => s.id)));
  for (const [role, list] of Object.entries(hw.MODELS)) {
    for (const model of list) {
      if (model.benchHash) {
        assert.ok(
          suiteIds.has(model.benchHash),
          `hardware.js ${role}/${model.id} references unknown benchmark suite #${model.benchHash}`
        );
      }
    }
  }
});

test('hardware.html SEO metadata, JSON-LD, OG image, and links are valid', () => {
  const html = fs.readFileSync(path.join(ROOT, 'Website', 'public', 'hardware.html'), 'utf8');
  assert.match(html, /<link rel="canonical" href="https:\/\/www\.lokalbot\.com\/hardware" \/>/);
  assert.match(html, /og-hardware\.png/);
  assert.ok(
    fs.existsSync(path.join(ROOT, 'Website', 'public', 'assets', 'og-hardware.png')),
    'Website/public/assets/og-hardware.png must exist'
  );
  const internalHtml = html.match(/href="(?:\/|https:\/\/www\.lokalbot\.com\/)[^"]*\.html(?:[#?][^"]*)?"/g);
  assert.equal(internalHtml, null, `Found .html internal links: ${internalHtml}`);

  const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  assert.ok(ldMatch, 'JSON-LD script block required');
  const graph = JSON.parse(ldMatch[1])['@graph'];
  const types = new Set(graph.map((n) => n['@type']));
  assert.ok(types.has('WebApplication'));
  assert.ok(types.has('BreadcrumbList'));
  assert.ok(types.has('FAQPage'));
});
