# Phone and tablet companion apps: plan

Date: 2026-10-30, revised 2026-10-31 after the owner's decisions. Status:
decided, not started.
Branch: `claude/companion-apps`.

**Goal.** People who run LokalBot on a Mac can read their Work Memory on an
iPhone, iPad or Android phone, tablet or foldable:

- meetings, action items and decisions;
- the Timeline and the Day Digest, including previous days;
- answers to questions about all of it.

Data moves only between the person's own devices, over their local network or
their Tailscale network, end-to-end encrypted. No LokalBot server or other
third party is involved. The Mac stays the place where everything is recorded,
processed and decided. The companion apps never record or transcribe.

Anyone can have one Mac and any number of paired phones and tablets. The first
test devices are the owner's iPad and Android phone. The apps ship through the
owner's App Store and Play Store accounts.

## The bet

The risk is not the screens. It is getting a trustworthy copy of a private
library onto a phone. Five choices follow:

- **The Mac is the hub. No cloud.** When sharing is on, the Mac listens for
  paired devices on the local network and on Tailscale, and accepts nothing
  from anywhere else. Phones sync whenever they can reach it:
  - on the same Wi-Fi;
  - from anywhere, with Tailscale on both devices.

  Phones keep a full copy, so reading works offline. The privacy policy's
  central promise still holds: LokalBot operates no server and receives
  nothing.
- **The Mac sends a cleaned-up view, not its files.** The library mixes
  canonical data with things that should not leave the Mac (attendee emails,
  speaker evidence, screenshot paths). It also uses four date encodings and has
  local SQLite IDs inside citations. So the Mac builds versioned *companion
  records*: plain JSON that holds only what an allowlist names. Everything is
  precomputed, including the action state, people, timeline sessions and
  digest sections. The phone only renders, filters and searches.
- **One protocol and storage core, written once.** This is a new Rust crate,
  `lokalbot-sync`, in the existing Rust workspace. UniFFI exposes it to:
  - Swift, for the Mac and the iOS/iPadOS app;
  - Kotlin, for Android.

  It holds the handshake, the encrypted session, the messages, the record
  schema, the phone's local store and its search index. A Windows/Linux Mac
  equivalent can serve devices later through the same crate.
- **Questions are answered by the Mac.** "Ask" on the phone goes to the Mac.
  The Mac runs the same Ask agent, engine, tools and approvals it uses today,
  and streams an answer with citations back. When the Mac is unreachable, the
  phone searches its own copy and queues the question. Answering on the device
  comes later.
- **Native UI on each platform, same design language.** SwiftUI for
  iPhone/iPad and Jetpack Compose with Material 3 Adaptive for Android. Both
  use tokens generated from one file that is taken from the Mac's
  `DesignTokens.swift` and `Brand.swift`.

## Architecture

```
 Mac (LokalBot)                                         iPhone · iPad · Android
 ──────────────                                         ───────────────────────
 meetings/, journal/, people/,                          lokalbot-sync (UniFFI)
 projects/, lokalbotv3.sqlite                             ├─ Noise session (pinned keys)
        │                                                 ├─ local SQLite + FTS5 copy
        ▼                                                 └─ query API
 Companion records (Swift builders)                     SwiftUI / Compose UI
        │
        ▼
 lokalbot-sync: listener ◄── LAN (Bonjour) or Tailscale (100.x / MagicDNS) ──► sync · Ask · action status
 Ask responder · op applier          Noise-encrypted, mutually authenticated
```

## What syncs

The Mac app gets a new settings pane, **Phones & tablets**. It turns sharing on
and sets what is shared, per data class. Everything stays within the person's
own devices, so the defaults are more generous than they would be for a
third-party destination.

| Data class | Source on the Mac | Default | Notes |
|---|---|---|---|
| Meetings: title, time, app, duration, people's display names, projects, summary, the user's notes | `meta.json`, `summary.md`, `notes.md` | On | Calendar attendee emails are left out |
| Actions, decisions, open questions | `outcomes.json` merged with `outcome-state.json` (`MeetingOutcomeProjection`) | On | Status, owner and due corrections already applied; the due date is resolved on the Mac and the spoken phrase is kept |
| Transcripts: text, times, speaker display names | `transcript.json` | On | Its own record. No speaker evidence, attribution or voice profiles |
| Day Digest | `journal/YYYY-MM-DD.md` + `.meta.json` | On | Markdown plus parsed sections. `[screen:N]` citations become "screen moment at HH:MM" |
| Timeline: work sessions, apps, durations, projects, coding-agent sessions, saved moments | `activity_blocks`, `coding_agent_bursts`, `screen_bookmarks` via `DayActivityProjection` | On | Computed on the Mac |
| Timeline: window titles | `activity_blocks.title` | On | Can be turned off; Mac retention that blanks titles carries over |
| People and projects | `PeopleDirectory` + `people/curation.json`; `projects/tracked.json` + `summaries.json` | On | Display names only |
| How far back | — | All history | Can be set to 30, 90 or 365 days |

**Not in the first release:**
- screenshots and OCR screen text: a later opt-in. Screen text needs its own
  toggle, as it does for agent access;
- audio: later, as streaming on demand, which is practical over a local
  network;
- email, Personal Context, overnight (Dream) memory;
- Ask conversations held on the Mac;
- speaker evidence and voice profiles, attendee emails;
- API keys and settings.

## Companion records (schema v1)

Records are JSON, compressed with zstd. All dates are ISO-8601 UTC with
milliseconds, plus the meeting's local time zone offset where display needs it.

| Record | Key | Contents |
|---|---|---|
| `manifest` | single | Schema version, library display name, the Mac's device name, enabled data classes, counts, history window |
| `meeting` | meeting UUID | Header, people and projects, summary Markdown, notes Markdown, actions `{id, text, owner, ownerIsUser, ownerUnclear, dueDate?, dueText?, status, importance, citations[{start, end, speaker, excerpt}]}`, decisions, open questions, `mergedInto?` |
| `transcript` | meeting UUID | Segments `{start, end, speaker, colorIndex, text}` |
| `day` | `YYYY-MM-DD` | Digest `{markdown, sections{blockers, highlights, decisions, tasks, followUps}, generatedAt, userEdited}`, timeline `{sessions[{start, end, project?, apps[{name, seconds}], titles?, agent?}], totals, meetingIDs, savedMoments}` |
| `person` | person ID | Display name, open work, decisions together, meetings together |
| `project` | project UUID | Name, "where it stands", your actions, waiting on others, time this week, people, meetings |

Deleting or merging a meeting produces a tombstone, so the phone removes it too.

**How the Mac notices changes.** Change detection uses a hash of each built
record, not file times. Loading the library rewrites `meta.json`, so mtime
reports false changes. The Mac keeps `(recordKey, contentHash, version, seq)` in
a small table. It rebuilds records when these fire:

- `primaryEvidenceDidChange(on:meetingIDs:)` (`AppState.swift:2120`);
- `OutcomeIndex.mutateAction` (`OutcomeIndex.swift:225`);
- saving notes;
- the Day Digest writer;
- saving people and project curation;
- meeting deletion and merge;
- every 15 minutes for today's `day` record while there is activity;
- a full reconcile at launch and once a day.

Records are built ahead of time, so a phone that connects gets its changes
straight away. The golden fixtures for the schema come from
`LokalBotTests/Fixtures/upgrade/<version>/library`.

## Network, encryption and pairing

**Where the Mac listens.** One TCP port, 17890 by default and changeable,
open only while sharing is on.
- Before any handshake, the Mac refuses peers outside these address ranges:
  - private LAN (RFC 1918, link-local, IPv6 ULA);
  - Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`).
- This uses the same address classes `InferenceEndpointPolicy` already treats
  as private.
- On the LAN, the Mac advertises a Bonjour service, `_lokalbot._tcp`. Its
  instance name is a neutral `LokalBot-XXXX` rather than the person's name.
  Its TXT record carries a short hash of the Mac's key so paired phones
  recognize it.
- Bonjour advertising can be turned off for Tailscale-only use.

**Encryption.** The Noise Protocol Framework, using the `snow` crate in the Rust
core: X25519, ChaChaPoly and BLAKE2s, the same family WireGuard uses.
- **Static keys.** Every device, the Mac included, has a long-term X25519 key.
  - Apple: the Keychain, `ThisDeviceOnly`, not synchronizable, like the
    existing `chat-key`.
  - Android: encrypted with a hardware-backed Keystore key.
- **Pairing** uses `Noise_XXpsk3`. The pre-shared key comes from the QR code,
  so only a phone that saw the code can pair, and each side learns the
  other's static key.
- **Every later connection** uses `Noise_IK`. The phone already knows the
  Mac's key. The Mac admits the phone only if its key is on the paired
  list.
- **Tailscale** adds its own WireGuard layer. LokalBot doesn't depend on it:
  the same session is safe on an open café network or a shared office LAN.
- With no third party holding data, there is no shared library key to rotate.
  Removing a device deletes its key from the paired list, and it is locked
  out immediately.

**Pairing (about 20 seconds; the phone must be able to reach the Mac).**
1. In Mac Settings → Phones & tablets → **Add a device**, the Mac shows a QR
   code. It holds:
   - the Mac's addresses: its current LAN addresses, its Tailscale address and
     MagicDNS name if there is one, and the Bonjour name;
   - the port;
   - the Mac's key fingerprint;
   - a 32-byte one-time secret.

   It expires after 5 minutes and works once.
2. The phone scans the code and runs the pairing handshake to whichever
   address answers first. It sends its name and platform.
3. The Mac asks: "Allow *Stevan's iPad* to read your shared LokalBot data?"
4. When the person allows it, the phone stores the Mac's key and addresses and
   starts syncing, newest records first.

**Finding the Mac later.** The phone tries three ways at once:
1. Bonjour on the current network;
2. the stored Tailscale address and MagicDNS name;
3. the last LAN address that worked.

The Mac's key, not its address, proves it is the right Mac.

**Removing a device.**
- From the Mac: remove it in the device list. It is refused from the next
  connection. If it is connected when removed, it is told to erase its local
  copy.
- From the phone: Settings → Remove this device erases the local copy and
  tells the Mac when it next connects.

**Platform permissions.**
- **Mac and iOS:** the local network permission
  (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).
  - The Mac's existing usage string must be rewritten to cover paired devices.
  - If the macOS firewall is on, it may ask to allow incoming connections.
- **Android:** NSD for Bonjour discovery, plus whatever local network access
  permission the target SDK requires. Check this at implementation time.

**On the phone.** The local database lives in the app's private storage:
- **iOS:** data protection class `completeUntilFirstUserAuthentication`, so
  background refresh works.
- **Android:** file-based encryption.

An optional app lock uses Face ID / Touch ID or BiometricPrompt. Unpairing
erases everything.

## Sync protocol

Messages are length-prefixed frames inside the Noise session. Large records are
split across Noise messages, which are capped at 64 KB.

- **Hello.** Each side sends its protocol version, schema version and the
  phone's cursor. The Mac replies with its manifest.
- **Changes.** The Mac streams records with `seq` greater than the cursor:
  - newest days and meetings first;
  - transcripts after the meeting records;
  - tombstones included.

  The phone upserts each one into its store and FTS index and advances the
  cursor in batches. An interrupted sync resumes where it stopped.
- **Live.** While the app is open and connected, the Mac pushes new records as
  it builds them.
- **Background.**
  - iOS: `BGAppRefreshTask`.
  - Android: periodic `WorkManager`, constrained to an unmetered network or
    Tailscale.

  Each run syncs whenever the Mac is reachable. With no server there are no
  remote push notifications: the phone learns about changes when it
  connects.
- **Action status from the phone.** The phone sends an op:
  - `action.setStatus{meetingID, actionID, actionTextSnapshot, status, at}`.

  Ops made offline are queued on the phone. The Mac applies each one through
  `OutcomeIndex.mutateAction`. If reprocessing changed the action ID, it
  matches on the text snapshot or parks the op the way `unmatchedActions`
  does today. It then rebuilds the meeting record and acknowledges the op.
  Until then the phone shows "waiting for your Mac".

## Ask from a phone or tablet

**When the Mac is reachable.**
1. The phone sends `ask.request{conversationID, question, scope, history}`.
2. A new `CompanionAskResponder` runs the existing `ChatAgent` with a
   `ScopedChatToolRunner` (`AskRouting.swift`). The runner disables tools for
   data classes that aren't shared. For example, `search_screen` stays
   disabled until screen text can be shared.
3. Answer text streams back as it is written. As on the Mac, streaming starts
   only after the `FINAL_ANSWER:` prefix.
4. It finishes with `ask.done{answer, citations, engineLabel, location}`.

The Mac applies all its current rules:
- the Think engine the person selected;
- per-origin remote-inference approvals;
- the citation check (`ChatCitation.swift`).

The phone shows where the answer was produced, using the Mac's colors:
- teal for "Answered on your Mac with Qwen3.6 35B";
- amber when an approved remote engine answered.

`[meeting:ID@HH:MM:SS]` citations open the synced meeting at that moment.
Screen citations are shown as text only.

**When the Mac is not reachable.** The phone says so and offers two things:
- **Search this device.** FTS5 over the local copy, covering meetings,
  actions, transcripts and digests.
- **Ask when my Mac is back.** The question is queued on the phone and sent
  on the next connection. A local notification announces the answer.

**Later: answering on the device.** Without a cloud relay, this matters more.
It ports the retrieve-first single-pass answer from
`LinuxWindows/crates/lokalbot-ai/src/ask.rs`. Retrieval runs in the Rust core.
Generation uses:
- Apple's Foundation Models on iPads and iPhones with Apple Intelligence;
- ML Kit GenAI (Gemini Nano) on supported Android devices.

The Mac's Apple Intelligence profile in `ChatAgent.swift` (smaller step and
history caps) shows the budget to plan for. These answers are labeled
"Answered on this iPad".

## Design language

The companion apps should look like LokalBot, not like a generic mobile
template. A new `Companion/design/tokens.json` is extracted from
`LokalBot/Support/DesignTokens.swift` (`LBTokens`), `Brand.swift` and
`DesignSystem.swift`. `LinuxWindows/crates/lokalbot-app/src/theme.rs` already
lists the exact hex values. A script generates `LBTokens.swift` for iOS and
`LokalBotTheme.kt` for Android from it.

| Token | Light | Dark | Use |
|---|---|---|---|
| accentFill | #0C8275 | #0C8275 | Filled buttons, selection, citation badges (white text) |
| accentText | #075F55 | #6EF2DC | Links, timestamps, icons, done checks, evidence pills |
| attention / attentionText | #FF9500 / #984C00 | #FF9F0A / #FFB84D | Owner unclear, blockers, remote-engine marker |
| success / successText | #28CD41 / #176F2C | #30D158 / #4BDC71 | |
| recording / recordingText | #FF3B30 / #B60012 | #FF453A / #FF9C95 | Overdue, destructive |
| groupFill / groupStroke | black 3.5% / 7% | white 5% / 6% | Grouped surfaces |
| supporting text | #575757 | #C2C2C2 | Metadata lines |
| window / sidebar / elevated (Android) | #FFFFFF / #F2F2F3 / #FFFFFF | #1E1E1F / #262628 / #2A2A2C | iOS uses system backgrounds |
| speakers 0–7 | #075F55 #007AFF #AF52DE #FF2D55 #D9A400 #5856D6 #A2845E #32ADE6 | #6EF2DC #0A84FF #BF5AF2 #FF375F #FFD60A #5E5CE6 #AC8E68 #64D2FF | Index 0 is "You" |
| app/project color | HSB(djb2(name) % 360, 0.55, 0.78) | same | Timeline dots and bars, identical hash on every platform |

**Shape and motion.**
- Radii: tab 7, row 8, control, panel and card 10, composer 18; chips are
  capsules.
- Almost no shadows. Materials only for floating chrome.
- Motion: selection 0.14 s ease-out, disclosure 0.16 s, drawer 0.18 s,
  tabs 0.22 s snappy, all off under Reduce Motion or "Remove animations".

**Type.** The Mac's sizes are desktop sizes (body 13 pt), so the companions keep
the Mac's *roles* and map them to each platform's scalable styles:

| Role | Mac | iOS | Android (Material 3) |
|---|---|---|---|
| pageTitle | largeTitle bold | `.largeTitle` bold | headlineMedium bold |
| question (Ask) | title2 semibold | `.title3` semibold | titleLarge semibold |
| section | headline | `.headline` | titleSmall |
| reading (transcript, digest) | 14 pt, line spacing 3 | `.body`, line spacing 3 | bodyLarge |
| secondary | callout | `.subheadline` | bodyMedium |
| caption | subheadline | `.footnote` | bodySmall |
| timestamp | callout, monospaced digits | `.subheadline.monospacedDigit()` | bodyMedium, `tnum` |

iOS uses SF. Android uses Inter, which the Linux/Windows app already bundles
under the OFL licence and which looks close to SF. Both honor Dynamic Type or
font scale, Increase Contrast and right-to-left layout.

**Components** to port, by their Mac names:
- `WorkspaceSection`, `SectionHeader`, `BrandChip` / chips, `StatusDot`;
- `EvidencePill`, `InitialsAvatar`, `ProjectMonogram`, `StatTile`;
- `ToolbarTabs` (the capsule tabs with the teal knob);
- the round `ActionItemToggleStyle`;
- the Ask layout: an editorial transcript with no bubbles, the question in
  semibold, numbered teal source badges, and a composer docked at the bottom
  (Liquid Glass on iOS 26 with the same fallbacks as the Mac).

Android turns dynamic color off so the teal brand stays.

## The apps

The screens are the same on both platforms. Their order follows the Mac
sidebar. Actions becomes a top-level destination because checking action items
is the main thing people do on a phone.

- **Today.** Needs attention (the top open actions, overdue first), today's
  Day Digest (or yesterday's until today's is ready), today's meetings and
  time, and when the phone last synced with the Mac.
- **Meetings.** A list grouped by day, with search. The detail view has the
  Summary, Transcript and Notes tabs. Review stays on the Mac.
  - The Summary tab has Recap, Action items with toggles, Decisions and Open
    questions. Evidence pills jump to the moment in the transcript.
- **Actions.** Filters for Mine, Others and Owner unclear, and for Open, Done
  and Deferred, sorted by due date. A row opens the cited passage.
- **Timeline.** A day strip you can swipe and a calendar to jump to any
  earlier day. It shows the activity overview bar, the work-session rail and
  that day's meetings. There are no screenshots.
- **Day Digest.** Any day's digest: Blockers, Highlights, Decisions, Tasks,
  Follow-ups.
- **People, Projects.** The same sections as on the Mac.
- **Ask.** The Mac's reading layout, a conversation list where there is room,
  and a status line showing where the answer comes from.
- **Settings.** Paired Mac and how it is reached (Wi-Fi or Tailscale), last
  sync, storage used, what this device receives, app lock, and remove device
  and erase.
- **Sample library.** "Try it without a Mac" opens a built-in demo library. It
  reuses the Mac's sample meeting. App Review and Play review need it, because
  reviewers cannot pair with a Mac.

**iPhone and iPad (SwiftUI, iOS/iPadOS 18+).**
- `TabView` with `.sidebarAdaptable` gives a tab bar on iPhone and in compact
  split view. It gives a sidebar matching the Mac's on a full-width iPad.
- A three-column `NavigationSplitView` for Meetings, Actions, People and
  Projects; two columns elsewhere.
- Timeline uses the Mac's 820-pt breakpoint: side-by-side day pane and session
  rail above it, a sheet drawer below it.
- Layout follows size class, not device, so Split View, Slide Over, Stage
  Manager and rotation all work.
- On iPad:
  - keyboard shortcuts (⌘F search, ⌘N new question, ⌘1–⌘7 sections);
  - pointer hover;
  - scenes, so a meeting can open in its own window.
- Later: a Today widget.

**Android (Kotlin, Jetpack Compose, Material 3 Adaptive, minSdk 29).**
- **Navigation.** `NavigationSuiteScaffold` shows a bottom bar on compact
  widths, a rail on medium, and a drawer on expanded and large widths. The
  drawer follows the Mac sidebar.
- **Panes.**
  - `ListDetailPaneScaffold` for Meetings, Actions, People and Projects: one
    pane on a phone, list plus detail on an unfolded foldable or tablet,
    with predictive back.
  - `SupportingPaneScaffold` for Timeline (day pane plus session rail).
- **Foldables.** Jetpack WindowManager `FoldingFeature`:
  - In book posture, panes split along the hinge and never under it.
  - In tabletop posture, Ask puts the answer on the top half and the
    composer on the bottom.
  - State survives folding and unfolding (`rememberSaveable` and ViewModels).
- Later: a Glance widget.

## Mac app changes

- `LokalBot/Services/Companion/`:
  - `CompanionSettings`;
  - record builders (meeting, transcript, day, person, project);
  - `CompanionPublisher` (hooks, hashes, sequence, tombstones);
  - `CompanionListener` (Network.framework listener, address filter, Bonjour);
  - `CompanionPairing`;
  - `CompanionAskResponder`, `CompanionOpApplier`.
- **Settings → Phones & tablets:**
  - on/off;
  - add a device (QR via Core Image);
  - paired devices with last-seen, network (Wi-Fi or Tailscale) and Remove;
  - data classes and history window;
  - "Answer questions from my devices";
  - port and Bonjour advertising.
- The sidebar's "Storage: this Mac" card shows paired devices when sharing is
  on.
- **PRIVACY.md:** a new section, "Phones and tablets", covering:
  - what is shared and what is not;
  - local network and Tailscale only;
  - end-to-end encryption;
  - how to remove a device.

  The section "nothing listens beyond loopback" gains this one opt-in
  listener, and the effective date changes. Sharing stays off until the
  person turns it on and pairs a device. It is independent of agent access
  and the other grants.
- **`Info.plist`:** rewrite `NSLocalNetworkUsageDescription` to cover paired
  devices and add `NSBonjourServices`.
- **`project.yml`:** link `LokalBotSyncKit` (the XCFramework built from the
  Rust crate) and add the new sources. Run `xcodegen generate`.

## Repository layout

```
LinuxWindows/crates/lokalbot-sync/   # Noise sessions, messages, records, phone store + FTS, UniFFI
Companion/
  README.md
  protocol/                         # protocol.md, record-schema.md, JSON Schema, test vectors
  design/                           # tokens.json + generator
  ios/                              # project.yml (xcodegen), app, LokalBotSyncKit package
  android/                          # Gradle project, :app, :sync (cargo-ndk + generated Kotlin)
Scripts/build-sync-xcframework.sh
```

Placing the crate in the existing Rust workspace reuses its toolchain,
dependency pins and `lokalbot-core` types. A later rename of `LinuxWindows/` is
out of scope.

The localized strings start from `LinuxWindows/localizations/*.json` (24
languages, `{name}` placeholders). They are converted to a String Catalog for
iOS and `strings.xml` for Android. English ships first.

## Building and testing

**Builds.**
- iOS: on the Mac with Xcode 27, team `3N8B4562P4`.
- Android: on the Mac, which already has SDK 35/36, the NDK and JDK 21, or on
  the Ubuntu box for long Gradle and emulator runs.
- CI gets three workflows: `companion-core`, `companion-ios` and
  `companion-android`.
- `xcrun simctl` hung on this Mac on 2026-10-30. Installed iOS simulator
  runtimes need checking before local simulator builds.

**Tests by layer.**
- **Rust core:**
  - handshake and session tests, including a wrong pairing secret, an
    unknown device key, a removed device and a replayed message;
  - convergence tests: interrupted sync, reordered and repeated ops,
    tombstones;
  - Mac-to-phone runs between two processes over localhost and over
    Tailscale.
- **Mac:**
  - golden-record tests from the upgrade fixtures;
  - an exclusion test asserting that no record contains attendee emails,
    speaker evidence, screenshot paths or OCR text, and no window titles when
    titles are off. It must fail when an exclusion is removed;
  - an address-filter test: public peers are refused before the handshake;
  - non-UI tests only, run locally as the repository allows.
- **iOS:**
  - unit tests;
  - snapshot tests at iPhone, iPad full, iPad split and Slide Over sizes,
    in light, dark, large Dynamic Type and RTL.

  These run on hosted CI, not on this MacBook, following the repository's UI
  test rule.
- **Android:**
  - JVM unit tests;
  - Compose screenshot tests (Roborazzi) at compact, medium and expanded
    widths and in book and tabletop postures;
  - emulator runs for Pixel Fold and Pixel Tablet profiles on the Ubuntu box
    or CI.

**On the owner's devices.** These use the `LokalBot Dev` build pointed at a
fixture library (`LOKALBOT_STORAGE_ROOT`). Real data is only involved once the
owner chooses to pair the real app. Each device is checked on the home Wi-Fi
and then on cellular through Tailscale.
- **iPad:** install from Xcode, then TestFlight.
- **Android phone:** `adb install`, then Play internal testing.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | Spec | The protocol spec, record schema v1 with fixtures, PRIVACY.md draft and `tokens.json` are reviewed |
| 1 | Core | Two harness processes pair and fully replicate a fixture library over localhost and over Tailscale. Handshake, removal and convergence tests pass |
| 2 | Mac | A dev build listens only while sharing is on, refuses public peers, pairs by QR, serves the fixture library and removes a device. The exclusion test passes and fails with an exclusion undone |
| 3 | iPhone/iPad, read-only | On the owner's iPad (Xcode, then TestFlight): it pairs, then shows Today, Meetings, Actions, Timeline and Digest for earlier days. It works offline and syncs on Wi-Fi and through Tailscale. Split View, Stage Manager and rotation layouts are checked. CI snapshots pass |
| 4 | Android, read-only (can run alongside 3) | On the owner's phone (`adb`, then Play internal testing): the same. Emulator screenshots pass at all widths and fold postures |
| 5 | Ask + action status | A question from either device is answered by the Mac with tappable citations. The offline search and queued questions work. Marking an action done on a phone shows on the Mac within seconds when connected, and after reconnecting when not |
| 6 | Store release | App lock, background refresh, sample library, localization, App Store and Play listings, privacy labels ("Data Not Collected"), Play Data safety, iOS export-compliance declaration, release notes with an explainer, website |

**Later:**
- answering on the device;
- audio on demand;
- screen text and screenshots as an opt-in;
- a Windows/Linux host;
- syncing Ask history between devices;
- correcting owners and due dates, and adding notes, from the phone.

## Risks

- **The phone is only as fresh as its last connection.** Without Tailscale,
  that means the last time it shared a network with the Mac. Asleep or quit
  also means unreachable: nothing in this plan wakes a Mac. The screens show
  "Last synced with your Mac at …" prominently, and Settings explains
  Tailscale.
- **Ask needs the Mac awake and reachable.** Offline search, queued questions
  and later on-device answers soften this.
- **Local network permissions.**
  - On the Mac, the existing local network usage string promises nothing goes
    to other devices; it must change with this feature.
  - On iOS, a denied local network prompt breaks Bonjour discovery. The app
    detects this, explains it, and still tries Tailscale addresses.
  - Android's local network rules are tightening by SDK level.
- **Action IDs are content hashes and change on reprocessing.** Ops carry a
  text snapshot and reuse the existing unmatched-action reconciliation.
- **Building Rust into three app builds.** Prebuilt XCFramework and AAR
  artifacts are cached in CI. If UniFFI proves awkward, the fallback is
  Swift (CryptoKit plus a Noise implementation) on Apple platforms and Kotlin
  on Android, held together by the same test vectors.
- **Store review.** Reviewers can't pair with a Mac, so the sample library is
  a release requirement, not a nice-to-have. The review notes must explain
  the Mac app, the local network and Tailscale.

## Decisions

Made by the owner on 2026-10-31:

1. **Local network and Tailscale only.** No relay, no LokalBot server, no
   other cloud.
2. **The privacy policy can bend.** PRIVACY.md will be updated for this
   feature. Defaults reflect that data stays within the person's own devices.
3. **Distribution through the owner's App Store and Play Store accounts.**
   TestFlight and Play internal testing from milestones 3–4, public release
   at milestone 6.

Proposed defaults, applied unless the owner says otherwise:

4. Phone questions are answered by whatever engine the Mac uses, under its
   existing approvals, with the teal or amber marker.
5. Window titles on, with a toggle. Screenshots and screen text later, as an
   opt-in.
6. Phones can change action status (done, open, deferred) in the first
   release. Corrections and notes come later.
