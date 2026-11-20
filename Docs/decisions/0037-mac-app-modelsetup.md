# 0037. Mac app: ModelSetup

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/ModelSetup/`, `LokalBot/Services/ModelSetup/`, `LokalBot/Views/ModelSetup/`, `LokalBotTests/Models/ModelSetup/`.

## Decisions

### `LokalBot/Models/ModelSetup/GraniteSpeechModelConfiguration.swift`

#### Model and projector pinned to immutable Hugging Face metadata
`GraniteSpeechModelConfiguration`: One llama.cpp-compatible Granite Speech model plus its multimodal projector.
Both artifacts are pinned to immutable Hugging Face metadata so a mutable
repository cannot silently replace the files LokalBot runs.

#### IBM recommends Q8 for 5.0; 4.1 selection and Q4 cache unchanged
`GraniteSpeechModelConfiguration.speech5`: IBM recommends Q8 for 5.0 accuracy; keep the existing 4.1 selection
and its Q4 cache unchanged.

#### Maps configuration to picker choice so language errors name it
`GraniteSpeechModelConfiguration.transcriptionChoice`: The picker choice this configuration runs under, so language errors
name the selected Granite model.

#### Built-in revision shares legacy folder; others get revision-scoped directory
`GraniteSpeechModelConfiguration.cacheDirectoryName`: Official Granite quantizations at the pinned built-in revision share
the legacy folder and projector. Other repositories get a stable,
revision-scoped directory so identically named files cannot collide.

#### Only 40-char commit SHAs accepted; refs are mutable
`GraniteSpeechModelConfiguration.isValidRevision`: The model API returns a 40-character Git commit SHA. Branches and
tags are mutable, so accepting one here would make the persisted
checksums describe a different artifact if the ref later moved.

### `LokalBot/Models/ModelSetup/InferenceEndpointPolicy.swift`

#### Loopback is frictionless; other hosts need approval before data is sent
`InferenceEndpointPolicy`: Makes the local/remote boundary explicit for user-configured inference
servers. Loopback endpoints stay zero-friction; any other host must be
approved before transcripts, screen text, or agent context can be sent.

#### URLComponents rejects bare IPv6 host so authority rendered directly
`InferenceEndpointPolicy.origin`: URLComponents.host rejects a bare IPv6 literal even though URL.host
correctly returns one (for example, "::1"). Render the authority
directly so loopback and approved remote IPv6 origins stay canonical.

#### 0.0.0.0 deliberately not loopback; use localhost or 127.0.0.1
`InferenceEndpointPolicy.isLoopback`: "0.0.0.0" is deliberately NOT loopback: it's the unspecified
address, and treating it as local would silently trust a
nonstandard destination. Local servers should use localhost or
127.0.0.1 — which is also where a 0.0.0.0-bound server listens.

#### Private network means RFC1918, link-local, Tailscale, local names; loopback excluded
`InferenceEndpointPolicy.isPrivateNetwork`: A host on the user's own network rather than the internet: a private
(RFC 1918), link-local or Tailscale (100.64.0.0/10) IPv4 address, an
IPv6 unique-local or link-local address, or a name only such a network
resolves (`.local`, `.home.arpa`, a Tailscale `.ts.net` name, or a
single-label name such as a MagicDNS short name). Judged from the URL
alone; loopback is not included, it has its own rule.

#### IPv6 zone names the interface, so it is stripped
`InferenceEndpointPolicy.isPrivateNetwork`: An IPv6 zone ("fe80::1%en0") names the interface, not the host.

#### Plain http always for loopback; private network only on opt-in
`InferenceEndpointPolicy.permitsUnencrypted`: Whether a request may use plain `http://` to `url`: always for
loopback, and for a private-network host only when the caller opts in.

#### Suffixes public DNS never answers: mDNS, home.arpa, Tailscale
`InferenceEndpointPolicy.privateNetworkSuffixes`: Name suffixes that public DNS never answers: mDNS, the RFC 8375 home
network domain, and Tailscale MagicDNS.

#### 169.254 link-local counts as private, e.g. a USB network
`InferenceEndpointPolicy.isPrivateIPv4`: link-local, e.g. a USB network

#### 100.64.0.0/10 counts as private for Tailscale addresses
`InferenceEndpointPolicy.isPrivateIPv4`: 100.64.0.0/10, Tailscale addresses

#### fc00::/7 unique local counts private, including Tailscale
`InferenceEndpointPolicy.isPrivateIPv6`: fc00::/7 unique local, incl. Tailscale

### `LokalBot/Models/ModelSetup/InferencePresentation.swift`

#### Presentation independent of download or test; authorization stays in endpoint policy
`InferencePresentation`: Presentation of the configured destination, independent of whether a model
is downloaded or has passed a test. Authorization stays in endpoint policy.

#### Privacy summary lists every server incl. autocomplete, or it misstates local AI
`AppSettings.remoteAIHosts`: Every server that receives what this Mac's AI features send, each
named once: Think's, the transcription server and, while autocomplete
is on, the server it sends typing to. The sidebar's privacy summary
lists them: with autocomplete left out it read "AI: on this Mac" while
every suggestion request went to a server.

### `LokalBot/Models/ModelSetup/ModelDownloadSource.swift`

#### Mirror sources for China; pinned size and SHA-256 still verified
`ModelDownloadSource`: Where LokalBot fetches its pinned model files, chosen in Settings → Models.

huggingface.co is blocked in mainland China, so two opt-in sources serve the
same files there: HF-Mirror (hf-mirror.com), a community mirror with
Hugging Face's paths, and ModelScope (modelscope.cn), Alibaba's model hub.
Every file is still checked against the size and SHA-256 LokalBot pins, so a
source can make a download fail but cannot change a model. See
`ModelDownloadRouting`.

### `LokalBot/Models/ModelSetup/ModelReadinessSnapshot.swift`

#### Core readiness is Transcribe, Think, Autocomplete; optional roles never fail stack
`ModelReadinessSnapshot`: One honest, UI-ready view of the selected model stack. Core readiness is
limited to Transcribe, Think, and Autocomplete; optional Voice/Embeddings
never make the main stack fail.

#### Automation must check readiness to avoid unrequested multi-gigabyte downloads
`ModelReadinessSnapshot.transcriptionReady`: True when the selected meeting-transcription model is fully on disk.
Automation (auto-processing, prewarm) must consult this before running:
a missing model means a multi-gigabyte download the user never asked
for at that moment.

#### Think ready without download; external endpoints approved, Apple Intelligence available
`ModelReadinessSnapshot.thinkReady`: True when the Think role can run without triggering a model download.
External endpoints must be approved; Apple Intelligence must be available.

#### Server autocomplete needs no download; ready once set up
`ModelReadinessSnapshot.autocompleteReady`: A server needs nothing downloaded; it is ready once it is set up.

#### Re-check parked meetings immediately after relevant selection changes
`ModelReadinessSnapshot.processingReadinessChanged`: Settings that can change whether a parked meeting may transcribe or
summarize without downloading anything. AppState uses this to re-check
parked work immediately after a selection change.

#### Counts missing GGUF bytes only; Transcribe downloads through its own path
`ModelReadinessSnapshot.missingCoreModelBytes`: Total bytes of the core GGUF models (Think when built-in, Autocomplete)
still missing on disk. The Transcribe model downloads through its
engine-specific path and is not included — callers name it separately.

#### Server autocomplete route reads settings only, ignoring stale disk state
`ModelReadinessSnapshot.make`: A server route reads settings only, so a disk check from older settings can't stand in for it.

### `LokalBot/Models/ModelSetup/ModelRoles.swift`

#### Single role lifecycle shared by onboarding, settings and automation
`ModelRoles`: Owns selection readiness, model preparation, progress, failures, and the
wake-up signal for work parked behind missing models. Onboarding, Settings,
and automation all read the same role lifecycle through this interface.

#### Draft folder failures belong to that folder, not the working selection
`ModelRoles.transcriptionErrors`: A draft folder's failure belongs to that folder, not the working selection.

#### Progress ticks alone are not readiness changes
`ModelRoles.init`: A progress tick alone is not a readiness change.

#### Relay only readiness changes; progress ticks re-rendered every window
`ModelRoles.readinessChanges`: What is downloading, preparing, failed or ready, without progress.
AppState relays only these: relaying every progress tick (up to 5 Hz
per download) re-rendered every window for the whole of a
multi-gigabyte download. Views that draw progress observe this object.

#### Revision bumps on download start, end or failure, never progress
`ModelRoles.readinessChanges`: Bumped when a download starts, ends or fails, never by progress.

#### Selection sheets prepare against draft, keeping current model until ready
`ModelRoles.ensureTranscriptionAvailable`: Selection sheets prepare against their draft, keeping the current
model and its settings intact until the replacement is available.

#### Backends finishing writes after cancellation must not activate the model
`ModelRoles.ensureTranscriptionAvailable`: Some backends finish their file writes after cancellation. That
completion must not turn a cancelled download into an activation.

#### Apple Speech already verified locale; disk snapshot refreshes after activation
`ModelRoles.ensureTranscriptionAvailable`: Apple Speech preparation already verified the selected locale using
AssetInventory. The disk snapshot is refreshed after activation.

### `LokalBot/Models/ModelSetup/ModelSettingsState.swift`

#### Narrow patch so switch or undo never overwrites privacy, credentials or other edits
`ModelSelectionPatch`: A deliberately narrow patch: applying or undoing a model switch must never
overwrite privacy choices, credentials, or unrelated edits made during a download.

#### Undo restoring a cleared path must still validate the model
`ModelSelectionPatch.transcriptionToPrepare`: Clearing a path needs no runtime. Restoring it through Undo must still
validate the model, even when the patch changes no role assignment.

#### Refuse activation if imported files or remote destination changed during preparation
`ModelSelectionPatch.preparationContextMatches`: IDs alone do not identify imported files or a remote destination.
Refuse activation if either changed while the replacement was preparing.

#### Names derive from patch IDs so the list cannot drift
`ModelStackPreset.modelSummary`: Names come from the same IDs the patch applies, so the list cannot drift.

#### Loopback transcription server still counts as running on this Mac
`ModelSettingsPresentation.transcriptionServerDestination`: Where the selected transcription server is, for the Core Roles row.
A loopback server still runs on this Mac.

#### Missing model with refused source cannot be switched to
`ModelSettingsPresentation.downloadBlocker`: Why a model can't be switched to: it is missing and its saved source is
one the downloader refuses, so preparation could only fail.

#### Removing custom model must not orphan files or saved role choices
`ModelSettingsPresentation.customModelRemoval`: Nil for catalog models. Removing a custom model only edits the list,
so it must never orphan a downloaded file or leave a saved role
choice (even an inactive on-device Think choice) pointing at nothing.

#### Memory estimate is model size plus a third
`ModelSettingsPresentation.memoryNeed`: Roughly what a text model needs in memory to run: its size and a
third more, the estimate the picker has always shown under Advanced.

### `LokalBot/Models/ModelSetup/ModelsPagePresentation.swift`

#### Bytes nil when nothing downloads or size unknown
`ModelRoleRow.bytes`: What the model weighs on disk. Nil when nothing downloads for it or
the size is not known.

#### Speech models have only estimated catalog sizes
`ModelRoleRow.sizeIsEstimate`: Speech models have no exact size in the catalog, only an estimate.

#### Autocomplete model not needed while Autocomplete off, so no warning
`ModelRoleRow.needed`: False for Autocomplete's model while Autocomplete is off: nothing
waits for it, so its missing download is not a warning.

#### Not-set-up choice is treated as online; chip says the rest
`ModelRoleRow.placeText`: "On this Mac · 2.74 GB" or "Online · example.com". A choice that is
not set up yet is an online one; its chip says the rest.

#### Preset size uses download plan sizes; nil if any size unknown
`ModelsPagePresentation.bytes(of:settings:)`: The preset's three models together, from the same sizes the download
plan uses. Nil when one of them has no known size.

#### Server on this Mac's own address counts as this Mac
`ModelsPagePresentation.place`: Where a role's model runs. A server on this Mac's own address counts
as this Mac: nothing leaves it.

#### Auto-check once after in-launch download, local models only; remote checks from sheet
`ModelAutoCheckTracker`: Decides which downloaded models are checked without being asked. A check
loads the model and runs a short built-in sample through it, so it runs
once, when a download made in this launch finishes, and only for a model
that runs on this Mac. A model on a server or a subscription is checked
only from the sheet that says what the check sends there.

#### Nil when role runs elsewhere or is not in use
`ModelAutoCheckTracker.localModelID`: The model a role's check would exercise. Nil when it runs elsewhere,
or is not in use.

#### Check roles that were downloading same model and are now ready
`ModelAutoCheckTracker.observe`: Takes the latest role statuses and returns the roles to check now:
those that were downloading the same model and are ready.

#### Dedicated Compose model always runs on this Mac
`DictationWriterPresentation.init`: A dedicated Compose model is always one on this Mac.

### `LokalBot/Services/ModelSetup/AppleSpeechAvailability.swift`

#### Isolate macOS 26 SpeechAnalyzer symbols from macOS 15 deployment target
`AppleSpeechAvailability`: Availability decision for macOS's built-in `SpeechAnalyzer` transcription,
keeping macOS 26 SDK symbols isolated from the macOS 15.0 deployment target.

#### Synchronous readiness gate refreshed by ModelRoles on config change
`AppleSpeechAvailability.installedLanguages`: Automation uses a synchronous readiness gate. ModelRoles refreshes this
from macOS when the selected configuration changes or preparation ends.

### `LokalBot/Services/ModelSetup/FoundationModelAvailability.swift`

#### FoundationModels references gated by canImport and macOS 26 availability
`FoundationModelAvailability`: Binary "can Apple Intelligence run right now?" decision plus a user-facing
reason, so views and engines never touch FoundationModels symbols directly.

FoundationModels ships only in the macOS 26 SDK, but LokalBot deploys to
macOS 15.0 — every framework reference therefore lives behind
`#if canImport(FoundationModels)` and `if #available(macOS 26.0, *)`. On
anything older the framework is simply unavailable and `current()` reports
the supported-OS requirement.

#### Two-case enum carries Settings reason; Sendable crosses actors
`FoundationModelAvailability.State`: A two-case enum rather than a Bool because the unavailable reason is
shown verbatim in Settings — callers need the explanation, not just a
flag. `Sendable` lets the `@MainActor` `current()` result cross back to
the non-isolated engine that consumes it without a concurrency warning.

#### One constant so defensive fallback reuses exact wording
`FoundationModelAvailability.unsupportedMessage`: Reason returned when the build runs below macOS 26 or the framework is
absent. Kept as one constant so the engine's defensive fallback path
reuses the exact wording.

#### MainActor keeps system-model reads on one actor to avoid duplicate observation
`FoundationModelAvailability.current`: Resolves availability against the live system model on macOS 26+, and
reports `unsupportedMessage` everywhere else. `@MainActor` because the
system model is observed from the UI layer and we keep all reads on one
actor to avoid duplicating observation state.

### `LokalBot/Services/ModelSetup/ModelCheckController.swift`

#### Identity covers only the checked config; unrelated settings must not invalidate
`ModelCheckIdentity`: Identifies just the configuration exercised by a role's check. Unrelated
writing or appearance changes must not invalidate transcription results.

#### Running check re-compares identity before publishing
`ModelCheckController.invalidate(for:)`: A running check compares its own identity again before publishing.

#### Auto-check finished local downloads; never while recording or for servers
`ModelCheckController.readinessChanged`: Checks a model that has just finished downloading, without being
asked, when it runs on this Mac. Never while a meeting is recording,
and never for a model on a server: that check sends a sample there,
which only the Check sheet's own button does.

### `LokalBot/Services/ModelSetup/ModelSetupController.swift`

#### Prepare replacement models before atomic narrow settings update; outlives sheets
`ModelSetupController`: Prepares replacement models before publishing a narrow, atomic settings
update. The owner outlives sheets, so a switch can finish in the background.

#### Revalidate endpoint policy because approval may be revoked mid-download
`ModelSetupController`: Revalidate the live endpoint policy; an approval can be
revoked while the replacement's local downloads are running.

#### Non-retryable failures offer only Dismiss
`ModelSetupController`: Without a failed change there is nothing to retry, so the
banner offers only Dismiss for a source that always fails.

#### Cancelling switch only prevents activation; shared downloads continue
`ModelSetupController.cancelSwitch`: Shared downloads may also serve first-use requests. Cancelling the
switch prevents activation; Downloaded exposes explicit download cancellation.

#### Undo uses same preparation gate; old files may be gone
`ModelSetupController.undo`: Undo uses the same preparation gate: the old files may have been
removed since the switch, so never restore an unavailable assignment.

### `LokalBot/Views/ModelSetup/GraniteSpeechModelPicker.swift`

#### Only integrity-pinned audio-capable GGUF plus projector; generic ASR checkpoints excluded
`GraniteSpeechModelPicker`: Selects one integrity-pinned Granite Speech GGUF and its matching projector
from a public Hugging Face repository. Generic ASR checkpoints are excluded:
LokalBot's Granite path requires llama.cpp's audio-capable GGUF format.

### `LokalBot/Views/ModelSetup/ModelConnectionsView.swift`

#### Acknowledge key saved only after reading it back from Keychain
`ModelConnectionsView.apiKeyControl`: Only acknowledge persistence after reading back from Keychain.

### `LokalBot/Views/ModelSetup/ModelDownloadsView.swift`

#### Remote servers and built-in system speech have no files to manage
`ModelDownloadsView.transcriptionChoices`: A transcription server or built-in macOS speech engine has no files on disk to manage.

#### Row manages in-flight candidate while role readiness describes current model
`ModelDownloadsView.transcriptionRow`: Downloaded manages the in-flight candidate, while role readiness
continues to describe the current model. Keep candidate cancellation available.

### `LokalBot/Views/ModelSetup/ModelOverviewSections.swift`

#### Overview exposes approvals only; editing and disclosure stay in the existing editor
`ModelRemoteOverview`: The overview exposes saved approvals without choosing or approving a server.
Connection editing and its full data disclosure remain in the existing editor.

### `LokalBot/Views/ModelSetup/ModelPickerSheet.swift`

#### Previews and screenshots inject a signed-in sample account
`ModelPickerSheet.chatGPTAccount`: Previews and screenshots pass a signed-in sample account.

#### Plan approvals apply with Use model, so Cancel changes nothing
`ModelPickerSheet.chatGPTConsent`: Plan approvals apply with Use model, so Cancel changes nothing.

#### Typed key saved to Keychain with Use model; empty keeps saved key
`ModelPickerSheet.remoteTranscriptionKey`: Typed key, saved to Keychain with Use model. Empty keeps the saved one.

#### Audio approval for draft origin applies with Use model; Cancel changes nothing
`ModelPickerSheet.remoteTranscriptionConsent`: Audio approval for the draft server's origin; applied with Use model,
so Cancel changes nothing.

#### New key or approval applies even when server and model are unchanged
`ModelPickerSheet.changesRemoteTranscriptionAccess`: A new key or approval is worth applying even when the server and model
themselves are unchanged.

#### New key or approval applies even when server and model are unchanged
`ModelPickerSheet.changesAutocompleteAccess`: A new key or approval is worth applying even when the server and model
themselves are unchanged.

#### Empty plan model uses the CLI's own default
`ModelPickerSheet.canApply`: An empty model uses the CLI's own default.

#### Autocomplete picker has no Browse button; blocker text says where it is
`ModelPickerSheet.catalog`: Autocomplete's picker has no Browse button; say where it is.

#### Approval belongs to one origin; new server shows its saved choice
`ModelPickerSheet.remoteTranscriptionSetup`: An approval belongs to one origin. Show the saved choice for a
newly entered server rather than carrying the toggle over.

#### Think's key is reused only with no key of its own and same origin
`ModelPickerSheet.usesThinkKey`: No key of its own yet, and the same origin as Think's server.

#### Approval list replaced whole so unchecking revokes the origin
`ModelPickerSheet.applyRemoteTranscriptionAccess`: Saves the typed key and the audio approval for the chosen server. The
approval list is replaced as a whole so unchecking revokes the origin.

#### Only the list entry is removed; customModelRemoval checks prevent orphaning
`ModelPickerSheet.removeCustomModel`: Only the list entry goes: the role assignments and downloaded file
checks in `customModelRemoval` keep this from orphaning anything.

#### Server at this Mac's own address is listed with local models
`ModelPickerSheet.staysOnThisMac`: A server at this Mac's own address keeps what Think reads here, so
it is listed with the models on this Mac.

#### Server counts as another service only once in use; default address is placeholder
`ModelPickerSheet.staysOnThisMac`: "Another service" is one only once it is the one in use: its
address starts out as a placeholder on this Mac.

#### Explicit highlight keeps selection readable whether or not sheet window is key
`ModelPickerSheet.locationRow`: Plain rows with an explicit highlight: the selection reads the same in
a sheet whether or not its window is key.

### `LokalBot/Views/ModelSetup/ModelPreparationView.swift`

#### Cotyping, Dictation and Ask share vocabulary so first run never shows unexplained spinner
`ModelPreparationPresentation`: One presentation model for first-use downloads and local-runtime startup.
Cotyping, Dictation, and Ask use the same vocabulary and recovery shape so
a long first run never falls back to an unexplained spinner.

#### Ready or failed usually lands while user watches first download
`ModelPreparationView.stateIcon`: Ready or failed usually lands while the user watches a first download.

### `LokalBot/Views/ModelSetup/ModelStackOverviewView.swift`

#### Count files when something arrives or goes, not every progress tick
`ModelStackOverviewView.modelFilesOnDisk`: Text and speech models found on disk, counted when something
arrives or goes, not on every progress tick.

#### Search and deep links to Advanced settings open the group
`ModelStackOverviewView.advancedExpanded`: Search and deep links that land on a setting under Advanced open it.

#### Choosing a set opens review before applying; native pull-down for accessibility
`ModelStackOverviewView.modelSetRow`: Choosing a set opens its review, which lists the changes and
the download before anything is applied. A native pull-down:
SwiftUI's Menu gives assistive tools no way to open it.

#### Each server is set up where chosen: Think under Online services
`ModelStackOverviewView.reviewConnection`: Each server is set up where it is chosen: Think's on Online services,
the other two in their own pickers.

#### Count matches how the Downloaded page lists models
`ModelStackOverviewView.downloadedSummary`: How many models are on this Mac, counted the way Downloaded lists them.

#### Offer only levels the model accepts; stored unsupported level shows its mapping
`ModelStackOverviewView.reasoningRow`: Offers only the levels the selected model accepts (see
`ReasoningSupport`); a stored level it lacks shows as the one it maps to.

#### Processing budget applies to every Think model, so it lives here
`ModelStackOverviewView.budgetRow`: How much of a long meeting Think processes per pass. It applies to every
Think model, so it lives here rather than with one connection.

#### Checks auto-run after download for local models; online models checked only on request
`ModelStackOverviewView.checksRow`: The checks run by themselves after a download, for models on this
Mac. This is where to run them again, and the only place a model on
a server is checked.

### `LokalBot/Views/ModelSetup/ModelsView.swift`

#### Matches width of grouped settings forms on other tabs
`ModelsView.contentWidth`: Matches the width of the grouped settings forms on the other tabs.

### `LokalBot/Views/ModelSetup/SubscriptionPlanSetupView.swift`

#### Sign-in alone never lets context leave Mac; model and approval apply on Use model
`SubscriptionPlanSetupView`: Account, model, and consent for one subscription plan, shown in the Think
model sheet. Signing in, approval, and the model are separate steps: a
sign-in alone never lets context leave the Mac, and the sheet applies the
model and approval only when the user chooses Use model.

#### ChatGPT lists account models; Claude offers Code aliases following newest per family
`SubscriptionPlanModelPicker`: The model menu for a plan. A ChatGPT plan lists the signed-in account's
own models; a Claude plan offers Claude Code's aliases, which follow the
newest model of each family.

#### Retired saved model stays visible instead of silently changing
`SubscriptionPlanModelPicker.choices`: Known choices, plus a saved model the list no longer offers, so a
retired selection stays visible instead of silently changing.

### `LokalBotTests/Models/ModelSetup/InferenceEndpointPolicyTests.swift`

#### 172.20.10.x is a USB or hotspot network treated as private
`InferenceEndpointPolicyTests.testPrivateNetworkHostsAreRecognizedFromTheURLAlone`: a USB or hotspot network

#### Loopback has its own rule, not private-network
`InferenceEndpointPolicyTests.testPrivateNetworkHostsAreRecognizedFromTheURLAlone`: loopback has its own rule

### `LokalBotTests/Models/ModelSetup/ModelRoleNamingTests.swift`

#### CONTEXT.md role names Transcribe, Think, Autocomplete must be used on every surface
`ModelRoleNamingTests`: CONTEXT.md names the model roles Transcribe, Think, and Autocomplete. Every
surface that labels a role must use those names.

#### Stated sizes round to actual download bytes in decimal GB, matching README
`ModelStorageCopyTests.testTranscriptionSizesMatchPinnedDownloads`: Each stated size must round to the bytes the engine actually downloads,
at the label's own precision (decimal GB, matching the README).

### `LokalBotTests/Models/ModelSetup/ModelRolesTests.swift`

#### Settings Models Cancel stops downloads like each model's own Cancel
`ModelRolesTests.testCancellingTheCoreDownloadsStopsTheSelectedTranscriptionPreparation`: Settings › Models' Cancel stops the selected models' downloads the
way each one's own Cancel on Downloaded does.

#### Simulates a backend that finishes despite cancellation
`ModelRolesTests`: Simulate a backend that finishes despite cancellation.

### `LokalBotTests/Models/ModelSetup/ModelSettingsTests.swift`

#### A model already on disk needs no download, so source refusal is moot
`ModelSettingsTests.testOnlyMissingModelsWithRefusedSourcesAreBlocked`: A file already on disk needs no download, so its source is moot.

#### Saved on-device Think choice counts even while Think runs remotely
`ModelSettingsTests.testCustomModelRemovalNeverOrphansAssignmentsOrFiles`: A saved on-device Think choice counts even while Think runs remotely.

### `LokalBotTests/Models/ModelSetup/ModelsPagePresentationTests.swift`

#### Speech models have no exact size, so rows say about
`ModelsPagePresentationTests.testEachRoleSaysItsJobItsModelWhereItRunsAndItsSize`: A speech model has no exact size, so its row says "about".

#### Row sizes equal the sizes the download is announced with
`ModelsPagePresentationTests.testRowSizesMatchTheDownloadPlan`: The sizes are the ones the download is announced with.

#### A server at this Mac's own address sends nothing anywhere
`ModelsPagePresentationTests.testAServerOnThisMacIsNotOnline`: A server at this Mac's own address sends nothing anywhere.

#### Missing Autocomplete model is not a warning while Autocomplete is off
`ModelsPagePresentationTests.testAMissingModelWarnsOnlyWhenItIsNeeded`: Nothing waits for Autocomplete's model while Autocomplete is off, so
its missing download is not drawn as a warning.

#### A check result for a model no longer present says nothing
`ModelsPagePresentationTests.testACheckShowsOnAReadyModelOnly`: A check result for a model that is no longer here says nothing.

#### A set's size is the sum of its three rows' sizes
`ModelsPagePresentationTests.testAModelSetWeighsWhatItsThreeModelsWeigh`: A set's size is the sum of the three sizes its rows would show.

#### Models page is restored from scene storage by raw value
`ModelsPagePresentationTests.testThePagesMoreRowsOpenKeepTheirSavedNames`: The page is restored from scene storage by raw value.

#### Between last byte and file found the role reads as missing
`ModelsPagePresentationTests.testADownloadThatFinishesInThisLaunchIsCheckedOnce`: Between the last byte and the file being found, the role reads as missing.

#### Checking an online model sends it a sample; only the explicit sheet may
`ModelsPagePresentationTests.testAModelThatRunsOnlineIsNeverCheckedByItself`: A check of an online model sends it a sample, which only the sheet
that says so may do.

#### Switching Think to an already-present model drops the pending check
`ModelsPagePresentationTests.testChoosingAnotherModelWhileOneDownloadsDropsTheCheck`: Another model, already here, becomes the Think model.

#### A model chosen for Compose alone always runs on this Mac
`ModelsPagePresentationTests.testWhoWritesDictatedTextFollowsTheModeAndWhereTheModelRuns`: A model chosen for Compose alone always runs on this Mac.

#### Settings on the page itself open no other page
`ModelsPagePresentationTests.testSearchLandsOnTheRowsPageThatHoldsASetting`: Settings on the page itself open no other page.

#### Rows renamed plainly; settings still found by old names and same identifiers
`ModelsPagePresentationTests.testRenamedSettingsAreFoundByTheirOldAndNewNames`: The rows have plainer names; their settings are still found by the
old ones, and by the same identifiers.

#### Results read like the page row; setting name stays the one the CLI lists
`ModelsPagePresentationTests.testSearchShowsTheRowsWordsAndKeepsTheSettingsName`: A result reads like its row on the page, while the setting's own
name stays the one the CLI lists.

#### Exact match on a row's words ranks first
`ModelsPagePresentationTests.testSearchShowsTheRowsWordsAndKeepsTheSettingsName`: An exact match on the row's words ranks first.

#### Every composed sentence must have an entry in the localization catalog
`ModelsPagePresentationTests.testPresentationTextIsInTheCatalog`: Every sentence these types put together has an entry in the catalog.

#### The joiner key only joins a place and a size or host
`ModelsPagePresentationTests.testPresentationTextIsInTheCatalog`: "%@ · %@" only joins a place and a size or host.

#### Approved transcription server sentence is collected explicitly for the online-at case
`ModelsPagePresentationTests.testPresentationTextIsInTheCatalog`: An approved transcription server, for the "online at" sentence.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
