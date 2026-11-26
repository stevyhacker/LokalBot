#!/usr/bin/env node

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
const WEBSITE = 'https://www.lokalbot.com';

const HELP = `lokalbot: Agent Wrapped: your year with coding agents, counted locally

Usage
  npx lokalbot [options]
  npx lokalbot wrapped [options]

Options
  --year <year>            The year to count. Default: this year (last year in January).
  --share                  Write the shareable image page and open it in your browser.
                           On by default in an interactive terminal; pass --no-share to skip.
  --no-share               Print the terminal card only, without opening the image page.
  --wide                   Open the shareable card in 16:9 wide layout (for X / LinkedIn).
  --light                  Open the shareable card in light mode.
  --out <file>             Where the share page is written. Default: your temporary folder.
  --no-open                Write the share page without opening your browser.
  --projects               Name your three busiest projects on the image. The terminal
                           always shows them; the image leaves them out unless you ask.
  --no-api-value           Leave the estimated API-rate value off the card.
  --json                   Print the figures as JSON instead of the card.
  --claude-dir <dir>       Read Claude Code projects from here instead of ~/.claude/projects.
  --codex-dir <dir>        Read Codex from here instead of ~/.codex.
  --cursor-dir <dir>       Read Cursor from here instead of ~/.cursor and Cursor globalStorage.
  --pi-dir <dir>           Read Pi sessions from here instead of ~/.pi/agent/sessions.
  --omp-dir <dir>          Read OMP sessions from here instead of ~/.omp/agent/sessions.
  --opencode-dir <dir>     Read OpenCode from here instead of ~/.local/share/opencode.
  --antigravity-dir <dir>  Read Antigravity transcripts from here instead of ~/.gemini/antigravity/brain.
  --gemini-dir <dir>       Read Gemini CLI sessions from here instead of ~/.gemini/tmp.
  --demo                   Show a made-up year, without reading any logs.
  --no-color               Plain text.
  -h, --help               This text.
  -v, --version            The version.

What it reads
  Reads local session logs from Claude Code, Codex, Cursor, Pi, OMP, OpenCode,
  Antigravity, and Gemini CLI on this computer. It makes no network requests,
  and it never keeps what you or the agents wrote, only how much and when.

LokalBot gives your coding agents local memory of your meetings (no bot,
free, GPLv3): ${WEBSITE} · ${REPOSITORY}
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
        'no-share': { type: 'boolean', default: false },
        wide: { type: 'boolean', default: false },
        light: { type: 'boolean', default: false },
        out: { type: 'string' },
        'no-open': { type: 'boolean', default: false },
        projects: { type: 'boolean', default: false },
        'no-api-value': { type: 'boolean', default: false },
        json: { type: 'boolean', default: false },
        'claude-dir': { type: 'string' },
        'codex-dir': { type: 'string' },
        'cursor-dir': { type: 'string' },
        'pi-dir': { type: 'string' },
        'omp-dir': { type: 'string' },
        'opencode-dir': { type: 'string' },
        'antigravity-dir': { type: 'string' },
        'gemini-dir': { type: 'string' },
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
  if (values.help || command === 'help') {
    process.stdout.write(HELP);
    return;
  }
  if (command !== undefined && command !== 'wrapped') {
    process.stderr.write(
      `lokalbot: "${command}" is not a command here. This package runs Agent Wrapped (npx lokalbot).\n`
      + `For LokalBot's desktop CLI and MCP server, install the app: ${REPOSITORY}\n`);
    process.exitCode = 2;
    return;
  }

  const year = values.year === undefined ? defaultYear() : Number(values.year);
  if (!Number.isInteger(year) || year < 2020 || year > 2100) {
    process.stderr.write(`lokalbot: --year takes a year such as ${defaultYear()}.\n`);
    process.exitCode = 2;
    return;
  }

  const customDirs = [
    values['claude-dir'],
    values['codex-dir'],
    values['cursor-dir'],
    values['pi-dir'],
    values['omp-dir'],
    values['opencode-dir'],
    values['antigravity-dir'],
    values['gemini-dir'],
  ].some(Boolean);
  const omit = customDirs ? null : undefined;

  const progress = progressLine(process.stderr.isTTY && !values.json);
  const result = values.demo
    ? demoYear(year)
    : await wrapped({
      year,
      claudeDirs: values['claude-dir'] ? [values['claude-dir']] : omit,
      codexDir: values['codex-dir'] ?? omit,
      cursorDir: values['cursor-dir'] ?? omit,
      piDir: values['pi-dir'] ?? omit,
      ompDir: values['omp-dir'] ?? omit,
      opencodeDir: values['opencode-dir'] ?? omit,
      antigravityDirs: values['antigravity-dir'] ? [values['antigravity-dir']] : omit,
      geminiDir: values['gemini-dir'] ?? omit,
      onProgress: progress.update,
    });
  progress.clear();
  const { stats } = result;

  if (values.json) {
    process.stdout.write(`${JSON.stringify(stats, null, 2)}\n`);
    return;
  }
  if (stats.totals.sessions === 0 && stats.totals.tokens.total === 0) {
    const looked = collectLookedPaths(stats.sources);
    process.stderr.write(
      `No coding-agent sessions from ${year} were found on this computer.\n`
      + `Looked in:\n${looked.map((folder) => `  ${folder}`).join('\n')}\n`
      + 'Pass --year for another year, or --claude-dir / --codex-dir / --cursor-dir / --pi-dir / --omp-dir / --opencode-dir / --antigravity-dir / --gemini-dir.\n');
    process.exitCode = 1;
    return;
  }

  const color = !values['no-color'] && process.stdout.isTTY && !('NO_COLOR' in process.env) && process.env.TERM !== 'dumb';
  process.stdout.write(`${renderTerminal(result, { color })}\n`);

  const shouldShare = values.share || Boolean(values.out) || Boolean(values.wide) || Boolean(values.light) || (Boolean(process.stdout.isTTY) && !values['no-share']);
  if (shouldShare && !values['no-share']) {
    const file = path.resolve(values.out ?? path.join(os.tmpdir(), `agent-wrapped-${year}.html`));
    fs.writeFileSync(file, renderPage(result, {
      layout: values.wide ? 'wide' : 'portrait',
      theme: values.light ? 'light' : 'dark',
      showProjects: values.projects,
      showApiValue: !values['no-api-value'],
      platform: process.platform,
    }));
    process.stdout.write(`\n  Your image is on this page: ${pathToFileURL(file).href}\n`);
    if (!values['no-open']) open(file);
  } else {
    process.stdout.write('  Make the image to share: npx lokalbot --share\n');
  }
  process.stdout.write(`  Give Claude Code & Codex local memory of your meetings: ${WEBSITE} (${REPOSITORY})\n\n`);
}

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
  }
}

function collectLookedPaths(sources) {
  const paths = [];
  const push = (value) => {
    if (typeof value === 'string' && value.length > 0) paths.push(value);
    else if (Array.isArray(value)) value.forEach(push);
    else if (value && typeof value === 'object') {
      push(value.projectsDir);
      push(value.stateDb);
    }
  };
  for (const key of ['claude', 'codex', 'cursor', 'pi', 'omp', 'opencode', 'antigravity', 'gemini']) {
    push(sources?.[key]);
  }
  return paths;
}

function version() {
  const manifest = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'package.json');
  return JSON.parse(fs.readFileSync(manifest, 'utf8')).version;
}
