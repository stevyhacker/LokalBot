# LokalBot Privacy Policy

Effective: September 25, 2026

LokalBot is a local-first macOS application. It has no LokalBot account,
analytics service, advertising SDK, or telemetry backend. The project does not
receive your recordings, transcripts, summaries, screenshots, prompts, files,
calendar events, or usage history.

## Data stored on your Mac

LokalBot can store the following under its Application Support directory:

- meeting microphone and system-audio tracks;
- transcripts, summaries, notes, search indexes, and meeting metadata,
  including attendee names and emails for calendar-matched meetings;
- downloaded transcription, embedding, speech, and language models;
- permission-gated app/window activity history;
- permission-gated visible screen text and encrypted screenshots;
- separately opted-in, encrypted meeting-speaker evidence and confirmed local
  voice profiles;
- saved screen moments, optional unencrypted daily-memory exports, and optional
  routine drafts at folders you choose;
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

Development and UI-test builds use separate default libraries and Keychain
namespaces from the release app. Their retention settings do not apply to the
release library. An explicit storage-root override still selects that folder.

Dream reports and durable work memory record their source dependencies.
Deleting or correcting those sources retracts dependent facts, including pinned
entries. Older memory without source attribution is conservatively retracted
when evidence changes. If cleanup fails, a durable revocation record blocks
that memory from further use until cleanup succeeds. Exported copies remain
where you saved them.

Unchanged, app-generated daily journals retract when their primary evidence is
removed or corrected, including scheduled capture retention. Edited and legacy
unsigned journals are user-owned files and remain in the library's `journal`
folder until you remove them. Saved Ask conversations and Agent history also
have independent lifetimes: delete conversations in Ask or use **Clear saved
Agent history**. Source expiry does not erase text already copied into those
conversations. Daily-memory exports and routine outputs remain in your chosen
folders until removed. Disabling these features stops future runs; it does not
delete those existing copies.

Browser meeting detection checks the Meet document URL and call controls through Accessibility. These transient lifecycle checks do not retain page text, participant names, or pixels. Calendar entries and browser audio alone cannot authorize automatic recording. Reviewed meeting boundaries limit derived transcripts and summaries while preserving original audio.

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
  pinned CoreML model on first use;
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
  Scheduled daily summaries and overnight Dream runs require a separate approval
  for that exact remote origin in Models settings. They may send activity titles,
  captured screen text, meeting evidence, and retained Dream memory without a
  prompt each time. This unattended approval is off for new and migrated settings;
  changing or revoking the server approval cancels pending scheduled work.
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

## Permissions

LokalBot asks only for permissions needed by enabled features. macOS does not
grant optional permissions until you approve them:

- Microphone and system audio for recording meetings.
- Calendar access for meeting detection, titles, and local speaker-name
  suggestions. Attendee emails remain in meeting metadata, are deleted with
  the meeting, and are never added to transcripts, exports, or model prompts.
- Accessibility for browser-meeting detection, Autocomplete (the Cotyping
  engine), dictation insertion, visible-text context, and approved agent
  interaction.
- Screen Recording when visual screen context is selected. Meeting-speaker
  observation uses Accessibility only and does not require Screen Recording.

On a fresh install, LokalBot asks through a notification before it records a
detected meeting. You can switch to automatic recording or turn auto-record
off. You are responsible for informing participants and obtaining any consent required
before recording other people.

## External-agent access

The bundled `lokalbot-cli` and MCP interface are read-only. They refuse library
access unless you explicitly enable Agent Access under Settings → Privacy. An
enabled external tool runs as your macOS user, so only connect tools you trust.
Screen-memory MCP tools require a second, independent toggle and a history
profile: today, the rolling last seven days, or all retained history. They
expose captured text, window/app activity, timestamps, and capture metadata,
but never decrypted screenshot pixels or screenshot file paths. Queries are
clamped to the granted period and out-of-scope ids appear missing. Enabling
meeting access does not enable screen-memory access, or vice versa. A connected
MCP client may transmit tool inputs and results under that client's own privacy
terms.

Screen pixels and captured text follow the configured retention window by
default. A screen moment you explicitly save retains its encrypted pixels,
captured text, and semantic search vector until you unsave or delete that
moment. Private/incognito windows, excluded apps and domains, and focused
secure fields are skipped by default. Detected credential text is redacted and
causes the associated pixel payload to be dropped; no detector is perfect, so
exclude any source whose content should never be retained. Daily-memory exports
and routine outputs are ordinary unencrypted Markdown files written only to
folders you choose and remain there until you remove them. Routines have fixed
local read scopes and cannot run scripts, contact services, send messages, or
modify source meetings.

Visual capture includes only the focused window checked through Accessibility;
background and child windows are excluded. If the focused window or its privacy
state cannot be established, text and pixels are skipped. Activity-only tracking
uses the same exclusions and records denied or unknown samples as anonymous
“Private” duration blocks.

Browser titles cannot reliably establish normal versus private mode. Browser and
embedded-web windows with unverified mode are skipped unless **Allow private or
unverified browser windows** is enabled. Known private-title markers are also
skipped by default in other apps. App/domain exclusions and secure-field checks
still apply after that opt-in. Accessibility text is limited to visible-character
ranges and fully visible static labels within the window/scroll viewport; whole
document values, selected text, help, and descriptions are not collected. If an
app does not expose a usable visible range, text capture may be incomplete.
Pausing, changing exclusions, or disabling capture invalidates pending work
before any pixel file or text record is committed.

Autocomplete learning stores encrypted accepted examples for at most 30 days
and reuses them only in the same positively identified document. Mail, chat,
and unknown document contexts do not learn or reuse examples. Settings →
Autocomplete → **Forget learned text** removes the stored examples and cancels
pending learning writes.

Dictation Compose context has its own opt-in and also honors the shared
app/domain/private-window policy. It requires the verified focused window and
field to remain unchanged and redacts credentials before creating prompts; this
context path does not save pixels or OCR. Optional media pause uses macOS
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
