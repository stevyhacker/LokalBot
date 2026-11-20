# 0006. Mac app: App

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/App/`, `LokalBot/Services/App/`, `LokalBotTests/Models/App/`, `LokalBotTests/Services/App/`.

## Decisions

### `LokalBot/Models/App/AppDirectories.swift`

#### Single source of on-disk roots shared by app and lokalbot-cli
`AppDirectories`: Single source of truth for LokalBot's on-disk roots. Compiled into both the
app and the embedded `lokalbot-cli`, so every binary resolves the same
paths — nothing else in the codebase should rebuild these from
`FileManager.urls(for: .applicationSupportDirectory, ...)`.

#### Temp-directory fallback keeps the property total
`AppDirectories.userApplicationSupport`: `~/Library/Application Support` (temp-directory fallback keeps this
total; the URL is always present in practice).

#### Identity-scoped home not redirected by storage-root override; GGUFs excepted
`AppDirectories.applicationSupport`: The app identity's Application Support home. Development builds use
`me.dotenv.LokalBot.dev`; their retention settings cannot affect release
data. Identity-scoped runtimes and mutable process markers are separate too.

Deliberately NOT redirected by the storage-root override: transcription
model stores and the agent runtime live here even under
`LOKALBOT_STORAGE_ROOT` isolation, so fixture runs share them only with
their app identity (llama-server state: `localServerSupport`).
Catalog GGUFs are the exception — they download under the overridable
library root (`ModelCatalog.localURL`); `Scripts/test/e2e.sh` symlinks the
real models/ into its temp root to keep those shared too.

#### Unit-test host gets its own server folder, never the installed app's
`AppDirectories.localServerSupport`: The installed llama-server binary, its PID markers, owner locks and
bearer tokens. This is the identity's Application Support home, except
in the unit-test host: it carries the release bundle id, so it gets its
own folder and never writes the installed app's markers or reads its
tokens. Not redirected by the storage-root override either.

#### FluidAudio cache root follows the package's convention
`AppDirectories.fluidAudioRoot`: FluidAudio's own cache root (`~/Library/Application Support/FluidAudio`)
— the package's convention, not ours; Parakeet/Cohere models land here.

#### Keep the 1.6 GB WhisperKit model out of Documents
`AppDirectories.whisperKitDownloadRoot`: WhisperKit's Hugging Face cache base. Passing this explicitly keeps the
1.6 GB Core ML model out of `~/Documents`, which may be redirected to a
managed cloud provider, and alongside LokalBot's other local runtimes.

#### Library root honors LOKALBOT_STORAGE_ROOT so tests and CLI match the app
`AppDirectories.libraryRoot`: The meeting-library root — all user data (meetings, indexes, journal,
logs) lives under it. Honors the `LOKALBOT_STORAGE_ROOT` override so UI
tests, hermetic e2e runs, and the CLI all resolve the same isolated
library as the app.

#### Agent workspace is empty and beside the library to avoid exposing data
`AppDirectories.agentWorkspace`: Agent tools start in an empty workspace beside the private library, so
selecting the default workspace does not expose recordings or settings.

### `LokalBot/Models/App/AppIdentifiers.swift`

#### Release identity frozen for existing libraries and Keychain items
`AppIdentifiers.appBundleID`: The release identity is frozen for existing libraries and Keychain items.

#### Shared CLI resolves its enclosing app even via the command symlink
`AppIdentifiers.identity`: The shared CLI target is embedded in both app variants. Resolve its
enclosing app even when invoked through the installed command symlink.

#### XCTest hosts the production app, so keep launch hermetic
`UITestRuntime.isUnitTesting`: XCTest loads the production app as its host, so `LokalBotMain.main()` and
`AppState` still run before the first test method. Keep that launch
hermetic even when the caller did not provide the UI-test overrides.

#### Unit tests never download models; refusal throws and fails the test
`UITestRuntime.refuseDownloadInUnitTests`: Unit tests run with temporary libraries, so any model they reach would
be downloaded from the network. They never download one: the download
throws instead, and the test bundle fails the test that started it.

#### Folder and settings suite for release-identity Xcode build products
`UITestRuntime.localBuildName`: The folder and settings suite of a release-identity copy run from
Xcode build products.

#### Dev copies of release identity keep separate library and settings
`UITestRuntime.isLocalBuild`: A release-identity app run from Xcode build products (DerivedData or a
custom derived-data path) keeps its own library and settings, so a
development copy never writes the installed app's activity, journals,
or scheduled runs. `LOKALBOT_STORAGE_ROOT` still points it anywhere.

#### Distinguish never saved (nil) from unreadable keychain (throws)
`KeychainSecrets.existingData`: The item's data, or nil when it was never saved. Throws for any other
failure (a locked keychain, denied access), so a caller can tell
"signed out" from "can't read it right now".

#### Per-install AES-256 key in Keychain, cached on the main actor
`KeychainSecrets.symmetricKey`: A per-install AES-256 key for `account`, generated on first use and
stored in the Keychain (design §3.4). Used to seal at-rest data —
screenshots (`screenshot-key`) and chat history (`chat-key`) — with
`AES.GCM`. Cached in-process per account; `@MainActor` because the cache
is shared mutable state and every caller already runs on the main actor.

#### Never update existing keys; read failure is not absence; creator wins
`KeychainSecrets.resolveSymmetricKey`: Loads the existing AES-256 key or atomically creates it on first use.
Existing items are never updated: a temporary read failure must not be
mistaken for absence, and a concurrent creator wins without replacement.

### `LokalBot/Models/App/AppLanguage.swift`

#### Interface language only; never changes stored content or speech preferences
`AppLanguage`: Interface language only. Speech recognition and generated notes keep their
own preferences; changing the interface never changes stored user content.

#### Native names keep the picker recognizable in any interface language
`AppLanguage.displayName`: Native names keep the language picker recognizable regardless of the current interface language.

#### Exhaustive switch keeps every language searchable by English name
`AppLanguage.englishName`: English names for settings search. The exhaustive switch keeps a new
language from being unsearchable by its English name.

#### Traditional script or TW/HK/MO without Simplified selects Traditional Chinese
`AppLanguage.localizationIdentifier`: The Traditional script, or Taiwan, Hong Kong, or Macau without an
explicit Simplified script, selects Traditional Chinese.

#### Serbian either script and Montenegrin use the Latin Serbian catalog
`AppLanguage.localizationIdentifier`: Serbian in either script, and Montenegrin, use the Latin Serbian catalog.

#### ar-EG is not Egyptian Arabic; only language code arz selects it
`AppLanguage.localizationIdentifier`: A system ar-EG preference is Arabic with region Egypt, not a
dialect choice. Only the language code arz selects Egyptian Arabic.

#### Use Foundation's script direction instead of a hand-kept RTL list
`AppLanguage.isRightToLeft`: Foundation knows each script's direction, so a future Persian, Hebrew,
or Pashto catalog lays out right to left without a hand-kept list.

#### Translate only the system option so users can recover from wrong language
`AppLanguage.pickerLabel`: Translate only the system option; language names remain native so a
person can recover from accidentally selecting an unfamiliar language.

#### Native text-field bridges receive the locale from the SwiftUI parent
`AppLanguage.matching`: Native text-field bridges receive the locale from their SwiftUI parent.

#### Explicit Egyptian Arabic choice must stay ar-EG, not follow system rules
`AppLanguage.matching`: These bridges receive the selected catalog locale, so an explicit
Egyptian Arabic choice must stay ar-EG instead of following system rules.

#### Resolve AppKit and search labels without changing AppleLanguages or Bundle.main
`AppLanguage.localized`: AppKit menus and settings search do not read SwiftUI's locale. Resolve
their app-owned labels explicitly without changing AppleLanguages or
replacing Bundle.main (which would affect other frameworks).

### `LokalBot/Models/App/BackgroundActivity.swift`

#### Owners stay source of truth; derive merges their state ordered by Kind
`BackgroundActivity`: Long-running work shown in the sidebar progress card. The owners of each
kind of work stay the source of truth; `derive` maps their published state
into one list ordered by `Kind`.

#### Fraction is 0...1 only when the owner knows progress
`BackgroundActivity.fraction`: 0...1 when the owner knows how far along the work is.

### `LokalBot/Models/App/GitHubStarPrompt.swift`

#### Star request keeps only local state; sends nothing, never learns if starred
`GitHubStarPrompt`: The one-time request on Today to star LokalBot's repository, and the
address the permanent "Star on GitHub" links open. Everything here stays on
this Mac: LokalBot keeps only whether a meeting summary has finished, which
calendar days it was used, and whether the request was answered. It sends
nothing and never learns whether anyone starred.

#### Seven distinct active days make the request eligible without a summary
`GitHubStarPrompt.activeDaysBeforeAsking`: Distinct days of use that make the request eligible without a summary.

#### Marker written by seed_demo_library.py at every planted library root
`GitHubStarPrompt.demoLibraryMarker`: Written by `Scripts/test/seed_demo_library.py` at the root of every library
it plants, including the screenshot, film, and upgrade-fixture ones.

#### Either button sets dismissed permanently, never cleared
`GitHubStarPrompt.State.dismissed`: Set by either button on the request, and never cleared.

#### Active days stored as local yyyy-MM-dd, kept only until enough
`GitHubStarPrompt.State.activeDays`: Distinct local calendar days ("yyyy-MM-dd") LokalBot was used,
kept only until there are enough to ask.

#### Some launches must never show or count toward the request
`GitHubStarPrompt.Launch`: Launches that must never show the request or count toward it.

#### README, website and film captures run the UI-test host or flag
`GitHubStarPrompt.Launch.uiTesting`: XCUITest, and the README, website, and film captures, which all run
the UI-test host or pass the UI-test flag.

#### Show after first summary or seven active days until answered
`GitHubStarPrompt.shouldShow`: After the first completed meeting summary or `activeDaysBeforeAsking`
distinct days of use, whichever comes first, until it is answered.

### `LokalBot/Models/App/MenuBarStatus.swift`

#### First attention item leads the panel; status item dot while any exist
`MenuBarAttention`: One thing the menu bar asks the person to fix. The panel's status block
leads with the first and lists the rest under it, and the status item
carries a dot while there is any.

#### After refusal only System Settings can re-enable the microphone
`MenuBarAttention.microphoneRefused`: A recording or dictation start was refused: only System Settings can
turn the microphone back on.

#### Order most blocking first; refused mic replaces the ungranted one
`MenuBarAttention.items`: Everything waiting, most blocking first: what stops recording, then
the latest error, then approvals. A refused microphone stands in for
the ungranted one: both are the same switch, and once it was refused
only System Settings can turn it on.

#### Menu bar status is display-only; nothing stored or sent
`MenuBarStatus`: What the menu bar panel says LokalBot is doing, and the meetings listed
under it. Display-only; nothing here is stored or sent.

#### Meeting leads menu within 15 minutes, shorter than Today's hour
`MenuBarStatus.soonWindow`: A calendar meeting leads the menu once it starts within this long, and
keeps the block while under way and not being recorded. Shorter than
Today's hour (`TodayAgenda.nextMeetingWindow`): the menu is a glance.

#### Block priority order; recording or dictation always leads so Stop stays visible
`MenuBarStatus.Block`: The status block's one state. `init` picks it in this order:
recording, dictating, needs attention, a meeting about to start, day
memory paused, just stopped, idle. A recording or a dictation leads
even when something needs attention, so Stop is never hidden; the
waiting items are listed under it.

#### Attention items under the block: all while recording, else the rest
`MenuBarStatus.moreAttention`: Attention items listed under the block: every one while a recording
or a dictation leads, the rest when the first of them is the block.

#### Recording with capture warning turns amber and keeps buttons
`MenuBarStatus.tone`: A recording with a capture warning turns amber and keeps its buttons.

#### Microphone is live only while dictation is being spoken
`MenuBarStatus.tone`: The microphone is live only while the dictation is being spoken.

#### Only Mac recordings count as just stopped; imported files do not
`MenuBarStatus.justStopped`: The recording made on this Mac that ended within `justStoppedWindow`.
An imported file was not just recorded, whenever its audio ends.

#### Recent list excludes merged sources and the live recording
`MenuBarStatus.recentMeetings`: The first meetings of the library, which lists the newest first, with
the one just saved in front. Sources folded into a merged meeting and
the recording in progress are not listed.

#### Nil while only microphone is recorded since no call is attached
`MenuBarAudioLine.callAudio`: Nil while only the microphone is recorded: no call is attached.

#### Level 0...1 only if measured within the last second
`MenuBarAudioLine.callAudioLevel`: 0…1, when the call's audio was measured within the last second.

### `LokalBot/Services/App/AppLog.swift`

#### One logging bootstrap fans out to stdout and debug.log; not main-actor isolated
`AppLog`: LokalBot's logging front door. Wraps swift-log so the whole app logs through
one bootstrap that fans every event out to both stdout (visible in Console
and when launched from a terminal) and the on-disk `debug.log` the app has
always written. The `lokalbotLog(_:)` shim is rerouted to ``line(_:)`` so
call sites can keep using one plain-line diagnostics function.

Deliberately NOT main-actor isolated: `lokalbotLog` is a free function
called from any thread/actor, swift-log's `Logger` is a thread-safe value
type, and the only shared mutable state (the bootstrap latch) is lock-guarded.

#### Latch required because LoggingSystem.bootstrap traps on second call
`AppLog.bootstrap`: Installs the swift-log backend exactly once per process. Safe to call
from anywhere, any number of times: the second and later calls are
no-ops. The latch is mandatory, not just an optimization —
`LoggingSystem.bootstrap` traps on a second invocation.

#### One shared sink so all categories write the same file
`AppLog.bootstrap`: One shared sink for the whole process, captured by the factory so
every category's handler writes to the same file/handle.

#### Labels namespaced under bundle id for one category vocabulary
`AppLog.category`: A logger for a named subsystem, e.g. `AppLog.category("download")`.
Labels are namespaced under the bundle id so file lines and Console
share one consistent category vocabulary.

#### Lines before bootstrap log to stdout only, not the file
`AppLog.line`: Logs `message` at `.info` on the default category. This is the single
entry point the rerouted `lokalbotLog(_:)` calls, preserving the
"one plain line of diagnostics" behavior on top of swift-log.

`bootstrap()` is expected to have run at launch before the first call;
a line emitted earlier still logs, just via swift-log's default stdout
backend rather than the file.

#### debug.log follows LOKALBOT_STORAGE_ROOT override for isolated runs
`AppLog.debugLogURL`: `<library root>/debug.log` — the same file the app has always appended
diagnostics to, so existing tooling keeps working. Follows the
`LOKALBOT_STORAGE_ROOT` override so isolated runs log into their own
library instead of the real one.

### `LokalBot/Services/App/AppUpdateManager.swift`

#### Sparkle does signed in-place updates; no hand-rolled compare or banner
`AppUpdateManager`: Owns LokalBot's Sparkle integration and keeps the updater lifecycle out of
SwiftUI. Sparkle is side-effectful (network, persisted prefs, system UI), so
the rest of the app sees a tiny surface: `start()` once at launch and
`checkForUpdates()` from the Settings button.

Replaces the previous detection-only `UpdateChecker` (GitHub Releases probe).
Sparkle does signed, resumable, in-place updates from a notarized DMG via the
appcast, so there is no hand-rolled version compare or download banner here.

#### Placeholder key keeps updater off in fresh clones
`AppUpdateManager.publicKeyPlaceholder`: The placeholder shipped in Info.plist (`SUPublicEDKey`). Until the real
ed25519 public key replaces it, `hasUsableConfiguration` is false and the
updater never starts — a fresh clone can't accidentally self-update.

#### Retain Sparkle controller for process lifetime
`AppUpdateManager.updaterController`: Retained for the process lifetime — Sparkle expects its controller alive.

#### Do not start updater in init to avoid network work
`AppUpdateManager.init`: `startingUpdater: false` — the app decides when to start the updater,
rather than Sparkle doing network work during object construction.

#### Defaults on via Info.plist; user change persists and overrides
`AppUpdateManager.automaticallyChecksForUpdates`: Sparkle's automatic-check preference, surfaced as a Settings toggle.
New installs default on (`SUEnableAutomaticChecks=true` in Info.plist);
changing this persists through Sparkle and overrides the bundled default.

#### Inert on dev builds and placeholder config
`AppUpdateManager.start`: Start Sparkle exactly once after launch. No-op on dev builds and when the
feed/key are still placeholders, so the app stays inert until configured.

#### Launch background check only when user opted in
`AppUpdateManager.start`: Background check on launch only when the user opted in. Sparkle's
scheduled interval covers long-running sessions; this covers users who
reopen within a day without creating opt-out network traffic.

#### Manual check always shows dialog; launch uses silent check
`AppUpdateManager.checkForUpdates`: Manual "Check for Updates…" — always presents a result dialog. Reserved
for the explicit Settings button; launch uses the silent background check.

#### Dev bundle id must never be replaced by prod appcast
`AppUpdateManager.isUpdaterEnabledForThisBuild`: Compiled to `false` in the dev configuration (LOKALBOT_DEV), which ships a
distinct bundle id the prod appcast must never replace.

#### Usable only when feed URL and key are not placeholders
`AppUpdateManager.hasUsableConfiguration`: True only when both the feed URL and public key are real (not the shipped
placeholders). Mirrors the old `UpdateChecker.releasesURL == nil` gate.

### `LokalBot/Services/App/BackgroundActivityMonitor.swift`

#### Only combines owner-published state so cleared runs disappear
`BackgroundActivityMonitor`: Publishes the ordered list of long-running work shown by the sidebar
progress card. It only combines state the owners already publish, so a
cancelled or failed run disappears as soon as its owner clears it.

#### Deliver on next main turn since @Published emits before change
`BackgroundActivityMonitor.init`: @Published emits before the owner's property changes; deliver
on the next main-queue turn so views never update mid-update.

### `LokalBot/Services/App/DataMigration.swift`

#### Migrate old identities' data, defaults, keychain; run first in main
`DataMigration`: One-shot migrations from previous LokalBot identities to the current app id.

Bundle-id renames re-key every identity-scoped store at once:
  • the Application Support data dir   (`~/Library/Application Support/<bundle id>/`)
  • the login Keychain                 (service == bundle id)
  • UserDefaults                       (the per-bundle-id preference domain)

Without migration a rename would look like total data loss: an empty library,
reset settings, and — worst — screenshots that can no longer be decrypted
because the AES key lived under the old service. This copies all three forward
on first launch after a rename.

MUST run at the very top of process `main()` — before `AppSettings.load()`,
`StorageManager()`, or any Keychain read — so the current stores observe
migrated values and `StorageManager` doesn't create an empty dir first.

The embedded `lokalbot-cli` is a separate binary and does NOT run this; it
reads whatever the app has already migrated. The normal flow launches the app
(which migrates) before the CLI is used.

#### Old identity constants frozen to avoid stranding data
`DataMigration old identities`: MARK: Old identities. Keep these frozen; changing them would strand data.

#### Must mirror databaseURL built in AppState
`DataMigration.currentDBName`: New DB filename — mirrors the `databaseURL` built in `AppState`.

#### screenshot-key loss makes existing screenshots unreadable
`DataMigration.keychainAccounts`: Generic-password accounts to carry over (service is the bundle id).
`screenshot-key` is the AES-GCM key that decrypts the screenshot filmstrip
— losing it makes existing shots unreadable, so it matters most.

#### Set only after all phases succeed; conflicts stay recoverable
`DataMigration.migratedFromV2Flag`: Set only after every migration phase succeeds. Retained conflicting
libraries and failed operations remain recoverable on later launches.

#### Injectable secret store keeps tests off real Keychain
`DataMigration.SecretStore`: Injectable secret storage keeps migration orchestration testable without
reading or mutating the login Keychain. Production always uses `live`.

#### Migration separated from launch gate so upgrade tests run it
`DataMigration.migrate`: The migration itself, without the launch gate (which skips every test
host). Upgrade tests run it on each release's library.

#### Legacy identities belong to release app; Dev never moves its library
`DataMigration.shouldRun`: Legacy identities belong to the release app. A fresh Dev launch must
never acquire or move the release library and its retention authority.

#### XCTest host runs main; never move real library in tests
`DataMigration.shouldRun`: A unit-test run launches the app as its XCTest host, which still
executes main() — never let `xcodebuild test` move the real user
library. XCTest sets XCTestConfigurationFilePath in that process.

#### Skip under UI-test or storage-isolation launches
`DataMigration.shouldRun`: Never migrate under a UI-test / storage-isolation launch either: those
point storage at a throwaway dir, so there's no real library to move.

#### Xcode build copy has own library; never move installed data
`DataMigration.shouldRun`: A copy run from Xcode build products has its own library and must
never move the installed app's data.

#### Phase completion separate from whether files moved; injectable for tests
`DataMigration.completeMigration`: Separate phase completion from whether any files happened to move.
Injection keeps failure tests away from the user's library and Keychain.

#### Prepare keys before exposing encrypted files; denied read keeps old library
`DataMigration.completeMigration`: Prepare identity-scoped keys before exposing migrated encrypted
files. A denied Keychain read must leave the old library in place.

#### Move not copy to avoid duplicating model cache; V2 secrets kept
`DataMigration.migrateDataDir`: Move the whole V2 library to the V3 location and version-rename the DB.
A move (atomic rename on the same volume) — not a copy — so the multi-GB
model cache isn't duplicated; the V2 keychain secrets are left intact as a
fallback. No-op if there's no V2 library or a V3 one already exists.

#### replacePlaceholderDatabase now imports only when no destination database exists
`DataMigration.migrateDataDirChecked`: `replacePlaceholderDatabase` is a legacy option name. It now permits
import only when no destination database exists; an empty live database
is still owned by its current connections and is never replaced.

#### Rename DB and WAL/SHM sidecars so current app opens existing index
`DataMigration.migrateDataDirChecked`: The DB filename embeds the version; rename the file and its WAL/SHM
sidecars so the current app opens the existing index instead of a fresh one.

#### Restore old names before moving library back on failure
`DataMigration.migrateDataDirChecked`: Restore the old names before putting the whole library back. If
recovery itself fails the files still remain in the new directory.

#### Preserve assets alongside conflicting legacy DB; no partial merge
`DataMigration merge`: Preserve its assets alongside a conflicting legacy database. A
partial merge would make that retained library hard to recover.

#### Install database last; source intact through merge
`DataMigration merge`: Install the database last. The source stays intact throughout a
merge, including when a concurrent writer creates the destination.

#### Use SQLite backup API for WAL content without touching source
`DataMigration.importDatabaseIfMissing`: SQLite's backup API includes committed WAL content and does not move
or checkpoint the old database. If installation fails, both the
source library and this recovery snapshot remain available.

#### Never replace current DB; RENAME_EXCL makes creation atomic
`DataMigration.installDatabaseSnapshot`: Do not replace even an apparently empty current database. An independent
SQLite connection can commit immediately after an emptiness check, and
replacing its inode separates that writer from the active library path.
RENAME_EXCL makes creation atomic: a concurrent creator wins unchanged.

#### Orphaned sidecars also require recovery rather than new main file
`DataMigration.databaseFilesExist`: Orphaned sidecars also require recovery rather than a new main file.

#### Copy raw settings blob and onboarding flag to avoid re-onboarding
`DataMigration.migrateSettings`: Copy the encoded settings blob (raw — the Codable shape is unchanged by the
rename) and the "onboarding shown" flag so a migrated user keeps their
preferences and isn't re-onboarded.

#### Cross-app read prompts once; V2 items survive as fallback
`DataMigration.migrateKeychain`: Re-home each generic-password secret under the new service. The cross-app
read of a V2-created item triggers a one-time macOS "allow access" dialog;
once copied, the V3 app owns its own item and reads it silently. Reads are
non-destructive — the V2 items survive as a fallback.

#### Plan path rebases and ciphertext rewrites together, validate first
`DataMigration.recoverLegacyScreenshotKeyIfNeeded`: A successful directory move/copy is not sufficient when the destination
identity already owns a different screenshot key. Plan path rebases and
ciphertext rewrites together, validating every input before changing
either the database or a file.

#### Destination keychain item is add-only; concurrent creator wins
`DataMigration.recoverLegacyScreenshotKeyIfNeeded`: The destination item is add-only. If a concurrent process
creates it first, its value wins and is re-read here.

#### Opening writer and rechecking rows are still preflight
`DataMigration.recoverLegacyScreenshotKeyIfNeeded`: Opening the writer and rechecking source rows are still preflight:
neither ciphertext nor a stored path has changed yet.

#### Versioned chat-key repair runs even when main marker is set
`DataMigration.recoverLegacyChatKeyIfNeeded`: Chat encryption shipped before the last identity rename, while the old
migration omitted `chat-key`. This separate, versioned repair therefore
runs even for installations whose main migration marker is already set.
A still-conflicting legacy library keeps this check live so chats copied
during a later recovery are validated on the next launch.

#### SecItemAdd no-replace; concurrent current key wins, files re-encrypted
`DataMigration.recoverLegacyChatKeyIfNeeded`: SecItemAdd is no-replace. If another process creates the key
concurrently, that current key wins and legacy files are
re-encrypted to it below.

#### Decrypt all before any write; damaged envelope leaves directory untouched
`DataMigration.migrateEncryptedChats`: Re-seal only files that still use a legacy key. All files are decrypted
before any write, so an unknown or damaged envelope leaves the directory
untouched and the retry marker unset. Each replacement is atomic.

#### Never replace existing encryption key after read error or race
`DataMigration.writeData`: A concurrently created current item wins; never replace an existing
encryption key after a transient read error or a create race.

### `LokalBot/Services/App/FileLogHandler.swift`

#### Shared reference sink prevents per-category descriptors and rotation races
`FileLogSink`: Backing store for ``FileLogHandler``: owns the on-disk file handle, the
running byte count, and the lock that serializes both writes and rotation.

Why a separate reference type:
swift-log copies a `LogHandler` value per `Logger`, and `AppLog` hands the
same file destination to every category's handler. If the handle lived in
the struct, each category would copy it and open its own descriptor to one
file — interleaving writes and racing rotation. Centralizing the mutable
state in one shared object, guarded by a lock, is the only correct shape.

`@unchecked Sendable`: the mutable members (`handle`, `byteOffset`) are only
ever touched while `lock` is held, and `FileHandle` is not `Sendable`, so
the conformance cannot be derived automatically.

#### 8 MB cap, five rotations, about 40 MB for a working day
`FileLogSink.init`: `sizeCapBytes` defaults to 8 MB and five rotations are kept (`.1` is
the newest), about 40 MB in total — enough for a full working day of
diagnostics, which a single 2 MB backup could not hold.

#### Calling locked body in init is safe since sink unshared
`FileLogSink.init`: Safe to touch the locked body directly: the sink is not yet shared.

#### Size check first so crossing line lands in fresh file
`FileLogSink.write`: Appends one already-formatted line (the caller supplies the trailing
newline). The size check runs first so the line that crosses the cap
lands in the fresh file, keeping the live log's tail readable; the
handle is read *after* rotation since rotation replaces it.

#### Failed diagnostic write is dropped, never disrupts app
`FileLogSink.write`: A failed diagnostic write must never disrupt the app. Drop it.

#### Recreate live file only if move displaced it, to keep history
`FileLogSink.rotateLocked`: Only recreate an empty live file when the move actually displaced the
old one. If the move fails and the original is still present, writing
a fresh empty file over it would destroy the very history rotation is
meant to preserve.

#### Callers hold lock or run in init before sharing
`FileLogSink.openHandleLocked`: Opens (and seeks to the end of) the live file, creating the containing
directory and the file if absent. Callers hold `lock`, or run during
`init` before the sink is shared.

#### Qualify Logging types because module mixes logging frameworks
`FileLogHandler`: A swift-log ``LogHandler`` that appends one formatted, human-readable line
per event to a shared ``FileLogSink``. This is LokalBot's on-disk diagnostic
sink — the file an operator (or an AI agent) can `tail` directly, and the
destination the legacy `lokalbotLog(_:)` shim is rerouted to.

Types are qualified as `Logging.*` because the module mixes logging
frameworks (`os.Logger` lives in other files); qualification keeps `Logger`
unambiguous regardless of a file's imports.

#### Shared formatter is thread-safe once configured; nonisolated(unsafe)
`FileLogHandler.timestampFormatter`: Shared formatter — `ISO8601DateFormatter` is thread-safe for formatting
once configured, so reusing one avoids an allocation per line. Marked
`nonisolated(unsafe)` because the type is not `Sendable`; concurrent use
is safe per Foundation's documented formatting guarantee.

### `LokalBot/Services/App/GitHubStarPromptStore.swift`

#### Local facts stored in app preferences, test suite when set
`GitHubStarPromptStore`: Keeps the GitHub star request's local facts in the app's preferences (the
test suite when one is set), like the other small preference stores, and
opens the repository in the default browser.

#### Suppressed for UI tests, unit tests, headless, demo libraries
`GitHubStarPromptStore.live`: The store for this process, suppressed for UI tests and captures, unit
tests, headless commands, and seeded demo libraries.

#### Opening repository from anywhere retires the request
`GitHubStarPromptStore.openRepository`: Opening the repository from any entry point also retires the request:
whatever the person did there, they have seen it.

#### Dismissing is permanent; request never returns
`GitHubStarPromptStore.dismiss`: "Not now". The request never returns.

#### Suppressed launches and answered request record nothing
`GitHubStarPromptStore.records`: Suppressed launches and an answered request record nothing new.

### `LokalBot/Services/App/LaunchAtLoginState.swift`

#### Cache SMAppService status off main thread; toggle binding blocked main
`LaunchAtLoginState`: Cached "Launch at login" registration for Settings.

`SMAppService.status` is a synchronous round trip to the service-management
daemon. `LaunchAtLogin.Toggle` bound it directly, and SwiftUI re-reads a
toggle's binding on every view-graph update while it is visible, so General
blocked the main thread thousands of times per minute. Reads and writes here
run off the main thread, one at a time, and only the latest result is
published.

### `LokalBot/Services/App/NavigationHandoff.swift`

#### Nil unrestricted; empty collection permits no screens
`AskNavigationHandoff.screenSnapshotIDs`: Nil is unrestricted; an empty collection deliberately permits no screens.

#### Nil keeps chosen sources; set when handoff narrows them
`AskNavigationHandoff.sources`: The sources to search, when the handoff narrows them (Quick Recall's
"Show all" for one kind). Nil leaves the chosen sources as they are.

#### Destinations consume whole payload at once to avoid misrouting
`NavigationHandoff`: Owns the short-lived payloads passed between navigation destinations.
Each destination consumes its complete payload at once, so SwiftUI view
mounting and coalesced state updates cannot split or misroute a handoff.

#### Each meeting navigation replaces prior seek request
`NavigationHandoff.stageMeeting`: Every meeting navigation replaces the previous seek request. Opening a
meeting without a timestamp therefore cannot inherit an older seek.

### `LokalBot/Services/App/PowerSourceMonitor.swift`

#### Battery sampled every 30 s; Low Power Mode notified immediately
`PowerSourceMonitor`: Publishes whether the Mac is on battery and whether Low Power Mode is enabled,
so power-aware features (e.g. deferring heavy local generation) can react.

On the main actor because `@Published` feeds SwiftUI. Battery state is sampled
on a ~30s timer — charger plug/unplug isn't latency-sensitive for our use, and
a slow poll keeps wakeups negligible. Low Power Mode toggles arrive immediately
via `NSProcessInfoPowerStateDidChange`, which also triggers a full refresh so
both flags stay coherent.

#### Seed flags so views bound before start show real state
`PowerSourceMonitor.init`: Seed the published flags at construction so a view bound before `start()`
shows the real state instead of the `false` defaults.

#### One-shot read for callers like dreaming downtime gate
`PowerSourceMonitor.currentlyOnBattery`: One-shot battery read for callers that need the current state without
owning a monitor (e.g. the dreaming downtime gate, checked per tick).

#### Unnamed providing source treated as AC; desktops report none
`PowerSourceMonitor.readIsOnBattery`: True when the providing power source is the internal battery. Defaults to
false (treat as AC) when IOKit can't name a providing source — desktop Macs
have no battery and report none, and "not on battery" is the safe read there.

### `LokalBot/Services/App/SettingsStore.swift`

#### Services capture store, not weak AppState, to avoid default-settings fallback
`SettingsStore`: The single, always-alive owner of the persisted `AppSettings` value.

Long-lived services (pipeline, dictation, cotyping, chat tools, screenshots)
capture this store instead of weak-referencing `AppState`: a weak capture
with a `?? AppSettings()` fallback would silently hand out factory-default
settings if `AppState` were ever released — an incorrect success. The store
makes "settings always exist" true in the type system.

`AppState.settings` remains the UI-facing binding surface; its `didSet`
writes through here, so the store is always current.

#### Store is sole entry point for globals read by model layer
`SettingsStore.init`: Transcript identity and the download source are read from many
model-layer call sites; the store is the one place they enter the process.

### `LokalBot/Services/App/SystemSettingsWindowLocator.swift`

#### Guidance follows privacy window across displays as it moves
`SystemSettingsWindowLocator`: Locates the privacy window so permission guidance can follow it across
displays and remain visually attached while it moves or resizes.

### `LokalBotTests/Models/App/AppIdentifiersTests.swift`

#### Unit-test settings enable semantic search, which downloaded the 310 MB embedder
`AppIdentifiersTests.testHostedUnitTestAppStateNeverDownloadsTheEmbeddingModel`: Unit tests' settings turn semantic search on, so searching screens
through `AppState` used to download the 310 MB embedding model.

#### Unit tests reaching the real embedder are refused and failed by LokalBotTestObservation
`AppIdentifiersTests.testHostedUnitTestEmbeddingModelDownloadIsRefused`: Any other unit test that reaches the real embedder is refused before
the download starts, and `LokalBotTestObservation` fails it.

### `LokalBotTests/Models/App/AppLanguageRootTests.swift`

#### Tests environment propagation in-process without windows or input
`AppLanguageRootTests`: In-process environment propagation: no window is shown and no input is
sent. Two independently created hosting views share the production root.

#### Retain hosts while SwiftUI processes publisher updates
`AppLanguageRootTests.testIndependentHostingRootsUpdateInPlaceAndOverrideInheritedLocale`: Retain the hosts while SwiftUI processes publisher updates.

### `LokalBotTests/Models/App/AppLanguageTests.swift`

#### Dutch, Croatian and Bosnian have no catalog and are not folded into Serbian
`AppLanguage.localizationIdentifier`: Dutch, Croatian, and Bosnian have no catalog; Croatian and Bosnian are
not folded into Serbian.

#### Direction comes from Foundation so new catalogs need no list edit
`AppLanguage.isRightToLeft`: Direction comes from Foundation, so future catalogs need no list edit.

#### UTF-16 string tables made Settings category switching take seconds
`AppLanguageTests.testBundledStringTablesAreBinary`: SwiftUI resolves every label through the injected app-language locale,
and Foundation re-reads the table on each such lookup. UTF-16 text
tables made switching Settings categories take seconds.

### `LokalBotTests/Models/App/GitHubStarPromptTests.swift`

#### XCTest hosts the app, so the test process counts as a test launch
`GitHubStarPromptStore.live`: The detection the app itself uses: XCTest hosts the app, so this very
process must count as a test launch.

#### Star request counts a summary only when the pipeline saved one
`ProcessingPipelineSummarySignalTests`: The request counts a meeting summary only when the pipeline saved one.

#### onArtifactsWritten also fires when notes fail, so it cannot signal a finished summary
`ProcessingPipeline.onArtifactsWritten`: `onArtifactsWritten` also fires when notes fail, so it cannot tell a
finished summary from a failed one.

#### Unapproved server makes the engine refuse before any request
`ProcessingPipelineSummarySignalTests.testFailedSummaryIsNotACompletedSummary`: Not approved, so the engine is refused before any request is made.

### `LokalBotTests/Models/App/MenuBarStatusTests.swift`

#### Fixed test clock 18:12 UTC, far from midnight
`MenuBarStatusTests.now`: 18:12 on a day far from midnight in UTC.

#### Status priority: recording, dictating, attention, meeting soon, paused, just stopped, idle
`MenuBarStatusTests.testEachStateOutranksTheOnesAfterIt`: Recording, dictating, needs attention, a meeting soon, paused, just
stopped, idle.

#### Stop is never hidden behind a warning; waiting items listed under recording
`MenuBarStatusTests.testARecordingKeepsTheBlockAndListsWhatWaitsUnderIt`: Stop is never hidden behind a warning: the recording keeps the block
and every waiting item is listed under it.

#### Dictation is red only while spoken and keeps waiting items listed
`MenuBarStatusTests.testADictationLeadsWhileItRuns`: A dictation is red only while it is being spoken, and keeps what
waits listed under it, as a recording does.

#### Refused mic and ungranted mic are one switch; Settings fix is offered
`MenuBarStatusTests.testARefusedMicrophoneStandsInForTheUngrantedOne`: Both are the microphone switch. Once a start was refused only System
Settings can turn it on, so that fix is the one offered.

#### Panel clock updates every few seconds, so slightly future saves still count as just stopped
`MenuBarStatusTests.testARecordingSavedAfterTheLastClockReadingStillCounts`: The panel's clock is read every few seconds, so a recording saved a
moment after the last reading still counts.

#### Just-saved meeting is listed first even if library order differs
`MenuBarStatusTests.testTheMeetingJustSavedIsListedFirstAsJustNow`: Even when the library has not put it first.

#### Menu uses Today's next-meeting rule with a shorter window
`MenuBarStatusTests.testTheMenuLeadsWithAMeetingOnlyOnceItIsClose`: Today's rule with the menu's shorter window.

#### Bitmap rows count down from top while image points count up
`MenuBarStatusTests.alpha`: Bitmap rows count down from the top; image points count up.

#### Sample point is the middle of the waveform's centre bar
`MenuBarStatusTests.testThePausedGlyphIsFaintAndTheAttentionDotIsNot`: The middle of the waveform's centre bar.

#### Head's top right corner runs under the dot; a clear ring separates them
`MenuBarStatusTests.testTheAttentionDotIsCutClearOfTheGlyph`: The head's top right corner runs under the dot; a clear ring keeps the
two apart.

#### Sample point sits on head's top edge between the dot and ring rim
`MenuBarStatusTests.testTheAttentionDotIsCutClearOfTheGlyph`: On the head's top edge, between the dot and the ring's outer rim.

### `LokalBotTests/Services/App/DataMigrationTests.swift`

#### Filesystem and settings halves tested with injected dirs; Keychain half verified on install
`DataMigrationTests`: Migration from old LokalBot identities. Exercises the data-loss-prone
filesystem/settings halves with injected dirs/suites (the Keychain half talks
to the real login keychain, so it's verified on install, not here).

#### Database and its WAL/SHM sidecars carry the old version in the filename
`DataMigration.migrateDataDir`: DB + its WAL/SHM sidecars carry the old version in the filename.

#### Unit-test host runs main(); XCTestConfigurationFilePath guard must stop migration touching real library
`DataMigration.runIfNeeded`: Running the app as a unit-test host executes main() and thus
runIfNeeded; the XCTestConfigurationFilePath guard must make it bail
before it marks itself done or touches the real user library.

### `LokalBotTests/Services/App/LaunchAtLoginStateTests.swift`

#### SwiftUI reads the toggle each update; reads must never reach the daemon
`LaunchAtLoginState.isEnabled`: SwiftUI reads the toggle's value on every update; none of those reads
may reach the service-management daemon.

### `LokalBotTests/Services/App/NavigationHandoffTests.swift`

#### Show all opens Ask on the search narrowed to one kind; other handoffs keep sources
`NavigationHandoff.stageAsk`: Quick Recall's "Show all" opens Ask on the search, narrowed to one
kind's source. Every other handoff leaves the chosen sources alone.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
