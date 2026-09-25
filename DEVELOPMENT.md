# LokalBot — technical deep dive

Everything the [README](README.md) summarizes, in full detail: build workflows, subsystem internals, configuration, headless flags, testing, and the on-disk layout. Shared contributor instructions live in [AGENTS.md](AGENTS.md); the data and network contract lives in [PRIVACY.md](PRIVACY.md). For signing and publication, use [RELEASING.md](RELEASING.md).

Jump to [build workflows](#build-workflows), [capture and processing](#recording--meeting-detection), [search and Ask](#search--player), [Today and Timeline](#day-tracking--today-timeline-and-ask), [Autocomplete and Dictation](#autocomplete-cotyping-engine), [Agent Mode](#agent-mode--an-embedded-coding-agent-on-your-selected-main-llm), [configuration](#configuration), [testing](#testing), or [storage](#on-disk-layout).

## Build workflows

The Xcode project is generated from `project.yml`. Regenerate it after editing project configuration or adding/removing source files:

```bash
xcodegen generate
```

Use the **LokalBot Dev** scheme for local development. Build it with:

```bash
xcodebuild -project LokalBot.xcodeproj -scheme 'LokalBot Dev' -destination 'platform=macOS' build
```

The prod and Dev targets share sources, but have separate bundle identities (`me.dotenv.LokalBot` and `me.dotenv.LokalBot.dev`) and macOS permission grants. `LOKALBOT_DEV` disables Sparkle's launch path in every Dev configuration. The dedicated **LokalBot UI Test Host** also sets `LOKALBOT_UI_TEST_HOST` and removes the menu-bar extra for XCUITest. Unit tests use the **LokalBot** scheme; see [Testing](#testing).

Dev and UI Test Host also have separate Application Support roots and Keychain namespaces. Dev starts with its own library and downloaded models; it never imports the release library automatically. An embedded CLI resolves the enclosing app identity, including when invoked through a symlink. `LOKALBOT_STORAGE_ROOT` remains an explicit fixture/storage override.

App Sandbox is intentionally disabled because Core Audio process taps do not work in the sandbox. Distribution uses Developer ID signing and notarization. When the user requests reinstallation of the installed app, use `Scripts/reinstall-preserve-permissions.sh` to validate signing identity and update it in place.

The first build uses `Scripts/fetch-llama.sh` and `Scripts/fetch-sherpa.sh` to vendor native runtimes. Read their pins and the Swift package versions from the checked-in configuration rather than copying version numbers from prose. Preserve pins unless the requested work needs an update.

The `lokalbot-cli` target shares `LokalBot/CLISupport/` and selected model files by direct source inclusion. It is built before the app and embedded in `Contents/Helpers/`; it is not a shared framework. `project.yml` separately copies `.agents/skills/lokalbot-cli/SKILL.md` into `Contents/Resources/lokalbot-cli/`. Keep that skill self-contained unless its packaging is also updated. `Scripts/build-mcpb.sh` packages the helper for GUI MCP clients.

Unit tests are hosted inside the prod app binary and link `libllama` directly; `-bundle_loader` resolves host-defined symbols only. Generated `default.profraw` coverage files are gitignored and should not be committed. Signing keys and populated environment files must remain outside version control.

## Recording & meeting detection

- **Detection:** native meeting apps combine process audio signals with bounded start/stop policies. Quiet grace preserves a start candidate but requires fresh audio to complete confirmation; a native-app handoff passes the same start gate. Browser auto-recording requires a supported Google Meet document and explicit in-call controls, confirmed across consecutive observations. Calendar events and arbitrary browser output never prove a call. Meet controls currently require supported English Accessibility labels; unavailable/unsupported documents abstain, and manual recording remains available. A bound browser session ends on explicit leave or bounded loss of call evidence, independent of other browser audio. Minimizing the exact previously verified window suspends observation without ending or trimming the recording; a minimized window cannot authorize a new recording. Calendar grace applies only to native sessions.
- **Two synchronized tracks:** `mic.m4a` (AVAudioEngine) captures microphone input; `system.m4a` captures the selected application process through a Core Audio tap. Audio source is separate from speaker identity. The engine re-installs its tap on `AVAudioEngineConfigurationChange` (AirPods/USB switches no longer truncate the recording), drains the converter on stop (keeps trailing audio), stops cleanly if the captured app exits, and encodes AAC off the real-time IOProc thread.
- **Recording timeline:** new recordings use timing version 2 and one continuous origin for both tracks and preview files. Late attachment, recovered gaps, and sleep insert bounded silence, preserving playback/transcript alignment. Detector lifecycle IDs prevent an unrelated native meeting-end event from stopping a manual recording. Historical version-1 recordings retain their original interpretation; repairing them would require a coordinated audio, transcript, and speaker-evidence migration.
- **Finalization:** stopping preserves failed metadata/processing-queue writes for retry and surfaces the error. Quitting saves automatic processing intent durably for the next launch without starting inference; an unsaved finalization cancels quitting so the storage error can be resolved and Quit retried. Reconnecting a microphone rearms bounded recovery after its earlier attempts were exhausted.
- **UI:** the menu-bar item exposes record state, start/stop, recent meetings, and pause/resume. A live meeting opens with quick notes and an opt-in rolling transcript. A completed meeting opens as a workspace with synchronized playback, reviewable action items, decisions, summary, transcript evidence, export, and reprocessing controls.

## Transcription & speakers

Engines (Settings → Models; CoreML/MLX, in-process, Neural Engine/Metal):

| Engine | Coverage | Notes |
| --- | --- | --- |
| **IBM Granite Speech 4.1** | high-accuracy local ASR | **recommended** |
| **Parakeet TDT 0.6B v3** | 25 languages, up to ~190× realtime in local benchmarks | fastest local option |
| **Parakeet TDT 0.6B v2** | English only | slightly higher recall |
| **Qwen3-ASR 1.7B** (MLX, ~3.2 GB) | 52 languages/dialects | best Qwen accuracy tier for harder recordings |
| **Qwen3-ASR 0.6B** (MLX, ~0.7 GB) | global coverage | compact tier |
| **Whisper large-v3 turbo** (WhisperKit, ~1.6 GB) | 99 languages | word timestamps; wide-language fallback |
| **SenseVoice / GigaAM** (ONNX) | CJK/Cantonese/English, Russian | specialist coverage |
| **Cohere Transcribe** (2B) | 14 languages | legacy — hidden unless already installed (no language detection, timestamps, or diarization) |

Models auto-download on first use (Hugging Face; the ONNX specialists fetch sherpa-onnx archives from GitHub) and are cached under Application Support.

- **Speaker attribution:** microphone speech is the user's (“Me”) while Settings → Summarization → Speaker names → **My microphone is me** is on (the default); the preference also normalizes old persisted track/diarization defaults when read. Turning it off, for shared-room microphones, keeps microphone voices unidentified until confirmed. Explicit corrections, voice profiles, overlapping speech, and suspected echo keep their own identity. Microphone text that mostly repeats simultaneous remote speech is treated as suspected echo for notes evidence: it is withheld from the model, cannot prove ownership, and cannot outvote the speaker's own identity. User confirmations and supported voice-profile evidence are separate from track origin. Cross-track loudness correlation marks possible echo without relying on identical ASR text; speech is retained unless the narrower waveform-and-text proof authorizes duplicate removal. Summaries and action ownership use the same normalized provenance. Calendar guests remain suggestions even when only one attendee is listed; attendance cannot identify a voice. A freeform alias “Me” becomes “You” only when its speaker identity is confirmed as the user.
- **Neural diarization:** Settings → Recording → **Separate voices by speaker** partitions microphone and system audio before ASR. Fresh installs default to **Nemotron 3 (Preview)**, a post-recording model for up to eight speakers using FluidAudio 0.17.1's full-precision `offline` preset. Existing selections are preserved; older saved settings without a model field keep Pyannote Community-1 (threshold 0.70, step ratio 0.15, min segment 0.3 s), which remains selectable. Overlapping voices remain unresolved. Nemotron's approximately 200 MB CoreML download is pinned by revision and per-file SHA-256 under `Models/NemotronDiarization/` in app support. Preparation is shared with recording-time prewarm; model failures surface for retry instead of checkpointing generic-speaker success. Partial transcript keys include the backend/weight identity. See the [public AMI benchmark](Benchmarks/NemotronDiarization/results/2026-09-23/REPORT.md) and [integration notes](Benchmarks/NemotronDiarization/INTEGRATION.md).
- **Speaker names from Google Meet (experimental, off by default):** a recording-scoped Accessibility observer selects the expected Chrome/Meet document at no more than 2 Hz and retains that window binding. If several windows show the same call, the focused matching window establishes the initial binding. Only structured participant labels or names corroborated by participant controls qualify. These names are retained in the encrypted session header independently of speaking intervals and appear in one name-suggestion list alongside calendar guests and other hints. Unambiguous supplied names share Meet and Calendar badges; same-name guests with different emails, email-derived guesses, and historical OCR remain distinct choices. Presence alone cannot name a voice. Automatic naming additionally requires a known self tile, explicit Accessibility speaking labels, and recorded-audio alignment. There is no screenshot, OCR, or pixel-indicator fallback. Missing names/activity abstain; hidden tabs and minimized windows remain unsupported. No browser extension is included yet. Existing saved names and historical evidence remain readable.
- **Clock and matching:** the Core Audio callback copies only its host timestamp and validity with the existing pooled-buffer handoff. The writer records anchors after successful file writes. Speaker intervals cannot bridge missing buffers, recovery padding, source/layout changes, stale observations, or invalid timestamps. The original diarizer timeline supplies speaker boundaries. Four independent clear turns, 15 seconds of support, 98% usable support, and no competing two-second turn qualify for the provisional automatic meeting-observation rule. These are experimental rules, not probability estimates or measured accuracy.
- **Review and meeting memory:** the rename sheet offers automatic provenance, ranked suggestions, supporting playback, dismissal, undo/reset, and resume. The encrypted identity journal is authoritative before public aliases are projected. Corrections win over stale results; retranscription remaps retained audio turns against an exact audio digest, including clean splits and rejection of conflicting merges. Existing summaries can be explicitly refreshed after a correction. Private evidence never enters `Transcript` or the CLI source graph.
- **Optional local voice profiles:** **Remember speakers on this Mac** separately exposes Pyannote's `embedding256` chunk vectors. With Nemotron selected, an additional Pyannote pass supplies compatible vectors, mapped to transcript speakers only by clean temporal coverage. Nemotron channel IDs and internal state never become identity embeddings. Existing profile fingerprints are retained after the runtime compatibility check described in the integration notes. Only explicit user confirmations can enroll at least three independent clean turns totaling 15 seconds. Profiles use bounded normalized vectors, exact model/preprocessing fingerprints, source contributions, revisions, and deletion tombstones. Unknown and confusable voices abstain; recognition thresholds require held-out calibration. A profile database revision check rejects results computed before a rename, deletion, or enrollment change.
- **Storage and retention:** meeting-private AES-GCM files live under `speaker-evidence/`; the same library root holds `speaker-profiles/profiles.sealed`. No observer pixels are persisted. Authenticated completed chunks survive interruption; incomplete chunks cannot fabricate coverage. A serial store commits decisions, bounds the capture backlog, expires raw evidence/suggestions independently of feature toggles, and preserves confirmed assignments. Source deletion revokes enrollments before deleting audio. Key/storage failures leave an advisory and never stop recording.

## Summarization & notes

- **Meeting boundaries:** the meeting actions menu exposes a range in original audio seconds. Rebuilding transcribes only that range; raw tracks remain playable. A detected browser stop retains the call boundary separately from the recorder shutdown time. Crossing old transcript spans are excluded until retranscription establishes their words.
- **Summary recovery:** old source-less rejection checkpoints receive a fresh scan with accepted evidence retained. New invalid source IDs or stalled generation produce an explicit persisted provider failure; identical retries do not repeat requests. Changing the provider/model invalidates that checkpoint.

- **Backends** (Settings → Models): **Built-in** (included localhost llama.cpp runtime; choose/download a GGUF model) · **Apple Intelligence** (FoundationModels, macOS 26+, gated so the app still builds/launches on 15.0) · **Ollama** · **any OpenAI-compatible server** (LM Studio, vllm-mlx, …). Non-loopback endpoints require explicit origin approval before context is sent.
- **Output:** `summary.md` with TL;DR / Key points / Decisions / Action items / Open questions. Map-reduce for long meetings; `<think>` reasoning blocks are stripped.
- **Outcomes:** `MeetingNotesGenerator` projects decisions and action items into the local outcome index while `MeetingOutcomeStore` keeps user status changes separate from generated source material. The meeting workspace and Today can therefore mark, reassign, or open work in Agent Mode without rewriting the transcript or summary. Action items list the user's work first: their own commitments and requests they answered in the next turn, then unclear-owner actions spoken on the microphone, then at most five other actions by importance. Unrecognized commitment wording keeps the task with an unclear owner; negated, conditional, and questioned undertakings do not become tasks.
- **Action threads:** membership uses canonical immutable source text and compatible source owners, never fuzzy similarity or editable corrections. Corrections retain membership; mixed completion remains visible. A meeting-level toggle writes only its own overlay; a multi-meeting toggle requires native confirmation and rejects stale thread snapshots. Ask includes all statuses by default and supports explicit active/open/deferred/done filters with per-source status for mixed threads.
- **Thread corrections:** each corrected field keeps its own revision time, so completing an older source cannot replace newer wording, ownership, or deadlines. Sources can be kept separate and allowed to match again without changing generated outcomes. Clustering indexes canonical text and owner within the 30-day window; bulk edits notify dependent products once.
- **Templates & language:** pick a notes template (Meeting / Lecture / Study guide / Podcast / Free-form) and a summary language (auto-detected via `NLLanguageRecognizer`, with Simplified / Traditional / Cantonese handling). Prompt budgeting (`TokenCountEstimator`, `PromptContextSanitizer`, `PromptSectionBudget`) keeps prompts within the model's context.
- **Pipeline:** runs automatically when a recording stops (configurable); serial queue with per-meeting status in the UI, plus a Process menu for manual re-runs.

## Built-in LLM runtime — llama.cpp & model catalog

- `LlamaServer` copies the vendored `llama-server` out of Resources into Application Support on first run (never executes from inside the bundle), spawns it (`-ngl 99 --jinja`, port 17872), health-checks `/health`, restarts on model switch, and terminates on quit.
- **Inference broker:** the three shared llama-servers — main (17872), embeddings (17873), cotyping fallback (17874) — are lease-managed by `InferenceBroker`: consumers take per-request leases, a server with no active leases unloads after a short linger, and loaded models sit under a RAM residency budget with LRU eviction. Settings → Advanced shows a live **resource monitor** of what's loaded and which lease is pinning it.
- **Model catalog** (Settings → Models) — download / cancel / delete with progress, radio-select the active model. Qwen "thinking" is disabled for summaries via `chat_template_kwargs`. The Models tab also manages the dedicated cotyping model, the embedding model, and the **Kokoro** TTS voice (sherpa-onnx; downloads once, then reads summaries and chat answers aloud offline).

| Model | Size | Best for |
| --- | --- | --- |
| Qwen 3.5 · 0.8B | ~0.5 GB | tiny downloadable fallback |
| LFM2.5 · 1.2B Instruct | ~0.7 GB | recommended cotyping |
| Qwen 3.5 · 2B | 1.3 GB | lightweight cotyping |
| Qwen 3.5 · 4B | ~2.8 GB | balanced summaries |
| Gemma 4 · E4B | ~6.7 GB | higher-capacity cotyping |
| LFM2.5 · 8B MoE | 5.2 GB | fast summaries |
| Qwen 3.6 · 35B-A3B | 17.7 GB | recommended summaries on 32 GB+ Macs |
| Qwen 3.6 · 27B | ~16.8 GB | maximum-quality dense summaries |
| Gemma 4 · 12B | ~7.5 GB | multimodal-family summaries |

- **Browse Hugging Face** in-app: search GGUF repos, list `.gguf` files, download — resilient (synchronous temp-file rescue, outcome classification, GGUF magic-byte validation). `HardwareCapabilityProbe` surfaces a per-model fit advisory under Settings → Models.

## Search & player

- **Index:** SQLite + FTS5 (`lokalbotv3.sqlite` — system SQLite, no dependency) over titles, transcript segments, summaries, and OCR'd screen text. Segment rows carry their audio timestamp; incremental re-index by file mtime on launch and after each pipeline run.
- **Semantic search:** transcript/summary chunks and retained screen OCR are embedded with Harrier OSS v1 0.6B GGUF (`Q8_0`, approximately 0.64 GB) on a second llama-server instance (port 17873, `--embeddings --pooling last`); vectors live in SQLite with an index-version marker covering the model, pooling, prompts, and chunking. Queries use brute-force cosine similarity. Screen results fuse FTS and semantic ranks with deterministic reciprocal-rank fusion while preserving the exact snapshot id. Qwen3-VL-Embedding 2B remains future work for direct image-vector retrieval.
- **UI:** sidebar Today | Meetings | Timeline | Ask | Agent | Settings. Ask searches as you type and keeps the conversation column in place. One date control offers Any time, Today, Yesterday, Last 7 days, and a specific date across meeting, activity, and screen search and answers. Selected result-type and screen-app filters appear as removable labels beside the query; empty results offer Clear search filters. Source and result-type choices remain in the source menu. Civil-date ranges persist with questions and survive reopening and retries without widening retrieval. Keyword and available semantic rankings blend automatically, respecting the semantic-indexing preference. Reading excerpts remove generated metadata and malformed repetition; semantic meeting hits recover the original indexed passage instead of displaying an old truncated embedding prefix. Keyword matches appear first and semantic suggestions are labeled **Related by meaning**. **Answer sources** lists the meeting/date and screen-moment boundary before sending, including collapsed matches and attached screens. For keyword input, Return opens the selected result with playback paused and never starts inference; question-like input (`AskIntent`) makes Return ask instead, unless a result was picked with the arrow keys. **Command-Return** or **Ask about results** always submits a question bounded to the displayed meetings and screen moments, through the same path as a Return-submitted question. With no results, Ask uses the chosen source/date scope; result-type and screen-app filters constrain search results only.
- **Player:** mic + system tracks play in sync (shared device-time anchor); seek bar; click any transcript line to jump the audio there; the currently-playing segment is highlighted.
- **Meeting summary:** a single Summary tab shows a bulleted recap (whole points expand after five), editable actions, decisions, and open questions, with full notes behind **Show full notes**. Find-in-page opens the full notes automatically when needed. Processing badges remain on library rows; failures expose a conditional retry banner. A single Summary notice links to speaker review, where action-linked speakers appear first and substantive voice excerpts replace filler-only samples.
- **Meeting review:** the Review tab connects bounded speaker excerpts (at most 12 seconds), existing speaker confirmation, action-owner corrections, and an explicit refresh of derived notes. When a speaker change archives the old extraction, Review retains those actions with a stale notice so owners can still be corrected; archived actions stay out of the current action index until refresh. Refresh shows the selected inference destination; saved action corrections remain separate from regenerated extraction. Mixed or unresolved voices are never silently named.

## Ask assistant — conversational Q&A over your library

- **Chat with your meetings:** pressing ⌘↵ in the **Ask** section escalates your query to a conversational assistant over your library — ask what was decided, find action items, or search transcripts in natural language. A small ReAct agent (`ChatAgent`) reuses the selected `TextEngine` and calls tools to ground every answer. With the built-in default it stays on the Mac; an approved remote backend receives the prompt context needed to answer.
- **Tools (pi-agent style, mirroring the CLI):** `search_meetings` (FTS5 keyword + optional semantic search), `list_meetings` (filter by title), and `get_meeting` (read a meeting's summary or transcript). The agent picks a tool, reads the observation, then answers — citing meeting titles and dates, and saying so plainly when nothing matches.
- **Robust protocol:** tools are advertised in the system prompt with the recent-meeting list as ambient context; a tool call is parsed from a JSON object **or** a model's native `name(arg=…)` function-call form (smaller Qwen models emit the latter), with a tolerant fallback to a plain answer so a sloppy reply never hard-fails.
- **Reuses the configured backend:** built-in llama-server by default, or Ollama / OpenAI-compatible / Apple Intelligence — the same Settings → Models choice.

## Day tracking — Today, Timeline, and Ask

- **Default modes:** fresh settings select activity-only day tracking. Accessible text and encrypted visual context require opt-in and applicable macOS grants. Settings → Recording → Day tracking can also turn collection fully off.
- **Sampler:** frontmost app + focused-window title every 5 s, idle-aware (3 min), minimum 5 s block, pause/resume from the menu bar. A metadata-only Accessibility read checks private windows, secure fields, and excluded apps/domains without reading document text. Denied or unknown samples become anonymous “Private” duration blocks. Stored in `activity_blocks` (same SQLite db).
- **Timeline sessions:** titles use duration-ranked observed window/document titles, with the original app/time blocks available for inspection. Sessions split at gaps over five minutes, a sustained new document after ten minutes, or the next source boundary after 45 minutes. Individual and overlapping blocks stay intact; brief app interruptions do not force a new session. These labels describe captured evidence, not inferred tasks.
- **Today:** the default landing page combines capture state, the current day digest, open meeting actions, upcoming-meeting preparation, and direct routes to Ask, Timeline, and Agent Mode. The reading column puts decisions and next steps before the current work summary. The shared digest keeps freshness in a compact footer and the expandable Yesterday recap below current work; previous-day provenance is inside that disclosure. Calendar setup lives in Settings. The next meeting leads with Join/Record, and the rest of today's meetings follow in a compact Later today list. Events with other attendees or a conferencing link are meetings; a solo event is listed without Join/Record when its title names a meeting (for example “Product Standup”), and personal appointments are left out.
- **Timeline:** groups adjacent activity into meaningful work sessions and interleaves meetings chronologically. A bounded Work sessions rail on the right leaves most width for the day digest and selected evidence on the left. Selecting a session foregrounds its captured text or encrypted visuals, with full window titles expandable and secondary session statistics disclosed below; **Browse raw capture** retains the per-block track and Context Rewind controls for exact evidence, saved moments, notes, and time-range deletion.
- **Day digest:** "Write digest" / "Update digest" runs the configured LLM over the day's blocks, meetings, and captured text → `journal/YYYY-MM-DD.md`. The same digest is visible from Today and Timeline, can be copied or exported, and grounds **Ask about day**.
- **Digest provenance:** version-2 metadata fingerprints the exact digest inputs and generated journal bytes. Dream, exports, and routines reuse a digest only while both match, including after corrections or deletion of the last source. Legacy unsigned journals remain readable but are not reused as verified evidence until regenerated. Automatic repair preserves edited signed journals; explicit meeting/screen deletions invalidate dependent day products.
- **Refresh ordering:** generation rechecks the journal revision before saving, preserving edits made while the model runs. Persisting a digest reopens exports and routines that may have finished earlier. Meeting edits invalidate every Dream report whose 14-day comparison window includes the source, including cancelling an affected in-flight generation.
- **Dream retraction:** app-owned provenance follows facts across memory merges. Source deletion/correction retracts dependent projects, goals, patterns, and reports, including pins; unattributed legacy facts are conservatively removed on evidence mutation. Stable meeting IDs and conservative civil-date coverage handle timezone changes. A root-level revocation intent and process-shared lock protect source writes and prevent stale in-flight commits or restart recovery from reviving withdrawn facts. Automatic screen retention uses the same boundary and deletes only reviewed rows.

## Autocomplete (Cotyping engine)

- **Ghost text everywhere:** as you type in almost any macOS text field, a gray suggestion appears next to the cursor; press **Tab** to accept a word or the full suggestion, keep typing, or press **Esc** to dismiss. The subsystem remains named Cotyping in source and settings keys. Its Accessibility poll resolves the focused field and caret, a `CGEventTap` watches keystrokes, a borderless click-through `NSPanel` renders at the caret, and accepted text is inserted as synthetic Unicode keystrokes.
- **Its own dedicated on-device model:** Autocomplete decodes a dedicated model (recommended **LFM2.5 · 1.2B Instruct**) **in-process via libllama** for low latency, with the localhost `llama-server` as the fallback. The prompt treats the model as a pure text continuer; a shared normalizer strips chat/`<think>` scaffolding, prompt echoes, and trailing-text duplication, then collapses the result to one line.
- **Opt-in & private:** off by default; needs **Accessibility** + **Input Monitoring**. Never reads password/secure fields; honors a per-user app exclusion list (preseeded with password managers and terminals).
- **In-app preview:** Settings → Writing exposes readiness and one real autocomplete preview before the feature is enabled system-wide. The menu bar provides the quick toggle.

## Dictation — system-wide voice typing

- **Hold ⌥ Space and talk** (or switch to toggle mode): a floating pill shows recording state and a live transcript while you speak; release, and the text is pasted into the focused app — or copied to the clipboard instead (Settings → Writing).
- **Your ASR, prewarmed:** dictation reuses the transcription engine and language you picked under Models (Granite, Parakeet, Whisper, Qwen3-ASR, …) and prewarms it when the shortcut is armed, so short dictations start instantly.
- **Considerate capture:** playing media (Spotify, Music, browsers, VLC, …) is paused before recording starts; browser pausing skips live streams and supported conference domains. Audio goes to a local PCM scratch file and is deleted right after transcription. Optional Compose context requires an unchanged focused window and field and honors the shared app/domain/private-window policy and credential redaction.
- **Opt-in & private:** off by default; needs the Microphone grant plus Input Monitoring for the global shortcut. Audio, transcription, and paste all happen on-device.

## Agent Mode — an embedded coding agent on your selected Main LLM

- **A coding agent in the sidebar:** the **Agent** section embeds the pi coding agent, preconnected to the same local Main LLM through an OpenAI-compatible shim — a coding agent running on your own GGUF (or whichever backend you configured). A persistent task sidebar supports search, rename, pin, archive, and restore. Browsing saved tasks loads native Pi history without starting inference. Execution is limited to four live runtimes; idle saved tasks can release their runtime when another starts.
- **Conversation workspace:** a constrained reading column groups adjacent tool activity. Approvals remain above the composer, with the target and effect visible. The results inspector previews recorded output, proposed edits, and attached sources, with copy and local export. Copy, edit as follow-up, review and retry, and branch from message preserve the original conversation and do not undo completed actions.
- **Composer and context:** drag in files or use the context menu and `@` picker to attach UTF-8 documents, text-layer PDFs, meetings, and separately authorized saved moments. Sources are reread on send, with limits of 10 attachments and 60,000 total characters. Explicitly selected meetings are attached as summary/transcript text; screen sources include retained text and notes, never pixels. The model and inference destination remain visible.
- **Follow-ups:** while working, **Send now** uses Pi steering; **Queue follow-up** keeps an editable, cancelable host-side queue. Stop and app relaunch pause the queue. **Send next** explicitly resumes it. Failed sends retain their draft and attachments for review.
- **Navigation:** ⌘N creates a task, ⌘⇧F searches tasks, ⌘⌥←/→ moves between tasks, ⌘F finds in the current conversation, ⌘L focuses the composer, and ⌘⌥B toggles results. Agent actions and tasks also appear in the command palette. Text zoom is available in the Agent menu.
- **Persistence:** `agent/sessions/tasks.json` stores task metadata, drafts, queued follow-ups, and attachment references alongside native Pi JSONL conversations. The latter contain the context actually sent. Archiving preserves both; **Clear saved Agent history** removes both after confirmation. A branch copies the chosen native conversation ancestry to an independent file; it neither replays tools nor rolls back files.
- **Pi's own network behavior is disabled:** pi runs with `--offline`, version checks and crash reporting disabled. Enabling Agent Mode downloads its runtime once — a checksum-verified Bun release from GitHub plus the pi package from npm, pinned by a lockfile bundled with LokalBot. LLM requests stay local with the built-in backend; an approved remote Ollama or OpenAI-compatible endpoint receives agent context when selected.
- **Workspace boundary:** new tasks use a sibling working directory outside the private library. Saved tasks rooted inside the library retain their history and drafts but cannot execute. Raw reads of protected library, runtime, and session paths enter the tool-approval flow when a broader parent directory is selected; the selected approval mode still applies.
- **You approve sensitive access:** file and shell calls follow the selected approval mode. Commands exceeding 65,536 JavaScript UTF-16 code units are rejected before approval; the host also rejects incomplete or truncated shell previews. Approved shell commands run with your macOS user permissions and may access files or the network.
- **Inference redirects:** native buffered/streaming HTTP requests follow redirects only within the original scheme/host/port. The Pi provider uses its own scoped fetch adapter that rejects all redirects and validates the initial origin. Configure a server's final endpoint directly; inference approval does not authorize forwarding prompts or credentials to a different origin.
- **Headless:** `LokalBot --agent "<prompt>"` runs one agent turn from the terminal (see Headless flags). It auto-approves file changes but safely declines shell and external-read requests because no person is present to review them.

## Screen context, OCR & privacy

- **Capture:** fresh settings select activity only; visible text and pixels require explicit opt-in and the applicable macOS grants. A bounded, single-flight Accessibility reader collects visible text first; Vision (`VNRecognizeTextRequest`, on-device) runs only when that text is too thin. Coarse triggers include app/window changes, clicks, typing pauses, settled scrolling, and pasteboard-generation changes, plus an idle-active fallback. The trigger monitor never reads raw keys, pointer positions, scroll deltas, or clipboard contents. Automatic work has a 20-second cooldown; byte-identical frames and unchanged text are skipped. Visual mode uses ScreenCaptureKit, downscales to ≤1500 px, encodes HEIC, and groups similar scenes with a 64-bit perceptual dHash.
- **Contextual privacy:** capture skips idle/lock/pause states, excluded apps and domains, private/incognito titles by default, and focused secure fields. URL metadata drops credentials, query, and fragment; document metadata keeps only the filename. Deterministic credential rules redact captured text before persistence. If either accessible text or OCR detects a credential, the redacted text remains useful but the pixel payload is never written.
- **Meetings:** visual context during recording is a separate opt-in. It is throttled to at most one automatic moment per minute and rows carry the active meeting id. Manual capture remains available.
- **Encryption & retention:** each retained visual is AES-GCM sealed with a per-install Keychain key. Pixels auto-delete after N days (default 14), and captured text follows the same retention unless you opt into keeping it forever. Saved moments retain their encrypted pixels, text, and semantic vector until unsaved or explicitly deleted. Accessibility-only and retention-pruned moments remain represented as text context rather than fake thumbnails.
- **Exclusions:** the comma-separated app list is preseeded with password managers; excluded time logs as "Private" with no title or context. Domain/URL-prefix rules apply to both text and pixels.

## Safe local routines

- **Curated jobs:** post-meeting follow-up, daily stand-up, weekly work log, unfinished-action rollup, and local journal. Each renderer has a fixed local read scope and accepts no arbitrary prompt, shell command, or network action.
- **Scheduling:** event-driven follow-ups run after processing; daily and weekly jobs catch up after wake. Meeting recording, dictation, cotyping generation, and the meeting pipeline take priority. Fixed calendar scopes and fingerprints of prepared output make corrections, completion, deletion, and reverted edits new durable revisions. Unchanged successful or failed revisions are terminal across relaunch; invalidation cancels stale work. Preparation and writing each have a 30-second bound.
- **Writes:** Markdown goes only under a user-selected destination with `0700` folders and `0600` files. Routines and daily exports share hash-sidecar ownership checks: unchanged output is idempotent, changed generated output is replaced only while its stored hash matches, and user edits or unrelated files are preserved. Legacy files without a sidecar can be adopted only when their bytes already equal the new output. Deterministic secret redaction is applied again before writing.

## Configuration

Everything lives in **Settings**, organized into searchable categories:

- **General** — launch at login, menu-bar-only mode, the opt-in `⌃⇧Space` Quick Recall shortcut, permission status + repair, storage location, update checks.
- **Recording** — auto-record behavior, calendar-assisted detection, auto-transcribe/summarize, notes template + language, neural diarization, day tracking modes, scheduled Markdown/Obsidian/Logseq daily-memory export, and safe local routines.
- **Models** — readiness for the Transcribe, Think, and Autocomplete roles; recommended/lightweight presets; transcription engines; Main LLM backends (Built-in / Apple Intelligence / Ollama / OpenAI-compatible); the GGUF catalog and Hugging Face browser; embeddings; and Kokoro TTS.
- **Privacy** — screen-text retention plus independent meeting-library and time-scoped screen-memory MCP permission profiles.
- **Advanced** — unified Memory Health for capture and processing, the live resource monitor, hardware fit advice, retention controls, and Agent CLI installation.
- **Writing** — a persistent Autocomplete/Dictation selector opens each tool directly, including settings-search jumps. Category and tool switches start at the top rather than inheriting another form’s scroll position. Test and tune Autocomplete (the Cotyping engine, exclusions, acceptance behavior) and Dictation (shortcut style, paste vs. clipboard).

## Agent CLI & MCP

`lokalbot-cli` (ArgumentParser, embedded in `Contents/Helpers/`) gives coding agents read-only access to the meeting library via `list` / `get` / `search` / `path`. JSON by default, `--table` for humans. Settings → Advanced → Agent CLI (or `lokalbot-cli install-skill`) symlinks the binary to `~/.local/bin/lokalbot-cli` and the bundled skill to `~/.agents/skills/lokalbot-cli/`.

The same binary is an **MCP server**: `lokalbot-cli mcp` speaks MCP over stdio. Meeting tools are `list_meetings` / `get_meeting` / `search_meetings` / `ask_library`. Independently gated screen tools are `search_screen` / `get_timeline` / `get_recent_activity` / `get_app_usage` / `get_screenshot_detail`; they use a query-only SQLite connection and return captured text/metadata, never decrypted pixels or file paths. The screen marker stores one of three profiles: today, rolling seven days, or all retained history; every query is clamped and out-of-scope detail ids appear missing. LokalBot does not upload library content, but an external MCP client may transmit tool inputs and results under its own privacy terms.

Both agent surfaces are **off by default**. Meeting tools require `control/agent-access-enabled`; screen-memory tools require the separate JSON `control/screen-memory-access-enabled` marker. Neither marker grants the other capability. Empty markers written by older builds retain their prior unscoped authorization until the user chooses a profile; newly enabled access defaults to seven days.

See [`.agents/skills/lokalbot-cli/SKILL.md`](.agents/skills/lokalbot-cli/SKILL.md).

## Headless flags

The app binary doubles as a test harness; flows that need ungranted permissions are skipped.

| Flag | Effect |
| --- | --- |
| `--process <meeting-folder> [--no-summary]` | Run the transcribe/summarize pipeline, then exit |
| `--search "<query>"` | Print FTS5 hits (and semantic hits, if enabled) |
| `--record <seconds>` | Record for N seconds (needs the Mic grant) |
| `--digest` | Generate today's day digest |
| `--shot-test` | Capture one screenshot (needs Screen Recording) |
| `--chat "<question>"` | Ask the meeting chat assistant once and print the answer |
| `--agent "<prompt>"` | Run one Agent Mode turn headlessly (tool calls auto-approved) and exit by result |
| `--cotyping-bench` | Run the cotyping quality benchmark and print a JSON report (exit 0 when every scenario passes) |

## Testing

- **Unit** (`LokalBotTests`, in-process):
  ```bash
  xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
  ```
  Pure-logic coverage — prompt sanitizers, search ranker, model fit, transcript merging, settings codecs, data migration, and the chat agent (tool-call parsing for JSON **and** native function-call forms, the ReAct loop, observation formatters).
  Select an affected class or method with `-only-testing:LokalBotTests/CotypingTests` (replace the class with the relevant test).
- **Agent runtime:** `LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/agent-runtime bash Scripts/tests/run-pi-runtime-tests.sh` runs the extension and adapter tests against the pinned runtime. It copies test sources to a temporary folder and uses synthetic loopback services without changing the installed runtime.
- **UI** (`LokalBotUITests`, XCUITest): run the hosted **UI Tests** workflow or another remote Mac runner. `Scripts/ui-tests.sh --remote` dispatches the suite; append a test name to select one test. Never use `--foreground` or run UI tests locally on this MacBook. The script checks that the relevant changes are committed and pushed so the remote runner tests the intended revision. It drives a dedicated UI Test Host against a synthetic library under a temporary `LOKALBOT_STORAGE_ROOT`; `LOKALBOT_UI_TEST=1` skips side-effectful subsystems, so the suite never touches the installed production app.
- **Documentation captures:** `Scripts/capture-screenshots.sh --stills-only` builds the same isolated host, seeds synthetic data, and renders fixed-density PNGs in-process. This is a capture pass, not the XCUITest suite; see [Docs/screenshot-kit.md](Docs/screenshot-kit.md).
- **End-to-end** (`Scripts/e2e.sh`): exercises real audio, CoreML transcription, the bundled llama-server, and SQLite via the headless flags; skips flows needing ungranted permissions.

## On-disk layout

```
~/Library/Application Support/me.dotenv.LokalBot/
├── meetings/YYYY/MM/dd-slug/   # mic.m4a, system.m4a, meta.json, transcript.{json,md}, summary.md
├── journal/YYYY-MM-DD.md       # day digests
├── activity/YYYY-MM-DD/shots/  # <epoch>.heic.enc  (AES-GCM sealed)
├── models/                     # downloaded GGUFs
├── qwen3-asr-models/           # downloaded Qwen3-ASR MLX weights
└── lokalbotv3.sqlite           # FTS5 (docs) + embeddings + activity_blocks + ocr_fts + screenshots
```

Rooted at the bundle id (not "LokalBot") so it never collides with another app's `Application Support/LokalBot` on the default case-insensitive filesystem.

Legacy migration never replaces an existing current database, including an empty one. A missing database is imported through a WAL-aware SQLite snapshot and atomic no-replace installation; concurrent creation wins safely. Conflicting legacy data and recovery snapshots remain available for explicit reconciliation. Dev, UI-test, and fixture launches skip legacy migration.

## Project layout

```
repository/
├── project.yml                            # XcodeGen manifest: LokalBot + LokalBot Dev + tests + lokalbot-cli
├── Scripts/                               # fetch-llama, e2e, ui-tests, DMG + appcast release tooling
├── CLI/                                   # lokalbot-cli ArgumentParser entry + Commands/ (list/get/search/path/mcp/install-skill)
├── .agents/skills/lokalbot-cli/SKILL.md   # bundled into the app, symlinked on install
└── LokalBot/
    ├── LokalBotApp.swift   # @main: Window + MenuBarExtra + Settings scenes, headless flags
    ├── Models/             # Meeting, Transcript, AppSettings, NoteTemplate, SummaryLanguage, *Language
    ├── CLISupport/         # SessionLookup + SessionFormatter (shared with the CLI)
    ├── Services/           # detection, recorders, ProcessingPipeline, StorageManager, SearchIndex/
    │                       #   EmbeddingIndex, ActivityTracker/ScreenshotService (OCR), diarization,
    │                       #   PermissionManager, AppUpdateManager, AppLog, HuggingFace/, Chat/ (agent + tools)
    ├── Engines/            # TranscriptionEngine, TextEngine, AppleIntelligenceEngine,
    │                       #   ModelCatalog / ModelDownloadManager / LlamaServer / InferenceBroker
    ├── Support/            # prompt budgeting, download rescue, DeviceInfo/HardwareCapabilityProbe, ranker
    ├── Cotyping/           # CotypingCoordinator + AX focus tracker, CGEventTap input monitor,
    │                       #   ghost-text overlay, synthetic inserter, prompt renderer + output normalizer
    ├── Agent/              # Agent Mode: pi RPC session, Bun runtime installer, approval flow
    └── Views/              # Today, MeetingWorkspace, Ask, Timeline, Autocomplete, Settings, Agent, Onboarding
```

## Releasing

In-place signed updates ship via [Sparkle](https://github.com/sparkle-project/Sparkle). The release runbook (notarization, appcast signing, DMG tooling) lives in [`RELEASING.md`](RELEASING.md). `AppUpdateManager` stays inert on dev builds (`LOKALBOT_DEV`) and in forks with placeholder `SUFeedURL` or `SUPublicEDKey` values.

## Status

**Done:** robust two-track recording · live notes and transcript · local transcription and neural diarization · four summary backends with templates and languages · reviewable outcomes with cited evidence · Today and session-based Timeline views · FTS5 and semantic meeting/screen search · synchronized playback and Kokoro TTS · encrypted visual context, saved moments, and contextual privacy · Quick Recall · scheduled exports and fixed-scope routines · Memory Health · Ask · model-role readiness and presets · Agent Mode · independently gated meeting/screen MCP tools · Sparkle updates · dev/prod split · Autocomplete via the opt-in Cotyping engine · opt-in system-wide Dictation.

**Not yet built:** VLM screenshot captions (needs a multimodal model + an mmproj slot in `LlamaServer`).
