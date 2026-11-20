# 0049. Mac app: Settings

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Settings/`, `LokalBot/Views/Settings/`, `LokalBotTests/Models/Settings/`.

## Decisions

### `LokalBot/Models/Settings/AppSettings.swift`

#### OpenRouter account filters apply after the request-level provider preference
`OpenRouterDataPolicy.providerDataCollectionValue`: OpenRouter applies account, API-key, workspace, and guardrail filters
after this request-level provider preference.

#### ChatGPT plan backend uses Sign in with ChatGPT
`SummarizerBackend.chatGPTPlan`: The user's ChatGPT plan through Sign in with ChatGPT.

#### Claude plan runs through the user's own Claude Code installation
`SummarizerBackend.claudePlan`: The user's Claude plan through their own Claude Code installation.

#### Antigravity plan runs through the user's own agy CLI
`SummarizerBackend.antigravityPlan`: The user's Antigravity plan through their own Antigravity CLI (`agy`).

#### Gemini plan runs through the user's own gemini CLI
`SummarizerBackend.geminiPlan`: The user's Gemini plan through their own Gemini CLI (`gemini`).

#### New installs ask before recording; old settings keep automatic default
`AppSettings.autoRecordMode`: New installs ask before recording a detected meeting. Decoding old
settings preserves the previous automatic default.

#### Seconds the meeting app's audio must be gone before meeting ends
`AppSettings.stopDebounceSeconds`: Seconds the meeting app's own audio must be gone before a meeting counts
as ended.

#### Calendar reading is opt-in, off by default, gated on TCC grant
`AppSettings.calendarDetectionEnabled`: Read the Mac Calendar to confirm meetings and title recordings. Off by
default and gated on a calendar TCC grant — calendar contents are
sensitive, so this is strictly opt-in.

#### Matched calendar event title preferred over app-derived meeting name
`AppSettings.useCalendarTitles`: Prefer the matched calendar event's title over the app-derived name.

#### Browser auto-record needs an active calendar event with meeting link
`AppSettings.requireCalendarForBrowser`: Stricter: only auto-record a browser tab when an active calendar event
with a meeting link backs it (ignores window-title-only matches).

#### Menu-bar-only mode shows recording state in menu bar, no Dock icon
`AppSettings.menuBarOnly`: Run as a menu-bar-only app: no Dock icon, no window at launch. The
recording state lives in the menu bar (live timer + indicator) so the
main window is never required to know a meeting is being captured.
When off, LokalBot behaves like a normal windowed app with a Dock icon.

#### Old settings decode to pinned Q4; custom models keep revision and checksum
`AppSettings.graniteSpeechModel`: The GGUF/projector pair used when Granite Speech is selected. Older
settings decode to the pinned Q4 default; custom Hugging Face choices
retain immutable revision and checksum metadata.

#### sherpa-onnx model directory is user-owned, never copied or deleted
`AppSettings.funASRNanoModelDirectory`: User-owned sherpa-onnx model directory; never copied or deleted by the app.

#### OpenAI-style speech-to-text server, cloud or on another device
`AppSettings.remoteTranscriptionBaseURL`: The OpenAI-style speech-to-text server used when Transcribe is set to
a transcription server: a cloud provider or a server on another device.

#### Empty model sends no model field, for single-model servers like whisper.cpp
`AppSettings.remoteTranscriptionModel`: Empty sends no model field, for single-model servers such as whisper.cpp.

#### Audio origin approvals are separate from Think server approvals
`AppSettings.approvedRemoteTranscriptionOrigins`: Origins the user approved to receive meeting, dictation, and live
preview audio. Separate from `approvedRemoteInferenceOrigins`:
approving a Think server never sends it audio.

#### Known names are added to prompt-capable speech models
`AppSettings.autoTranscriptionVocabulary`: Adds names LokalBot already knows (calendar attendees, names applied
in related meetings, Dream projects) to prompt-capable speech models.

#### Looks done? is only offered, never auto-completes actions
`AppSettings.suggestActionCompletion`: Offers "Looks done?" on open actions when later retained screen text
shows a matching completion (sent, merged, submitted). Never auto-completes.

#### Live Radar off by default; reads transcript only after Start Radar; Muse approvers keep it
`AppSettings.liveRadarEnabled`: Off by default: offers Live Radar while a meeting records. It reads
the live transcript with the Think model, under that model's own local
or remote setting, and only after Start Radar is pressed. A library
that had approved Meta Muse, which the radar used before, keeps it on.

#### Muse live text is off by default and needs api.meta.ai approval
`AppSettings.museLiveTextEnabled`: Off by default: the live transcript preview streams meeting audio to
Muse Voice Transcribe for text within a second of each turn, instead
of transcribing chunks on this Mac. Also needs the api.meta.ai approval.

#### Turn-by-turn live text off by default; Muse fast live text takes precedence
`AppSettings.turnByTurnLiveTextEnabled`: Off by default: the live transcript preview cuts each track at pauses
and transcribes one turn at a time with the Transcribe model, so a
turn's text follows its speaker by about a second, and Live Radar
reads after each turn. Muse's fast live text takes precedence.

#### Screen-text crops go to Think model for radar answers, off by default
`AppSettings.museScreenAnswersEnabled`: Off by default: when Live Radar catches a question, the text of crops
of earlier screen captures that mention it goes to the Think model for
the answer.

#### Radar panel opens at recording start and when the radar starts
`AppSettings.liveRadarPanelEnabled`: The floating Live Radar panel opens when a recording starts (once
Live Radar is on) and when the radar starts.

#### Radar panel excluded from screen sharing and recordings
`AppSettings.liveRadarPanelHiddenFromCapture`: Leaves the panel out of screen sharing and screen recordings.

#### Live answers search memory first, then meetings, screen text and folders
`AppSettings.liveAnswersEnabled`: Off by default: when Live Radar catches a question or problem, the
Think model looks for the answer in the person's work, memory first,
then their meetings, screen text, and `liveAnswerFolders`.

#### Live answers read documents and git repository code, commits, PRs, issues
`AppSettings.liveAnswerFolders`: Folders live answers may read: documents anywhere in them, and code,
commits, pull requests, and issues in git repositories.

#### Notes may use calendar title, invitees and on-screen document titles as secondary context
`AppSettings.meetingNotesUseCalendarContext`: Meeting notes may use the calendar title and invited names, and the
titles of documents on screen during the call, as secondary context.

#### Invitation agenda saved with calendar-matched recordings, off by default
`AppSettings.useCalendarAgenda`: Off by default: reads the invitation agenda (notes without joining
details) and saves it with calendar-matched recordings.

#### Auto handoff sends meeting notes to Agent Mode model, off by default
`AppSettings.handOffActionsAfterSummary`: After each summary, open one Agent Mode task per open action that is
the person's. Off by default: it hands meeting notes to Agent Mode's
model without a click.

#### Handed-off tasks start on their own; off by default
`AppSettings.startHandoffsAutomatically`: Handed-off tasks start on their own instead of waiting in the composer
for Send. Off by default.

#### Audio destination is this Mac for local models, else the server host
`AppSettings.transcriptionPresentation`: Where the selected Transcribe model sends audio: this Mac for every
local model, otherwise the transcription server's host.

#### Transcription key falls back to same-origin Think key, never other origins
`AppSettings.remoteTranscriptionRequestKey`: The key sent with transcription requests: the transcription server's
own key, or, when none is saved and the server is the same origin as
Think's OpenAI-compatible connection, that connection's key, so one
OpenAI or OpenRouter key serves both. Never sent to another origin.

#### Engine value is a snapshot while approval is read live
`AppSettings.transcriptionEngine`: This value is a snapshot; the approval is read live.

#### Dictation: shortcut, speak, transcribe locally, deliver to focused app
`AppSettings.dictationEnabled`: Handy-style system-wide dictation: press the shortcut, speak, transcribe
locally with the selected ASR engine, then deliver the text to the focused app.

#### Start sound plays only once the microphone delivers audio
`AppSettings.dictationPlaysStartSound`: A short sound once the microphone delivers audio.

#### Empty microphone ID follows macOS default input
`AppSettings.dictationMicrophoneID`: Capture-device unique ID; empty follows the macOS default input.

#### Empty composition model keeps using the Main LLM setting
`AppSettings.dictationCompositionBuiltInModelID`: Optional built-in model used only for dictation composition/rewrite.
Empty preserves the historical behavior of using the Main LLM setting.

#### Activity sampling on for fresh installs; Accessibility gates window titles
`AppSettings.trackingEnabled`: M4: app/window activity sampling. Fresh installs enable the local day
timeline; macOS Accessibility still gates window-title collection.

#### Semantic search uses EmbeddingGemma 2, downloaded on first use
`AppSettings.semanticSearchEnabled`: M6: embedding-based semantic search (EmbeddingGemma 2, downloaded on first use).

#### New installs capture activity only; legacy boolean stays encoded for older builds
`AppSettings.screenContextCaptureMode`: M5: new installs start with activity only; text and pixels are opt-in, while
macOS Accessibility and Screen Recording permissions still gate capture.
The legacy boolean remains encoded so older builds can read a new settings
blob safely.

#### Bridge for settings that only set the old screenshot switch
`AppSettings.effectiveScreenContextCaptureMode`: Compatibility bridge for callers/settings blobs that still set only the
pre-mode screenshot switch.

#### Meeting visual context is off by default and throttled harder
`AppSettings.meetingVisualContextEnabled`: Capture change-driven visual context while a meeting is recording.
Off by default and throttled more aggressively than normal capture.

#### Excluded hosts or URL prefixes apply to both text and pixels
`AppSettings.excludedScreenDomains`: Comma-separated hosts or URL prefixes excluded from both text and pixels.

#### Keeping OCR text past retention is explicit opt-in because it is sensitive
`AppSettings.keepOCRTextForever`: Keep OCR'd screen text past `retentionDays`. Off by default — screen
text can be as sensitive as the pixels it came from, so keeping it
forever is an explicit opt-in (Settings → Screen & Activity).

#### Quick Recall is off by default because a global shortcut is explicit
`AppSettings.quickRecallEnabled`: System-wide Quick Recall opens a compact search surface without first
bringing the main app forward. Off by default because a global shortcut
is an explicit automation choice.

#### Selection actions off by default; reads another app's selected text
`AppSettings.selectionActionsEnabled`: A system-wide shortcut that reads the text selected in the frontmost
app and offers local AI actions on it. Off by default for the same
reason as Ask's shortcut, and because it reads another app's text.

#### Window handoff off by default; reads window including off-screen text
`AppSettings.windowHandoffEnabled`: A system-wide shortcut that reads the focused window and hands the
task on it to another agent. Off by default: it reads another app's
window, including text that is scrolled out of view.

#### Auto digest runs after set hour only with activity; refreshes manual digest
`AppSettings.dayDigestAutoEnabled`: Generate the day digest automatically once the clock passes
`dayDigestHour`, so the Timeline's journal fills in without a click.
Runs only when the day has recorded activity or finished meetings; a
digest generated manually earlier in the day is refreshed with the
fuller day at the scheduled hour.

#### Local wall-clock hour 0 to 23 after which digest generates
`AppSettings.dayDigestHour`: Local wall-clock hour (0...23) after which today's digest is generated.

#### Custom guidance applies to scheduled, manual and CLI digests; empty keeps default
`AppSettings.dayDigestCustomPrompt`: Optional guidance folded into the digest prompt — scheduled, manual,
and `--digest` CLI generation alike. Empty keeps the built-in prompt.

#### Coding-agent transcripts read locally into evidence, on by default
`AppSettings.codingAgentEvidenceEnabled`: Read local Claude Code and Codex transcripts into day evidence. On by
default: much of the day's work runs in agents the screen never sees.
Reading stays local; folder exclusions and deletion live in Settings.

#### Comma-separated folders whose agent sessions are never read
`AppSettings.codingAgentExcludedFolders`: Comma-separated folders whose sessions are never read.

#### Agent memory notes are indexed only after opt-in; reuse per-agent switches
`AppSettings.codingAgentNotesEnabled`: Read the notes Claude Code and Codex keep for their own later
sessions into a searchable index. Off until the person turns it on:
the notes are the agents' words about any project they worked in.
The per-agent switches and folder exclusions above apply here too.

#### Empty export folder keeps the scheduler parked even if enabled
`AppSettings.dailyMemoryExportEnabled`: Optional, local-only daily export. An empty folder means the scheduler
remains parked even if an older settings blob somehow enables it.

#### Export hour is local 0 to 23; scheduler clamps decoded values
`AppSettings.dailyMemoryExportHour`: Local wall-clock hour (0...23) at which yesterday/today's memory note is
refreshed. The scheduler clamps decoded values defensively.

#### Per-meeting Markdown export is local-only; empty folder keeps it parked
`AppSettings.meetingNoteExportEnabled`: Optional, local-only: one Markdown note per meeting in a folder the
person picks, in the same formats as the daily note. An empty folder
keeps the export parked.

#### Dreaming runs overnight on AC power when idle, on by default, stays local
`AppSettings.dreamingEnabled`: Overnight retrospective: after `dreamingHour`, once the Mac is on AC
power and LokalBot is not recording or processing, compile the previous
day's evidence into a morning brief plus a structured local memory of
active projects and goals, shown on Today. On by default; everything it
reads and writes stays inside the storage root, and users can turn it
off at any time. Briefs and memory outlive screen retention.

#### Dream hour is local 0 to 23; slept-through nights catch up on wake
`AppSettings.dreamingHour`: Local wall-clock hour (0...23) after which the overnight dream may run.
Nights the Mac slept through catch up at the next launch or wake.

#### Companion sharing is encrypted, LAN or Tailscale only, nothing listens when off
`AppSettings.companionSharingEnabled`: Shares an allowlisted, end-to-end encrypted copy of the library with
phones and tablets the person pairs, over the local network or
Tailscale only. Off by default: nothing listens while it is off, and
it is independent of agent access and the other grants.

#### Companion share defaults are generous because copy stays on own devices
`AppSettings.companionShareMeetings`: What paired devices receive, per data class. The defaults are generous
because the copy stays on the person's own devices; each applies only
while sharing is on.

#### Already-cleared window titles stay cleared in shared Timeline
`AppSettings.companionShareWindowTitles`: Window titles in the shared Timeline. Titles the Mac's retention has
already cleared stay cleared.

#### Shared copy reaches back a window; older records are withdrawn
`AppSettings.companionHistory`: How far back the shared copy reaches; older records are withdrawn.

#### Paired-device questions answered by Think model with existing approvals
`AppSettings.companionAnswersQuestions`: Answer questions sent from paired devices with the Think model and its
existing approvals.

#### Recordings from paired devices become ordinary meetings
`AppSettings.companionAcceptsRecordings`: Make meetings from recordings paired devices send, processed like any
other recording.

#### Single TCP port bound while sharing is on
`AppSettings.companionPort`: The one TCP port the listener binds while sharing is on.

#### Bonjour off leaves Mac reachable only at stored paired addresses
`AppSettings.companionAdvertisesOnBonjour`: Advertise `_lokalbot._tcp` on the local network. Off leaves the Mac
reachable only at the addresses a device stored when it paired, such
as its Tailscale address.

#### Persisted boundary prevents skipping workdays without backfilling pre-opt-in history
`AppSettings.dreamingFirstEligibleDayKey`: First local calendar day eligible for dreaming during the current
enabled period. Persisting the boundary prevents a multi-day sleep from
silently skipping the last workday, without backfilling history from
before the user opted in.

#### Ask memory saves only on request; turning off keeps stored memories
`AppSettings.askMemoryEnabled`: Ask saves "Remember …" statements and gives the selected ones to the
Think model with each question. On by default; nothing is saved until
the person asks. Turning it off stops saving and use but keeps what is
already remembered until the person forgets it.

#### File search needs notice acknowledgment; disabling deletes the file index
`AppSettings.fileSearchEnabled`: Files (Settings → Files): search the folders the
person chooses by what is in them, with DigUp's engine. Off until they
turn it on after a notice; turning it off deletes the file index.

#### Searched folders are stored as absolute paths
`AppSettings.fileSearchFolders`: The folders Files reads, as absolute paths.

#### Media search reads 30-second audio windows and a frame per shot
`AppSettings.fileSearchIncludesMedia`: Files also reads recordings and video (sound in 30-second windows, a
frame per shot), so a moment can be found and opened.

#### Big first-pass reads wait for charger; a few new files read at once
`AppSettings.fileSearchReadsOnBattery`: Files reads a folder's first pass on battery too. Off, big reads wait
for a charger; a few new files are read right away either way.

#### Personal learning uses own meeting lines; preferences await review, principles never learned
`AppSettings.personalLearningEnabled`: After the overnight review, learn facts and goals about the person
from their own lines in that day's meetings (preferences wait for
review; principles are never learned). Needs Ask memory and the review.

#### Dictation learning keeps encrypted raw words at most two days, always reviewed
`AppSettings.personalLearningFromDictation`: Also learn from what the person dictates into other apps. Off by
default: while on, LokalBot keeps the raw dictated words, encrypted,
until the next learning pass reads them and for at most two days
(`DictationLearningLog`). Items found there always wait for review.

#### Routines are curated local writers with fixed read scopes, no shell or network
`AppSettings.memoryRoutinesEnabled`: Curated local writers only: routines have fixed read scopes, cannot run
shell/network actions, and write solely inside this chosen folder.

#### Weekday uses Calendar numbering, 1 Sunday to 7 Saturday
`AppSettings.memoryRoutineWeekday`: Calendar weekday (1 = Sunday ... 7 = Saturday) used by the weekly log.

#### Excluded app substrings are never captured and show as Private
`AppSettings.excludedApps`: Comma-separated app-name substrings that are never captured;
their time shows as "Private" in the timeline.

#### Fresh installs use fast 4B model; existing installs keep saved choice
`AppSettings.builtInModelID`: Fresh installs use the fast, broadly compatible 4B model. Existing
installs keep whatever their saved settings blob says.

#### OpenRouter stays private-routing by default; account policy is explicit opt-in
`AppSettings.openRouterDataPolicy`: Per-request OpenRouter provider policy. Private routing remains the
default for both new and migrated installs; following account policy is
an explicit opt-in because Think requests may contain sensitive context.

#### Mirrors HF-Mirror and ModelScope serve same verified files for mainland China
`AppSettings.modelDownloadSource`: Where pinned model files download from. Hugging Face unless the user
picks HF-Mirror or ModelScope, which serve the same verified files in
mainland China; see `ModelDownloadRouting`.

#### Remote inference needs explicit origin approval, loopback exempt, includes scheduled runs
`AppSettings.approvedRemoteInferenceOrigins`: Origins the user explicitly approved for sending transcript, OCR, and
agent context off this Mac, including scheduled digest and Dream runs.
Loopback endpoints never need approval.

#### ChatGPT plan model slug comes from signed-in account list
`AppSettings.chatGPTPlanModel`: Model slug for the ChatGPT plan, from the signed-in account's list.

#### Claude plan model is alias or full id; empty uses Claude Code default
`AppSettings.claudePlanModel`: Model for the Claude plan: an alias Claude Code accepts ("sonnet") or a
full model id. Empty uses Claude Code's own default.

#### Antigravity model slug from agy models; empty uses CLI default
`AppSettings.antigravityPlanModel`: Model slug for the Antigravity plan (`agy models`). Empty uses
Antigravity CLI's own default.

#### Gemini model slug from gemini models; empty uses CLI default Auto
`AppSettings.geminiPlanModel`: Model slug for the Gemini plan (`gemini models`). Empty uses Gemini
CLI's own default (Auto).

#### Records dismissal of the one-time ChatGPT plan notice
`AppSettings.chatGPTPlanNoticeAcknowledged`: The one-time "You're using your ChatGPT plan" notice was dismissed.

#### Notes-generation budget applies to every Think backend
`AppSettings.generationBudgetPreset`: Processing budget for meeting-notes generation. Applies to every Think
backend, not only the connection it is edited alongside.

#### Automatic keeps per-task budgets; chosen level also caps them
`AppSettings.thinkReasoningLevel`: How much the Think model reasons. Automatic keeps per-task budgets and
each server's own default; a chosen level also caps those budgets.

#### Agent reasoning level overrides Think; nil follows Think level
`AppSettings.agentReasoningLevel`: Agent Mode's own reasoning level, chosen in the Agent composer. Nil
follows `thinkReasoningLevel`.

#### True only for approved remote servers; unapproved, insecure, loopback are false
`AppSettings.usesRemoteMainLLM`: True only when the selected Think backend may actually send meeting or
workday text to an approved remote server. Configured-but-unapproved,
insecure, invalid, and loopback endpoints all return false.

#### Scheduled runs use same origin approval as manual Think requests
`AppSettings.allowsAutomaticMainInference`: Scheduled digest and Dream runs use the same origin approval as manual
Think requests: on-device backends, loopback, or an approved origin.

#### Think name follows summarizerBackend, ignoring leftover builtInModelID
`AppSettings.thinkModelDisplayName`: Name shown for the Think role. Always follows `summarizerBackend`;
leftover `builtInModelID` is ignored when Think is not the local GGUF.

#### Meta key falls back to Think key when Think points at api.meta.ai
`AppSettings.effectiveMetaModelAPIKey`: Meta's own key, else Think's key when Think already points at
api.meta.ai, so one key serves both.

#### UI-test film key wins over typed key and runner Keychain
`AppSettings.effectiveMetaModelAPIKey`: The film's key (or none for scripted replies) wins over what the
test typed into Settings, and a runner's Keychain never decides the run.

#### Fast live text may send meeting audio to api.meta.ai
`AppSettings.metaModelAPIApproved`: Fast live text may send meeting audio to api.meta.ai.

#### Template selects the section headings the summariser uses
`AppSettings.noteTemplate`: Which set of section headings the summariser uses (meeting, lecture,
study guide, podcast, freeform).

#### matchTranscript auto-detects language; otherwise prompt forces chosen language
`AppSettings.summaryLanguage`: Target language for the summary. `.matchTranscript` auto-detects from
the transcript text; otherwise the prompt forces the chosen language.

#### Separates acoustic voices per track after recording
`AppSettings.multiSpeakerDiarization`: Separate acoustic voices on microphone and system tracks after recording.

#### Fresh installs use Nemotron; older installs keep their backend
`AppSettings.diarizationModel`: Fresh installs use Nemotron. Decoding preserves the backend of older installs.

#### Mic speech is the user's unless corrected; disable for shared microphones
`AppSettings.microphoneIsUser`: Microphone speech is the user's unless corrected. Turn off when several
people share this Mac's microphone.

#### Cotyping is opt-in: needs Accessibility and Input Monitoring, types into other apps
`AppSettings.cotypingEnabled`: Master switch. Off by default — cotyping needs Accessibility + Input
Monitoring grants and types into other apps, so it is strictly opt-in.

#### Author name is folded into prompt as voice cue
`AppSettings.cotypingUserName`: Optional author name folded into the prompt as a voice cue.

#### Free-form style guidance such as concise or British spelling
`AppSettings.cotypingStyleNote`: Optional free-form style guidance ("concise", "British spelling", …).

#### Off restricts suggestions to one line
`AppSettings.cotypingMultiLine`: Allow multi-line completions (off keeps suggestions to one line).

#### Four-word target matches Cotypist and is topped up on accept
`AppSettings.cotypingMaxWords`: Soft length target; drives the per-request token budget. Four words is
what Cotypist usually shows; the suggestion is then topped up as it is
accepted, so it offers the next few words, not a sentence.

#### Initial idle before first measured request; later adaptive tiers
`AppSettings.cotypingDebounceMs`: Initial idle time before the first measured in-process request, and the
minimum pause on the model-server fallback. Once local latency is known,
the in-process route switches to its documented adaptive tiers.

#### Primary accept key granularity; full-accept key always takes all
`AppSettings.cotypingAcceptGranularity`: How much the primary accept key takes (the full-accept key always takes all).

#### Primary key accepts next word or phrase; full key accepts tail
`AppSettings.cotypingAcceptKey`: Primary accept key (next word/phrase) and the full-accept key (whole tail).

#### Punctuation takes its own press by default, matching Cotypist
`AppSettings.cotypingAutoAcceptTrailingPunctuation`: Accept punctuation attached to the next word in the same Tab press.
Off by default to match Cotypist: a full stop or comma takes its own
press, so the sentence can still be ended differently.

#### Space after accept off by default, matching CoTabby
`AppSettings.cotypingAddSpaceAfterAccept`: Add or consume a horizontal space after accepting a completed word.
Off by default to match CoTabby's shipped behavior.

#### Excluded app substrings preseeded with password managers and terminals
`AppSettings.cotypingExcludedApps`: Comma-separated app-name / bundle-id substrings never suggested into.
Preseeded with password managers and terminals.

#### Excluded domains include subdomains, read via Accessibility in browsers only
`AppSettings.cotypingExcludedDomains`: Comma-separated domains where cotyping never runs (bare host or full URL;
subdomains included). Read over Accessibility in browsers only.

#### Integrated terminals off by default: history conflicts with ghost text
`AppSettings.cotypingSuggestInIntegratedTerminals`: Allow suggestions in xterm.js integrated terminals (VS Code / Cursor /
browser terminals). Off by default because terminal history/completions
conflict with ghost text; standalone terminal apps remain blocked.

#### App and window title context read via Accessibility, on-device
`AppSettings.cotypingUseAppContext`: Condition suggestions on the focused app + window title / field label
(e.g. the email subject or chat channel). On by default; reads window
titles via Accessibility (already required for cotyping), stays on-device.

#### Clipboard read fresh at generation time, never persisted
`AppSettings.cotypingUseClipboard`: Fold the current clipboard into the prompt as context, so suggestions can
build on what you just copied. On by default; read fresh at generation
time, never persisted, and ignored while cotyping itself is disabled.

#### Visible Accessibility text context is transient; old settings keep prior value
`AppSettings.cotypingUseVisibleContext`: Separately opt in to relevant meeting notes/outcomes and attributed work
memory. Screen-derived facts require their independent permission too.
Transient Accessibility text above the focused field. Separate from saved screen memory.
On for new installs; settings saved before this default keep theirs (see the decoder).

#### Window OCR needs Screen Recording; image and text held in memory only
`AppSettings.cotypingUseWindowText`: Read the whole focused window with on-device text recognition. On for
every install, including saved settings that predate it (see the
decoder). Needs Screen Recording; the image and text are held in memory only.

#### Host font and color read via Accessibility, cached per field
`AppSettings.cotypingMatchHostStyle`: Match the host field's font and text color so ghost text reads as a
continuation. On by default; reads via Accessibility (cached per field).

#### Chromium full accessibility mode gives caret and font from the page
`AppSettings.cotypingChromiumEnhancedAccessibility`: Ask Chrome-based browsers for their complete accessibility mode, so
the caret and font size come from the page instead of the screen.

#### Auto picks inline or popup ghost text by caret quality
`AppSettings.cotypingMirrorPreference`: How ghost text is shown: inline at the caret, or a popup when geometry is
unreliable / the caret is mid-line. `.auto` defers to caret quality.

#### Autocorrect uses NSSpellChecker and suppresses continuation on typos
`AppSettings.cotypingAutocorrect`: One-key inline autocorrect of the word you're typing (NSSpellChecker).
On by default; suppresses a continuation on an unresolved typo.

#### Colon-shortcode emoji autocomplete, on by default
`AppSettings.cotypingEmoji`: Inline `:shortcode:` emoji autocomplete (e.g. `:rocket:` → 🚀). On by default.

#### Slash macros cover math, dates, units, currency, random
`AppSettings.cotypingMacros`: Inline `/macro` autocomplete (math `/5+5`, dates `/today`, units `/10km->mi`,
currency `/100usd to eur`, random `/d20`). On by default.

#### Comma-separated writing languages used as prompt voice hint
`AppSettings.cotypingLanguages`: Languages you usually write in (comma-separated) — a prompt voice hint.

#### Free-form glossary and notes folded into the prompt
`AppSettings.cotypingExtendedContext`: Free-form notes / glossary / jargon folded into the prompt as context.

#### Cotyping uses a dedicated llama.cpp server so summarization never contends
`AppSettings.cotypingBuiltInModelID`: Catalog model id for cotyping. Cotyping always runs its own dedicated
llama.cpp model on a separate server instance, so
inline suggestions never contend with summarization for the shared
server. Defaults to the recommended cotyping model.

#### In-process libllama default; HTTP llama-server fallback for non-GGUF or load failure
`AppSettings.cotypingInProcessRuntime`: When true (default), cotyping uses the in-process `libllama` runtime for
the selected GGUF backend on Apple Silicon; false forces the HTTP
`llama-server` path. The HTTP fallback also covers non-GGUF backends and
any in-process load failure regardless of this flag.

#### Autocomplete runs on-device, on Think server, or a separate server
`AppSettings.cotypingBackend`: Where autocomplete runs: the model above on this Mac (default), Think's
own server, or a separate server. See `CotypingRoute`.

#### OpenAI-compatible URL for server route, cloud or local network
`AppSettings.cotypingServerBaseURL`: OpenAI-compatible base URL for `.server`: a cloud API or a model server
on this Mac or another device on the user's network.

#### Empty model uses Think's own model on thinkServer route
`AppSettings.cotypingThinkServerModel`: Model ID for `.thinkServer`; empty uses Think's own model.

#### Autocomplete origins approved separately because typed text leaves other apps
`AppSettings.approvedRemoteAutocompleteOrigins`: Origins approved for autocomplete specifically. Separate from
`approvedRemoteInferenceOrigins`: autocomplete sends what is typed in
other apps, which approving a server for Think never covered.

#### Learns encrypted accepted text with sanitized hint; skips secure fields, terminals, code editors
`AppSettings.cotypingUseLocalLearning`: Learn from accepted continuation text, encrypted locally. Stores accepted
text plus a short sanitized prefix/context hint for ranking — never full
raw typing streams — and skips secure fields, terminals, and code editors.

#### Number of similar accepted completions added to the prompt
`AppSettings.cotypingLearningExamplesInPrompt`: Number of similar accepted completions folded into the next prompt.

#### Version 4 moved defaults to match Cotypist
`AppSettings.cotypistDefaultsCotypingSettingsVersion`: Defaults before version 4, which moved both to what Cotypist does.

#### Pre-v4 stored true was a default, not a choice
`AppSettings.migratedCotypingAutoAcceptTrailingPunctuation`: Attaching punctuation was the default before version 4 and had no
control in Settings, so a stored `true` from then is that default, not
a choice. From version 4 on the stored value is the user's.

#### Token ceiling ceil(words*1.3), floor 5, doubled multi-line up to 120
`AppSettings.cotypingMaxResponseTokens`: Token ceiling for one completion: ceil(words * 1.3), floor 5, doubled for
multi-line up to 120.

#### On-device cotyping pinned to built-in backend independent of summarizer
`AppSettings.cotypingTextEngineSettings`: Settings the on-device cotyping route builds its `TextEngine` from: a
copy pinned to the built-in backend with `cotypingBuiltInModelID`
(independent of the summarizer's backend/model). Server routes are
resolved by `cotypingRoute` instead.

#### Stale composition model IDs inherit Main LLM instead of catalog default
`AppSettings.dictationCompositionTextEngineSettings`: Settings used by the compose pass after dictation ASR. A valid override
is pinned to the local built-in backend without changing the Main LLM
configuration used by summaries, Ask, and Agent Mode. Missing or stale
model IDs safely inherit the Main LLM instead of falling through to an
unrelated catalog default.

#### Think reasoning level does not apply to dictation composition model
`AppSettings.dictationCompositionTextEngineSettings`: The Think reasoning level belongs to the Think model, not this one.

#### Echo cancellation needs Standard mic mode; Voice Isolation breaks adaptive filter; off by default
`AppSettings.echoCancellation`: Subtract the system-audio track from the microphone track before
transcription, using an adaptive filter. Works on meetings already
recorded, at the cost of a codec generation: both tracks are AAC by
then. Harmless with headphones — with no echo to find, the filter
converges to silence and the original track is used instead.

Requires the microphone mode for the recording app to be Standard
(Control Center → microphone icon → the app's own row). macOS Voice
Isolation processes the input nonlinearly before this ever sees it,
which breaks the assumption an adaptive filter depends on — measured,
echo return loss drops from ~17 dB to ~3 dB with Isolation on, the
latter indistinguishable from noise. A call's *other* participants can
still get Voice Isolation: it is set per capturing app, not on the
microphone itself, so setting the meeting app to Isolation and this
app to Standard gets both — isolated audio on the call, a genuine echo
signal for this filter to remove.

Off by default while the filter is new: it rewrites the microphone
track every transcription takes as input, so a bad pass is not
something the user can see went wrong.

#### Settings key is internal so DataMigration can copy prior installs
`AppSettings.key`: UserDefaults key for the encoded settings blob. Internal (not private)
so `DataMigration` can copy a prior install's settings under it.

#### UI tests use a disposable defaults suite to protect real preferences
`AppSettings.defaults`: UI tests launch the app out-of-process. Let them point settings at a
disposable suite so test runs do not inherit or mutate the user's real
app preferences.

#### languageHint is legacy key from builds before typed language selection
`AppSettings.CodingKeys.languageHint`: legacy key used by builds before typed language selection

#### Unreadable privacy fields must trigger a one-time notice, never silent reset
`AppSettings.corruptedSettingsKeys`: Names of settings whose stored values were present but unreadable, so
they silently fell back to defaults during decode. Transient — never
encoded — and empty in the normal case, including when an older build's
blob simply lacks newer keys. `AppState` surfaces a one-time notice
when this is non-empty: a privacy-relevant field resetting itself (say,
screenshot capture) must never go unannounced.

#### Marker used when the whole stored blob was unreadable
`AppSettings.wholeStoreCorruptionMarker`: Marker used instead of field names when the entire stored blob was
unreadable and every setting reset to defaults.

#### Unreadable stored data is corruption, not first run; reset and announce
`AppSettings.load`: Stored data exists but is unreadable — that is corruption,
not a first run. Reset, but say so.

#### UI-test demo state applied at source for multiple AppState instances
`AppSettings.load`: Marketing captures launch more than one AppState while SwiftUI
assembles its scenes. Apply demo state at the source so every one of
those instances renders the same enabled feature state; production
builds never compile this override.

#### Tolerant decoding keeps older builds' settings instead of resetting
`AppSettings.init`: Tolerant decoding: settings saved by an older build (fewer keys) keep
working instead of silently resetting everything to defaults.

#### Absent key keeps default silently; unreadable key is recorded as corruption
`AppSettings.init(from:)`: Two very different reasons a stored value can be unusable: the key
is absent (an older build wrote this blob — expected, keep the
default silently) or the key is present but unreadable (corruption
or hand-editing — keep the default, but record the field so the
app can tell the user what silently reset).

#### Existing installs keep original Compose dictation behavior
`AppSettings.dictationIntent`: Existing installations keep the original Compose behavior.

#### Stored shortcut that blocks typing falls back to Option Space
`AppSettings.dictationShortcut`: A stored shortcut that would now block typing falls back to ⌥ Space.

#### Old settings keep Live Radar on when Meta Muse was approved
`AppSettings.liveRadarEnabled`: Live Radar used to be offered once Meta Muse was approved. Settings
saved before it had its own switch keep it on with that approval.

#### Blob without diarization field keeps Community-1; fresh stores get Nemotron
`AppSettings.diarizationModel`: A persisted blob without this field predates model selection and used
Community-1. Preserve that backend; only a fresh settings store gets
the new Nemotron default. Valid explicit choices always round-trip.

#### Saved settings without key keep it off; default-on applies to new installs
`AppSettings.cotypingUseVisibleContext`: Saved settings without the key predate it and keep it off: the
on-by-default applies to new installs only.

#### Window text is on for everyone including saved settings without key
`AppSettings.cotypingUseWindowText`: On for everyone: saved settings without the key turn it on too.

### `LokalBot/Models/Settings/SettingDescriptor.swift`

#### Label is the row's plainer wording; search finds by title or label
`SettingDescriptor.label`: What its row on the page says, where that is plainer than the name.
Search shows this and finds the setting by either.

#### User-entered names, prompts, URLs and paths are never translated
`SettingDescriptor.currentValue`: User-entered names, prompts, URLs and paths must never be translated.

#### Phones & tablets controls appear only while sharing is on
`SettingDescriptor.focusTarget`: Phones & tablets shows its other controls only while sharing is on.

#### Former page names still find their settings
`SettingDescriptor.search`: A page's earlier names still find its settings.

### `LokalBot/Models/Settings/SettingsStatus.swift`

#### Permission rows follow macOS privacy grants plus Calendar in page order
`SettingsPermission`: A permission row on Privacy & permissions: macOS's four privacy grants
and Calendar, in the order the page lists them.

#### Calendar has no AppPermission because EventKit grants it
`SettingsPermission.appPermission`: Nil for Calendar, which EventKit grants.

#### Lists features that can use it whether or not enabled
`SettingsPermission.usedBy`: The features that can use it, whether or not they are on now.

#### Allow title is what Overview asks for
`SettingsPermission.allowTitle`: What Overview asks for.

#### Some grants take effect only at next launch
`SettingsPermission.needsRelaunchAfterGrant`: A grant made while LokalBot runs reaches these only at the next launch.

#### Model types supply catalog key and arguments; view localizes
`SettingsText`: Interface text a model type puts together: a catalog key and what fills
its placeholders. The view looks the key up in the app's language.

#### One line under page header: works, or the one control that fixes it
`SettingsStatusLine`: One line under a Settings page's header: whether the feature works, and
when it does not, the one control that fixes it.

#### Need tone is amber with a warning sign
`SettingsStatusLine.Tone.need`: Something the person has to do: amber, with a warning sign.

#### OK tone is a green dot
`SettingsStatusLine.Tone.ok`: Working: a green dot.

#### Quiet tone is gray for off or already in progress
`SettingsStatusLine.Tone.quiet`: Off, or waiting on something that is already under way: gray.

#### Online tone is amber with a globe for data leaving the Mac
`SettingsStatusLine.Tone.online`: Something leaves this Mac: amber, with a globe.

#### Progress value is optional, shown when known
`SettingsStatusLine.Tone.progress`: Under way, with how far along it is when that is known.

#### Allow asks for permission the same way Privacy & permissions does
`SettingsStatusLine.Action.allow`: Ask for the permission, the same way Privacy & permissions does.

#### Overrides button title for open actions other than Change
`SettingsStatusLine.actionTitle`: The action's button title, for an `open` whose title is not "Change…".

#### Buttons fix something; links only navigate
`SettingsStatusLine.isLink`: Buttons fix something; links only take you somewhere.

#### All Settings status derives from real state so every place agrees
`SettingsStatus`: What the Settings window says about the state of each feature: the
"Off" and "Paused" marks and count badges in its list, what needs the
person on Overview, each permission's row on Privacy & permissions, and
the status lines under every page's header. Derived from real state and
nothing else, so each of those places says the same thing.

#### Missing means an enabled feature uses it and it is not granted
`SettingsStatus.Access.missing`: A feature that is on uses it, and it is not granted.

#### Not needed means not granted and no enabled feature uses it
`SettingsStatus.Access.notNeeded`: Not granted, and nothing that is on uses it.

#### Paused means on but blocked by missing permission or model
`SettingsStatus.RowState.paused`: On, but blocked by a missing permission or model.

#### Calendar not asked yet means LokalBot can still request it
`SettingsStatus.CalendarAccess.notAsked`: macOS has not asked yet, so LokalBot can.

#### After refusal only System Settings can enable Calendar
`SettingsStatus.CalendarAccess.refused`: Refused: only System Settings can turn it on.

#### Feature names are shown in Needed for lists
`SettingsStatus.Feature`: A feature that uses a permission, named in "Needed for: …".

#### Bytes set only when a download is needed and size known
`SettingsStatus.Model.bytes`: What its download weighs, when one is needed and its size is known.

#### False for servers and Apple Intelligence, which download nothing
`SettingsStatus.Model.downloads`: False for a server or Apple Intelligence: nothing downloads.

#### Unread permissions count as granted to avoid warning flash on open
`SettingsStatus.Input.granted`: The real grants. A permission with no entry has not been read
yet and counts as granted, so no warning flashes on open.

#### Whole minutes until running downloads finish, once estimable
`SettingsStatus.Input.downloadMinutesLeft`: Whole minutes until the running downloads finish, once that can be told.

#### Only models present that failed their check
`SettingsStatus.Input.failedChecks`: Models that are here and did not answer their check.

#### Counts kinds of data external agents may read
`SettingsStatus.Input.agentKinds`: The kinds of data external agents may read.

#### Need's page is where it is fixed and carries the badge
`SettingsStatus.Need.page`: The page where it is fixed, which carries the count badge.

#### Autocomplete omitted from Screen Recording since it never asks for it
`SettingsStatus.features(using:)`: The features that are on and use the permission now. Autocomplete
reads the focused window only when Screen Recording is already
granted and never asks for it, so it is not listed there.

#### Granted this launch but only working after next launch
`SettingsStatus.permissionsAwaitingRelaunch`: Granted since this launch began, and only working after the next one.

#### Autocomplete model required only while Autocomplete is on
`SettingsStatus.requiredModels`: Transcribe and Think always; Autocomplete's model only while
Autocomplete is on.

#### Overall fraction needs known sizes and progress for all downloads
`SettingsStatus.downloadFraction`: 0…1 across the models that are downloading, when their sizes and
progress are known.

#### Arrived and total bytes used to estimate remaining time
`SettingsStatus.runningDownload`: How much of the running downloads has arrived, and what they weigh
together, for telling how long they still take.

#### Every AI server sent to, each named once
`SettingsStatus.remoteHosts`: Every server the AI features send to, each named once.

#### Summary is second line of the LokalBot row
`SettingsStatus.summary`: The second line of the LokalBot row at the top of the list.

#### Overview headline and detail line
`SettingsStatus.headline`: Overview's headline, and the line under it.

#### Off or Paused mark shown at right of feature row
`SettingsStatus.rowState`: "Off" or "Paused" at the right of a feature's row.

#### Badge counts needs on the page where they are fixed
`SettingsStatus.badge`: How many things need the person on the page where they are fixed.

#### Status lines ordered most pressing first
`SettingsStatus.lines(for:)`: The status lines under a page's header, most pressing first.

#### Calendar refusal switches button to Open System Settings
`SettingsStatus.allowTitle`: macOS asks for Calendar once. After a refusal only System Settings
can turn it on, and the button says so.

#### Grants waiting for next launch are shown on pages that use them
`SettingsStatus.relaunchLines`: A grant that waits for the next launch, for the pages that use it.

#### Download button moves to this line while header shows Cancel
`SettingsStatus.modelLines`: The header's own button downloads them all. While it shows
Cancel for a running download, this line keeps the button.

#### Ready sizes must match the sizes announced at download
`SettingsStatus.modelLines`: The same sizes the download was announced with.

#### Failed check line opens the sheet that runs checks
`SettingsStatus.modelChecksFocus`: The setting a failed check's line opens: the sheet that runs the checks.

#### Total for Download all; nil when nothing missing or size unknown
`SettingsStatus.bytesToDownload`: What every model that still has to arrive weighs together, for the
header's "Download all" button. Nil when nothing is missing or a size
is unknown.

#### Shows as much progress info as is known
`SettingsStatus.downloadingText`: "Downloading · 3.7 GB of 9 GB · about 5 minutes left", with as much
of that as is known.

#### Visiting the current page changes nothing; history capped at 50
`SettingsPageHistory.visit`: A page chosen from the list, a search result or a deep link. Choosing
the page already shown changes nothing.

### `LokalBot/Models/Settings/SettingsSubpage.swift`

#### Subpages open in place of a Settings page with a way back
`SettingsSubpage`: A page that a row of a Settings page opens in its place, with a way
back: Autocomplete's writing profile, skipped apps, usage and advanced
settings, and Dictation's writing profile and recent dictations.

#### Subpage setting IDs let search and deep links open it
`SettingsSubpage.settingIDs`: The settings that are edited on this page, so settings search and
deep links open it and land on them.

#### Writing profile fields belong to Autocomplete and open there
`SettingsSubpage.containing`: The page that holds a setting, when it is not on its Settings page
itself. The writing profile's fields are Autocomplete's settings, so
they open there.

### `LokalBot/Views/Settings/CodingAgentEvidenceSettings.swift`

#### Sessions on by default; notes off until notice; agents' own files untouched
`CodingAgentEvidenceSettings`: Settings → Screen & Activity → Coding agent sessions. Sessions are on by
default and their saved records can be deleted here. Notes are off until
turned on after a notice. The agents' own files stay untouched either way.

### `LokalBot/Views/Settings/CompanionSettingsView.swift`

#### Sharing starts a LAN and Tailscale listener; controls exist only while on
`CompanionSettingsSections`: Settings → Phones & tablets. Turning sharing on starts a listener for
paired devices on the local network and Tailscale; everything below the
switch only exists while it is on.

#### Apply port when editing ends so half-typed numbers do not restart listener
`CompanionPortField`: The listener's port, applied when editing ends so a half-typed number
never restarts the listener.

### `LokalBot/Views/Settings/EmailSettings.swift`

#### One catalog key split across lines only to keep line short
`EmailSettingsSection.readingDetails`: One catalog key, split only to keep the line short.

### `LokalBot/Views/Settings/FileSearchSettings.swift`

#### Nothing is read until Files is turned on after notice and a folder chosen
`FileSearchSettingsSection`: Settings → Files. Nothing is read until the person
turns Files on after a notice and chooses a folder.

#### Suggestion opens estimate sheet; macOS asks folder access only then
`FileSearchSettingsSection.suggestions`: One click opens the same estimate sheet as Add Folder…; macOS asks for
access to the folder only then.

#### Estimate counted from metadata; nothing read until added; adding does not wait
`FileFolderAddSheet`: Before a folder is added: what it holds and how long its first read takes
on this Mac, counted from metadata while the sheet is open. Nothing is
read until the person adds it, and adding doesn't wait for the count.

### `LokalBot/Views/Settings/MemoryHealthSection.swift`

#### Unexpected status strings outside both lists ask for attention
`MemoryHealthTone.status`: Status strings outside both lists are unexpected, so they ask for a look.

#### Only live input is good; quiet states idle; stalls and missing tap need attention
`MemoryHealthTone.audio`: Meeting audio: only live input is good; quiet states between meetings
are idle; stalls, recovery, degradation, and a missing tap need a look.

#### One grid aligns columns; each row is one accessibility element on its name
`MemoryHealthTable`: Health rows in aligned columns: symbol, name, when it last happened, and
status. One grid keeps the columns straight whatever the text lengths;
each row reads to assistive technology as one element on its name.

#### Shared minimum title width aligns detail column across sections
`MemoryHealthTable.body`: A shared minimum lines the detail column up across sections.

#### Word keeps meaning without color; only user-needed states get filled capsule
`MemoryHealthStatus`: A status shared by health readouts: a toned dot and a word, the word
keeping its meaning without color. Only states that need the user get a
filled capsule, so a healthy page stays quiet.

### `LokalBot/Views/Settings/PersonalContextSettings.swift`

#### Show five suggestions before Show more so kept items stay in view
`PersonalContextSettings.collapsedSuggestionLimit`: Suggestions shown before "Show N more", so kept items stay in view.

#### Same grant as External Agents' box so sharing is set up here
`PersonalContextSettings.agentsSection`: The same grant as External Agents' box, so sharing is set up here.

#### Dictated words are gone once read, so nothing can retract the item
`PersonalContextSettings.hasRemovableSource`: Dictated words are gone once read, so nothing can retract the item.

#### Attach editor sheet to the opening row because lazy Form rows may not exist
`View.editorSheet`: The editor sheet hangs off the row or button that opens it: Form
rows load lazily, so a sheet on another row may not exist to present.

#### onSave returns an error message to keep sheet open; nil closes it
`PersonalClaimEditor`: Add or edit one claim. Returns an error message from `onSave` to keep the
sheet open; nil closes it.

### `LokalBot/Views/Settings/ResourceMonitorSection.swift`

#### Whole-app figures use native process accounting; model rows merge runtimes and retained models
`ResourceMonitorSection`: A compact live readout in Settings → Diagnostics. Whole-app figures use
native process accounting for LokalBot and its helpers; model rows merge
subprocess-backed GGUF/ONNX runtimes with retained CoreML/MLX models.

#### Pure logic kept outside SwiftUI state so count, stale-PID and estimate rules are testable
`ResourceMonitorPresentation`: Pure presentation logic kept outside the SwiftUI state lifecycle so the
model count, stale-PID filtering, and measured-vs-estimated memory rules are
deterministic unit-test targets.

#### Lease note only on GGUF residency rows; nil when idle
`ResourceMonitorPresentation.Model.leaseNote`: "in use — chat (interactive)" while the broker holds leases on this
row; nil when idle. Only GGUF (residency) rows carry notes.

### `LokalBot/Views/Settings/SettingsApprovalView.swift`

#### Approve applies exactly the listed changes through Settings paths; Deny changes nothing
`SettingsApprovalView`: The approval window: one card for each terminal request waiting for the
person, listing every change it makes in full. Approve applies exactly
those changes through the same paths as Settings; Deny changes nothing.

#### Show every value in full because this is what the person approves
`SettingsApprovalCard`: Every value in full: this is what the person approves.

#### Approval failure stays on the card as its problem
`SettingsApprovalCard`: A failure stays on the card as its problem.

#### Counts match retention review; approving deletes exactly this
`SettingsApprovalRetention`: The same counts the retention review in Settings shows. Approving deletes
exactly this.

#### Approval lists name every added and removed entry; others show before and after
`SettingSpec.changeLines`: What the approval card says a change does, in full. Lists name every
entry added and removed; other values show before and after.

#### URLs omit user info and query in displayed values
`SettingSpec.displayText`: A setting's whole value as the person reads it. URLs leave out user
info and query.

### `LokalBot/Views/Settings/SettingsOverview.swift`

#### Learned items wait for review but block nothing
`SettingsOverview.learnedRow`: What LokalBot learned waits for a look, but stops nothing from working.

#### Shared by Overview and Privacy & permissions
`SettingsLibraryRow`: Where the library is and how much it holds, with a way to see it in
Finder. Overview and Privacy & permissions share it.

#### Privacy & permissions names the folder; Overview says what is in it
`SettingsLibraryRow.showsPath`: Privacy & permissions names the folder; Overview says what is in it.

### `LokalBot/Views/Settings/SettingsPageHeader.swift`

#### Autocomplete on a server is appended since the download plan omits it
`SettingsStatus.Input.init`: Autocomplete on a server: nothing downloads, so the plan leaves it out.

#### Observer owns all status inputs so the root does not; writes only on change
`SettingsStatusObserver`: Keeps a `SettingsStatus` current. It observes everything the status is
derived from, so the window's root does not have to, and writes the
status only when it changes.

#### Status button, Overview row and Privacy row share actions so permissions are asked identically
`SettingsStatusActions`: What a status line's button, an Overview row and a Privacy & permissions
row all do, so a permission is asked for the same way everywhere.

#### Autocomplete model downloads only while Autocomplete is on
`SettingsStatusActions.perform`: Autocomplete's model comes along only while Autocomplete is on.

#### Button reports its screen frame so the permission walkthrough starts from it
`SettingsFixButton`: A button that runs a status action. It reports where it is on screen, so
the permission walkthrough can start from it.

#### Header layout; use a Section in grouped forms, settingsPageHeaderCard elsewhere
`SettingsPageHeader`: How every Settings page opens: the page's icon, name and one-line
description, "Try it…" where the feature has something to try, the
page's main switch where it has one, and under them one status line for
each thing to know, with the button that fixes it.

In a grouped `Form`, put it in a `Section` of its own as the first row.
On a page that is not a form, add `.settingsPageHeaderCard()`.

#### Setting ID lets settings search and deep links land on the switch
`SettingsPageHeader.switchSettingID`: The setting the main switch stands for, so settings search and
deep links land on it.

#### Measure library size off the main thread; libraries hold many thousands of files
`SettingsLibrarySize.measure`: How much the library holds without the downloaded models, read off the
main thread: a long-used library has many thousands of files.

### `LokalBot/Views/Settings/SettingsPrivacyPage.swift`

#### Privacy page contents; PRIVACY.md is the contract for every sentence
`SettingsPrivacySections`: Settings → Privacy & permissions: the one place that asks for macOS
permissions and shows what leaves this Mac. Each permission says which
features use it and where it stands; each server that receives something
is listed with the control that revokes it; sharing with agents and with
phones is summed up and opens its own page, where its consent lives.
PRIVACY.md is the contract for every sentence here.

#### Calendar provider observed for the error a request can end with
`SettingsPrivacySections.calendar`: Observed for the error a Calendar request can end with.

#### Revocation confirmations attached to one row so they are presented once
`SettingsPrivacySections.body`: On one row, so the confirmations are presented once.

#### Allow stays offered for not-needed permissions since later features or window reading use them
`SettingsPrivacySections.permissionRow`: Still offered: a feature turned on later, or Autocomplete
reading the focused window, uses it once it is granted.

#### Revocation confirmations shared by Models and Privacy so both revoke identically
`RemoteOriginRevocation`: The two confirmations that revoke a server's approval, shared by Models
and Privacy & permissions so both revoke the same way.

### `LokalBot/Views/Settings/SettingsSharedRows.swift`

#### Row name is the switch's only accessibility label; a hidden label is read twice
`SettingsSwitchRow`: The row's name is the switch's one accessibility label. A
hidden label of its own would be read as well.

#### Kind access here is the same grant as that kind's box on AI agents
`AgentKindAccessSection`: One kind of agent read access, shown on the page of the data it covers.
It is the same grant as that kind's box on AI agents.

#### Autocomplete and Dictation Compose edit the same writing profile settings in place
`WritingProfileFields`: The writing profile Autocomplete and Dictation's Compose share. Both pages
show these fields, bound to the same settings, so neither sends you to the
other to edit them.

### `LokalBot/Views/Settings/SettingsSidebar.swift`

#### Group headings are plain rows since a List Section reaches accessibility unnamed
`SettingsSidebar.body`: Headings are plain rows, like the main sidebar's: a List
Section reaches accessibility as a group with no name.

#### Gap above last page is row padding; empty spacer rows failed VoiceOver audit
`SettingsSidebar.body`: The gap above the last page is padding on its row. An empty
spacer row was a list cell with nothing to read, which
VoiceOver stopped on and the accessibility audit flagged.

#### Each text carries its own accessibility identifier; one on the row would replace both
`SettingsIdentityRow.body`: Each text carries its own identifier: one on the row would
replace both.

#### Selected prominent row falls back to its foreground so glyphs do not vanish into teal
`SettingsCategoryRow`: Category glyphs carry the accent like Agent's starters. A selected row on
the prominent accent highlight falls back to the row's own foreground so
nothing disappears into a teal fill.

### `LokalBot/Views/Settings/SettingsView.swift`

#### Model choices and options open as sheets so no setting sends you elsewhere
`SettingsView.sheet`: Model choices and transcription options open over the page that uses
them, so no setting sends you to another page to finish.

#### Settings window shows its own error toast; it no longer sits above the main window's bar
`SettingsView.body`: Settings no longer sits above the main window's error bar.

#### Register window opener so a window opened from the menu bar alone can open others
`SettingsView.body`: Lets a window opened from the menu bar alone open the others.

#### A row's subpage belongs to the Settings page that opened it
`SettingsView.body`: A row's page belongs to the Settings page that opened it.

#### Focused setting ID is consumed so reopening Settings does not reopen the sheet
`SettingsView.revealFocusedSetting`: Consumed, so reopening Settings does not open the sheet again.

#### Settings search filters across all tabs regardless of the selected tab
`SettingsView.searchResults`: Spec §2.5: the search field filters across ALL tabs — a non-empty
query shows every matching section regardless of the selected tab,
plus a jump row into the Models tab when its keywords match.

#### Flush saved settings before DockPolicy.sync because it reads saved settings
`SettingsView.generalSection`: The Dock policy reads saved settings.

#### Ask sources summary is one of the few rows that opens another page
`SettingsView.askSourcesSection`: Where Ask's answers come from. Each source is set up on its own page,
so this summary is one of the few rows that opens another page.

#### Digest uses only the first characters of sanitized instructions; warn instead of dropping silently
`SettingsView.digestInstructionsField`: The digest uses only the first characters of the cleaned-up
text; say so instead of dropping the rest silently.

#### Repository opens in the default browser; LokalBot itself sends nothing
`SettingsView.aboutSection`: The repository opens in the default browser; LokalBot itself sends nothing.

#### Zip diagnostics off the main thread; up to 48 MB froze the app and recording timer
`SettingsView.exportDiagnostics`: Copying and zipping up to 48 MB of logs takes seconds. On the main
thread the whole app stood still for them, a recording's timer
included.

#### Release builds explain the state; only dev builds point at release setup
`SettingsView.inactiveUpdaterNote`: Release builds explain the state; only dev builds point at release setup.

#### Bind the cached registration, never SMAppService, which SwiftUI re-reads on every update
`LaunchAtLoginToggleRow`: Binds the cached registration, never `SMAppService` itself: SwiftUI re-reads
a toggle's binding on every update while it is visible.

#### Observe the coordinator, which forwards per-kind changes so agent-setup grants show at once
`AgentReadAccessRows`: The one switch for reading LokalBot data, and a box for each kind under
it (`AgentReadAccess`). Observes the coordinator, which forwards every
per-kind manager's changes, so grants from agent setup show at once.

### `LokalBot/Views/Settings/ShortcutRecorder.swift`

#### Recording accepts a key with modifiers or a modifier chord; global shortcuts are suspended meanwhile
`ShortcutRecorder`: Click, then press a new global shortcut: a key with modifiers, or two or
more modifiers pressed together and released (⌃⌥) where `validate` allows
it. Esc cancels. While recording, the global shortcuts are suspended so the
current one can be pressed too.

#### Track modifiers since last release so a chord records though keys go up one at a time
`ShortcutRecorder.chordModifiers`: Every modifier held since the last release, so ⌃⌥ is recorded as one
chord even though its keys go down and up one at a time.

#### A non-modifier key ends the chord, so the key is included in the shortcut
`ShortcutRecorder.handle`: A key ends the chord: ⌃⌥ then D records ⌃⌥ D, not ⌃⌥.

#### Resume the current shortcut first so the new one replaces it
`ShortcutRecorder.accept`: Resume the current shortcut first, so the new one replaces it.

#### App keeps the previous shortcut when the system refuses the new one
`ShortcutRecorder.commit`: The app keeps the previous shortcut when the system refuses a new one.

### `LokalBotTests/Models/Settings/AppSettingsTests.swift`

#### Older blobs lacking newer keys are normal tolerant decoding and stay silent
`AppSettingsTests.testAbsentKeysAreNotReportedAsCorruption`: An older build's blob simply lacks newer keys — that is the normal
tolerant-decoding case and must stay silent.

#### Meet naming removed; remembering speakers is always on
`AppSettingsTests.testRetiredSpeakerSettingKeysDecodeSilentlyAndAreDropped`: Meet naming was removed; remembering speakers is always on.

#### Wrong-shaped value resets to default and is recorded by name, as flipped privacy settings matter
`AppSettingsTests.testCorruptFieldFallsBackToDefaultAndIsReported`: Key present but the value is the wrong shape: the field resets to
its default, and — because a silently flipped privacy setting is a
real event — the reset is recorded by name.

#### No stored blob is a genuine first run, nothing to report
`AppSettingsTests.testWholeStoreCorruptionResetsWithMarker`: No stored blob at all: a genuine first run, nothing to report.

#### Unreadable blob resets to defaults but is reported
`AppSettingsTests.testWholeStoreCorruptionResetsWithMarker`: Unreadable blob: reset to defaults, but say so.

#### Pre-stabilization settings stored display strings and must keep decoding
`AppSettingsTests.testDecodesLegacyTranscriptionModelDisplayString`: Settings written before TranscriptionModelChoice raw values were
stabilized persisted the display strings — they must keep decoding so
an update never silently resets a user's model choice.

#### Old screenshot switch maps to visual context mode
`AppSettingsTests.testLegacyScreenshotChoiceMapsToVisualContext`: Legacy settings that predate the typed screen-context mode still map the
old screenshot switch to visual context.

#### OCR text prunes with pixels by default; keeping forever is opt-in
`AppSettingsTests.testKeepOCRTextForeverDefaultsFalse`: The default prunes OCR text on the same schedule as the pixels;
keeping it forever is the explicit opt-in.

#### Evening digest auto-generates at 18:00, matching daily memory export default hour
`AppSettingsTests.testDayDigestDefaultsToAutomaticEveningGeneration`: Fresh installs generate the evening digest without a click; 18:00
matches the daily memory export's default refresh hour.

#### Blobs lacking digest keys decode to new defaults without disabling schedule
`AppSettingsTests.testLegacySettingsDecodeWithDayDigestDefaults`: Settings blobs from builds without the day-digest keys decode to the
new defaults instead of failing or disabling the schedule.

#### Settings predating menuBarOnly keep working and default to menu-bar-only
`AppSettingsTests.testDecodesSettingsWithoutMenuBarOnlyKeyAsDefault`: Settings persisted by a build that predates the key keep working and
fall back to the menu-bar-only default rather than resetting everything.

### `LokalBotTests/Models/Settings/SettingsStatusTests.swift`

#### Unread permission counts as granted so no warning flashes while window opens
`SettingsStatusTests.testUnreadPermissionsCountAsGranted`: A permission that has not been read yet counts as granted, so no
warning flashes while the window opens.

#### PRIVACY.md: Autocomplete reads focused window only if Screen Recording already granted
`SettingsStatusTests.testAutocompleteNeverAsksForScreenRecording`: PRIVACY.md: Autocomplete reads the focused window only when Screen
Recording is already granted and never asks for it.

#### Microphone works at once; Dictation does not paste, so no relaunch line
`SettingsStatusTests.testAGrantMadeSinceLaunchAsksForARelaunchOnThePagesThatUseIt`: The microphone works at once, and Dictation does not paste here.

#### Autocomplete model is not requested while Autocomplete is off
`SettingsStatusTests.testMissingModelsAreOneNeedFixedOnModels`: Autocomplete is off, so its model is not asked for.

#### Header Download all handles missing models, so the line has no action
`SettingsStatusTests.testMissingModelsAreOneNeedFixedOnModels`: The header's "Download all" button downloads them, so the line has none of its own.

#### While header shows Cancel, unrequested model keeps its own Download button
`SettingsStatusTests.testAMissingModelKeepsItsDownloadButtonWhileAnotherDownloads`: While the header shows Cancel for a running download, a model that
still has to be asked for keeps its own Download button.

#### Model for disabled Autocomplete is not counted in sizes
`SettingsStatusTests.testADownloadSaysHowMuchHasArrivedAndHowLongItStillTakes`: Autocomplete is off and its model is not here: it is not counted.

#### Failed check is a Models line, not a badge, since the model may still work
`SettingsStatusTests.testAFailedCheckIsALineOnModels`: A model that is here and did not answer its check is said on Models,
with the way to the sheet that checks it again. It is not a count
badge: the model may still work.

#### Copying to clipboard needs no Accessibility; pasting does
`SettingsStatusTests.testDictationIsPausedByWhatItUses`: Copying to the clipboard needs no Accessibility; pasting does.

#### Apps are tracked without Accessibility; only window titles are missing
`SettingsStatusTests.testScreenAndActivityIsPausedOnlyWhenWhatItReadsIsBlocked`: Apps are still tracked without Accessibility; only titles are missing.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
