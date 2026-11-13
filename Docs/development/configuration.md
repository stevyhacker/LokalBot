# Configuration

Part of the [development guide](../../DEVELOPMENT.md).

## Interface languages

Settings → General → Appearance → App language and the setup wizard's first step offer English, Simplified
Chinese, Hindi, Spanish, Modern Standard Arabic, French, Bengali, Portuguese,
Indonesian, Urdu, Russian, German, Japanese, Nigerian Pidgin, Egyptian Arabic,
Marathi, Vietnamese, Telugu, Swahili, and Hausa. These are the first twenty entries
by total speakers (first and second language users) in the 2026 Ethnologue ranking
([methodology](https://shop.ethnologue.com/products/2026-ethnologue-200),
[public ranking table](https://en.wikipedia.org/w/index.php?title=List_of_languages_by_total_number_of_speakers&oldid=1380301586)).
The ranking counts Nigerian Pidgin and Egyptian Arabic separately, so both have
full catalogs. Korean (`ko`, 한국어), Traditional Chinese (`zh-Hant`, 繁體中文),
Italian (`it`), and Serbian in Latin script (`sr-Latn`, Srpski (latinica)) are also
available, bringing the total to 24.
Egyptian Arabic uses the `ar-EG` catalog when explicitly selected, or when
Follow System encounters the language code `arz`. System `ar-EG` and other
`ar-*` preferences mean Arabic with a region and use Modern Standard Arabic.
Nigerian Pidgin uses `pcm`. Chinese preferences with the Traditional script, or
with a Taiwan, Hong Kong, or Macau region and no explicit Simplified script, use
Traditional Chinese with Taiwan terminology; other Chinese preferences use
Simplified Chinese. Serbian in either script and Montenegrin (`cnr`) use the
ekavian Latin Serbian catalog; Croatian and Bosnian are separate languages and
fall back to English. Portuguese uses broadly
understandable Brazilian terminology for both Brazilian and European locales.

Follow System selects the first supported macOS language preference, including
regional variants, and falls back to English. Explicit selection updates open
windows immediately, including right-to-left layout for both Arabic varieties and Urdu. Language
names remain in their native scripts. This setting changes interface text only;
transcription, generated notes, model prompts, and saved user content keep their
own languages. Existing Follow System preferences adopt newly supported languages;
explicit language choices remain unchanged. Native macOS menus and panels follow
macOS language preferences independently of the app-owned interface.

In a right-to-left interface, transcripts and Markdown content take their
direction from their own first strong letter (`contentLayoutDirection(of:)`), so
English content stays left-aligned. The playback waveform stays left to right,
like platform media controls, and the native text-field bridges mirror the
window's direction.

SwiftUI and AppKit hosting roots use `appLanguageRoot(settingsStore)` to observe
the selected locale, including already-open dictation overlays and the UI test
host. App-owned dynamic labels use `LocalizedStringKey`; native menus and
settings search use `AppLanguage.localized`. Keep user content verbatim.

`LokalBot/Resources/en.lproj/Localizable.strings` is the source catalog. Keep every
language's keys, printf arguments, and embedded line breaks aligned when changing
interface copy. Run `uv run --no-project python -m unittest discover -s Scripts/tests -p test_localization.py`
to check key parity, format arguments, and hidden direction marks without building
the app, and run `xcodegen generate` after adding a language. The same test fails
when a `Text`, `Button`, `Label`, `navigationTitle` or `StatTile` literal in
`LokalBot/Views` has no `en.lproj` key, or is joined with `+` or `??` (SwiftUI
shows such a String verbatim). It also checks `var title = "…"` defaults shown
through `LocalizedStringKey(title)`. `Scripts/tests/untranslated_view_literals.json`
lists the older untranslated literals; delete an entry when you translate it. `AppLanguageTests`
covers preference migration, persistence, language resolution, bundled lookup,
binary catalogs in the built app, and translated settings search.
`AppLanguageRootTests` verifies live locale propagation and preserved content
identity in offscreen hosting views. Hosted Settings and Onboarding UI tests cover
switching and relaunch; the UI test host is pinned to English with
`-AppleLanguages (en)`. New translations are machine-assisted and have not had a
native-speaker editorial review.


## Fun-ASR-Nano local transcription

Choose **Settings → Models → Transcribe → Fun-ASR-Nano-2512 → Choose model
folder…**, select an extracted model directory, then choose **Use model**.
LokalBot checks the files and loads a short synthetic input before activating
the selection. A failed or cancelled load leaves the previous model active.

This uses the bundled sherpa-onnx CPU runtime and its
[Fun-ASR-Nano-2512 ONNX exports](https://k2-fsa.github.io/sherpa/onnx/funasr-nano/pretrained.html),
not the original Hugging Face/ModelScope PyTorch checkpoint. Supported layouts:

| Export | Encoder / embedding | Decoder | Extra weights |
| --- | --- | --- | --- |
| int8 | `encoder_adaptor.int8.onnx`, `embedding.int8.onnx` | `llm.int8.onnx` | — |
| fp16 | Same int8 encoder and embedding | `llm.fp16.onnx` | — |
| fp32 | `encoder_adaptor.onnx`, `embedding.onnx` | `llm.fp32.onnx` | `llm.fp32.data` |

All layouts need `Qwen3-0.6B/tokenizer.json`, `vocab.json`, and `merges.txt`.
An inline `llm.onnx` decoder is also accepted. Actual graph compatibility is
checked by the runtime; empty files, Git LFS pointers, missing tokenizer files,
and missing fp32 external weights are rejected before loading.

The selected path is saved as `funASRNanoModelDirectory`. Files are used in
place, including local cache symlinks; the app never imports, overwrites, or
deletes this directory. **Clear selection** in the picker is saved with the
**Clear selection** button at the bottom; **Cancel** keeps the saved path.
Undo validates the previous folder before restoring it. Removing the model in
**Downloaded** also only clears the saved path. Moving the folder requires selecting it again. No Fun-ASR model
download or remote inference occurs. The existing shared Silero VAD may still
download its small pinned model on first use, as with other transcription engines.
Speech is decoded in at most 20-second regions with span/coarse timestamps;
this is not streaming or word-aligned transcription. Chinese, English, and
Japanese hints are supported; automatic detection is used for other selections.

`FunASRNanoModelTests`, `FunASRNanoSelectionTests`, and the FunASR cases in
`ModelRolesTests` cover directory validation, settings persistence, selection
undo, readiness invalidation, file ownership, and preparation cancellation.
`FunASRNanoRuntimeTests` checks subprocess results and offers an opt-in real
model check using `LOKALBOT_FUNASR_TEST_MODEL_DIR` and `LOKALBOT_FUNASR_TEST_WAV`
(public or synthetic audio only). Prefix these variables with `TEST_RUNNER_`
when running through `xcodebuild`.

## Settings pages

Everything lives in **Settings**, which has its own window (`Window(id: "settings")` in `LokalBotApp`, opened through `WindowAccess` by ⌘,, the app menu, the Settings row in the main sidebar's foot, the menu bar extra and every `AppState.openSettings(tab:)` deep link, also while LokalBot runs with only its menu bar icon). The main window stays on what it was showing; `NavSection` has no Settings case. The UI-test host builds the same window by hand: launching with a Settings name in `LOKALBOT_INITIAL_SECTION` (`settings`, `models`, `dictation`, …) makes it the launch window, and opening Settings later puts it beside the main one. There is one page per feature, so everything that turns a feature on and sets it up is on its page. `AppState.SettingsTab` lists the pages in the order of the window's list: the LokalBot row (Overview), General, Models and Privacy & permissions, then four headings (Remember, Assistant, Writing, Sharing), then Diagnostics. Raw values stay stable for the CLI, AppControl and saved selections, renamed pages keep their old names as capture names (`init(captureName:)`), and settings search still finds a page's settings by its former name (`formerNames`). Settings opens on **Overview** the first time, then on the last page chosen (`lokalbotv4.settings.selectedPage`). Search covers every page (`SettingDescriptor`), and `SettingRegistry` keeps the same categories for `lokalbot-cli config`.

`SettingsStatus` (`LokalBot/Models/Settings/SettingsStatus.swift`) derives, from `PermissionManager`, the model roles and each feature's own switch, everything the window says about state: the quiet **Off** or amber **Paused** at the right of a feature's row, the count badge on the page where something is fixed (Privacy & permissions, Models), what needs the person on Overview, each permission's state, and the status lines under the page headers. A permission counts as needed only while a feature that uses it is on; Autocomplete never makes Screen Recording needed. Every page opens with `SettingsPageHeader`: the page's icon, name and one-line description, **Try it…** where there is something to try (a sheet over the page: `AutocompleteTrySheet`, `DictationTrySheet`; the Autocomplete and Dictation commands open it through `SettingsSheet(focusedSettingID:on:)`), the main switch where the page has one (Autocomplete, Dictation), and one status line per thing to know, each with the button that fixes it (`SettingsStatusActions`). Other pages no longer ask for permissions in their own way. A row with a chevron opens another page in place of its own, with a way back (`SettingsSubpage`, and `ModelsSettingsPage` on Models); `SettingsSubpage.settingIDs` lists the settings each holds, so settings search and deep links open it and land on them.

- **Overview** (`SettingsOverview`), opened from the LokalBot row, is a status page: what needs you, each with its own fix (**Allow…**, **Download**), learned items to review, where your data is (what leaves this Mac, the library and its size, the models), every keyboard shortcut, and the version. It has no feature switches of its own.
- **General** — launch at login, menu-bar-only mode, appearance (theme: Match System / Light / Dark; five text sizes applied through `AppFont` and the `\appTextScale` environment, since macOS text styles ignore SwiftUI Dynamic Type; Default renders body text at 14 pt, one point above macOS, and Small is the unscaled system size), and updates.
- **Models** (`ModelsView`, `ModelStackOverviewView`, derived by `ModelsPagePresentation`) — the header carries **Download all · size** for the models that are missing (the sizes of `OnboardingDownloadPlan`, with free space in its status line) and becomes a progress line with **Cancel** (`ModelRoles.cancelCoreModelDownloads`). **What each model does** has the model set (the `ModelStackPreset` the three choices match, or Custom; choosing one opens its review sheet) and one row per role: what it does in plain words, the model, On this Mac or Online, its size, a status chip (Ready, Not downloaded, Downloading with progress, Checking, Check failed, Stopped, Not set up) and **Change…**, which opens the role's picker. Think's picker lists two groups, on this Mac and online, with each model's size and memory need; a server at a loopback address counts as this Mac. **More** rows open the downloaded models, the online services (approvals with Revoke, then the connection editor) and the other models (Dictation's Compose, read aloud, search by meaning). A folded **Advanced** holds how long Think reasons, the effort on long meetings, the download source, storage, and **Check Setup…**. A model on this Mac is checked by itself once, when a download made in this launch finishes and no meeting is recording (`ModelAutoCheckTracker`, `ModelCheckController.readinessChanged`); a failed check shows on the chip and as a status line that opens the check sheet. A model on a server or subscription is checked only from that sheet, which says what the check sends.
- **Privacy & permissions** (`privacy`, `SettingsPrivacySections`) — the one home for permissions and for what leaves the Mac: each macOS permission and Calendar with the features that use it and its state (Allowed, Allow…, or not needed now), the relaunch a grant may need, every origin approved to receive something with its Revoke (the same confirmations as on Models), summaries of agent access and phone sharing that open their pages, and the library's folder and size. PRIVACY.md is the contract for its wording.
- **Remember:** **Meetings** (`recording`) — detection, calendar, processing with the Transcribe and Think models and transcription language and vocabulary in sheets over the page, speakers, notes, and per-meeting note export. **Screen & activity** (`dayMemory`) — app tracking, screen context, retention, capture exclusions, coding agent sessions, and the agent box for screen memory. **Files** and **Email** — their sources, with the agent box for Files.
- **Assistant:** **Ask** — the opt-in Quick Recall shortcut (`⌃⇧Space` by default) and the selection actions shortcut, the Think model, search by meaning, and a summary of what Ask can search. **About you** (`personalContext`, formerly Personal Context) — what you told LokalBot, learning, and the agent box for shared items. **Daily review** (`daily`) — the day digest, overnight review, routines, and the daily note export.
- **Writing:** **Autocomplete** (`writing`, `AutocompleteSettingsSections`) — the settings first, in groups: Suggestions (length, the wait after typing stops, the accept key and what each press takes, punctuation, Escape, multi-line), What it can read (app and window name, clipboard, text above the field, the whole window, facts from meetings and from screen history), Extras (typo fixes, emoji, macros, matching the app's font), then More: the model (in a sheet over the page) and rows that open the writing profile with local learning, the apps and sites to skip, Usage (statistics and timings in one place) and Advanced. The rehearsal is the header's **Try it…** sheet. **Dictation** (`DictationSettingsSections`) — the shortcut (recordable, including modifier-only chords), how it starts and stops, paste vs. clipboard, the microphone; the mode, with Compose's sources and the shared writing profile indented under it and a **Who writes the text** row that names the model and says when dictated words are sent to a service (`DictationWriterPresentation`); what shows while dictating; and a row that opens the recent dictations. Trying it out is the header's **Try it…** sheet. Row labels are plainer than the settings' names. Identifiers, stored values and the names in `SettingRegistry` and the CLI are unchanged; `SettingDescriptor.label` holds a row's words, which settings search shows and matches along with the name.
- **Sharing:** **AI agents** (`agents`, formerly External Agents) — the read switch with its boxes, settings access with recent changes and Undo, and Agent CLI installation. **Phones & tablets** (`devices`) — off by default; shares an allowlisted, Noise-encrypted copy of the library with paired iPhone, iPad and Android devices over the local network or Tailscale (`LokalBot/Services/Companion/`): the on/off switch, Add a device (a QR code), the paired devices, the data classes and history window, answering questions from devices, accepting recordings from devices, the port, and Bonjour advertising. Record builders turn the library into the JSON of `Companion/protocol/records.md`; `CompanionRecordBuilderTests` checks that no record carries attendee emails, speaker evidence, screenshot paths, screen text, or window titles when they are off.
- **Diagnostics** (`advanced`) — Memory Health, the live resource monitor, hardware, recent generations, and diagnostics export.

Category switches start at the top rather than inheriting another page's scroll position.

## First-run setup

`OnboardingView` is three steps (`OnboardingStep`: Choose, Allow access, Download), named in a stepper that sits in the window's title bar; a finished step is a button that goes back. The choices are a `CaptureSetupDraft` started from the current settings, so a new install keeps its defaults, and nothing is applied until **Start using LokalBot** or **Skip for now** calls `AppState.finishOnboarding`. The app language menu is on the first step only.

- **Choose:** Meeting notes is a switch over `autoRecordMode` (off is `.manual`; the draft remembers the automatic or ask choice behind it), Your workday is `trackingEnabled` with the capture mode beside it, and Coding agent sessions is the master switch.
- **Allow access:** `OnboardingAccess` lists only what the draft needs (the microphone always, Accessibility for the workday, Screen Recording for screenshots) and gives each row its state from `PermissionManager`: needed, waiting after System Settings was opened, allowed, allowed after a restart (granted since `grantedAtLaunch`), or turned off (`turnedOff`, a refused microphone). **Restart now** saves an `OnboardingResumeState` (step, draft, the settings the draft started from, the two download options) through `OnboardingResumeStore` and relaunches; the window keeps that state current while it is open, since macOS can also ask to quit after a Screen Recording grant. At launch `OnboardingLaunch.decision` reopens an unfinished setup that has saved state even when the microphone is already granted, and a finished one only after its own Restart now. Saved state is ignored once the settings no longer match the ones the draft started from, and `markSetupFinished` clears it.
- **Download:** `OnboardingDownloadPlan` turns the `ModelRoles` statuses into rows with each model's job, name and size (`ModelSettingsPresentation.estimatedTranscriptionBytes` and the catalog's byte counts), the total still to fetch, and the free space from the readiness snapshot. Nothing downloads until the button that names the size is pressed. While it runs, the plan counts only the models that were missing when it began; `DownloadTimeEstimator` gives minutes left from the last 30 seconds of progress once it has watched for 5, and the amount alone before that. A failed model reads Stopped with Retry, which calls `startCoreModelDownloads` again. The sample-meeting option sets `AppState.sampleMeetingWaitsForModels`; `openWaitingSampleMeeting` adds the sample when the models become ready, also after the window has closed, until LokalBot quits.
