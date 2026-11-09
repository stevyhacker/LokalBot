// Text rules shared by the Claude Code and Codex readers. They mirror
// LokalBot's own readers (LokalBot/Services/CodingAgents/CodingAgentText.swift):
// only what a person typed counts as a request, and only the commands an
// agent ran count as actions. No text leaves this module, only counts.

/** Session-management commands say nothing about the work. */
const HOUSEKEEPING = new Set([
  '/clear', '/compact', '/model', '/resume', '/exit', '/config', '/login', '/logout',
  '/cost', '/status', '/help', '/context', '/mcp', '/permissions', '/hooks',
  '/memory', '/doctor', '/usage', '/fast', '/effort', '/rename', '/export',
]);

/** Whole messages the harness writes in the person's turn. */
const IGNORED_PREFIXES = [
  '<local-command', 'Caveat:', '[Request interrupted', '# AGENTS.md instructions',
  '<permissions', '<image', '</image>', '<collaboration_mode',
];

// Harness context wrapped around or beside a request. These tags are
// hyphenated or underscored (`system-reminder`, `ide_selection`), unlike
// HTML a person might paste into a prompt.
const IGNORED_BLOCKS = /<([a-z]+(?:[-_][a-z0-9]+)+|skill|attachments?)\b[^>]*>[\s\S]*?<\/\1\s*>/g;
const HARNESS_TAG_OPENING = /^<[a-z]+(?:[-_][a-z0-9]+)+\b/;
const PASTED_CONTENT = /<pasted_content\b[^>]*>[\s\S]*?<\/pasted_content[^>]*>/g;
const COMMAND_NAME = /<command-name>\s*(\/[^<\s]+)\s*<\/command-name>/;
const BASH_INPUT = /<bash-input>([\s\S]*?)<\/bash-input>/;
const SCHEDULED_TASK = /^<scheduled-task\b[^>]*\bname="[^"]+"/;

/** Pasted logs should not decide how wordy someone's requests are. */
const MAX_WORDS = 2000;

/**
 * What a user-turn text is: a request the person typed (`prompt`), a slash
 * command (`command`), a shell command typed into the agent (`terminal`), a
 * run they scheduled earlier (`scheduled`), or `null` for harness text.
 */
export function classifyPrompt(raw) {
  if (typeof raw !== 'string' || raw.length === 0) return null;
  let text = raw;
  // Codex puts IDE, browser, and file context above the request.
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
  const terminal = terminalCommand(trimmed);
  if (terminal !== null) return { kind: 'terminal', words: 0, command: terminal };
  if (IGNORED_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) return null;
  const clean = trimmed.replace(PASTED_CONTENT, ' ').replace(IGNORED_BLOCKS, ' ').trim();
  // An unclosed harness tag is still harness text.
  if (clean.length === 0 || HARNESS_TAG_OPENING.test(clean)) return null;
  return { kind: 'prompt', words: Math.min(MAX_WORDS, countWords(clean)) };
}

/** A command the person typed into the agent's terminal mode. */
export function terminalCommand(raw) {
  const match = BASH_INPUT.exec(raw);
  return match ? match[1].trim() : null;
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

// MARK: - Commands

const COMMIT_MESSAGE =
  /\bgit\s+(?:-C\s+\S+\s+)?commit\b[^\n]*?\s-[a-zA-Z]*m\s*(?:"\$\(cat\s+<<-?\s*'?\w+'?\s*\n\s*([^\n]{3,200})|"((?:[^"\\\n]|\\.){3,200})|'([^'\n]{3,200})')/g;
const PULL_REQUEST_TITLE =
  /\bgh\s+pr\s+create\b[^\n]*?\s(?:--title|-t)(?:\s+|=)(?:"((?:[^"\\\n]|\\.){3,200})"|'([^'\n]{3,200})')/g;
const PULL_REQUEST_MERGE =
  /\bgh\s+pr\s+merge\b(?:\s+(?:https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/)?(\d+))?/g;
const RELEASE_TAG = /\bgh\s+release\s+create\s+([^\s"';&|]+)/g;
const GIT_PUSH = /\bgit\s+(?:-C\s+\S+\s+)?push\b/;
const TEST_RUN = new RegExp(
  [
    String.raw`\bxcodebuild\b[^\n;&|]*\btest(?:-without-building)?\b`,
    String.raw`\b(?:swift|cargo|go|forge|bun|deno|dotnet|mix|flutter|zig)\s+test\b`,
    String.raw`\b(?:npm|pnpm|yarn)\s+(?:run\s+)?test\b`,
    String.raw`\bnode\s+--test\b`,
    String.raw`\b(?:pytest|vitest|jest|rspec|phpunit|tox)\b`,
    String.raw`\b(?:mvn|gradle|\./gradlew|make|just|rake)\s+(?:\S+\s+)?test\b`,
  ].join('|'),
);

/**
 * Outcomes a shell command records. Command output is never read, so an
 * action means the agent ran the command, not that it succeeded.
 */
export function actionsInCommand(raw) {
  const command = unwrappedShellCommand(raw);
  const actions = { commits: [], pullRequestsOpened: [], pullRequestsMerged: [], releases: [], pushed: false, ranTests: false };
  if (typeof command !== 'string' || command.length === 0) return actions;
  // A command is rarely long; a pasted heredoc should not stall the scan.
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

/**
 * Codex records commands as a JSON-encoded argv such as
 * `["/bin/zsh","-lc","git push"]`; the script is the last element.
 */
export function unwrappedShellCommand(command) {
  if (Array.isArray(command)) return typeof command.at(-1) === 'string' ? command.at(-1) : '';
  if (typeof command !== 'string' || !command.startsWith('[')) return command;
  try {
    const argv = JSON.parse(command);
    if (Array.isArray(argv) && typeof argv.at(-1) === 'string') return argv.at(-1);
  } catch {
    // Not an argv after all.
  }
  return command;
}

function firstCapture(match) {
  for (let index = 1; index < match.length; index += 1) {
    if (match[index] !== undefined) return match[index].replaceAll('\\"', '"').trim();
  }
  return null;
}

// MARK: - Projects

const CHECKOUT_FOLDERS = new Set([
  'code', 'desktop', 'dev', 'developer', 'documents', 'downloads', 'git', 'github',
  'projects', 'repos', 'repositories', 'scratchpad', 'src', 'tmp', 'workspace', 'workspaces',
]);
const SCRATCH_FOLDER = /^scratch(-[0-9a-f-]+)?$/;

/**
 * The repository a folder belongs to, or `null` when the folder names no
 * project: a scratch folder, the home folder, or a folder that only holds
 * checkouts. Agent worktrees are named for their repository.
 */
export function projectName(workingDirectory, userName = '') {
  if (typeof workingDirectory !== 'string' || workingDirectory.length === 0) return null;
  const parts = workingDirectory.split(/[\\/]+/).filter(Boolean);
  if (parts.length === 0) return null;
  // Claude Code: <repo>/.claude/worktrees/<name>
  const claude = parts.lastIndexOf('.claude');
  if (claude > 0 && parts[claude + 1] === 'worktrees') return parts[claude - 1];
  let name = parts.at(-1);
  // Codex: ~/.codex/worktrees/<id>/<repo>
  const lowered = name.toLowerCase();
  if (CHECKOUT_FOLDERS.has(lowered) || SCRATCH_FOLDER.test(lowered)) return null;
  if (userName && lowered === userName.toLowerCase()) return null;
  if (name.startsWith('.')) name = name.slice(1);
  return name.length > 0 ? name : null;
}
