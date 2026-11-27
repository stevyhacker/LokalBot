(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  } else {
    root.LokalBotWrapped = api;
    if (typeof document !== 'undefined') {
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { api.initUI(); });
      } else {
        api.initUI();
      }
    }
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const MINUTE = 60 * 1000;
  const HOUR = 60 * MINUTE;
  const DAY = 24 * HOUR;
  const INACTIVITY_GAP = 10 * MINUTE;
  const ACTIVE_GAP_CAP = 5 * MINUTE;
  const PARALLEL_MINIMUM = MINUTE;
  const MAX_IMPORT_FILE_BYTES = 64 * 1024 * 1024;
  const MAX_IMPORT_TOTAL_BYTES = 256 * 1024 * 1024;
  const CARD_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  const AGENTS = {
    'claude-code': 'Claude Code',
    codex: 'Codex',
    cursor: 'Cursor',
    pi: 'Pi',
    omp: 'OMP',
    opencode: 'OpenCode',
    antigravity: 'Antigravity',
    'gemini-cli': 'Gemini CLI',
  };

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

  const RATES = [
    { match: /opus[-._]?4[-._]?[5-9]|opus[-._]?[5-9]/i, rate: { input: 5, cacheRead: 0.5, cacheWrite: 6.25, output: 25 } },
    { match: /opus/i, rate: { input: 15, cacheRead: 1.5, cacheWrite: 18.75, output: 75 } },
    { match: /sonnet/i, rate: { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 } },
    { match: /haiku[-._]?(?:3[-._]?5|[4-9])/i, rate: { input: 1, cacheRead: 0.1, cacheWrite: 1.25, output: 5 } },
    { match: /haiku/i, rate: { input: 0.25, cacheRead: 0.03, cacheWrite: 0.3, output: 1.25 } },
    { match: /gpt[-._]?5[-._]?[2-9].*pro/i, rate: { input: 15, cacheRead: 1.5, cacheWrite: 15, output: 120 } },
    { match: /(?:gpt[-._]?5|codex).*mini/i, rate: { input: 0.25, cacheRead: 0.025, cacheWrite: 0.25, output: 2 } },
    { match: /gpt[-._]?5[-._]?[2-9]|gpt[-._]?[6-9]/i, rate: { input: 1.75, cacheRead: 0.175, cacheWrite: 1.75, output: 14 } },
    { match: /gpt[-._]?5|codex/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },
    { match: /o[34][-._]?mini/i, rate: { input: 1.1, cacheRead: 0.275, cacheWrite: 1.1, output: 4.4 } },
    { match: /\bo3\b|o3[-._]/i, rate: { input: 2, cacheRead: 0.5, cacheWrite: 2, output: 8 } },
    { match: /gpt[-._]?4\.1[-._]?mini/i, rate: { input: 0.4, cacheRead: 0.1, cacheWrite: 0.4, output: 1.6 } },
    { match: /gpt[-._]?4\.1/i, rate: { input: 2, cacheRead: 0.5, cacheWrite: 2, output: 8 } },
    { match: /gpt[-._]?4o[-._]?mini/i, rate: { input: 0.15, cacheRead: 0.075, cacheWrite: 0.15, output: 0.6 } },
    { match: /gpt[-._]?4o/i, rate: { input: 2.5, cacheRead: 1.25, cacheWrite: 2.5, output: 10 } },
    { match: /gemini.*flash[-._]?lite/i, rate: { input: 0.1, cacheRead: 0.01, cacheWrite: 0.1, output: 0.4 } },
    { match: /gemini.*flash/i, rate: { input: 0.3, cacheRead: 0.03, cacheWrite: 0.3, output: 2.5 } },
    { match: /gemini[-._]?[3-9]|gemini.*carbon/i, rate: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 12 } },
    { match: /gemini/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },
    { match: /composer/i, rate: { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 } },
    { match: /grok/i, rate: { input: 3, cacheRead: 0.75, cacheWrite: 3, output: 15 } },
    { match: /kimi/i, rate: { input: 0.6, cacheRead: 0.15, cacheWrite: 0.6, output: 2.5 } },
    { match: /deepseek/i, rate: { input: 0.28, cacheRead: 0.028, cacheWrite: 0.28, output: 0.42 } },
    { match: /qwen/i, rate: { input: 0.3, cacheRead: 0.06, cacheWrite: 0.3, output: 1.2 } },
  ];

  const AGENT_FALLBACK = {
    'claude-code': { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 },
    codex: { input: 1.75, cacheRead: 0.175, cacheWrite: 1.75, output: 14 },
    cursor: { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 },
    pi: { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 },
    omp: { input: 3, cacheRead: 0.3, cacheWrite: 3.75, output: 15 },
    opencode: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 10 },
    antigravity: { input: 2, cacheRead: 0.2, cacheWrite: 2, output: 12 },
    'gemini-cli': { input: 1.25, cacheRead: 0.125, cacheWrite: 1.25, output: 10 },
  };

  const DEFAULT_RATE = { input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, output: 12 };

  const HOUSEKEEPING = new Set([
    '/clear', '/compact', '/model', '/resume', '/exit', '/config', '/login', '/logout',
    '/cost', '/status', '/help', '/context', '/mcp', '/permissions', '/hooks',
    '/memory', '/doctor', '/usage', '/fast', '/effort', '/rename', '/export',
  ]);
  const IGNORED_PREFIXES = [
    '<local-command', 'Caveat:', '[Request interrupted', '# AGENTS.md instructions',
    '<permissions', '<image', '</image>', '<collaboration_mode',
  ];
  const IGNORED_BLOCKS = /<([a-z]+(?:[-_][a-z0-9]+)+|skill|attachments?)\b[^>]*>[\s\S]*?<\/\1\s*>/g;
  const HARNESS_TAG_OPENING = /^<[a-z]+(?:[-_][a-z0-9]+)+\b/;
  const PASTED_CONTENT = /<pasted_content\b[^>]*>[\s\S]*?<\/pasted_content[^>]*>/g;
  const COMMAND_NAME = /<command-name>\s*(\/[^<\s]+)\s*<\/command-name>/;
  const BASH_INPUT = /<bash-input>([\s\S]*?)<\/bash-input>/;
  const SCHEDULED_TASK = /^<scheduled-task\b[^>]*\bname="[^"]+"/;
  const COMMIT_MESSAGE = /\bgit\s+(?:-C\s+\S+\s+)?commit\b[^\n]*?\s-[a-zA-Z]*m\s*(?:"\$\(cat\s+<<-?\s*'?\w+'?\s*\n\s*([^\n]{3,200})|"((?:[^"\\\n]|\\.){3,200})|'([^'\n]{3,200})')/g;
  const PULL_REQUEST_TITLE = /\bgh\s+pr\s+create\b[^\n]*?\s(?:--title|-t)(?:\s+|=)(?:"((?:[^"\\\n]|\\.){3,200})"|'([^'\n]{3,200})')/g;
  const PULL_REQUEST_MERGE = /\bgh\s+pr\s+merge\b(?:\s+(?:https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/)?(\d+))?/g;
  const RELEASE_TAG = /\bgh\s+release\s+create\s+([^\s"';&|]+)/g;
  const GIT_PUSH = /\bgit\s+(?:-C\s+\S+\s+)?push\b/;
  const TEST_RUN = new RegExp([
    '\\bxcodebuild\\b[^\\n;&|]*\\btest(?:-without-building)?\\b',
    '\\b(?:swift|cargo|go|forge|bun|deno|dotnet|mix|flutter|zig)\\s+test\\b',
    '\\b(?:npm|pnpm|yarn)\\s+(?:run\\s+)?test\\b',
    '\\bnode\\s+--test\\b',
    '\\b(?:pytest|vitest|jest|rspec|phpunit|tox)\\b',
    '\\b(?:mvn|gradle|\\./gradlew|make|just|rake)\\s+(?:\\S+\\s+)?test\\b',
  ].join('|'));
  const CHECKOUT_FOLDERS = new Set([
    'code', 'desktop', 'dev', 'developer', 'documents', 'downloads', 'git', 'github',
    'projects', 'repos', 'repositories', 'scratchpad', 'src', 'tmp', 'workspace', 'workspaces',
  ]);
  const SCRATCH_FOLDER = /^scratch(-[0-9a-f-]+)?$/;
  const PATCHED_FILE = /\*\*\* (?:Update|Add) File: ([^\n\\"]+)/g;
  const UUID_SUFFIX = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const CLAUDE_EDIT_TOOLS = new Set(['Edit', 'MultiEdit', 'Write', 'NotebookEdit']);
  const CLAUDE_SUBAGENT_TOOLS = new Set(['Task', 'Agent']);
  const PI_EDIT_TOOLS = new Set(['write', 'edit', 'multi_edit', 'multiedit', 'patch', 'apply_patch', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
  const PI_SHELL_TOOLS = new Set(['bash', 'shell', 'exec', 'Bash']);
  const PI_SUBAGENT_TOOLS = new Set(['task', 'subagent', 'Task', 'Agent']);
  const GEMINI_EDIT_TOOLS = new Set(['write_file', 'replace', 'edit', 'edit_file', 'save_file']);
  const GEMINI_SHELL_TOOLS = new Set(['run_shell_command', 'shell', 'bash']);
  const GEMINI_SUBAGENT_TOOLS = new Set(['codebase_investigator', 'delegate_to_agent', 'subagent', 'task']);

  function positiveNum(value) {
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
  }

  function nonEmptyString(value) {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
  }

  function rateForModel(model, agentId) {
    if (typeof model === 'string' && model.length > 0) {
      for (const entry of RATES) {
        if (entry.match.test(model)) return entry.rate;
      }
    }
    return AGENT_FALLBACK[agentId] ?? DEFAULT_RATE;
  }

  function tokenCostUsd({ input = 0, cached = 0, cacheWrite = 0, output = 0 }, model, agentId) {
    const rate = rateForModel(model, agentId);
    const uncached = Math.max(0, input - cached - cacheWrite);
    return (
      uncached * rate.input
      + cached * rate.cacheRead
      + cacheWrite * rate.cacheWrite
      + output * rate.output
    ) / 1_000_000;
  }

  function sessionApiUsd(session) {
    if (session.modelTokens && session.modelTokens.size > 0) {
      let total = 0;
      for (const [model, usage] of session.modelTokens) {
        total += tokenCostUsd(usage, model, session.agent);
      }
      return total;
    }
    const topModel = [...(session.models?.entries() ?? [])]
      .sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
    return tokenCostUsd(session.tokens, topModel, session.agent);
  }

  function countWords(text) {
    let words = 0;
    let inWord = false;
    for (let index = 0; index < text.length; index += 1) {
      const code = text.charCodeAt(index);
      const space = code === 32 || (code >= 9 && code <= 13);
      if (!space && !inWord) words += 1;
      inWord = !space;
    }
    return words;
  }

  function classifyPrompt(raw) {
    if (typeof raw !== 'string' || raw.length === 0) return null;
    let text = raw;
    for (const marker of ['## My request for Codex:', '## My request:']) {
      const at = text.indexOf(marker);
      if (at !== -1) {
        text = text.slice(at + marker.length);
        break;
      }
    }
    const trimmed = text.trim();
    if (trimmed.startsWith('<heartbeat>') || SCHEDULED_TASK.test(trimmed)) {
      return { kind: 'scheduled', words: 0 };
    }
    const command = COMMAND_NAME.exec(trimmed);
    if (command) {
      return HOUSEKEEPING.has(command[1].toLowerCase()) ? null : { kind: 'command', words: 0 };
    }
    const bashMatch = BASH_INPUT.exec(trimmed);
    if (bashMatch) return { kind: 'terminal', words: 0, command: bashMatch[1].trim() };
    if (IGNORED_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) return null;
    const clean = trimmed.replace(PASTED_CONTENT, ' ').replace(IGNORED_BLOCKS, ' ').trim();
    if (clean.length === 0 || HARNESS_TAG_OPENING.test(clean)) return null;
    return { kind: 'prompt', words: Math.min(2000, countWords(clean)) };
  }

  function unwrappedShellCommand(command) {
    if (Array.isArray(command)) return typeof command[command.length - 1] === 'string' ? command[command.length - 1] : '';
    if (typeof command !== 'string' || !command.startsWith('[')) return command;
    try {
      const argv = JSON.parse(command);
      if (Array.isArray(argv) && typeof argv[argv.length - 1] === 'string') return argv[argv.length - 1];
    } catch {
    }
    return command;
  }

  function firstCapture(match) {
    for (let index = 1; index < match.length; index += 1) {
      if (match[index] !== undefined) return match[index].replaceAll('\\"', '"').trim();
    }
    return null;
  }

  function actionsInCommand(raw) {
    const command = unwrappedShellCommand(raw);
    const actions = { commits: [], pullRequestsOpened: [], pullRequestsMerged: [], releases: [], pushed: false, ranTests: false };
    if (typeof command !== 'string' || command.length === 0) return actions;
    const text = command.length > 20000 ? command.slice(0, 20000) : command;
    for (const match of text.matchAll(COMMIT_MESSAGE)) {
      const message = firstCapture(match);
      if (message && !actions.commits.includes(message)) actions.commits.push(message);
    }
    for (const match of text.matchAll(PULL_REQUEST_TITLE)) {
      const title = firstCapture(match);
      if (title && !actions.pullRequestsOpened.includes(title)) actions.pullRequestsOpened.push(title);
    }
    for (const match of text.matchAll(PULL_REQUEST_MERGE)) {
      const number = match[1] ?? '';
      if (!actions.pullRequestsMerged.includes(number)) actions.pullRequestsMerged.push(number);
    }
    for (const match of text.matchAll(RELEASE_TAG)) {
      if (!actions.releases.includes(match[1])) actions.releases.push(match[1]);
    }
    actions.pushed = GIT_PUSH.test(text);
    actions.ranTests = TEST_RUN.test(text);
    return actions;
  }

  function projectName(workingDirectory) {
    if (typeof workingDirectory !== 'string' || workingDirectory.length === 0) return null;
    const parts = workingDirectory.split(/[\\/]+/).filter(Boolean);
    if (parts.length === 0) return null;
    const claude = parts.lastIndexOf('.claude');
    if (claude > 0 && parts[claude + 1] === 'worktrees') return parts[claude - 1];
    let name = parts[parts.length - 1];
    const lowered = name.toLowerCase();
    if (CHECKOUT_FOLDERS.has(lowered) || SCRATCH_FOLDER.test(lowered)) return null;
    if (name.startsWith('.')) name = name.slice(1);
    return name.length > 0 ? name : null;
  }

  function createCollector({ start, end }) {
    const sessions = new Map();
    return {
      start,
      end,
      sessions,
      files: new Set(),
      seenRecords: new Set(),
      filesRead: 0,
      bytesRead: 0,
      unreadableFiles: 0,
      compressedSkipped: 0,
      sqliteSkipped: 0,
      inWindow(at) {
        return Number.isFinite(at) && at >= start && at < end;
      },
      session(agent, id) {
        const key = `${agent}:${id}`;
        let session = sessions.get(key);
        if (!session) {
          session = {
            agent,
            id,
            hidden: false,
            times: [],
            prompts: 0,
            promptWords: 0,
            slashCommands: 0,
            scheduledRuns: 0,
            replies: 0,
            toolCalls: 0,
            edits: 0,
            subagentFiles: 0,
            subagentCalls: 0,
            tools: new Map(),
            models: new Map(),
            modelTokens: new Map(),
            folders: new Map(),
            tokens: { input: 0, cached: 0, output: 0 },
            commits: new Set(),
            pullRequestsOpened: new Set(),
            mergedNumbers: new Set(),
            mergedUnnumbered: 0,
            releases: new Set(),
            pushes: 0,
            testRuns: 0,
          };
          sessions.set(key, session);
        }
        return session;
      },
    };
  }

  function bump(map, key, by = 1) {
    map.set(key, (map.get(key) ?? 0) + by);
  }

  function addModelTokens(session, model, { input = 0, cached = 0, cacheWrite = 0, output = 0 }) {
    if (input === 0 && output === 0) return;
    const key = typeof model === 'string' && model.length > 0 ? model : '';
    const bucket = session.modelTokens.get(key) ?? { input: 0, cached: 0, cacheWrite: 0, output: 0 };
    bucket.input += input;
    bucket.cached += cached;
    bucket.cacheWrite += cacheWrite;
    bucket.output += output;
    session.modelTokens.set(key, bucket);
  }

  function emptyActions() {
    return { commits: [], pullRequestsOpened: [], pullRequestsMerged: [], releases: [], pushes: 0, testRuns: 0 };
  }

  function mergeActions(into, actions) {
    into.commits.push(...actions.commits);
    into.pullRequestsOpened.push(...actions.pullRequestsOpened);
    into.pullRequestsMerged.push(...actions.pullRequestsMerged);
    into.releases.push(...actions.releases);
    if (actions.pushed) into.pushes += 1;
    if (actions.ranTests) into.testRuns += 1;
  }

  function addActions(session, tally) {
    for (const message of tally.commits) session.commits.add(message);
    for (const title of tally.pullRequestsOpened) session.pullRequestsOpened.add(title);
    for (const number of tally.pullRequestsMerged) {
      if (number === '') session.mergedUnnumbered += 1;
      else session.mergedNumbers.add(number);
    }
    for (const tag of tally.releases) session.releases.add(tag);
    session.pushes += tally.pushes;
    session.testRuns += tally.testRuns;
  }

  function addFile(collector, file, workingDirectory) {
    if (typeof file !== 'string' || file.length === 0) return;
    const absolute = file.startsWith('/') || /^[A-Za-z]:[\\/]/.test(file) || file.startsWith('\\\\');
    if (absolute || !workingDirectory) {
      collector.files.add(file);
      return;
    }
    const sep = workingDirectory.includes('\\') && !workingDirectory.includes('/') ? '\\' : '/';
    const trimmed = workingDirectory.endsWith(sep) ? workingDirectory.slice(0, -1) : workingDirectory;
    collector.files.add(`${trimmed}${sep}${file}`);
  }

  function toolLabel(name) {
    if (typeof name !== 'string' || name.length === 0) return 'unknown';
    const mcp = /^mcp__(.+?)__/.exec(name)
      ?? /^mcp_([a-z0-9][a-z0-9-]*?)_/.exec(name)
      ?? /^mcp-([a-z0-9][a-z0-9]*?)-/.exec(name);
    return mcp ? `${mcp[1]} (MCP)` : name;
  }

  function normalizeModelName(raw) {
    if (typeof raw !== 'string') return '';
    let name = raw.trim();
    if (!name || name === '<synthetic>' || name.toLowerCase() === 'default') return '';
    if (name.includes('/')) name = name.split('/').pop();
    name = name.replace(/^(?:us|eu|ap|global)\.[a-z0-9-]+\./i, '');
    name = name.replace(/-v\d+(?::\d+)?$/i, '').replace(/:[a-z0-9-]+$/i, '');
    name = name.replace(/-20\d{6}$/, '');
    return name.trim();
  }

  function yearWindow(year) {
    return { start: new Date(year, 0, 1).getTime(), end: new Date(year + 1, 0, 1).getTime() };
  }

  function newCalendar(year) {
    const { start } = yearWindow(year);
    const days = Math.round((Date.UTC(year + 1, 0, 1) - Date.UTC(year, 0, 1)) / DAY);
    const dayStarts = new Float64Array(days + 1);
    const months = new Uint8Array(days);
    for (let day = 0; day <= days; day += 1) {
      const date = new Date(year, 0, 1 + day);
      dayStarts[day] = date.getTime();
      if (day < days) months[day] = date.getMonth();
    }
    const firstWeekday = (new Date(year, 0, 1).getDay() + 6) % 7;
    const dayOf = (at) => {
      let day = Math.floor((at - start) / DAY);
      if (day < 0) day = 0;
      if (day > days - 1) day = days - 1;
      while (day > 0 && at < dayStarts[day]) day -= 1;
      while (day < days - 1 && at >= dayStarts[day + 1]) day += 1;
      return day;
    };
    return {
      year,
      days,
      firstWeekday,
      dayOf,
      cellOf(at) {
        const day = dayOf(at);
        const hour = Math.min(23, Math.max(0, Math.floor((at - dayStarts[day]) / HOUR)));
        return day * 24 + hour;
      },
      weekday: (day) => (firstWeekday + day) % 7,
      month: (day) => months[day],
      date(day) {
        const date = new Date(year, 0, 1 + day);
        const pad = (value) => String(value).padStart(2, '0');
        return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
      },
    };
  }

  function newAgent(id) {
    return { id, sessions: 0, requests: 0, toolCalls: 0, agentMs: 0, estimatedApiUsd: 0, tokens: { input: 0, cached: 0, output: 0 }, models: new Map() };
  }

  function addSessionTime(session, { calendar, grid, dayTouched, agentDays, sessionsOnDay, runs }) {
    if (session.times.length === 0) return 0;
    const times = Float64Array.from(session.times).sort();
    let total = 0;
    let runStart = times[0];
    let runMs = 0;
    let lastDay = -1;
    const close = (end) => {
      runs.push({ start: runStart, end, agentMs: runMs, agent: session.agent });
    };
    for (let index = 0; index < times.length; index += 1) {
      const at = times[index];
      const cell = calendar.cellOf(at);
      const day = (cell - (cell % 24)) / 24;
      if (day !== lastDay) {
        dayTouched[day] = 1;
        if (agentDays) agentDays[day] = 1;
        sessionsOnDay[day] += 1;
        lastDay = day;
      }
      if (index === 0) continue;
      const previous = times[index - 1];
      const gap = at - previous;
      if (gap > INACTIVITY_GAP) {
        close(previous);
        runStart = at;
        runMs = 0;
        continue;
      }
      const worked = Math.min(gap, ACTIVE_GAP_CAP);
      grid[calendar.cellOf(previous)] += worked;
      runMs += worked;
      total += worked;
    }
    close(times[times.length - 1]);
    return total;
  }

  function creditProjects(session, sessionMs, projects) {
    if (sessionMs <= 0) return;
    let records = 0;
    for (const count of session.folders.values()) records += count;
    if (records === 0) return;
    for (const [folder, count] of session.folders) {
      const name = projectName(folder);
      if (name) projects.set(name, (projects.get(name) ?? 0) + (sessionMs * count) / records);
    }
  }

  function topMap(map, limit) {
    return [...map.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count || (a.name < b.name ? -1 : 1))
      .slice(0, limit);
  }

  function unionMs(runs) {
    const ordered = runs.filter((run) => run.end > run.start).sort((a, b) => a.start - b.start);
    let total = 0;
    let start = null;
    let end = null;
    for (const run of ordered) {
      if (end === null || run.start > end) {
        if (end !== null) total += end - start;
        start = run.start;
        end = run.end;
      } else if (run.end > end) {
        end = run.end;
      }
    }
    if (end !== null) total += end - start;
    return total;
  }

  function longestStreak(dayTouched, calendar) {
    let best = { days: 0, start: null, end: null };
    let length = 0;
    for (let day = 0; day < calendar.days; day += 1) {
      length = dayTouched[day] ? length + 1 : 0;
      if (length > best.days) best = { days: length, start: calendar.date(day - length + 1), end: calendar.date(day) };
    }
    return best;
  }

  function busiestDay(byDay, sessionsOnDay, calendar) {
    let best = -1;
    for (let day = 0; day < byDay.length; day += 1) {
      if (byDay[day] > 0 && (best === -1 || byDay[day] > byDay[best])) best = day;
    }
    if (best === -1) return null;
    return { date: calendar.date(best), day: best, agentMs: Math.round(byDay[best]), sessions: sessionsOnDay[best] };
  }

  function longestRun(runs, calendar) {
    let best = null;
    for (const run of runs) {
      if (run.end - run.start > (best ? best.end - best.start : 0)) best = run;
    }
    if (!best) return null;
    return { ms: Math.round(best.end - best.start), date: calendar.date(calendar.dayOf(best.start)), agent: best.agent };
  }

  function mostAtOnce(runs, calendar) {
    const edges = [];
    for (const run of runs) {
      if (run.end - run.start < PARALLEL_MINIMUM) continue;
      edges.push([run.start, 1], [run.end, -1]);
    }
    edges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    let current = 0;
    let best = { count: 0, date: null };
    for (const [at, change] of edges) {
      current += change;
      if (current > best.count) best = { count: current, date: calendar.date(calendar.dayOf(at)) };
    }
    return best;
  }

  function computeShares(grid, calendar, agentMs) {
    let night = 0;
    let early = 0;
    let weekend = 0;
    let office = 0;
    for (let day = 0; day < calendar.days; day += 1) {
      const weekday = calendar.weekday(day);
      for (let hour = 0; hour < 24; hour += 1) {
        const ms = grid[day * 24 + hour];
        if (ms === 0) continue;
        if (hour >= 22 || hour < 5) night += ms;
        if (hour >= 5 && hour < 9) early += ms;
        if (weekday >= 5) weekend += ms;
        else if (hour >= 9 && hour < 18) office += ms;
      }
    }
    const share = (ms) => (agentMs > 0 ? Math.round((ms / agentMs) * 1000) / 1000 : 0);
    return { night: share(night), early: share(early), weekend: share(weekend), office: share(office) };
  }

  function computePersona(stats) {
    const { totals, shares: share, agents } = stats;
    const hours = totals.agentMs / HOUR;
    if (hours < 1) {
      return { id: 'first-steps', title: 'The Newcomer', line: 'A quiet first year. The logs are ready when you are.' };
    }
    const percent = (value) => `${Math.round(value * 100)}%`;
    const second = agents[1];
    const firstShare = agents[0] && totals.agentMs > 0 ? agents[0].agentMs / totals.agentMs : 0;
    const split = second && totals.agentMs > 0 ? second.agentMs / totals.agentMs : 0;
    const activeAgents = agents.filter((agent) => totals.agentMs > 0 && agent.agentMs / totals.agentMs >= 0.03);
    const perDay = totals.activeDays > 0 ? totals.commits / totals.activeDays : 0;
    const switchLine = !second
      ? ''
      : activeAgents.length >= 3
        ? `You split the year across ${activeAgents.length} agents, led by ${agents[0].name} (${percent(firstShare)}) and ${second.name} (${percent(split)}).`
        : `You split the year between ${agents[0].name} and ${second.name}, ${percent(firstShare)} to ${percent(split)}.`;
    const candidates = [
      {
        id: 'night-shift', title: 'The Night Shift', score: share.night / 0.3,
        line: `${percent(share.night)} of your agent hours ran between 10 pm and 5 am.`,
      },
      {
        id: 'air-traffic', title: 'The Air Traffic Controller', score: stats.mostAtOnce.count / 6,
        line: `You had ${stats.mostAtOnce.count} agents working at the same moment.`,
      },
      {
        id: 'weekend', title: 'The Weekend Regular', score: share.weekend / 0.36,
        line: `${percent(share.weekend)} of your agent hours fell on a Saturday or Sunday.`,
      },
      {
        id: 'first-light', title: 'The First Light', score: share.early / 0.28,
        line: `${percent(share.early)} of your agent hours ran before 9 am.`,
      },
      {
        id: 'long-hauler', title: 'The Long Hauler', score: (stats.longestRun?.ms ?? 0) / (8 * HOUR),
        line: `Your longest run without a break lasted ${Math.round((stats.longestRun?.ms ?? 0) / HOUR)} hours.`,
      },
      {
        id: 'switch-hitter', title: 'The Switch Hitter', score: split / 0.3,
        line: switchLine,
      },
      {
        id: 'release-train', title: 'The Release Train', score: Math.max(perDay / 6, totals.pullRequestsMerged / 150),
        line: `${totals.commits.toLocaleString('en-US')} commits and ${totals.pullRequestsMerged.toLocaleString('en-US')} merged pull requests.`,
      },
      {
        id: 'daily-driver', title: 'The Daily Driver', score: stats.streak.days / 45,
        line: `${stats.streak.days} days in a row with an agent at work.`,
      },
      {
        id: 'one-liner', title: 'The One-Liner',
        score: totals.requests >= 50 && totals.avgPromptWords > 0 && totals.avgPromptWords <= 12 && totals.toolsPerRequest >= 8
          ? (12 / totals.avgPromptWords) * (totals.toolsPerRequest / 12)
          : 0,
        line: `Average prompt: ${totals.avgPromptWords} words. Average reply: ${totals.toolsPerRequest} tool calls.`,
      },
      {
        id: 'orchestrator', title: 'The Orchestrator',
        score: totals.requests >= 25
          ? Math.max(totals.subagents / 150, totals.toolsPerRequest / 28)
          : 0,
        line: totals.subagents >= 20
          ? `${totals.subagents.toLocaleString('en-US')} subagents launched, averaging ${totals.toolsPerRequest} tool calls per request.`
          : `You averaged ${totals.toolsPerRequest} tool calls for every request.`,
      },
    ];
    const winner = candidates.filter((candidate) => candidate.score >= 1).sort((a, b) => b.score - a.score)[0];
    if (winner) return { id: winner.id, title: winner.title, line: winner.line };
    return {
      id: 'steady-hand', title: 'The Steady Hand',
      line: `${percent(share.office)} of your agent hours ran on weekdays between 9 and 6.`,
    };
  }

  function computeStats(collector, { year, generatedAt = new Date(), summaryDays = new Map() } = {}) {
    const calendar = newCalendar(year);
    const grid = new Float64Array(calendar.days * 24);
    const dayTouched = new Uint8Array(calendar.days);
    const claudeDays = new Uint8Array(calendar.days);
    const sessionsOnDay = new Uint32Array(calendar.days);
    const runs = [];
    const projects = new Map();
    const tools = new Map();
    const modelTotals = new Map();
    const agents = new Map(Object.keys(AGENTS).map((id) => [id, newAgent(id)]));
    const totals = {
      sessions: 0, requests: 0, requestWords: 0, slashCommands: 0, scheduledRuns: 0, replies: 0,
      toolCalls: 0, subagents: 0, edits: 0, filesChanged: collector.files.size,
      agentMs: 0, wallClockMs: 0, activeDays: 0,
      tokens: { input: 0, cached: 0, output: 0, total: 0 },
      estimatedApiUsd: 0, cacheHitRate: 0, parallelMultiplier: 1, avgPromptWords: 0, toolsPerRequest: 0,
      commits: 0, pullRequestsOpened: 0, pullRequestsMerged: 0, releases: 0, pushes: 0, testRuns: 0,
    };

    for (const session of collector.sessions.values()) {
      const agent = agents.get(session.agent) ?? agents.set(session.agent, newAgent(session.agent)).get(session.agent);
      for (const key of ['input', 'cached', 'output']) {
        agent.tokens[key] += session.tokens[key];
        totals.tokens[key] += session.tokens[key];
      }
      const apiUsd = sessionApiUsd(session);
      agent.estimatedApiUsd += apiUsd;
      totals.estimatedApiUsd += apiUsd;
      agent.toolCalls += session.toolCalls;
      totals.toolCalls += session.toolCalls;
      totals.edits += session.edits;
      totals.commits += session.commits.size;
      totals.pullRequestsOpened += session.pullRequestsOpened.size;
      totals.pullRequestsMerged += session.mergedNumbers.size + session.mergedUnnumbered;
      totals.releases += session.releases.size;
      totals.pushes += session.pushes;
      totals.testRuns += session.testRuns;
      for (const [name, count] of session.tools) tools.set(name, (tools.get(name) ?? 0) + count);
      for (const [rawModel, count] of session.models) {
        const model = normalizeModelName(rawModel);
        if (model) agent.models.set(model, (agent.models.get(model) ?? 0) + count);
      }
      for (const [rawModel, bucket] of session.modelTokens) {
        const name = normalizeModelName(rawModel);
        if (!name) continue;
        const total = (bucket.input ?? 0) + (bucket.output ?? 0);
        if (total <= 0) continue;
        const agg = modelTotals.get(name) ?? { name, input: 0, output: 0, total: 0 };
        agg.input += bucket.input ?? 0;
        agg.output += bucket.output ?? 0;
        agg.total += total;
        modelTotals.set(name, agg);
      }
      if (session.hidden) continue;

      totals.subagents += Math.max(session.subagentFiles, session.subagentCalls);
      totals.requests += session.prompts;
      totals.requestWords += session.promptWords;
      totals.slashCommands += session.slashCommands;
      totals.scheduledRuns += session.scheduledRuns;
      totals.replies += session.replies;
      agent.requests += session.prompts;
      if (session.prompts + session.scheduledRuns + session.toolCalls + session.replies > 0) {
        agent.sessions += 1;
        totals.sessions += 1;
      }

      const agentDays = session.agent === 'claude-code' ? claudeDays : null;
      const sessionMs = addSessionTime(session, { calendar, grid, dayTouched, agentDays, sessionsOnDay, runs });
      agent.agentMs += sessionMs;
      totals.agentMs += sessionMs;
      creditProjects(session, sessionMs, projects);
    }
    totals.tokens.total = totals.tokens.input + totals.tokens.output;

    const byDay = new Array(calendar.days).fill(0);
    const byHour = new Array(24).fill(0);
    const byWeekday = new Array(7).fill(0);
    const byMonth = new Array(12).fill(0);
    for (let day = 0; day < calendar.days; day += 1) {
      for (let hour = 0; hour < 24; hour += 1) {
        const ms = grid[day * 24 + hour];
        if (ms === 0) continue;
        byDay[day] += ms;
        byHour[hour] += ms;
        byWeekday[calendar.weekday(day)] += ms;
        byMonth[calendar.month(day)] += ms;
      }
      if (dayTouched[day]) totals.activeDays += 1;
    }
    totals.wallClockMs = unionMs(runs);
    totals.estimatedApiUsd = Math.round(totals.estimatedApiUsd * 100) / 100;
    totals.cacheHitRate = totals.tokens.input > 0 ? Math.round((totals.tokens.cached / totals.tokens.input) * 1000) / 1000 : 0;
    totals.parallelMultiplier = totals.wallClockMs > 0 ? Math.round((totals.agentMs / totals.wallClockMs) * 100) / 100 : 1;
    totals.avgPromptWords = totals.requests > 0 ? Math.round(totals.requestWords / totals.requests) : 0;
    totals.toolsPerRequest = totals.requests > 0 ? Math.round((totals.toolCalls / totals.requests) * 10) / 10 : 0;

    const earlierDays = new Float64Array(calendar.days);
    const earlier = { days: 0, sessions: 0, toolCalls: 0, from: null };
    const anyDay = Uint8Array.from(dayTouched);
    let countedOnly = 0;
    for (const [date, counts] of [...summaryDays.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
      const [summaryYear, month, dayOfMonth] = date.split('-').map(Number);
      if (summaryYear !== year) continue;
      const day = calendar.dayOf(new Date(year, month - 1, dayOfMonth, 12).getTime());
      if (claudeDays[day] || earlierDays[day] > 0 || counts.sessions + counts.toolCalls === 0) continue;
      if (!anyDay[day]) countedOnly += 1;
      anyDay[day] = 1;
      earlierDays[day] = Math.max(1, counts.toolCalls);
      earlier.days += 1;
      earlier.sessions += counts.sessions;
      earlier.toolCalls += counts.toolCalls;
      earlier.from ??= date;
    }
    const firstLogged = dayTouched.indexOf(1);
    const firstClaudeLogged = claudeDays.indexOf(1);

    const agentList = [...agents.values()]
      .filter((agent) => agent.sessions > 0 || agent.tokens.input + agent.tokens.output > 0)
      .map((agent) => ({
        id: agent.id,
        name: AGENTS[agent.id] ?? agent.id,
        sessions: agent.sessions,
        requests: agent.requests,
        toolCalls: agent.toolCalls,
        agentMs: agent.agentMs,
        tokens: { ...agent.tokens, total: agent.tokens.input + agent.tokens.output },
        estimatedApiUsd: Math.round(agent.estimatedApiUsd * 100) / 100,
        topModel: topMap(agent.models, 1)[0]?.name ?? null,
      }))
      .sort((a, b) => b.agentMs - a.agentMs || b.sessions - a.sessions);

    const projectList = [...projects.entries()]
      .filter(([, ms]) => ms >= 10 * MINUTE)
      .map(([name, ms]) => ({ name, agentMs: Math.round(ms) }))
      .sort((a, b) => b.agentMs - a.agentMs);

    const topModels = [...modelTotals.values()]
      .sort((a, b) => b.total - a.total || a.name.localeCompare(b.name))
      .slice(0, 5);

    const months = new Array(calendar.days);
    for (let day = 0; day < calendar.days; day += 1) months[day] = calendar.month(day);

    const stats = {
      schema: 1,
      year,
      generatedAt: generatedAt.toISOString(),
      agents: agentList,
      totals: { ...totals, agentMs: Math.round(totals.agentMs), wallClockMs: Math.round(totals.wallClockMs) },
      coverage: {
        loggedFrom: firstLogged === -1 ? null : calendar.date(firstLogged),
        claudeLoggedFrom: firstClaudeLogged === -1 ? null : calendar.date(firstClaudeLogged),
        earlier: earlier.days > 0 ? earlier : null,
        daysWithAnAgent: totals.activeDays + countedOnly,
      },
      streak: longestStreak(anyDay, calendar),
      busiestDay: busiestDay(byDay, sessionsOnDay, calendar),
      longestRun: longestRun(runs, calendar),
      mostAtOnce: mostAtOnce(runs, calendar),
      shares: computeShares(grid, calendar, totals.agentMs),
      byHour: byHour.map(Math.round),
      byWeekday: byWeekday.map(Math.round),
      byMonth: byMonth.map(Math.round),
      byDay: byDay.map(Math.round),
      topTools: topMap(tools, 5),
      topModels,
      projects: projectList.slice(0, 5),
      projectCount: projectList.length,
      sources: {
        filesRead: collector.filesRead,
        bytesRead: collector.bytesRead,
        unreadableFiles: collector.unreadableFiles,
        compressedSkipped: collector.compressedSkipped,
        sqliteSkipped: collector.sqliteSkipped,
      },
    };
    stats.persona = computePersona(stats);
    return { year, days: calendar.days, months, stats, grid, calendar, earlierDays };
  }

  function mulberry32(seed) {
    let state = seed >>> 0;
    return () => {
      state = (state + 0x6d2b79f5) >>> 0;
      let mixed = state;
      mixed = Math.imul(mixed ^ (mixed >>> 15), mixed | 1);
      mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
      return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
    };
  }

  function addSampleSession(collector, { agent, id, start, minutes, project, random, model, subagentBias = 0.1 }) {
    const session = collector.session(agent, id);
    const end = Math.min(start + minutes * MINUTE, collector.end - 1);
    let at = start;
    let steps = 0;
    while (at < end && at >= collector.start) {
      session.times.push(at);
      at += (20 + random() * 200) * 1000;
      if (random() < 0.03) at += (4 + random() * 9) * MINUTE;
      steps += 1;
    }
    session.folders.set(`/Users/demo/code/${project}`, steps);
    session.prompts = 1 + Math.floor(steps / 14);
    session.promptWords = session.prompts * (12 + Math.floor(random() * 30));
    session.replies = session.prompts;
    session.toolCalls = Math.floor(steps * 0.8);
    session.edits = Math.floor(steps * 0.12);
    session.tokens.input = steps * (60000 + Math.floor(random() * 90000));
    session.tokens.cached = Math.floor(session.tokens.input * 0.9);
    session.tokens.output = steps * (500 + Math.floor(random() * 900));
    session.models.set(model, session.prompts);
    addModelTokens(session, model, {
      input: session.tokens.input,
      cached: session.tokens.cached,
      output: session.tokens.output,
    });
    for (const [tool, share] of [['Bash', 0.4], ['Read', 0.3], ['Edit', 0.2], ['Grep', 0.1]]) {
      session.tools.set(tool, Math.floor(session.toolCalls * share));
    }
    for (let index = 0; index < session.edits; index += 1) {
      collector.files.add(`/Users/demo/code/${project}/src/file-${Math.floor(random() * 400)}.ts`);
    }
    if (random() < 0.55) session.commits.add(`${id} commit`);
    if (random() < 0.2) session.commits.add(`${id} second commit`);
    if (random() < 0.16) session.pullRequestsOpened.add(`${id} pull request`);
    if (random() < 0.12) session.mergedNumbers.add(id);
    if (random() < 0.3) session.testRuns += 1 + Math.floor(random() * 4);
    if (random() < subagentBias) session.subagentCalls += 1 + Math.floor(random() * 5);
  }

  function buildDemoSwitchHitter(year) {
    const projects = ['harbor-app', 'tide-api', 'northwind-site', 'lantern-docs', 'kiln'];
    const random = mulberry32(7 + year);
    const window = yearWindow(year);
    const collector = createCollector(window);
    const days = Math.round((window.end - window.start) / DAY);
    let session = 0;

    for (let day = 0; day < days; day += 1) {
      const date = new Date(year, 0, 1 + day);
      const weekend = date.getDay() === 0 || date.getDay() === 6;
      if (date.getMonth() === 7 && date.getDate() >= 8 && date.getDate() <= 21) continue;
      const appetite = 0.45 + 0.5 * (day / days);
      if (random() > (weekend ? 0.35 : 0.9) * appetite + 0.1) continue;
      const sprint = date.getMonth() === 9 && date.getDate() >= 12 && date.getDate() <= 16;
      const sessions = sprint ? 6 + Math.floor(random() * 3) : 1 + Math.floor(random() * 3 * appetite + (weekend ? 0 : 0.6));
      for (let index = 0; index < sessions; index += 1) {
        const agent = random() < 0.68 ? 'claude-code' : 'codex';
        const evening = random() < 0.42;
        const startHour = sprint ? 9 + random() * 13 : evening ? 20 + random() * 4.5 : 9 + random() * 8;
        const minutes = sprint ? 120 + random() * 240 : 20 + random() * random() * 200;
        session += 1;
        const modelRoll = random();
        const model = agent === 'codex'
          ? (modelRoll < 0.78 ? 'gpt-6-astra' : 'gpt-5.4-mini')
          : (modelRoll < 0.68 ? 'claude-fable-5' : (modelRoll < 0.90 ? 'claude-sonnet-5' : 'claude-haiku-5'));
        addSampleSession(collector, {
          agent,
          id: `demo-${session}`,
          start: date.getTime() + startHour * HOUR,
          minutes,
          project: projects[Math.floor(random() * random() * projects.length)],
          random,
          model,
        });
      }
    }
    return computeStats(collector, { year, generatedAt: new Date(year, 11, 31, 12) });
  }

  function buildDemoNightShift(year) {
    const projects = ['aurora-cli', 'signal-core', 'drift-ui', 'patchbay'];
    const random = mulberry32(41 + year);
    const window = yearWindow(year);
    const collector = createCollector(window);
    const days = Math.round((window.end - window.start) / DAY);
    let session = 0;

    for (let day = 0; day < days; day += 1) {
      const date = new Date(year, 0, 1 + day);
      const weekend = date.getDay() === 0 || date.getDay() === 6;
      if (random() > (weekend ? 0.55 : 0.78)) continue;
      const burst = date.getMonth() === 10 && date.getDate() >= 4 && date.getDate() <= 8;
      const count = burst ? 4 + Math.floor(random() * 3) : 1 + Math.floor(random() * 2);
      for (let index = 0; index < count; index += 1) {
        const roll = random();
        const agent = roll < 0.52 ? 'claude-code' : (roll < 0.80 ? 'cursor' : 'gemini-cli');
        const late = random() < 0.68;
        const startHour = late ? (random() < 0.55 ? 22 + random() * 1.9 : 0.2 + random() * 3.1) : 13 + random() * 6;
        const minutes = burst ? 90 + random() * 160 : 25 + random() * 120;
        session += 1;
        const model = agent === 'claude-code'
          ? (random() < 0.65 ? 'claude-sonnet-5' : 'claude-fable-5')
          : agent === 'cursor'
            ? (random() < 0.6 ? 'claude-sonnet-5' : 'composer-2')
            : 'gemini-3-pro';
        addSampleSession(collector, {
          agent,
          id: `night-${session}`,
          start: date.getTime() + startHour * HOUR,
          minutes,
          project: projects[Math.floor(random() * projects.length)],
          random,
          model,
        });
      }
    }
    return computeStats(collector, { year, generatedAt: new Date(year, 11, 31, 12) });
  }

  function buildDemoOrchestrator(year) {
    const projects = ['forge-engine', 'mesh-router', 'lokalbot', 'eval-harness'];
    const random = mulberry32(99 + year);
    const window = yearWindow(year);
    const collector = createCollector(window);
    const days = Math.round((window.end - window.start) / DAY);
    let session = 0;

    for (let day = 0; day < days; day += 1) {
      const date = new Date(year, 0, 1 + day);
      const weekend = date.getDay() === 0 || date.getDay() === 6;
      if (random() > (weekend ? 0.32 : 0.84)) continue;
      const launch = date.getMonth() === 8 && date.getDate() >= 15 && date.getDate() <= 19;
      const waves = launch ? 3 : 1 + Math.floor(random() * 2);
      for (let wave = 0; wave < waves; wave += 1) {
        const baseHour = 10 + wave * 3.2 + random() * 1.4;
        const parallel = launch ? 4 : 2 + Math.floor(random() * 2);
        for (let slot = 0; slot < parallel; slot += 1) {
          const roll = random();
          const agent = roll < 0.42 ? 'codex' : (roll < 0.74 ? 'claude-code' : (roll < 0.9 ? 'pi' : 'opencode'));
          session += 1;
          const model = agent === 'codex'
            ? 'gpt-6-astra'
            : agent === 'claude-code'
              ? 'claude-fable-5'
              : agent === 'pi'
                ? 'claude-sonnet-5'
                : 'deepseek-r2';
          addSampleSession(collector, {
            agent,
            id: `orch-${session}`,
            start: date.getTime() + (baseHour + slot * 0.12) * HOUR,
            minutes: 35 + random() * 85,
            project: projects[Math.floor(random() * projects.length)],
            random,
            model,
            subagentBias: 0.48,
          });
        }
      }
    }
    return computeStats(collector, { year, generatedAt: new Date(year, 11, 31, 12) });
  }

  function buildDemoClaude30d(year) {
    const projects = ['lokalbot', 'notes-sync', 'bench-suite'];
    const random = mulberry32(211 + year);
    const window = yearWindow(year);
    const collector = createCollector(window);
    const summaryDays = new Map();
    const cal = newCalendar(year);
    const endDay = Math.min(cal.days - 1, 325);
    const startDay = endDay - 28;
    let session = 0;

    for (let day = 14; day < startDay; day += 1) {
      if (random() < 0.56) {
        summaryDays.set(cal.date(day), {
          sessions: 1 + Math.floor(random() * 4),
          toolCalls: 25 + Math.floor(random() * 140),
        });
      }
    }

    for (let day = startDay; day <= endDay; day += 1) {
      const date = new Date(year, 0, 1 + day);
      if (random() > 0.88) continue;
      const peak = day === endDay - 6;
      const sessions = peak ? 5 : 1 + Math.floor(random() * 3);
      for (let index = 0; index < sessions; index += 1) {
        session += 1;
        const model = random() < 0.72 ? 'claude-fable-5' : 'claude-sonnet-5';
        addSampleSession(collector, {
          agent: 'claude-code',
          id: `c30-${session}`,
          start: date.getTime() + (9 + random() * 11) * HOUR,
          minutes: peak ? 90 + random() * 120 : 30 + random() * 110,
          project: projects[Math.floor(random() * projects.length)],
          random,
          model,
        });
      }
    }
    return computeStats(collector, { year, generatedAt: new Date(year, 10, 26, 12), summaryDays });
  }

  function buildSampleProfiles(year = 2026) {
    return [
      {
        id: 'switch-hitter',
        label: 'The Switch Hitter',
        hint: 'Claude Code + Codex · Full year',
        data: buildDemoSwitchHitter(year),
      },
      {
        id: 'night-shift',
        label: 'The Night Shift',
        hint: 'Claude Code + Cursor + Gemini CLI',
        data: buildDemoNightShift(year),
      },
      {
        id: 'orchestrator',
        label: 'The Orchestrator',
        hint: '4 agents in parallel · Subagents',
        data: buildDemoOrchestrator(year),
      },
      {
        id: 'claude-30d',
        label: '30-Day Claude Window',
        hint: 'Auto-zoom + stats-cache.json',
        data: buildDemoClaude30d(year),
      },
    ];
  }

  function shellCommandFromBody(body) {
    if (typeof body !== 'string' || !body.startsWith('{')) return null;
    try {
      const args = JSON.parse(body);
      const command = args?.cmd ?? args?.command;
      if (typeof command === 'string') return command;
      if (Array.isArray(command) && typeof command[command.length - 1] === 'string') return command[command.length - 1];
    } catch {
    }
    return null;
  }

  function modelShares(running) {
    const shares = new Map(running.byModel);
    const unknown = shares.get('');
    const first = [...shares.keys()].find((model) => model !== '');
    if (unknown && first !== undefined) {
      const into = shares.get(first);
      shares.set(first, { input: into.input + unknown.input, cached: into.cached + unknown.cached, output: into.output + unknown.output });
      shares.delete('');
    }
    return shares;
  }

  function advanceRunningTotal(running, reading, inWindow, model) {
    if (!reading || typeof reading !== 'object') return;
    const now = {
      input: positiveNum(reading.input_tokens),
      cached: positiveNum(reading.cached_input_tokens),
      output: positiveNum(reading.output_tokens),
    };
    const before = running.last;
    const restarted = before !== null && now.input + now.output < before.input + before.output;
    const base = before === null || restarted ? { input: 0, cached: 0, output: 0 } : before;
    running.last = now;
    if (!inWindow) return;
    running.seen = true;
    const delta = {
      input: Math.max(0, now.input - base.input),
      cached: Math.max(0, now.cached - base.cached),
      output: Math.max(0, now.output - base.output),
    };
    running.input += delta.input;
    running.cached += delta.cached;
    running.output += delta.output;
    const key = typeof model === 'string' && model.length > 0 ? model : '';
    const bucket = running.byModel.get(key) ?? { input: 0, cached: 0, output: 0 };
    bucket.input += delta.input;
    bucket.cached += delta.cached;
    bucket.output += delta.output;
    running.byModel.set(key, bucket);
  }

  function extractTextContent(content) {
    if (typeof content === 'string') return content;
    if (!Array.isArray(content)) return '';
    return content
      .filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text)
      .join('\n');
  }

  function stemOfPath(filePath) {
    const normalized = String(filePath || 'session').replaceAll('\\', '/');
    const base = normalized.split('/').pop() || 'session';
    return base.replace(/\.(jsonl|json)$/i, '');
  }

  function parseClaudeJsonl(lines, filePath, collector, yearsSeen) {
    const normalized = String(filePath || '').replaceAll('\\', '/');
    const subMatch = /\/([^/]+)\/subagents\//i.exec(normalized);
    const subagent = Boolean(subMatch);
    const id = subMatch ? subMatch[1] : stemOfPath(normalized);
    let session = null;
    let launched = false;
    const usage = new Map();
    const tally = emptyActions();

    const touch = (at) => {
      session ??= collector.session('claude-code', id);
      session.times.push(at);
      if (subagent && !launched) {
        launched = true;
        session.subagentFiles += 1;
      }
      return session;
    };
    const admit = (uuid) => {
      if (typeof uuid !== 'string' || uuid.length === 0) return true;
      if (collector.seenRecords.has(uuid)) return false;
      collector.seenRecords.add(uuid);
      return true;
    };

    for (const rawLine of lines) {
      const trimmed = rawLine.trim();
      if (!trimmed) continue;
      let record;
      try {
        record = JSON.parse(trimmed);
      } catch {
        continue;
      }
      const type = record?.type;
      if (type !== 'user' && type !== 'assistant') continue;
      if (record.isMeta === true || record.isCompactSummary === true) continue;
      const at = Date.parse(record.timestamp);
      if (Number.isFinite(at)) yearsSeen.add(new Date(at).getFullYear());
      if (!collector.inWindow(at) || !admit(record.uuid)) continue;

      const current = touch(at);
      const side = subagent || record.isSidechain === true;
      const cwd = typeof record.cwd === 'string' ? record.cwd : null;
      if (cwd && !side) bump(current.folders, cwd);
      const message = record.message;
      if (type === 'user') {
        if (!side) {
          const request = classifyPrompt(extractTextContent(message?.content));
          if (request) {
            if (request.kind === 'scheduled') current.scheduledRuns += 1;
            else {
              current.prompts += 1;
              current.promptWords += request.words;
              if (request.kind === 'command') current.slashCommands += 1;
              if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
            }
          }
        }
      } else if (message && typeof message === 'object') {
        const model = typeof message.model === 'string' && message.model !== '<synthetic>' ? message.model : null;
        const msgId = typeof message.id === 'string' ? message.id : null;
        if (model && !side && (!msgId || !usage.has(msgId))) bump(current.models, model);
        if (message.usage && typeof message.usage === 'object') {
          const key = msgId ?? `record-${usage.size}`;
          const seen = usage.get(key) ?? { model: null, input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };
          if (model && !seen.model) seen.model = model;
          seen.input = Math.max(seen.input, positiveNum(message.usage.input_tokens));
          seen.cacheWrite = Math.max(seen.cacheWrite, positiveNum(message.usage.cache_creation_input_tokens));
          seen.cacheRead = Math.max(seen.cacheRead, positiveNum(message.usage.cache_read_input_tokens));
          seen.output = Math.max(seen.output, positiveNum(message.usage.output_tokens));
          usage.set(key, seen);
        }
        if (Array.isArray(message.content)) {
          for (const block of message.content) {
            if (block?.type === 'text') {
              if (!side && typeof block.text === 'string' && block.text.trim().length > 0) current.replies += 1;
            } else if (block?.type === 'tool_use') {
              const name = typeof block.name === 'string' ? block.name : '';
              const input = block.input && typeof block.input === 'object' ? block.input : {};
              current.toolCalls += 1;
              bump(current.tools, toolLabel(name));
              if (CLAUDE_EDIT_TOOLS.has(name)) {
                current.edits += 1;
                addFile(collector, input.file_path ?? input.notebook_path, cwd);
              } else if (name === 'Bash' && typeof input.command === 'string') {
                mergeActions(tally, actionsInCommand(input.command));
              } else if (CLAUDE_SUBAGENT_TOOLS.has(name) && !side) {
                current.subagentCalls += 1;
              }
            }
          }
        }
      }
    }

    if (!session) return;
    for (const used of usage.values()) {
      const input = used.input + used.cacheWrite + used.cacheRead;
      session.tokens.input += input;
      session.tokens.cached += used.cacheRead;
      session.tokens.output += used.output;
      addModelTokens(session, used.model, {
        input,
        cached: used.cacheRead,
        cacheWrite: used.cacheWrite,
        output: used.output,
      });
    }
    addActions(session, tally);
  }

  function parseCodexJsonl(lines, filePath, collector, yearsSeen) {
    const stem = stemOfPath(filePath);
    const uuidMatch = UUID_SUFFIX.exec(stem);
    let meta = { id: uuidMatch ? uuidMatch[0] : stem, parent: null, helper: false, cwd: null };
    let session = null;
    let launched = false;
    let workingDirectory = null;
    let currentModel = null;
    const asked = { actions: emptyActions(), edits: 0 };
    const done = { actions: emptyActions(), edits: 0, commands: false, changes: false };
    const totals = {
      token_count: { seen: false, last: null, input: 0, cached: 0, output: 0, byModel: new Map() },
      token_usage_record: { seen: false, last: null, input: 0, cached: 0, output: 0, byModel: new Map() },
    };

    const touch = (at) => {
      const side = meta.parent !== null;
      if (!session) {
        session = collector.session('codex', side ? meta.parent : meta.id);
        if (meta.helper) session.hidden = true;
      }
      session.times.push(at);
      if (side && !launched) {
        launched = true;
        session.subagentFiles += 1;
      }
      return session;
    };

    for (const rawLine of lines) {
      const trimmed = rawLine.trim();
      if (!trimmed) continue;
      let record;
      try {
        record = JSON.parse(trimmed);
      } catch {
        continue;
      }
      const payload = record?.payload;
      if (!payload || typeof payload !== 'object') continue;
      const type = record.type;
      if (type === 'session_meta') {
        if (typeof payload.id === 'string' && payload.id.length > 0) meta.id = payload.id;
        if (typeof payload.cwd === 'string') {
          meta.cwd = payload.cwd;
          workingDirectory = payload.cwd;
        }
        const subagent = payload.source && typeof payload.source === 'object' ? payload.source.subagent : null;
        if (subagent) {
          const parent = subagent.thread_spawn?.parent_thread_id;
          if (typeof parent === 'string' && parent.length > 0) meta.parent = parent;
          else meta.helper = true;
        }
        continue;
      }
      const at = Date.parse(record.timestamp);
      if (Number.isFinite(at)) yearsSeen.add(new Date(at).getFullYear());
      const inWindow = collector.inWindow(at);
      if (type === 'token_usage_record') {
        advanceRunningTotal(totals.token_usage_record, payload.thread_token_usage, inWindow, currentModel);
      } else if (type === 'event_msg' && payload.type === 'token_count') {
        advanceRunningTotal(totals.token_count, payload.info?.total_token_usage, inWindow, currentModel);
      }
      if (!inWindow) continue;

      const current = touch(at);
      const quiet = meta.parent !== null || meta.helper;
      if (type === 'turn_context') {
        if (typeof payload.cwd === 'string') workingDirectory = payload.cwd;
        if (typeof payload.model === 'string' && payload.model.length > 0) currentModel = payload.model;
        if (!quiet) {
          if (typeof payload.model === 'string' && payload.model.length > 0) bump(current.models, payload.model);
          if (workingDirectory) bump(current.folders, workingDirectory);
        }
      } else if (type === 'response_item') {
        if (payload.type === 'message') {
          if (!quiet && Array.isArray(payload.content)) {
            const texts = payload.content
              .filter((item) => (item?.type === 'input_text' || item?.type === 'output_text') && typeof item.text === 'string')
              .map((item) => item.text);
            if (payload.role === 'user') {
              const requests = texts.map(classifyPrompt).filter(Boolean);
              if (requests.length > 0) {
                if (requests.every((request) => request.kind === 'scheduled')) {
                  current.scheduledRuns += 1;
                } else {
                  current.prompts += 1;
                  current.promptWords += requests.reduce((sum, request) => sum + request.words, 0);
                  if (requests.some((request) => request.kind === 'command')) current.slashCommands += 1;
                }
              }
            } else if (payload.role === 'assistant' && texts.some((text) => text.trim().length > 0)) {
              current.replies += 1;
            }
          }
        } else if (payload.type === 'function_call' || payload.type === 'custom_tool_call' || payload.type === 'local_shell_call') {
          current.toolCalls += 1;
          const name = payload.type === 'local_shell_call' ? 'shell' : payload.name;
          bump(current.tools, toolLabel(name));
          const body = payload.arguments ?? payload.input;
          if (typeof body === 'string') {
            for (const match of body.matchAll(PATCHED_FILE)) {
              asked.edits += 1;
              addFile(collector, match[1].trim(), workingDirectory);
            }
            const command = shellCommandFromBody(body);
            if (command) mergeActions(asked.actions, actionsInCommand(command));
          }
          const argv = payload.action?.command;
          if (argv) mergeActions(asked.actions, actionsInCommand(argv));
        }
      } else if (type === 'event_msg' && payload.type === 'item_completed' && payload.item) {
        const item = payload.item;
        if (item.type === 'CommandExecution') {
          done.commands = true;
          mergeActions(done.actions, actionsInCommand(item.command));
        } else if (item.type === 'FileChange' && item.changes && typeof item.changes === 'object') {
          done.changes = true;
          for (const file of Object.keys(item.changes)) {
            done.edits += 1;
            addFile(collector, file, workingDirectory);
          }
        } else if (item.type === 'CollabAgentToolCall' && !quiet && typeof item.tool === 'string' && /spawn/i.test(item.tool)) {
          current.subagentCalls += 1;
        }
      }
    }

    if (!session) return;
    const used = totals.token_count.seen ? totals.token_count : totals.token_usage_record;
    session.tokens.input += used.input;
    session.tokens.cached += used.cached;
    session.tokens.output += used.output;
    for (const [model, tokens] of modelShares(used)) addModelTokens(session, model, tokens);
    addActions(session, done.commands ? done.actions : asked.actions);
    session.edits += done.changes ? done.edits : asked.edits;
  }

  function parsePiJsonl(lines, filePath, collector, yearsSeen) {
    const normalized = String(filePath || '').replaceAll('\\', '/');
    const agent = /(?:^|\/)\.omp\//i.test(normalized) ? 'omp' : 'pi';
    const stem = stemOfPath(normalized);
    const uuidMatch = UUID_SUFFIX.exec(stem);
    let sessionId = uuidMatch ? uuidMatch[0] : stem;
    let session = null;
    let cwd = null;
    let currentModel = null;
    const tally = emptyActions();

    const admit = (id) => {
      if (typeof id !== 'string' || id.length === 0) return true;
      const key = `${agent}:${id}`;
      if (collector.seenRecords.has(key)) return false;
      collector.seenRecords.add(key);
      return true;
    };

    for (const rawLine of lines) {
      const trimmed = rawLine.trim();
      if (!trimmed) continue;
      let record;
      try {
        record = JSON.parse(trimmed);
      } catch {
        continue;
      }
      const type = record?.type;
      if (type === 'session') {
        if (typeof record.id === 'string' && record.id.length > 0 && !session) sessionId = record.id;
        if (typeof record.cwd === 'string' && record.cwd.length > 0) cwd = record.cwd;
        continue;
      }
      if (type === 'model_change') {
        const model = nonEmptyString(record.modelId) ?? nonEmptyString(record.model);
        if (model) currentModel = model;
        continue;
      }
      if (type !== 'message') continue;
      const message = record.message;
      if (!message || typeof message !== 'object') continue;
      const at = typeof record.timestamp === 'string' ? Date.parse(record.timestamp) : (typeof message.timestamp === 'number' ? message.timestamp : NaN);
      if (Number.isFinite(at)) yearsSeen.add(new Date(at).getFullYear());
      if (!collector.inWindow(at) || !admit(record.id)) continue;

      session ??= collector.session(agent, sessionId);
      session.times.push(at);
      if (cwd) bump(session.folders, cwd);

      if (message.role === 'user') {
        const request = classifyPrompt(extractTextContent(message.content));
        if (request) {
          if (request.kind === 'scheduled') session.scheduledRuns += 1;
          else {
            session.prompts += 1;
            session.promptWords += request.words;
            if (request.kind === 'command') session.slashCommands += 1;
            if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
          }
        }
      } else if (message.role === 'assistant') {
        const model = nonEmptyString(message.model) ?? currentModel;
        if (model) bump(session.models, model);
        const usage = message.usage;
        if (usage && typeof usage === 'object') {
          const uncached = positiveNum(usage.input);
          const cacheRead = positiveNum(usage.cacheRead);
          const cacheWrite = positiveNum(usage.cacheWrite);
          const output = positiveNum(usage.output);
          const input = uncached + cacheRead + cacheWrite;
          if (input > 0 || output > 0) {
            session.tokens.input += input;
            session.tokens.cached += cacheRead;
            session.tokens.output += output;
            addModelTokens(session, model, { input, cached: cacheRead, cacheWrite, output });
          }
        }
        if (Array.isArray(message.content)) {
          let countedReply = false;
          for (const block of message.content) {
            if (!block || typeof block !== 'object') continue;
            if (block.type === 'text' && !countedReply && typeof block.text === 'string' && block.text.trim().length > 0) {
              session.replies += 1;
              countedReply = true;
            } else if (block.type === 'toolCall' || block.type === 'tool_use') {
              const name = typeof block.name === 'string' ? block.name : '';
              let args = block.arguments ?? block.input ?? {};
              if (typeof args === 'string' && args.startsWith('{')) {
                try {
                  args = JSON.parse(args);
                } catch {
                  args = {};
                }
              }
              session.toolCalls += 1;
              bump(session.tools, toolLabel(name));
              if (PI_EDIT_TOOLS.has(name)) {
                session.edits += 1;
                addFile(collector, args.path ?? args.file_path ?? args.filePath, cwd);
              } else if (PI_SHELL_TOOLS.has(name)) {
                const command = args.command ?? args.cmd;
                if (typeof command === 'string' || Array.isArray(command)) mergeActions(tally, actionsInCommand(command));
              } else if (PI_SUBAGENT_TOOLS.has(name)) {
                session.subagentCalls += 1;
              }
            }
          }
        }
      }
    }

    if (session) addActions(session, tally);
  }

  function parseGeminiJson(data, filePath, collector, yearsSeen) {
    if (!data || typeof data !== 'object' || !Array.isArray(data.messages)) return;
    const id = nonEmptyString(data.sessionId) ?? stemOfPath(filePath);
    let session = null;
    const tally = emptyActions();

    for (const msg of data.messages) {
      if (!msg || typeof msg !== 'object') continue;
      const at = Date.parse(msg.timestamp);
      if (Number.isFinite(at)) yearsSeen.add(new Date(at).getFullYear());
      if (!collector.inWindow(at)) continue;

      session ??= collector.session('gemini-cli', id);
      session.times.push(at);
      if (msg.type === 'user') {
        const request = classifyPrompt(extractTextContent(msg.content));
        if (request) {
          if (request.kind === 'scheduled') session.scheduledRuns += 1;
          else {
            session.prompts += 1;
            session.promptWords += request.words;
            if (request.kind === 'command') session.slashCommands += 1;
            if (request.kind === 'terminal') mergeActions(tally, actionsInCommand(request.command));
          }
        }
      } else if (msg.type === 'gemini') {
        const model = nonEmptyString(msg.model);
        if (model) bump(session.models, model);
        if (extractTextContent(msg.content).trim().length > 0) session.replies += 1;
        const t = msg.tokens;
        if (t && typeof t === 'object') {
          const input = positiveNum(t.input);
          const cached = Math.min(input, positiveNum(t.cached));
          const output = positiveNum(t.output) + positiveNum(t.thoughts);
          if (input > 0 || output > 0) {
            session.tokens.input += input;
            session.tokens.cached += cached;
            session.tokens.output += output;
            addModelTokens(session, model, { input, cached, cacheWrite: 0, output });
          }
        }
        if (Array.isArray(msg.toolCalls)) {
          for (const tc of msg.toolCalls) {
            if (!tc || typeof tc !== 'object') continue;
            const tcAt = Date.parse(tc.timestamp);
            if (collector.inWindow(tcAt)) session.times.push(tcAt);
            const name = typeof tc.name === 'string' ? tc.name : '';
            const args = tc.args && typeof tc.args === 'object' ? tc.args : {};
            session.toolCalls += 1;
            bump(session.tools, toolLabel(name));
            if (GEMINI_EDIT_TOOLS.has(name)) {
              session.edits += 1;
              addFile(collector, args.file_path ?? args.path, null);
            } else if (GEMINI_SHELL_TOOLS.has(name)) {
              const command = args.command ?? args.cmd;
              if (typeof command === 'string' || Array.isArray(command)) mergeActions(tally, actionsInCommand(command));
            } else if (GEMINI_SUBAGENT_TOOLS.has(name)) {
              session.subagentCalls += 1;
            }
          }
        }
      }
    }
    if (session) addActions(session, tally);
  }

  function detectJsonlFormat(lines) {
    for (let i = 0; i < Math.min(lines.length, 30); i += 1) {
      const trimmed = lines[i].trim();
      if (!trimmed || !trimmed.startsWith('{')) continue;
      try {
        const record = JSON.parse(trimmed);
        if (!record || typeof record !== 'object') continue;
        if (record.type === 'session_meta' || record.type === 'turn_context' || record.type === 'response_item' || record.type === 'token_usage_record') {
          return 'codex';
        }
        if (record.type === 'session' || record.type === 'model_change' || (record.type === 'message' && record.message && typeof record.message === 'object')) {
          return 'pi';
        }
        if ((record.type === 'user' || record.type === 'assistant') && record.message) {
          return 'claude';
        }
      } catch {
      }
    }
    return 'claude';
  }

  function applyStatsCacheEntries(caches, year, collector) {
    const calendar = newCalendar(year);
    const hasMatchingDays = caches.some((cache) => Array.isArray(cache.dailyActivity) && cache.dailyActivity.some((entry) => typeof entry?.date === 'string' && entry.date.startsWith(`${year}-`)));
    if (!hasMatchingDays) return false;

    const hourWeights = new Float64Array(24);
    let totalWeight = 0;
    for (const cache of caches) {
      if (cache.hourCounts && typeof cache.hourCounts === 'object') {
        for (const [hourKey, val] of Object.entries(cache.hourCounts)) {
          const h = Number(hourKey);
          const count = positiveNum(val);
          if (Number.isInteger(h) && h >= 0 && h < 24 && count > 0) {
            hourWeights[h] += count;
            totalWeight += count;
          }
        }
      }
    }
    let peakHour = 14;
    if (totalWeight > 0) {
      let best = -1;
      for (let h = 0; h < 24; h += 1) {
        if (hourWeights[h] > best) {
          best = hourWeights[h];
          peakHour = h;
        }
      }
    }

    const dailyTokens = new Map();
    const aggregateModelUsage = new Map();
    for (const cache of caches) {
      if (Array.isArray(cache.dailyModelTokens)) {
        for (const row of cache.dailyModelTokens) {
          if (typeof row?.date !== 'string' || !row.date.startsWith(`${year}-`) || !row.tokensByModel || typeof row.tokensByModel !== 'object') continue;
          const bucket = dailyTokens.get(row.date) ?? new Map();
          for (const [model, count] of Object.entries(row.tokensByModel)) {
            const n = positiveNum(count);
            if (n > 0) bucket.set(model, (bucket.get(model) ?? 0) + n);
          }
          dailyTokens.set(row.date, bucket);
        }
      }
      if (cache.modelUsage && typeof cache.modelUsage === 'object') {
        for (const [model, usage] of Object.entries(cache.modelUsage)) {
          if (!usage || typeof usage !== 'object') continue;
          const prev = aggregateModelUsage.get(model) ?? { input: 0, cached: 0, cacheWrite: 0, output: 0 };
          prev.input += positiveNum(usage.inputTokens) + positiveNum(usage.cacheReadInputTokens) + positiveNum(usage.cacheCreationInputTokens);
          prev.cached += positiveNum(usage.cacheReadInputTokens);
          prev.cacheWrite += positiveNum(usage.cacheCreationInputTokens);
          prev.output += positiveNum(usage.outputTokens);
          aggregateModelUsage.set(model, prev);
        }
      }
    }

    let synthIndex = 0;
    let tokensAttributed = false;
    for (const cache of caches) {
      if (!Array.isArray(cache.dailyActivity)) continue;
      for (const entry of cache.dailyActivity) {
        if (typeof entry?.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(entry.date)) continue;
        const [y, m, d] = entry.date.split('-').map(Number);
        if (y !== year) continue;
        const sessionsCount = Math.max(1, positiveNum(entry.sessionCount));
        const toolCalls = positiveNum(entry.toolCallCount);
        const messages = positiveNum(entry.messageCount);
        if (sessionsCount === 0 && toolCalls === 0 && messages === 0) continue;
        collector.cacheMessages = (collector.cacheMessages ?? 0) + messages;

        const estMinutes = Math.min(480, Math.max(15, Math.round(sessionsCount * 20 + toolCalls * 0.45 + messages * 0.3)));
        const baseDate = new Date(year, m - 1, d, peakHour, 0, 0, 0).getTime();
        const perSessionMin = Math.max(6, Math.round(estMinutes / sessionsCount));
        const dayModelMap = dailyTokens.get(entry.date);

        for (let s = 0; s < sessionsCount; s += 1) {
          synthIndex += 1;
          const session = collector.session('claude-code', `cache-${entry.date}-${synthIndex}`);
          const start = Math.min(collector.end - 2 * MINUTE, Math.max(collector.start, baseDate + s * 15 * MINUTE));
          const steps = Math.max(2, Math.ceil(perSessionMin / 4));
          for (let step = 0; step <= steps; step += 1) {
            const stamp = Math.min(collector.end - 1000, start + step * 4 * MINUTE);
            session.times.push(stamp);
          }
          session.replies = 1;
          if (s === 0) {
            session.toolCalls = toolCalls;
            if (dayModelMap && dayModelMap.size > 0) {
              tokensAttributed = true;
              for (const [model, totalTok] of dayModelMap) {
                const input = Math.round(totalTok * 0.94);
                const cached = Math.round(input * 0.85);
                const output = Math.max(1, totalTok - input);
                session.tokens.input += input;
                session.tokens.cached += cached;
                session.tokens.output += output;
                bump(session.models, model, sessionsCount);
                addModelTokens(session, model, { input, cached, cacheWrite: 0, output });
              }
            }
          }
        }
      }
    }

    if (!tokensAttributed && aggregateModelUsage.size > 0 && collector.sessions.size > 0) {
      const firstSession = collector.sessions.values().next().value;
      for (const [model, usage] of aggregateModelUsage) {
        firstSession.tokens.input += usage.input;
        firstSession.tokens.cached += usage.cached;
        firstSession.tokens.output += usage.output;
        bump(firstSession.models, model, Math.max(1, firstSession.prompts));
        addModelTokens(firstSession, model, usage);
      }
    }
    return calendar.days > 0 && collector.sessions.size > 0;
  }

  function runLocalPass(entries, year) {
    const window = yearWindow(year);
    const collector = createCollector(window);
    const summaryDays = new Map();
    const caches = [];
    const yearsSeen = new Set();

    for (const entry of entries) {
      const name = String(entry.name || '');
      const fullPath = String(entry.path || name);
      const text = typeof entry.text === 'string' ? entry.text : '';
      const bytes = typeof entry.size === 'number' ? entry.size : text.length;
      if (!text.trim()) continue;

      if (name.endsWith('.json')) {
        let parsed;
        try {
          parsed = JSON.parse(text);
        } catch {
          collector.unreadableFiles += 1;
          continue;
        }
        collector.filesRead += 1;
        collector.bytesRead += bytes;
        if (Array.isArray(parsed?.dailyActivity)) {
          caches.push(parsed);
          for (const item of parsed.dailyActivity) {
            if (typeof item?.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(item.date)) continue;
            const y = Number(item.date.slice(0, 4));
            if (Number.isInteger(y)) yearsSeen.add(y);
            const day = summaryDays.get(item.date) ?? { sessions: 0, toolCalls: 0 };
            day.sessions += positiveNum(item.sessionCount);
            day.toolCalls += positiveNum(item.toolCallCount);
            summaryDays.set(item.date, day);
          }
        } else if (Array.isArray(parsed?.messages)) {
          parseGeminiJson(parsed, fullPath, collector, yearsSeen);
        }
      } else if (name.endsWith('.jsonl') || name.endsWith('.ndjson')) {
        const lines = text.split(/\r?\n/);
        collector.filesRead += 1;
        collector.bytesRead += bytes;
        const kind = detectJsonlFormat(lines);
        if (kind === 'codex') parseCodexJsonl(lines, fullPath, collector, yearsSeen);
        else if (kind === 'pi') parsePiJsonl(lines, fullPath, collector, yearsSeen);
        else parseClaudeJsonl(lines, fullPath, collector, yearsSeen);
      }
    }

    let cacheOnly = false;
    if (collector.sessions.size === 0 && caches.length > 0) {
      cacheOnly = applyStatsCacheEntries(caches, year, collector);
    }

    const result = computeStats(collector, {
      year,
      generatedAt: new Date(),
      summaryDays: cacheOnly ? new Map() : summaryDays,
    });
    result.stats.cacheOnly = cacheOnly;
    if (cacheOnly) result.stats.cacheMessages = collector.cacheMessages ?? 0;
    return { result, yearsSeen: [...yearsSeen].sort((a, b) => b - a), cacheOnly };
  }

  function parseLocalEntries(entries, { year = 2026 } = {}) {
    let pass = runLocalPass(entries, year);
    let resolvedYear = year;
    if (pass.result.stats.totals.sessions === 0 && pass.result.stats.totals.tokens.total === 0 && pass.yearsSeen.length > 0) {
      const candidate = pass.yearsSeen[0];
      if (candidate !== year) {
        pass = runLocalPass(entries, candidate);
        resolvedYear = candidate;
      }
    }
    return {
      data: pass.result,
      year: resolvedYear,
      yearsAvailable: pass.yearsSeen,
      cacheOnly: pass.cacheOnly,
    };
  }

  function cardDimensions(layout) {
    return layout === 'wide' ? { width: 1600, height: 900 } : { width: 1200, height: 1500 };
  }

  function activeDaySpan(byDay) {
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

  function defaultWindowMode(stats) {
    const { span } = activeDaySpan(stats.byDay);
    return span >= 3 && span <= 45 ? 'active' : 'year';
  }

  function canZoomWindow(stats) {
    const { span } = activeDaySpan(stats.byDay);
    return span >= 3 && span <= 90;
  }

  function svgEscape(value) {
    return String(value)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  }

  function svgRound(value) {
    return Math.round(value * 100) / 100;
  }

  function svgFit(value, size, maxWidth, em) {
    const natural = value.length * size * em;
    return natural <= maxWidth ? size : Math.max(13, Math.floor(maxWidth / Math.max(1, value.length * em)));
  }

  function svgText(x, y, value, { family, size, fill, weight, anchor, italic, spacing } = {}) {
    const attributes = [`x="${x}"`, `y="${y}"`, `class="${family}"`, `font-size="${size}"`, `fill="${fill}"`];
    if (spacing !== undefined) attributes.push(`letter-spacing="${spacing}"`);
    if (weight) attributes.push(`font-weight="${weight}"`);
    if (anchor) attributes.push(`text-anchor="${anchor}"`);
    if (italic) attributes.push('font-style="italic"');
    return `<text ${attributes.join(' ')}>${svgEscape(value)}</text>`;
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
    const value = ms / HOUR;
    return value >= 10 ? cardNumber(value) : String(Math.round(value * 10) / 10);
  }

  function cardDuration(ms) {
    const minutes = Math.round(ms / MINUTE);
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

  function truncateText(text, maxChars) {
    if (text.length <= maxChars) return text;
    return `${text.slice(0, maxChars - 1)}…`;
  }

  function headerAgentLine(agents) {
    if (!Array.isArray(agents) || agents.length === 0) return '';
    if (agents.length <= 4) return agents.map((agent) => agent.name).join(' · ');
    return `${agents.slice(0, 4).map((agent) => agent.name).join(' · ')} · +${agents.length - 4}`;
  }

  function resolveRange(data, windowOption) {
    const totalDays = data.days;
    const mode = windowOption === 'auto'
      ? defaultWindowMode(data.stats)
      : (windowOption === 'active' ? 'active' : 'year');
    if (mode !== 'active') return { start: 0, end: totalDays - 1, zoomed: false };
    const { first, last, span } = activeDaySpan(data.stats.byDay);
    if (first === -1 || span > 90) return { start: 0, end: totalDays - 1, zoomed: false };
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
    const parallelText = !stats.cacheOnly && (totals.parallelMultiplier ?? 1) >= 1.2
      ? `${daysText} · ${cardMultiplier(totals.parallelMultiplier)} parallel`
      : `${daysText} active`;
    tiles.push({
      label: stats.cacheOnly ? 'EST. AGENT WORK' : 'AGENT WORK',
      value: stats.cacheOnly ? `~${hrs} h` : `${hrs} h`,
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
        sub: stats.longestRun && !stats.cacheOnly ? `Longest ${cardDuration(stats.longestRun.ms)}` : 'Logged locally',
      });
    }

    const toolDisplay = totals.toolCalls >= 100000 ? cardCompact(totals.toolCalls) : cardNumber(totals.toolCalls);
    tiles.push({
      label: 'TOOL CALLS',
      value: toolDisplay,
      sub: stats.cacheOnly
        ? cardPlural(stats.cacheMessages ?? 0, 'message')
        : `${cardNumber(totals.requests)} ${totals.requests === 1 ? 'request' : 'requests'}`,
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
      family: 'mono', size: labelSize, fill: tile.highlight ? pal.teal : pal.faint, weight: 700, spacing: 1.2,
    }));
    parts.push(svgText(x + padX, y + Math.round(h * 0.62), tile.value, {
      family: 'sans', size: svgFit(tile.value, valueSize, maxW, 0.58), fill: valFill, weight: 800, spacing: -1.1,
    }));
    parts.push(svgText(x + padX, y + h - 20, tile.sub, {
      family: 'sans', size: svgFit(tile.sub, subSize, maxW, CARD_SANS_EM), fill: pal.dim, weight: 500,
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
        family: 'mono', size, fill: pal.tealBright, weight: 700, spacing, anchor: 'middle',
      }),
    ];
  }

  function dailyActivity(data) {
    const byDay = data.stats?.byDay;
    if (Array.isArray(byDay) && byDay.length === data.days) return byDay;
    const totals = new Float64Array(data.days);
    for (let day = 0; day < data.days; day += 1) {
      let sum = 0;
      for (let hour = 0; hour < 24; hour += 1) sum += data.grid[day * 24 + hour] ?? 0;
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
    const p88 = nonZero.length > 0 ? nonZero[Math.min(nonZero.length - 1, Math.floor(nonZero.length * 0.88))] : 4 * HOUR;
    const scaleRef = Math.max(1.5 * HOUR, p88);
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
        family: 'mono', size: compact ? 13 : 14, fill: pal.faint, weight: 500,
      }));
    }

    for (const [dow, name] of [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']]) {
      const ly = svgRound(gridY + dow * step + cell * 0.76);
      parts.push(svgText(offsetX - 12, ly, name, {
        family: 'mono', size: compact ? 12 : 13, fill: pal.faint, anchor: 'end', weight: 500,
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
      if (isPeak) fill = pal.cellPeak;
      else if (ms > 0) fill = pal.ramp[levelFor(ms)];
      else if (!range.zoomed && earlierDays && earlierDays[day] > 0) fill = pal.cellEarlier;
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
      family: 'mono', size: compact ? 12 : 13, fill: pal.faint, anchor: 'end', weight: 500,
    }));
    legSwatches.forEach((fill, idx) => {
      const sx = swatchesStartX + idx * (legSize + legGap);
      parts.push(`<rect x="${sx}" y="${footerY - legSize + 2}" width="${legSize}" height="${legSize}" rx="3" fill="${fill}"/>`);
    });
    parts.push(svgText(moreLabelX, footerY, 'More', {
      family: 'mono', size: compact ? 12 : 13, fill: pal.faint, anchor: 'end', weight: 500,
    }));

    if (busiest) {
      const peakMaxW = Math.max(200, swatchesStartX - 58 - (x + padX));
      const approx = stats.cacheOnly ? '~' : '';
      const peakText = compact
        ? `Peak · ${cardDayLabel(busiest.date)} · ${approx}${cardHours(busiest.agentMs)}h (${cardPlural(busiest.sessions, 'session')})`
        : `Peak · ${cardDayLabel(busiest.date)} · ${approx}${cardHours(busiest.agentMs)} agent hours across ${cardPlural(busiest.sessions, 'session')}`;
      parts.push(`<circle cx="${x + padX + 6}" cy="${footerY - 5}" r="5" fill="${pal.cellPeak}"/>`);
      parts.push(svgText(x + padX + 20, footerY, peakText, {
        family: 'mono', size: svgFit(peakText, compact ? 14 : 16, peakMaxW, CARD_MONO_EM), fill: pal.amber, weight: 600,
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

  function drawDailyRhythm(data, pal, { x, y, width, height }) {
    const byHour = new Float64Array(24);
    for (let day = 0; day < data.days; day += 1) {
      for (let hour = 0; hour < 24; hour += 1) byHour[hour] += data.grid[day * 24 + hour] ?? 0;
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
    parts.push(svgText(x + padX, y + 32, 'DAILY RHYTHM', { family: 'mono', size: 13, fill: pal.faint, weight: 700, spacing: 1.2 }));
    if (maxMs > 0) {
      const peakLabel = `Most active around ${formatHourLabel(peakHour)}-${formatHourLabel((peakHour + 2) % 24)}`;
      parts.push(svgText(x + width - padX, y + 32, peakLabel, { family: 'mono', size: 14, fill: pal.dim, anchor: 'end', weight: 600 }));
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
      parts.push(svgText(lx, y + height - 16, lbl, { family: 'mono', size: 13, fill: pal.faint, anchor: 'middle', weight: 500 }));
    }
    return parts;
  }

  function drawTopModelsPortrait(models, pal, { x, y, width, height }) {
    const list = models.slice(0, 5);
    const maxTokens = Math.max(1, list[0]?.total ?? 1);
    const parts = [];
    const padX = 24;
    parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.4"/>`);
    parts.push(svgText(x + padX, y + 32, 'TOP MODELS', { family: 'mono', size: 13, fill: pal.faint, weight: 700, spacing: 1.2 }));
    parts.push(svgText(x + width - padX, y + 32, 'TOKENS', { family: 'mono', size: 13, fill: pal.faint, anchor: 'end', weight: 700, spacing: 1.2 }));
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
      const fillW = svgRound(Math.max(8, (model.total / maxTokens) * barW));
      const barFill = isTop ? pal.teal : (idx === 1 ? pal.ramp[2] : pal.slate);
      parts.push(svgText(x + padX, ry, `${idx + 1}`, { family: 'mono', size: 15, fill: isTop ? pal.teal : pal.faint, weight: 700 }));
      const label = truncateText(model.name, 28);
      parts.push(svgText(nameX, ry, label, { family: 'mono', size: svgFit(label, 17, nameMaxW, CARD_MONO_EM), fill: isTop ? pal.text : pal.dim, weight: isTop ? 700 : 600 }));
      parts.push(`<rect x="${barX}" y="${ry - 10}" width="${barW}" height="10" rx="5" fill="${pal.barTrack}"/>`);
      parts.push(`<rect x="${barX}" y="${ry - 10}" width="${fillW}" height="10" rx="5" fill="${barFill}"/>`);
      parts.push(svgText(x + width - padX, ry, cardCompact(model.total), { family: 'mono', size: 17, fill: isTop ? pal.tealBright : pal.text, anchor: 'end', weight: 700 }));
    });
    return parts;
  }

  function drawTopModelsWide(models, pal, { x, y, width, height }) {
    const list = models.slice(0, 5);
    const maxTokens = Math.max(1, list[0]?.total ?? 1);
    const parts = [];
    const padX = 22;
    parts.push(`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="16" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.4"/>`);
    parts.push(svgText(x + padX, y + 26, 'TOP MODELS', { family: 'mono', size: 12, fill: pal.faint, weight: 700, spacing: 1.2 }));
    parts.push(svgText(x + width - padX, y + 26, 'TOTAL TOKENS', { family: 'mono', size: 12, fill: pal.faint, anchor: 'end', weight: 700, spacing: 1.2 }));
    const gap = 14;
    const innerW = width - padX * 2;
    const cols = list.length;
    const colW = Math.floor((innerW - gap * (cols - 1)) / cols);
    const slotY = y + 38;
    const slotH = height - 50;
    list.forEach((model, idx) => {
      const cx = x + padX + idx * (colW + gap);
      const isTop = idx === 0;
      const slotFill = isTop ? pal.surfaceHi : pal.ground;
      const slotStroke = isTop ? pal.borderHi : pal.border;
      const barFill = isTop ? pal.teal : (idx === 1 ? pal.ramp[2] : pal.slate);
      parts.push(`<rect x="${cx}" y="${slotY}" width="${colW}" height="${slotH}" rx="10" fill="${slotFill}" stroke="${slotStroke}" stroke-width="1.1"/>`);
      const labelText = `#${idx + 1} ${truncateText(model.name, cols >= 5 ? 21 : 28)}`;
      parts.push(svgText(cx + 14, slotY + 25, labelText, { family: 'mono', size: svgFit(labelText, 14, colW - 28, CARD_MONO_EM), fill: isTop ? pal.tealBright : pal.dim, weight: isTop ? 700 : 600 }));
      parts.push(svgText(cx + 14, slotY + 53, cardCompact(model.total), { family: 'sans', size: 23, fill: pal.text, weight: 800, spacing: -0.5 }));
      const barMaxW = colW - 28;
      const barW = svgRound(Math.max(8, (model.total / maxTokens) * barMaxW));
      parts.push(`<rect x="${cx + 14}" y="${slotY + slotH - 12}" width="${barMaxW}" height="5" rx="2.5" fill="${pal.barTrack}"/>`);
      parts.push(`<rect x="${cx + 14}" y="${slotY + slotH - 12}" width="${barW}" height="5" rx="2.5" fill="${barFill}"/>`);
    });
    return parts;
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
      if (otherShare >= 0.005 || segments.length < 2) segments.push({ name: 'Other', share: otherShare, color: pal.slate });
    }
    if (segments.length < 2) return [];
    const sumShare = segments.reduce((sum, seg) => sum + seg.share, 0) || 1;
    const rawPcts = segments.map((seg) => (seg.share / sumShare) * 100);
    const pcts = rawPcts.map((value) => Math.floor(value));
    const remainder = 100 - pcts.reduce((sum, p) => sum + p, 0);
    const order = rawPcts.map((value, idx) => ({ idx, frac: value - pcts[idx] })).sort((a, b) => b.frac - a.frac);
    for (let i = 0; i < remainder && i < order.length; i += 1) pcts[order[i].idx] += 1;

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
      parts.push(svgText(svgRound(lx + dotBlock), ly, label, { family: 'mono', size, fill: idx === 0 ? pal.text : pal.dim, weight: idx === 0 ? 700 : 600 }));
      lx += dotBlock + label.length * size * CARD_MONO_EM + itemGap;
    });
    return parts;
  }

  function cardFactLines(stats, { showApiValue = true } = {}) {
    const { totals } = stats;
    const worked = cardHours(totals.agentMs);
    const first = stats.cacheOnly
      ? [
        [`~${worked}`, true],
        [worked === '1' ? ' estimated hour of agent work on ' : ' estimated hours of agent work on '],
        [cardNumber(totals.activeDays), true],
        [totals.activeDays === 1 ? ' day' : ' days'],
      ]
      : [
        [worked, true],
        [worked === '1' ? ' hour of agent work on ' : ' hours of agent work on '],
        [cardNumber(totals.activeDays), true],
        [totals.activeDays === 1 ? ' day' : ' days'],
      ];
    if (!stats.cacheOnly && (totals.parallelMultiplier ?? 1) >= 1.2) {
      first.push([' · '], [cardMultiplier(totals.parallelMultiplier), true], [' parallel']);
    }
    const lines = [
      first,
      stats.cacheOnly
        ? [[cardNumber(totals.sessions), true], [totals.sessions === 1 ? ' session, ' : ' sessions, '], [cardNumber(stats.cacheMessages ?? 0), true], [(stats.cacheMessages ?? 0) === 1 ? ' message, ' : ' messages, '], [cardNumber(totals.toolCalls), true], [' tool calls']]
        : [[cardNumber(totals.requests), true], [totals.requests === 1 ? ' request from you, ' : ' requests from you, '], [cardNumber(totals.toolCalls), true], [' tool calls from them']],
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
    } else if (stats.longestRun && !stats.cacheOnly) {
      lines.push([[cardNumber(totals.sessions), true], [totals.sessions === 1 ? ' session, the longest run ' : ' sessions, the longest run '], [cardDuration(stats.longestRun.ms), true]]);
    }
    return lines;
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
        family: 'mono', size: svgFit(agents, 18, inner - 290, CARD_MONO_EM), fill: pal.faint, anchor: 'end', weight: 600,
      }));
    }
    const titleSize = svgFit(stats.persona.title, 96, inner, 0.54);
    parts.push(svgText(MARGIN - 2, 204, stats.persona.title, { family: 'sans', size: titleSize, fill: pal.text, weight: 800, spacing: -2.2 }));
    parts.push(svgText(MARGIN, 252, stats.persona.line, { family: 'sans', size: svgFit(stats.persona.line, 25, inner, CARD_SANS_EM), fill: pal.dim, weight: 500 }));

    const tiles = buildKpiTiles(stats, { showApiValue });
    const gap = 20;
    const tileW = Math.floor((inner - gap) / 2);
    const tileH = 144;
    const gridY = 290;
    tiles.forEach((tile, idx) => {
      const col = idx % 2;
      const row = Math.floor(idx / 2);
      parts.push(...drawKpiTile(MARGIN + col * (tileW + gap), gridY + row * (tileH + gap), tileW, tileH, tile, pal, { valueSize: 50, labelSize: 14, subSize: 17 }));
    });

    const graphY = 610;
    const graphH = 252;
    parts.push(...drawContributionGraph(data, range, pal, { x: MARGIN, y: graphY, width: inner, height: graphH, compact: true }));

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
      parts.push(...drawTopModelsPortrait(topModels, pal, { x: MARGIN, y: nextY + 4, width: inner, height: middleH }));
    } else {
      parts.push(...drawDailyRhythm(data, pal, { x: MARGIN, y: nextY + 4, width: inner, height: middleH }));
    }

    const timed = stats.agents.filter((agent) => agent.agentMs > 0);
    if (timed.length > 1 && stats.totals.agentMs > 0) {
      const barY = Math.min(nextY + middleH + 38, 1252);
      parts.push(...drawAgentSplitBar(timed, stats.totals.agentMs, pal, { x: MARGIN, y: barY, width: inner, maxNamed: 4, fontSize: 18 }));
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
        family: 'mono', size: svgFit(agents, 17, inner - 270, CARD_MONO_EM), fill: pal.faint, anchor: 'end', weight: 600,
      }));
    }
    parts.push(`<line x1="${MARGIN}" y1="78" x2="${WIDTH - MARGIN}" y2="78" stroke="${pal.border}" stroke-width="1"/>`);

    const titleMaxW = 900;
    parts.push(svgText(MARGIN - 2, 150, stats.persona.title, {
      family: 'sans', size: svgFit(stats.persona.title, 62, titleMaxW, 0.54), fill: pal.text, weight: 800, spacing: -2.0,
    }));
    const subText = showProjects && stats.projects.length > 0
      ? `${stats.persona.line}  Most hours: ${stats.projects.slice(0, 3).map((p) => p.name).join(', ')}.`
      : stats.persona.line;
    parts.push(svgText(MARGIN, 186, subText, { family: 'sans', size: svgFit(subText, 20, titleMaxW, CARD_SANS_EM), fill: pal.dim, weight: 500 }));

    const timed = stats.agents.filter((agent) => agent.agentMs > 0);
    if (timed.length > 1 && stats.totals.agentMs > 0) {
      const barW = timed.length >= 3 ? 500 : 440;
      parts.push(...drawAgentSplitBar(timed, stats.totals.agentMs, pal, {
        x: WIDTH - MARGIN - barW, y: 136, width: barW, maxNamed: 3, fontSize: timed.length >= 3 ? 14 : 16,
      }));
    }

    const tiles = buildKpiTiles(stats, { showApiValue });
    const gap = 20;
    const tileW = Math.floor((inner - gap * (tiles.length - 1)) / tiles.length);
    tiles.forEach((tile, idx) => {
      parts.push(...drawKpiTile(MARGIN + idx * (tileW + gap), 212, tileW, 122, tile, pal, { valueSize: 42, labelSize: 13, subSize: 15 }));
    });

    const topModels = stats.topModels ?? [];
    const graphH = topModels.length > 0 ? 276 : 408;
    parts.push(...drawContributionGraph(data, range, pal, {
      x: MARGIN, y: 352, width: inner, height: graphH, compact: topModels.length > 0,
    }));
    if (topModels.length > 0) {
      parts.push(...drawTopModelsWide(topModels, pal, { x: MARGIN, y: 644, width: inner, height: 132 }));
    }

    parts.push(`<line x1="${MARGIN}" y1="798" x2="${WIDTH - MARGIN}" y2="798" stroke="${pal.border}" stroke-width="1"/>`);
    parts.push(`<rect x="${MARGIN}" y="820" width="184" height="44" rx="10" fill="${pal.surface}" stroke="${pal.border}" stroke-width="1.2"/>`);
    parts.push(svgText(MARGIN + 19, 848, 'npx lokalbot', { family: 'mono', size: 20, fill: pal.text, weight: 700 }));
    parts.push(svgText(MARGIN + 208, 848, 'Counted locally from session logs. Nothing was uploaded.', { family: 'sans', size: 18, fill: pal.faint, weight: 500 }));
    parts.push(svgText(WIDTH - MARGIN, 848, 'lokalbot.com/wrapped', { family: 'mono', size: 21, fill: pal.tealBright, anchor: 'end', weight: 700 }));
    return wrapSvg(WIDTH, HEIGHT, stats, showApiValue, parts);
  }

  function renderCardSvg(data, options = {}) {
    const layout = options.layout === 'wide' ? 'wide' : 'portrait';
    const theme = options.theme === 'light' ? 'light' : 'dark';
    const resolved = { ...options, theme };
    return layout === 'wide' ? renderWideCard(data, resolved) : renderPortraitCard(data, resolved);
  }

  function cardShareCaption(stats, { showApiValue = true } = {}) {
    const { totals } = stats;
    const bits = stats.cacheOnly
      ? [`~${cardHours(totals.agentMs)} estimated agent hours on ${cardPlural(totals.activeDays, 'day')}`, cardPlural(totals.sessions, 'session'), cardPlural(stats.cacheMessages ?? 0, 'message')]
      : [`${cardHours(totals.agentMs)} agent hours on ${cardPlural(totals.activeDays, 'day')}`];
    if (!stats.cacheOnly && (totals.parallelMultiplier ?? 1) >= 1.2) bits[0] += ` (${cardMultiplier(totals.parallelMultiplier)} parallel)`;
    if (totals.toolCalls > 0) bits.push(`${cardNumber(totals.toolCalls)} tool calls`);
    if (showApiValue && (totals.estimatedApiUsd ?? 0) >= 10) bits.push(`~${cardCurrency(totals.estimatedApiUsd)} API value`);
    if (totals.commits > 0) bits.push(cardPlural(totals.commits, 'commit'));
    return `My ${stats.year} Agent Wrapped: ${stats.persona.title}\n${bits.join(' · ')}\n\nRun yours locally (zero uploads): npx lokalbot\nhttps://www.lokalbot.com/wrapped`;
  }

  function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function detectVisitorOs() {
    if (typeof navigator === 'undefined') return 'darwin';
    const ua = navigator.userAgent || '';
    const plat = (navigator.userAgentData && navigator.userAgentData.platform) || '';
    if (/Win/i.test(plat) || /Windows NT/i.test(ua)) return 'win32';
    if (/Linux/i.test(plat) || (/Linux|X11/i.test(ua) && !/Android/i.test(ua))) return 'linux';
    return 'darwin';
  }

  function copyString(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).then(() => true, () => legacyCopy(text));
    }
    return Promise.resolve(legacyCopy(text));
  }

  function legacyCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, text.length);
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch {
    }
    document.body.removeChild(ta);
    return ok;
  }

  async function collectDroppedFiles(dataTransfer) {
    const collected = [];
    const items = dataTransfer?.items ? Array.from(dataTransfer.items) : [];
    const hasEntries = items.some((item) => typeof item.webkitGetAsEntry === 'function');
    if (hasEntries) {
      const walk = (entry, prefix) => new Promise((resolve) => {
        if (!entry) {
          resolve();
          return;
        }
        if (entry.isFile) {
          entry.file((file) => {
            collected.push({ file, path: prefix ? `${prefix}/${file.name}` : file.name });
            resolve();
          }, () => resolve());
        } else if (entry.isDirectory) {
          const reader = entry.createReader();
          const allChildren = [];
          const readBatch = () => {
            reader.readEntries((batch) => {
              if (!batch.length) {
                Promise.all(allChildren.map((child) => walk(child, prefix ? `${prefix}/${entry.name}` : entry.name))).then(() => resolve());
                return;
              }
              allChildren.push(...batch);
              readBatch();
            }, () => resolve());
          };
          readBatch();
        } else {
          resolve();
        }
      });
      await Promise.all(items.map((item) => walk(item.webkitGetAsEntry(), '')));
      return collected;
    }
    const files = dataTransfer?.files ? Array.from(dataTransfer.files) : [];
    return files.map((file) => ({ file, path: file.webkitRelativePath || file.name }));
  }

  function initUI() {
    const stage = document.getElementById('wrapped-stage');
    if (!stage) return;

    const samples = buildSampleProfiles(2026);
    const profiles = new Map(samples.map((item) => [item.id, item]));
    let localProfile = null;
    let cachedEntries = null;
    let importGeneration = 0;

    const prefersLight = typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches;
    const state = {
      profileId: samples[0].id,
      layout: 'portrait',
      theme: prefersLight ? 'light' : 'dark',
      window: 'auto',
      showApiValue: true,
      showProjects: false,
      year: 2026,
    };

    const stageWrap = document.getElementById('wrapped-stage-wrap');
    const profileBar = document.getElementById('wrapped-profiles');
    const windowGroup = document.getElementById('wrapped-window-group');
    const toggleApiWrap = document.getElementById('wrapped-toggle-api-wrap');
    const toggleApi = document.getElementById('wrapped-toggle-api');
    const toggleProjectsWrap = document.getElementById('wrapped-toggle-projects-wrap');
    const toggleProjects = document.getElementById('wrapped-toggle-projects');
    const saveBtn = document.getElementById('wrapped-save-png');
    const copyImgBtn = document.getElementById('wrapped-copy-png');
    const copyCaptionBtn = document.getElementById('wrapped-copy-caption');
    const postXBtn = document.getElementById('wrapped-post-x');
    const actionStatus = document.getElementById('wrapped-action-status');
    const captionPreview = document.getElementById('wrapped-caption-preview');
    const dropzone = document.getElementById('wrapped-dropzone');
    const fileInput = document.getElementById('wrapped-file-input');
    const dirInput = document.getElementById('wrapped-dir-input');
    const pickFilesBtn = document.getElementById('wrapped-pick-files');
    const pickDirBtn = document.getElementById('wrapped-pick-dir');
    const yearSelect = document.getElementById('wrapped-year-select');
    const dropStatus = document.getElementById('wrapped-drop-status');
    const clearBtn = document.getElementById('wrapped-clear-local');

    function currentProfile() {
      if (state.profileId === 'local' && localProfile) return localProfile;
      return profiles.get(state.profileId) ?? samples[0];
    }

    function renderProfileButtons() {
      if (!profileBar) return;
      const items = localProfile ? [localProfile, ...samples] : samples;
      profileBar.innerHTML = '';
      for (const item of items) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = item.id === 'local' ? 'wrapped-profile-btn wrapped-profile-btn--local' : 'wrapped-profile-btn';
        btn.dataset.sampleProfile = item.id;
        btn.setAttribute('aria-pressed', String(state.profileId === item.id));
        const title = document.createElement('strong');
        title.textContent = item.label;
        const sub = document.createElement('span');
        sub.textContent = item.hint;
        btn.appendChild(title);
        btn.appendChild(sub);
        btn.addEventListener('click', () => {
          state.profileId = item.id;
          state.window = defaultWindowMode(item.data.stats);
          update();
          if (actionStatus) actionStatus.textContent = '';
        });
        profileBar.appendChild(btn);
      }
    }

    function update() {
      const active = currentProfile();
      const data = active.data;
      const stats = data.stats;
      const zoomAvailable = canZoomWindow(stats);
      const resolvedWindow = zoomAvailable
        ? (state.window === 'auto' ? defaultWindowMode(stats) : state.window)
        : 'year';

      if (stageWrap) stageWrap.classList.toggle('is-wide', state.layout === 'wide');
      stage.innerHTML = renderCardSvg(data, {
        layout: state.layout,
        theme: state.theme,
        window: resolvedWindow,
        showApiValue: state.showApiValue,
        showProjects: state.showProjects,
      });

      for (const btn of document.querySelectorAll('[data-wrapped-layout]')) {
        btn.setAttribute('aria-pressed', String(btn.dataset.wrappedLayout === state.layout));
      }
      for (const btn of document.querySelectorAll('[data-wrapped-theme]')) {
        btn.setAttribute('aria-pressed', String(btn.dataset.wrappedTheme === state.theme));
      }
      if (windowGroup) {
        windowGroup.hidden = !zoomAvailable;
        for (const btn of windowGroup.querySelectorAll('[data-wrapped-window]')) {
          btn.setAttribute('aria-pressed', String(btn.dataset.wrappedWindow === resolvedWindow));
        }
      }
      if (toggleApiWrap) toggleApiWrap.hidden = (stats.totals.estimatedApiUsd ?? 0) < 10;
      if (toggleProjectsWrap) toggleProjectsWrap.hidden = (stats.projects?.length ?? 0) === 0;
      for (const btn of document.querySelectorAll('[data-sample-profile]')) {
        btn.setAttribute('aria-pressed', String(btn.dataset.sampleProfile === active.id));
      }

      const caption = cardShareCaption(stats, { showApiValue: state.showApiValue });
      if (postXBtn) postXBtn.href = `https://x.com/intent/tweet?text=${encodeURIComponent(caption)}`;
      if (captionPreview) captionPreview.textContent = caption;
    }

    async function renderPngBlob() {
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
        canvas.width = dims.width * 2;
        canvas.height = dims.height * 2;
        canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
        return await new Promise((resolve, reject) => {
          canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('png failed'))), 'image/png');
        });
      } finally {
        URL.revokeObjectURL(objectUrl);
      }
    }

    async function handleFileRecords(records, generation = ++importGeneration) {
      if (generation !== importGeneration) return;
      const supported = records.filter(({ file }) => /\.(json|jsonl|ndjson)$/i.test(file.name));
      if (supported.length === 0) {
        if (dropStatus) {
          dropStatus.textContent = 'No .json or .jsonl files found in that selection. Drop Claude Code stats-cache.json, Claude/Codex/Pi .jsonl logs, or Gemini CLI session JSON files.';
        }
        return;
      }
      const readable = supported.filter(({ file }) => file.size <= MAX_IMPORT_FILE_BYTES);
      const selectedBytes = readable.reduce((sum, { file }) => sum + file.size, 0);
      if (selectedBytes > MAX_IMPORT_TOTAL_BYTES) {
        if (dropStatus) {
          dropStatus.textContent = `That selection holds ${formatBytes(selectedBytes)} of logs, more than the ${formatBytes(MAX_IMPORT_TOTAL_BYTES)} this page reads at once. Pick one agent's folder or a smaller set of files, such as ~/.claude/stats-cache.json or this year's ~/.codex/sessions/2026 folder, or run npx lokalbot for your full history.`;
        }
        return;
      }
      if (dropStatus) dropStatus.textContent = `Reading ${readable.length} local ${readable.length === 1 ? 'file' : 'files'} in browser memory...`;

      const entries = [];
      let totalBytes = 0;
      for (const { file, path } of readable) {
        if (generation !== importGeneration) return;
        try {
          const text = await file.text();
          totalBytes += file.size;
          entries.push({ name: file.name, path: path || file.name, text, size: file.size });
        } catch {
        }
      }

      if (generation !== importGeneration) return;
      cachedEntries = { entries, totalBytes };
      rebuildFromCachedEntries(state.year);
    }

    function rebuildFromCachedEntries(targetYear) {
      if (!cachedEntries) return;
      const parsed = parseLocalEntries(cachedEntries.entries, { year: targetYear });
      const { data, year, cacheOnly } = parsed;
      const { stats } = data;
      if (stats.totals.sessions === 0 && stats.totals.tokens.total === 0) {
        if (dropStatus) {
          dropStatus.textContent = `Scanned ${cachedEntries.entries.length} local files (${formatBytes(cachedEntries.totalBytes)}, 0 bytes uploaded), but found no coding-agent sessions for ${targetYear}. Try another year or drop ~/.claude/projects/*.jsonl or ~/.claude/stats-cache.json.`;
        }
        return;
      }

      state.year = year;
      if (yearSelect) yearSelect.value = String(year);
      const agentNames = stats.agents.map((a) => a.name).join(', ') || 'Local logs';
      localProfile = {
        id: 'local',
        label: `Your ${year} Logs`,
        hint: cacheOnly ? 'stats-cache.json · 0 bytes uploaded' : `${agentNames} · 0 bytes uploaded`,
        data,
      };
      state.profileId = 'local';
      state.window = defaultWindowMode(stats);
      renderProfileButtons();
      update();
      if (clearBtn) clearBtn.hidden = false;
      if (dropStatus) {
        const suffix = cacheOnly
          ? ' Built from stats-cache.json (add .jsonl logs for exact hours and git commits).'
          : '';
        dropStatus.textContent = `Parsed ${stats.sources.filesRead} local ${stats.sources.filesRead === 1 ? 'file' : 'files'} (${formatBytes(cachedEntries.totalBytes)}) in browser memory. 0 bytes uploaded. Agents: ${agentNames}.${suffix}`;
      }
      stageWrap?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    for (const btn of document.querySelectorAll('[data-wrapped-layout]')) {
      btn.addEventListener('click', () => {
        state.layout = btn.dataset.wrappedLayout;
        update();
        if (actionStatus) actionStatus.textContent = '';
      });
    }
    for (const btn of document.querySelectorAll('[data-wrapped-theme]')) {
      btn.addEventListener('click', () => {
        state.theme = btn.dataset.wrappedTheme;
        update();
        if (actionStatus) actionStatus.textContent = '';
      });
    }
    if (windowGroup) {
      for (const btn of windowGroup.querySelectorAll('[data-wrapped-window]')) {
        btn.addEventListener('click', () => {
          state.window = btn.dataset.wrappedWindow;
          update();
        });
      }
    }
    if (toggleApi) {
      toggleApi.addEventListener('change', () => {
        state.showApiValue = toggleApi.checked;
        update();
      });
    }
    if (toggleProjects) {
      toggleProjects.addEventListener('change', () => {
        state.showProjects = toggleProjects.checked;
        update();
      });
    }

    if (saveBtn) {
      saveBtn.addEventListener('click', async () => {
        try {
          const active = currentProfile();
          const suffix = (state.layout === 'wide' ? '-wide' : '') + (state.theme === 'light' ? '-light' : '');
          const link = document.createElement('a');
          link.href = URL.createObjectURL(await renderPngBlob());
          link.download = `agent-wrapped-${active.data.year}${suffix}.png`;
          link.click();
          setTimeout(() => URL.revokeObjectURL(link.href), 1000);
          if (actionStatus) actionStatus.textContent = '2x PNG downloaded locally.';
        } catch {
          if (actionStatus) actionStatus.textContent = 'Could not export PNG in this browser.';
        }
      });
    }

    if (copyImgBtn && navigator.clipboard && window.ClipboardItem) {
      copyImgBtn.hidden = false;
      copyImgBtn.addEventListener('click', async () => {
        try {
          await navigator.clipboard.write([new ClipboardItem({ 'image/png': renderPngBlob() })]);
          if (actionStatus) actionStatus.textContent = 'PNG copied. Paste into X, LinkedIn, or Slack.';
        } catch {
          if (actionStatus) actionStatus.textContent = 'Could not copy PNG here. Use Download 2x PNG instead.';
        }
      });
    }

    if (copyCaptionBtn) {
      copyCaptionBtn.addEventListener('click', async () => {
        const caption = cardShareCaption(currentProfile().data.stats, { showApiValue: state.showApiValue });
        const ok = await copyString(caption);
        if (actionStatus) actionStatus.textContent = ok ? 'Share text copied.' : 'Could not copy share text.';
      });
    }

    if (pickFilesBtn && fileInput) {
      pickFilesBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        fileInput.click();
      });
    }
    if (pickDirBtn && dirInput) {
      pickDirBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        dirInput.click();
      });
    }
    if (fileInput) {
      fileInput.addEventListener('change', () => {
        const files = Array.from(fileInput.files || []).map((file) => ({ file, path: file.name }));
        if (files.length) handleFileRecords(files);
        fileInput.value = '';
      });
    }
    if (dirInput) {
      dirInput.addEventListener('change', () => {
        const files = Array.from(dirInput.files || []).map((file) => ({ file, path: file.webkitRelativePath || file.name }));
        if (files.length) handleFileRecords(files);
        dirInput.value = '';
      });
    }
    if (dropzone) {
      dropzone.addEventListener('click', () => { if (fileInput) fileInput.click(); });
      dropzone.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          if (fileInput) fileInput.click();
        }
      });
      dropzone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropzone.classList.add('is-dragover');
      });
      dropzone.addEventListener('dragleave', () => {
        dropzone.classList.remove('is-dragover');
      });
      dropzone.addEventListener('drop', async (e) => {
        e.preventDefault();
        dropzone.classList.remove('is-dragover');
        const generation = ++importGeneration;
        const records = await collectDroppedFiles(e.dataTransfer);
        handleFileRecords(records, generation);
      });
    }
    if (yearSelect) {
      yearSelect.addEventListener('change', () => {
        const nextYear = Number(yearSelect.value) || 2026;
        state.year = nextYear;
        if (cachedEntries) rebuildFromCachedEntries(nextYear);
      });
    }
    if (clearBtn) {
      clearBtn.addEventListener('click', () => {
        importGeneration += 1;
        cachedEntries = null;
        localProfile = null;
        state.profileId = samples[0].id;
        state.window = defaultWindowMode(samples[0].data.stats);
        clearBtn.hidden = true;
        renderProfileButtons();
        update();
        if (dropStatus) dropStatus.textContent = 'Local logs cleared from browser memory. Drop files anytime to generate a card offline.';
      });
    }

    const defaultOs = detectVisitorOs();
    const setOsTab = (target) => {
      for (const btn of document.querySelectorAll('[data-wrapped-os]')) {
        btn.setAttribute('aria-pressed', String(btn.dataset.wrappedOs === target));
      }
      for (const panel of document.querySelectorAll('[data-wrapped-os-panel]')) {
        panel.hidden = panel.dataset.wrappedOsPanel !== target;
      }
    };
    setOsTab(defaultOs);
    for (const btn of document.querySelectorAll('[data-wrapped-os]')) {
      btn.addEventListener('click', () => setOsTab(btn.dataset.wrappedOs));
    }

    for (const btn of document.querySelectorAll('[data-wrapped-agent-tab]')) {
      btn.addEventListener('click', () => {
        const target = btn.dataset.wrappedAgentTab;
        for (const tab of document.querySelectorAll('[data-wrapped-agent-tab]')) {
          tab.setAttribute('aria-pressed', String(tab.dataset.wrappedAgentTab === target));
        }
        for (const panel of document.querySelectorAll('[data-wrapped-agent-panel]')) {
          panel.hidden = panel.dataset.wrappedAgentPanel !== target;
        }
      });
    }

    for (const btn of document.querySelectorAll('[data-wrapped-copy]')) {
      btn.addEventListener('click', async () => {
        const text = btn.getAttribute('data-wrapped-copy');
        const ok = await copyString(text);
        if (!ok) return;
        const label = btn.querySelector('[data-copy-label]') || btn;
        const prev = label.textContent;
        label.textContent = 'Copied';
        setTimeout(() => { label.textContent = prev; }, 2000);
      });
    }

    renderProfileButtons();
    update();
  }

  return {
    buildSampleProfiles,
    parseLocalEntries,
    renderCardSvg,
    cardShareCaption,
    cardDimensions,
    canZoomWindow,
    defaultWindowMode,
    initUI,
  };
});
