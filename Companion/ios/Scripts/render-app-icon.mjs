#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..', '..');
const source = readFileSync(join(repo, 'Assets/lokalbot-icon.svg'), 'utf8');
const output = join(here, '..', 'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png');

const plate = /<rect x="64" y="64" width="896" height="896" rx="204" fill="url\(#bg\)"\/>/;
if (!plate.test(source)) throw new Error('The macOS plate in lokalbot-icon.svg changed; update this script.');

const [head, robot] = source.split(plate);
const scale = 1024 / 896;
const svg = head.replace('<svg ', '<svg ')
  + '<rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>\n'
  + `<g transform="translate(512 512) scale(${scale.toFixed(5)}) translate(-512 -512)">`
  + robot.replace('</svg>', '</g>\n</svg>');

const work = mkdtempSync(join(tmpdir(), 'lokalbot-icon-'));
try {
  const svgPath = join(work, 'icon.svg');
  const rendered = join(work, 'rendered.png');
  const flattened = join(work, 'flattened.jpg');
  writeFileSync(svgPath, svg);
  execFileSync('sips', ['-s', 'format', 'png', '-z', '1024', '1024', svgPath, '--out', rendered], { stdio: 'ignore' });
  execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '100', rendered, '--out', flattened], { stdio: 'ignore' });
  execFileSync('sips', ['-s', 'format', 'png', flattened, '--out', output], { stdio: 'ignore' });
  console.log(`wrote ${output.replace(repo + '/', '')}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
