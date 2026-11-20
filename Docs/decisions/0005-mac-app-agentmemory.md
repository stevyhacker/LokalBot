# 0005. Mac app: AgentMemory

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/AgentMemory/`, `LokalBotTests/Services/AgentMemory/`.

## Decisions

### `LokalBot/Services/AgentMemory/AgentMemoryNote.swift`

#### Agent's file stays source and is never changed
`AgentMemoryNote`: A note a coding agent wrote for its own later sessions, as LokalBot keeps
it for search. The agent's file stays the source and is never changed.

#### Note id stable across scans: agent, file, section
`AgentMemoryNote.id`: Stable across scans: the agent, the file, and the section inside it.

#### Category is Claude Code's label: user, feedback, project, reference
`AgentMemoryNote.category`: Claude Code's label for the note: user, feedback, project, or reference.

#### Stored note text has detected credentials redacted
`AgentMemoryNote.text`: The note's text with detected credentials redacted.

#### Unreadable files are not treated as deleted notes
`AgentMemoryScan.unreadableFiles`: Files that exist but could not be read. While any are listed, notes
missing from the scan are not taken as deleted.

#### Counts notes dropped by never-read folder setting
`AgentMemoryScan.excludedNotes`: Notes left out by "Never read sessions in these folders".

#### Notes inside an excluded folder never leave the reader
`AgentMemoryExclusions`: The person's project-folder exclusions, applied to notes. A note about a
folder inside an excluded one never leaves the reader.

#### Folders are standardized absolute paths
`AgentMemoryExclusions.folders`: Standardized absolute folder paths.

#### Slug match loses slash info so siblings are excluded too, safely
`AgentMemoryExclusions.excludes`: Claude Code names a project folder after its working directory with
every character that is not a letter or digit turned into "-". That
loses which dashes were slashes, so a sibling such as `app-old` reads
as inside `app` and is left out too: the safe direction.

#### Match folder or inside it, not same-prefix siblings
`AgentMemoryExclusions.mentionsExcludedFolder`: The folder itself or something inside it, not a sibling
whose name merely starts the same (`app-old`, `app.bak`).

#### Files over 4 MB are not hand-written notes
`AgentMemoryText.maxFileBytes`: A memory file larger than this is not a note someone wrote.

#### Per-agent cap stops a runaway folder filling the library
`AgentMemoryText.maxNotesPerAgent`: Per agent, so a runaway folder cannot fill the library.

#### Keep Markdown layout; redact, fold line endings, cap at line end
`AgentMemoryText.body`: Credentials redacted, line endings folded, edges trimmed, capped at a
line end. Markdown layout is kept so a quoted passage reads as written.

#### Pre-heading text is level 0; headings in fences are text
`AgentMemoryText.sections`: Splits Markdown at headings of the given levels. Text before the first
such heading comes back with level 0 and an empty heading. Headings
inside fenced code are text.

### `LokalBot/Services/AgentMemory/AgentMemoryReaders.swift`

#### MEMORY.md supplies titles; only one session file head is read
`ClaudeCodeMemoryReader`: Reads Claude Code's notes from `~/.claude/projects/<cwd-slug>/memory/*.md`.

Each note is one Markdown file with a short header (name, description,
type). `MEMORY.md` is the folder's index of those files: it supplies
titles and is not a note itself. Nothing else in a project folder is read
except the opening of one session file, for the folder's real path.

#### Read first 256 KB of session file to find working directory
`ClaudeCodeMemoryReader.sessionPeekBytes`: How much of a session file is read to find its working directory.

#### Front matter is flat fields; file without block is all body
`ClaudeCodeMemoryReader.frontMatter`: The leading `---` block as flat fields (`name`, `metadata.type`), and
the text after it. A file without the block is all body.

#### Titles come from MEMORY.md index link lines
`ClaudeCodeMemoryReader.indexTitles`: File name to title, from index lines such as
`- [Release gotchas](release-gotchas.md) — per-release lessons`.

#### Folder name loses separators; verify path against newest session
`ClaudeCodeMemoryReader.workingDirectory`: The folder a project's sessions ran in. The project folder's name is
that path with its separators lost, so the path is read from the
newest session file and kept only if it produces the same name.

#### Which Codex memory files are read and which are skipped
`CodexMemoryReader`: Reads Codex's memories from `~/.codex/memories`.

- `MEMORY.md`: one note per top-level heading (a task group).
- `memory_summary.md`: one note per section.
- `rollout_summaries/*.md`: one note per session summary.

`raw_memories.md` repeats the session summaries and is not read. The
`skills` and `extensions` folders hold procedures and tools, not notes.

#### Task group scope is summary; folder from applies_to cwd
`CodexMemoryReader.taskGroups`: `MEMORY.md`: each `# Task Group: …` with its `scope:` line as the
summary and the folder from `applies_to: cwd=…`.

#### Section headed by folder path is about that folder
`CodexMemoryReader.summarySections`: `memory_summary.md`: one note per `##` or `###` section. A section
headed by a folder path is about that folder.

#### Rollout summary layout: header lines, blank line, titled body
`CodexMemoryReader.rolloutSummary`: A session summary: `key: value` header lines (`cwd`, `updated_at`),
a blank line, then the summary under its `#` title.

#### Folder is cwd value up to semicolon in applies_to
`CodexMemoryReader.cwd`: The folder in `cwd=/path; reuse_rule=…`.

### `LokalBot/Services/AgentMemory/AgentMemoryStore.swift`

#### Agent notes DB is rebuildable and deleted when feature turned off
`AgentMemoryStore`: Write side of the saved coding-agent notes (`agent-notes.sqlite` in the
library; `AgentNotesIndex` reads it). The file holds only what the readers
kept of the agents' own files, so it is rebuilt from them at any time and
deleted outright when the person turns the feature off.

#### Keep missing notes while a file was unreadable
`AgentMemoryStore.apply`: Make the saved notes of `agents` match `scan`, and drop notes of any
other agent. While a file could not be read, a note missing from the
scan stays: an unreadable file is not a deleted one.

#### No agent folder opened until enabled; off deletes saved notes
`AgentMemoryIngestor`: Keeps the saved coding-agent notes in step with the agents' files.

Scans and writes run off the main actor, one at a time. Nothing under the
agents' folders is opened until the person turns the feature on, and
turning it off deletes what was saved.

#### Refreshes are serialized
`AgentMemoryIngestor.refresh`: Read the agents' notes now. Refreshes run one after another.

#### Remove just-written notes if setting turned off while reading
`AgentMemoryIngestor.performRefresh`: Turned off or narrowed while reading: what was just written must go.

#### Deletion queues with refreshes so toggling cannot delete new read
`AgentMemoryIngestor.removeAll`: Deletion takes its turn with the refreshes, so turning the setting
off and on again cannot delete what the new read just saved.

#### Grant is only a marker; CLI searches notes without app
`AgentNotesAccessManager`: App-side owner of the Agent notes grant (Settings → External Agents). The
grant is only a marker: `lokalbot-cli` and its MCP server search the saved
notes themselves, without the app running, and find none while Read coding
agent notes is off because turning that off deletes them.

### `LokalBotTests/Services/AgentMemory/AgentMemoryReaderTests.swift`

#### A session that later moved still names its start folder first
`ClaudeCodeMemoryReader.workingDirectory(ofProject:)`: A session that later moved elsewhere still names its start folder first.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
