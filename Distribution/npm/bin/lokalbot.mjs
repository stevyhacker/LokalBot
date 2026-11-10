#!/usr/bin/env node
// `npx lokalbot wrapped`: your year with Claude Code and Codex, counted from
// the session logs on this computer. Nothing is sent anywhere.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

import { renderPage } from '../src/card.mjs';
import { demoYear } from '../src/demo.mjs';
import { renderTerminal } from '../src/terminal.mjs';
import { defaultYear, wrapped } from '../src/wrapped.mjs';

const REPOSITORY = 'https://github.com/stevyhacker/LokalBot';

const HELP = `lokalbot wrapped: your year with Claude Code and Codex

Usage
  npx lokalbot wrapped [options]

Options
  --year <year>       The year to count. Default: this year (last year in January).
  --share             Also make the image: writes a page and opens it in your browser,
                      where you can save or copy the picture.
  --out <file>        Where --share writes the page. Default: your temporary folder.
  --no-open           With --share, write the page without opening it.
  --projects          Name your three busiest projects on the image. The terminal
                      always shows them; the image leaves them out unless you ask.
  --json              Print the figures as JSON instead of the card.
  --claude-dir <dir>  Read Claude Code projects from here instead of ~/.claude/projects.
  --codex-dir <dir>   Read Codex from here instead of ~/.codex.
  --demo              Show a made-up year, without reading any logs.
  --no-color          Plain text.
  -h, --help          This text.
  -v, --version       The version.

What it reads
  Claude Code and Codex keep a log of every session on this computer. This
  command reads those files, counts, and prints. It makes no network requests,
  and it never keeps what you or the agents wrote, only how much and when.

LokalBot is a desktop app that shows each day's agent work on a timeline,
next to your meetings: ${REPOSITORY}
`;

main().catch((error) => {
  process.stderr.write(`lokalbot: ${error?.message ?? error}\n`);
  process.exitCode = 1;
});

async function main() {
  let parsed;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: {
        year: { type: 'string' },
        share: { type: 'boolean', default: false },
        out: { type: 'string' },
        'no-open': { type: 'boolean', default: false },
        projects: { type: 'boolean', default: false },
        json: { type: 'boolean', default: false },
        'claude-dir': { type: 'string' },
        'codex-dir': { type: 'string' },
        demo: { type: 'boolean', default: false },
        'no-color': { type: 'boolean', default: false },
        help: { type: 'boolean', short: 'h', default: false },
        version: { type: 'boolean', short: 'v', default: false },
      },
    });
  } catch (error) {
    process.stderr.write(`lokalbot: ${error.message}\n\n${HELP}`);
    process.exitCode = 2;
    return;
  }
  const { values, positionals } = parsed;
  if (values.version) {
    process.stdout.write(`${version()}\n`);
    return;
  }
  const command = positionals[0];
  if (values.help || command === undefined || command === 'help') {
    process.stdout.write(HELP);
    return;
  }
  if (command !== 'wrapped') {
    process.stderr.write(
      `lokalbot: "${command}" is not a command here. This package has one: wrapped.\n`
      + `For LokalBot's own CLI, install the app: ${REPOSITORY}\n`);
    process.exitCode = 2;
    return;
  }

  const year = values.year === undefined ? defaultYear() : Number(values.year);
  if (!Number.isInteger(year) || year < 2020 || year > 2100) {
    process.stderr.write(`lokalbot: --year takes a year such as ${defaultYear()}.\n`);
    process.exitCode = 2;
    return;
  }

  const progress = progressLine(process.stderr.isTTY && !values.json);
  const result = values.demo
    ? demoYear(year)
    : wrapped({
      year,
      claudeDirs: values['claude-dir'] ? [values['claude-dir']] : undefined,
      codexDir: values['codex-dir'],
      onProgress: progress.update,
    });
  progress.clear();
  const { stats } = result;

  if (values.json) {
    process.stdout.write(`${JSON.stringify(stats, null, 2)}\n`);
    return;
  }
  if (stats.totals.sessions === 0 && stats.totals.tokens.total === 0) {
    const looked = [...(stats.sources.claude ?? []), stats.sources.codex].filter(Boolean);
    process.stderr.write(
      `No Claude Code or Codex sessions from ${year} were found on this computer.\n`
      + `Looked in:\n${looked.map((folder) => `  ${folder}`).join('\n')}\n`
      + 'Pass --year for another year, or --claude-dir and --codex-dir if your logs live elsewhere.\n');
    process.exitCode = 1;
    return;
  }

  const color = !values['no-color'] && process.stdout.isTTY && !('NO_COLOR' in process.env) && process.env.TERM !== 'dumb';
  process.stdout.write(`${renderTerminal(result, { color })}\n`);

  if (values.share) {
    const file = path.resolve(values.out ?? path.join(os.tmpdir(), `agent-wrapped-${year}.html`));
    fs.writeFileSync(file, renderPage(result, { showProjects: values.projects }));
    process.stdout.write(`\n  Your image is on this page: ${pathToFileURL(file).href}\n`);
    if (!values['no-open']) open(file);
  } else {
    process.stdout.write('  Make the image to share: npx lokalbot wrapped --share\n');
  }
  process.stdout.write(`  From LokalBot, which shows each day's agent work next to your meetings: ${REPOSITORY}\n\n`);
}

/** One line on stderr that says how far the reading has got. */
function progressLine(enabled) {
  let shown = false;
  let last = 0;
  return {
    update(agent, done, total) {
      if (!enabled || total === 0) return;
      const now = Date.now();
      if (done < total && now - last < 120) return;
      last = now;
      shown = true;
      process.stderr.write(`\r\x1b[2K  Reading ${agent} sessions: ${done} of ${total}`);
    },
    clear() {
      if (shown) process.stderr.write('\r\x1b[2K');
    },
  };
}

function open(file) {
  const [command, args] = process.platform === 'darwin'
    ? ['open', [file]]
    : process.platform === 'win32'
      ? ['cmd', ['/c', 'start', '', file]]
      : ['xdg-open', [file]];
  try {
    const child = spawn(command, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {});
    child.unref();
  } catch {
    // The path is printed above; opening it is a convenience.
  }
}

function version() {
  const manifest = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'package.json');
  return JSON.parse(fs.readFileSync(manifest, 'utf8')).version;
}
