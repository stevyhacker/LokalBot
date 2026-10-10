# LokalBot Privacy Policy

Effective: October 2, 2026

LokalBot is a local-first macOS application. It has no LokalBot account,
analytics service, advertising SDK, or telemetry backend. The project does not
receive your recordings, transcripts, summaries, screenshots, prompts, files,
calendar events, or usage history.

## Data stored on your Mac

LokalBot can store the following under its Application Support directory:

- meeting microphone and system-audio tracks;
- transcripts, summaries, notes, search indexes, and meeting metadata,
  including attendee names and emails for calendar-matched meetings and,
  only when you turn on **Use invitation agendas**, the invitation's agenda
  with joining details, links, phone numbers, and addresses removed;
- the names LokalBot added to a meeting's transcription vocabulary;
- downloaded transcription, embedding, speech, and language models;
- permission-gated app/window activity history;
- permission-gated visible screen text and encrypted screenshots;
- separately opted-in, encrypted meeting-speaker evidence and confirmed local
  voice profiles;
- saved screen moments, optional unencrypted daily-memory exports, and optional
  routine drafts at folders you choose;
- records of local coding-agent sessions (Claude Code and Codex), on by
  default;
- opt-in Agent Mode sessions and the agent runtime; and
- preferences, diagnostic logs, and encryption keys.

Fresh installs select activity-only day tracking. Visible text and encrypted
screenshots are opt-in and require the applicable macOS Accessibility and
Screen Recording permissions. You can switch to accessible text without pixels,
visual context, or fully off. Pixels are deleted after 14 days by default, and
captured text, screenshot titles, URLs, and document names follow the same
retention unless you explicitly choose to keep screen text and metadata forever.
Activity titles expire on the configured schedule even with that exception;
app names and duration totals remain. Saved moments remain until you unsave or delete them. Dictation scratch
audio is deleted after transcription by default. You can delete an individual
meeting in the app or remove the entire LokalBot Application Support directory.

**Read coding agent sessions** is on by default and can be turned off in
Settings → Day Memory. While it is on, LokalBot reads Claude Code session files
under `~/.claude/projects`, Codex session files under `~/.codex/sessions` and
`~/.codex/archived_sessions`, and Codex's `session_index.jsonl` for session
titles. It never opens the agents' credentials, settings, or databases, and
never changes their files. From each session it keeps your requests, the
agent's final report, the project folder name and branch, changed file names,
and actions parsed from commands the agent ran: commit messages, pull request
titles and links, merges, releases, pushes, and test runs. Tool output, command
output, file contents, reasoning, and instructions the agents inject are not
kept, and detected credentials are redacted. Subagent sessions and sessions in
folders you exclude are skipped. Sessions that read LokalBot's library through
its CLI or MCP keep no reply text. Work is saved after ten quiet minutes, joins
the day digest, and follows the screen-text retention above. Turning the
setting off stops reading and keeps saved records; **Delete saved agent
sessions** removes them and withdraws unedited journals that used them.

Library health reports stay in the library's `diagnostics/health` folder on
this Mac. Development builds check the previous day each morning; released
builds check only when you choose **Run Health Check Now**. **Export
Diagnostics…** writes a zip to a location you choose and sends nothing. It
contains recent diagnostic logs (which can name apps and calendar meetings),
health reports, scrubbed capture-test traces, library row counts, and your
settings with keys, tokens, passwords, and URL credentials removed (settings
can include exclusion lists and custom prompts). It never includes meeting
audio, transcripts, notes, screenshots, or screen text. Review the file before
you share it.

Development and UI-test builds use separate default libraries and Keychain
namespaces from the release app. Their retention settings do not apply to the
release library. An explicit storage-root override still selects that folder.

Dream reports and durable work memory record their source dependencies.
Deleting or correcting those sources retracts dependent facts, including pinned
entries. Scheduled retention is not a deletion for this purpose: when screen
text, activity titles, or coding-agent records expire, the Dream reports and
work memory derived from them remain, so they can outlast the screen-retention
window. **Clear work memory** under Settings → Overnight review deletes every
report and all work memory, including pinned entries. Older memory without
source attribution is conservatively retracted when its sources are deleted or
corrected. If cleanup fails, a durable revocation record blocks that memory
from further use until cleanup succeeds. Exported copies remain where you saved
them.

Unchanged, app-generated daily journals are withdrawn when you delete their
sources: a meeting, a meeting's trimmed boundaries, a captured screen or
capture range, saved agent sessions, or older captures when you apply a shorter
retention. Reprocessing a meeting, transcript and action-item edits, saved
moments, and re-read agent sessions keep the journal, marked out of date, until
it is regenerated. Scheduled retention is not a deletion for this purpose
either: like Dream reports, a day's journal outlasts the screen text, titles,
and agent sessions it was written from, so it can hold text that has since
expired. Delete a day's journal from the library's `journal` folder to remove
it. Edited and legacy unsigned journals are user-owned files and remain there
until you remove them. Saved Ask conversations and Agent history also
have independent lifetimes: delete conversations in Ask or use **Clear saved
Agent history**. Source expiry does not erase text already copied into those
conversations. Daily-memory exports and routine outputs remain in your chosen
folders until removed. Disabling these features stops future runs; it does not
delete those existing copies.

Browser meeting detection checks the Meet document URL and call controls through Accessibility. When the controls cannot be read, it checks whether the call's window and tab are still open by their titles. These transient lifecycle checks do not retain page text, participant names, or pixels, and the call tab's title is kept in memory only. Calendar entries and browser audio alone cannot authorize automatic recording. Reviewed meeting boundaries limit derived transcripts and summaries while preserving original audio.

An authorized browser recording continues when call observation is unavailable,
including a temporarily missing browser host. It stops when you press Stop or
when LokalBot positively verifies the call ended or its bound tab closed. The
recording UI keeps the uncertainty visible. Capture is scoped to an application
process, not reliably to one tab, so continuing browser capture may include
other tabs playing audio in that process. A replacement browser host must verify
the same call before recovery attaches; uncertainty does not authorize another
app, a global audio tap, or a new automatic recording. Microphone-only recording
never acquires system audio through recovery.

Recordings also keep local PCM recovery checkpoints, manifests, and capture-health
reports beside the original tracks. These follow the meeting's deletion rules
and never bypass exclusions or permission revocation. Complete duplicate audio
is removed only after the primary file is verified; incomplete recovery keeps
its surviving sources. Reopening the app can repair existing media but does not
restart recording from recovery metadata. Reviewed and legacy boundaries stay
in place until you explicitly rebuild a different range.

LokalBot does not read Google Meet participant names or speaking activity.
Earlier versions offered an off-by-default **Meeting speaker identification**
setting that did; it has been removed. Files it left behind are deleted
automatically, while names you already applied to transcripts remain.

Compact speaker evidence, such as microphone voice samples and unaccepted name
suggestions, is AES-GCM encrypted with a per-install Keychain key. It expires
under the screen retention period, even when capture is disabled. Applied
names, user corrections, suppression choices, and the audio-turn anchors needed
to remember those choices remain with the meeting. Deleting meeting speaker
evidence keeps those choices.

**Remember speakers on this Mac** is a separate, off-by-default setting.
When you explicitly confirm who spoke into this Mac's microphone, enough clear
speech can enroll a local voice profile. Remote participants' voices are never
enrolled or matched; profiles earlier versions created from them remain until
forgotten. The profile stores bounded speaker vectors with their source
recording and confirmation, not extra audio clips. Automatic guesses never
train profiles. You can choose **This meeting only**, select an existing person
explicitly, or create a distinct person with the same name. Profiles remain
until forgotten or their source contributions are removed. Deleting a meeting
revokes its contributions. Disabling remembering stops profile use for new work
without erasing existing transcript names; Settings offers Rename, Forget, and
Clear all controls. Cleanup failures are reported instead of claiming deletion.

Speaker evidence, suggestions, vectors, and profile identity links do not enter
search indexes, normal exports, CLI/MCP results, or inference prompts. An applied
display name is part of the transcript and follows its existing export and
approved remote-inference settings. Correcting a name does not automatically
send a new request to a remote model; existing summaries have a refresh action.

## Network access

Core recording and local inference do not require a LokalBot-operated server.
The app may make these outbound connections:

- **Models:** model metadata and model files from Hugging Face or a model
  publisher's download host. Selected first-use models can download
  automatically; other downloads start when you request them.
  Nemotron speaker diarization, the default on fresh installs, downloads its
  pinned CoreML model on first use. With Qwen3-ASR, speaker separation
  also downloads a pinned Qwen3 forced aligner (about 1 GB) that times each word;
  audio and speaker processing remain on this Mac. Remembering voices remains
  a separate opt-in and also uses the local Pyannote models.
- **Updates:** the public GitHub Releases appcast and a signed update. Automatic
  checks are enabled for new installs and can be disabled in Settings; you can
  also run a manual check.
- **Optional remote inference:** an Ollama or OpenAI-compatible URL that you
  configure. Loopback URLs stay on your Mac. Before a non-loopback server can
  receive meeting, workday, or agent context, LokalBot requires approval for
  that exact origin. Native inference requests may redirect only within that
  origin; Agent inference rejects redirects entirely. Configure the final
  endpoint URL when a server redirects. The operator of that server controls
  its privacy terms.
  When the URL is Anthropic's API (`api.anthropic.com`), Think uses its
  Messages API and marks the system prompt and supplied context for prompt
  caching, so Anthropic keeps those prompt prefixes for about five minutes to
  answer a repeated request at its cache rate. For Claude models that support
  it, LokalBot also opts into Anthropic's server-side fallback: a request the
  selected model declines under Anthropic's safety policies may be answered by
  another Claude model that Anthropic chooses. Agent Mode reaches the same
  origin through Anthropic's OpenAI-compatible endpoint.
  Before writing meeting notes with an approved OpenRouter origin, LokalBot
  also reads the selected model's published endpoint list from that origin to
  learn its context window. That request carries only the model id, with no
  API key or content, and the answer is kept in local preferences. With any
  other OpenAI-compatible server allowed for inference, LokalBot reads that
  server's model list for the same purpose, at most once a day (from
  Anthropic's API, only the selected model's entry); for a server
  on this Mac it may also read llama-server's settings or LM Studio's details
  for the selected model. These requests carry the API key you configured,
  which the server already receives with every inference request, and no
  content. The answer is kept in local preferences. To offer
  the reasoning levels a model accepts, LokalBot reads OpenRouter's public
  model list from that approved origin at most once a day, or asks an allowed
  Ollama server for the selected model's capabilities. These requests carry
  no API key or content; the Ollama one names only the model.
  Meeting notes sent to an approved server can include the calendar title,
  invited participants' names, titles of documents on screen during the call,
  and, when enabled, the invitation agenda; each has its own setting.
  Follow-up drafts and pre-meeting briefs are written only by an on-device
  Think model.
  The same origin approval covers scheduled daily summaries and overnight Dream
  runs, which may send activity titles, captured screen text, meeting evidence,
  saved coding-agent session records, and retained Dream memory without a
  prompt each time. Missed runs catch up
  for at most the last seven days. Changing or revoking the server approval
  cancels pending scheduled work.
- **Optional Agent Mode:** enabling Agent Mode downloads its pinned runtime.
  Commands you approve can read files or access the network with your macOS
  user permissions; their destinations and data handling are outside
  LokalBot's control. Files and meetings you explicitly attach are read locally
  and included when you send; saved screen moments additionally require the
  current screen-memory grant and include retained text and notes, never pixels.
  Attached context goes to the task's displayed inference destination and is
  retained in its local conversation history. Drafts, queued messages, and
  attachment references are also saved locally. Archiving preserves this data;
  **Clear saved Agent history** deletes conversations and task metadata.
  New tasks default to a working folder outside the private library. Raw reads
  of protected library/runtime files enter the tool-approval flow even when
  a broader parent folder is selected; the selected approval mode still applies.
  Existing tasks rooted inside the private
  library remain readable but cannot run. Shell commands whose complete text
  cannot be reviewed are rejected.

Those services receive normal connection metadata such as your IP address and
request headers. LokalBot does not add an advertising identifier and does not
use those requests to track you.

LokalBot's own automated tests send only synthetic fixture text to remote
model providers, from the project's CI; they never use a user's library.

## Permissions

LokalBot asks only for permissions needed by enabled features. macOS does not
grant optional permissions until you approve them:

- Microphone and system audio for recording meetings.
- Calendar access for meeting detection, titles, local speaker-name
  suggestions, and names used as transcription vocabulary and meeting-notes
  context. The separate, off-by-default **Use invitation agendas** setting
  also reads the invitation's notes, keeps only the agenda text, and saves it
  with calendar-matched recordings; agendas already saved stay with their
  meeting until it is deleted. Attendee emails remain in meeting metadata, are
  deleted with the meeting, and are never added to transcripts, exports, CLI
  or MCP results, or model prompts. On this Mac they only help recognize the
  same person across meetings in People and are never shown there. When an
  attendee has no display name, People uses the name suggested from a company
  address ("dragan@…" becomes "Dragan"); the address itself is not shown.
- Accessibility for browser-meeting detection, Autocomplete (the Cotyping
  engine), dictation insertion, visible-text context, and approved agent
  interaction.
- Screen Recording when visual screen context is selected. Meeting-speaker
  observation uses Accessibility only and does not require Screen Recording.
  When it is already granted, Autocomplete also uses it to place suggestions
  in fields that report no caret position (see below); it never asks for it.

On a fresh install, LokalBot asks through a notification before it records a
detected meeting. You can switch to automatic recording or turn auto-record
off. You are responsible for informing participants and obtaining any consent required
before recording other people.

## External-agent access

The bundled `lokalbot-cli` and MCP interface are read-only. They refuse library
access unless you explicitly enable Agent Access under Settings → Privacy.
Meeting access includes action items with your saved corrections and a People
view of names, open actions, decisions, and shared meetings; it never
includes attendee email addresses. An
enabled external tool runs as your macOS user, so only connect tools you trust.
Screen-memory MCP tools require a second, independent toggle and a history
profile: today, the rolling last seven days, or all retained history. They
expose captured text, window/app activity, timestamps, and capture metadata,
but never decrypted screenshot pixels or screenshot file paths. Queries are
clamped to the granted period and out-of-scope ids appear missing. Enabling
meeting access does not enable screen-memory access, or vice versa. A connected
MCP client may transmit tool inputs and results under that client's own privacy
terms.

The optional [ChatGPT plugin companion](Distribution/chatgpt-plugin/README.md)
is a separate connection that must be paired and run deliberately. It delegates
meeting reads to the same CLI permission gate. Requested meeting metadata,
summaries, transcript excerpts, action items, and people pass through the
publisher's Cloudflare relay to the authorized client; this connection is not
entirely on-device. It does not expose screen memory, remote inference, library
writes, or Agent Mode. The adapter and relay do not persist meeting payloads;
the relay stores device and OAuth metadata to authorize requests. Cloudflare
and the connected client's own data-handling terms also apply. Stopping the
companion, disabling meeting access, or revoking the pairing blocks subsequent
reads, but cannot recall content already returned. Building this source does
not install the companion or connect the app to a public service.

**Open in Claude** and **Open in Codex**, in a meeting's More menu, start a new
conversation in that installed app with the meeting's title, summary, and as much
of its transcript as fits already typed into the composer. LokalBot hands the
text only to that app on this Mac; it is sent only if you press Send there, under
that app's privacy terms. This does not enable Agent Access.

Screen pixels and captured text follow the configured retention window by
default. A screen moment you explicitly save retains its encrypted pixels,
captured text, and semantic search vector until you unsave or delete that
moment. Excluded apps and domains and focused secure fields are skipped.
Private and incognito browser windows are captured like any other window, so
add a browser or site to the exclusions to keep it out. Detected credentials,
payment card numbers, and IBANs are redacted and
cause the associated pixel payload to be dropped; no detector is perfect, so
exclude any source whose content should never be retained. Daily-memory exports
and routine outputs are ordinary unencrypted Markdown files written only to
folders you choose and remain there until you remove them. Routines have fixed
local read scopes and cannot run scripts, contact services, send messages, or
modify source meetings.

Visual capture includes only the focused window checked through Accessibility;
background and child windows are excluded. If the focused window cannot be
established, text and pixels are skipped. Some apps, such as Chrome, do not
report which element has keyboard focus; their windows are captured only while
no password input field is visible among the inspected window elements, and a change
in that state during capture discards the pixels. Activity tracking
records excluded apps and excluded sites as anonymous “Private” duration blocks.
Every other window keeps its app name, and its title unless a password field is
focused or a site exclusion cannot be ruled out.

Browsers, web-based apps, and private or incognito windows are tracked and
captured like native apps; there is no separate private-window setting.
App/domain exclusions and secure-field checks always apply. A site exclusion
also covers pages framed inside another page, so a window that frames an
excluded site is skipped, and while site exclusions are configured a browser
window is skipped when its address, or a framed page's, cannot be read. Web
addresses are kept without credentials, query, or fragment.
Accessibility text is limited to visible-character
ranges and fully visible static labels within the window/scroll viewport; whole
document values, selected text, help, and descriptions are not collected. If an
app does not expose a usable visible range, text capture may be incomplete.
Pausing, changing exclusions, or disabling capture invalidates pending work
before any pixel file or text record is committed.

People and Projects are derived on this Mac from meeting metadata, summaries,
outcomes, applied speaker names, Dream projects, and activity titles each time
they are shown; nothing new is stored for them. Your Mac account name is read
only to leave you out of People. **Suggest actions that look done**
reads retained screen text locally to offer Mark Done on an open action; it
never changes an action by itself and sends nothing. Captures you dismiss are
remembered in local preferences so they are not offered again. A meeting's
page lists the titles, documents, and URLs captured on screen during the call
from the same retained screen memory.

Autocomplete learning stores encrypted accepted examples for at most 30 days
and reuses them only in the same positively identified document. Mail, chat,
and unknown document contexts do not learn or reuse examples. Settings →
Autocomplete → **Forget learned text** removes the stored examples and cancels
pending learning writes.

Autocomplete keeps local counters, shown under Settings → Writing → **Usage and
timing**: suggestions generated and accepted, generation time, and, for each
kind of app (native apps, browsers, chat, email), the wait from your last
keystroke to a visible suggestion, whether accepted text then appeared in the
field, and whether you deleted or undid it at once. To check an insertion,
LokalBot compares the end of the text before the caret with what it inserted.
That comparison is held in memory for about a second and a half and then
discarded; only the outcome is counted. No typed text, app name, or window title
is stored. **Reset** clears the counters, and **Copy measurements** puts the
counts on the clipboard only when you click it.

Autocomplete also has a separate **Use visible text above the field** setting.
It is on for new installs and only takes effect while Autocomplete itself is on;
settings saved by earlier versions keep their choice, which was off unless you
turned it on. Onboarding says so where Autocomplete is prepared, and Settings →
Writing turns it off. It reads Accessibility labels and messages in the focused
field's column, up to 600 points above it, within the same visible window/pane.
It selects at most three excerpts within 420 characters. Hidden/offscreen text,
other inputs, sidebars, toolbars, secure fields, credential-bearing snippets,
and excluded apps/sites do not enter the prompt, and private or incognito
browser windows are never read. Unknown browser origins abstain. Shared capture exclusions and autocomplete exclusions both apply.
This setting does not enable screen recording, screenshots, OCR, saved screen
memory, or external access. Context is processed locally and held only in memory;
context-grounded acceptances are excluded from saved learning. The setup preview
never reads the screen: with this setting on, the rehearsal in Settings uses its
own synthetic sample conversation as the nearby text. The nearby text is read
when the field gets focus and refreshed in the background at most every three
seconds while you type, so a suggestion may use text that changed in the last
few seconds. It is held for the focused field only and forgotten when focus
leaves it or moves to another field. Turning the setting off or excluding
the app or site forgets it at once and discards any suggestion that used it.
Tab performs no screen traversal.
Apps that do not expose visible static text through Accessibility get ordinary
autocomplete without this additional context.

Some fields, such as text areas in Chrome, do not report where the caret is.
For those, when Screen Recording is already granted, Autocomplete captures the
focused field's own frame, finds the line that ends at the caret with on-device
text recognition, and keeps only the caret's position. The image and the
recognized text are held in memory while this runs and then discarded; nothing
is saved, sent, or added to screen memory. It never runs for secure fields,
apps excluded from screen capture or autocomplete, or, while any site is
excluded from screen capture, a browser page whose address is unknown or
excluded. Without Screen Recording the suggestion is shown just outside the
field instead.

Autocomplete has separate, off-by-default **Use meeting and work memory** and
**Use screen-derived work memory** settings. When enabled, it can include up to
two short, relevant facts from the last 90 days in its local completion prompt.
Meeting sources include current notes, summaries, and outcomes with saved
corrections. With both relevant settings enabled, selected visible excerpts can
also supply project names for this local lookup. Visible-context permission
alone does not authorize saved-memory retrieval. Work memory includes attributed
projects and goals; screen-derived memory can include distilled screen/activity
and daily-journal facts. These two settings are the whole permission to read
saved work memory. They read what is already saved whether or not **Review the
day overnight** is on, and they never start or schedule a review. Turning
Overnight review off stops new reviews without withdrawing either grant;
**Clear work memory** deletes the saved facts. Facts combining meeting and screen
sources require both autocomplete grants. Unattributed legacy memories are
excluded. This does not enable new capture, read raw screenshot pixels or OCR,
grant external-agent access, or send the context to a remote model.

A saved fact is used only when the writing is about it. Either the writing names
the fact's source — at least half of the distinctive words of the meeting title
or project name appear in your draft, the window title, or the selected visible
text — or the fact shares several distinctive words with your own draft or
window title, one of them written as a name. Everyday wording, weekdays and
months, and app names never count, and a notes line that only restates its
source's title, such as a heading, is left out. Writing that names nothing
distinctive is answered without opening the library.

Autocomplete reads current source files and checks for source changes before
presenting or accepting a completion. Editing/deleting sources or revoking
access cancels affected pending and cached suggestions. No additional memory
store is created, and memory-grounded accepted suggestions are not copied into
autocomplete's learned examples. Text already accepted into another app remains
there until you remove it. The setup sample never reads saved memory; a personal
preview uses the enabled settings. Settings shows each setting's effective state
(available, unavailable and why, or nothing saved yet), the titles of the sources
the last suggestion used, and when a lookup found nothing relevant.

Dictation Compose has three independent, off-by-default grants: **Use visible
text above the field**, **Use meeting and work memory**, and **Use screen-derived
work memory**. Autocomplete's grants do not enable these. Nearby text uses the
same bounded Accessibility selection described above, with shared app/domain/
private-window exclusions. No screenshots are needed for this setting. Saved
facts use the current-source limits above; title matches in the spoken request
or authorized screen context establish relevance. Mixed provenance requires both
dictation memory grants. As with autocomplete, these grants read saved work
memory whether or not Overnight review is scheduled. No new saved-memory store
is created.

These sources assist explicit Compose writing requests such as “reply” or “draft.”
Directly dictated sentences do not invoke the nearby-text or saved-memory
providers and get no added context. The existing **Use the focused window as
context** option remains separate: when enabled, focused-window OCR may begin
during recording before the spoken request is known. After ASR, directly dictated
sentences cancel unused OCR and do not include it in the composition prompt.
Transcribe never invokes any of these context providers or a rewrite model.

Context requires the verified focused window and field to remain unchanged and
credentials are redacted before prompts are created. Source edits/deletion,
revoked grants and changed inference destinations invalidate pending composition;
source and permission checks also guard delivery. The transcript remains available
when a composition is rejected. Context is held in memory and this path does not
save pixels or OCR. The configured local Compose model keeps this context on the
Mac; if an approved remote Think endpoint is selected, it receives the spoken
request and any enabled screen context or saved facts included in the prompt.
Dictation displays that disclosure. Text already inserted into another app is
not removed by later source deletion.

After pasting, dictation reads up to the bounded text before the caret in the
same focused field once or a few times within about a second, to confirm the text
arrived. It reads only the exact field the text was pasted into, identified when
dictation started, and never a secure field; when that field could not be
identified, nothing is read back. The read is compared in memory and discarded; nothing from it is saved,
logged or sent anywhere. Apps on the shared exclusion list are not read, and a
field that cannot be read is left unchecked. When the text is missing, the
dictation overlay offers to copy it. The chosen dictation microphone is stored as
a device identifier in Settings.

Optional media pause uses macOS
Automation for audible supported players and browsers. It pauses finite
prerecorded media, excludes live MediaStream/infinite streams and supported
conference domains, and resumes only marked elements. macOS controls whether
Automation is permitted.

Manual OCR benchmark exports are separate from the app: they require an explicit
decryption flag and produce owner-only ordinary image/text files. Private model
runs require a pinned cached revision, safe tensor weights, disabled remote model
code, and a network-denied macOS sandbox. Delete exported fixtures and results
after review; application retention does not manage benchmark copies.

## Security and changes

No software can promise absolute security. Please report vulnerabilities using
the private channel in [SECURITY.md](SECURITY.md). Material changes to this
policy will be documented in the repository and release notes with a new
effective date.

## Contact

For privacy questions, open a support issue using the contact path in
[SUPPORT.md](SUPPORT.md). Do not include recordings, transcripts, secrets, or
other sensitive data in a public issue.
