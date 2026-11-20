# 0039. Mac app: Onboarding

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Onboarding/`, `LokalBot/Views/Onboarding/`, `LokalBotTests/Models/Onboarding/`.

## Decisions

### `LokalBot/Models/Onboarding/OnboardingDownloadPlan.swift`

#### needsSetup: nothing downloads (server or Apple Intelligence) and not usable yet
`OnboardingDownloadPlan.ModelState.needsSetup`: Nothing downloads for this role (a server or Apple Intelligence),
and it is not usable yet.

#### Bytes nil when nothing downloads or size unknown in advance
`OnboardingDownloadPlan.Model.bytes`: What the download weighs. Nil when nothing downloads here or the
size is not known in advance.

#### Arrived nil while progress unreported or size unknown; stopped counts zero
`OnboardingDownloadPlan.Model.arrivedBytes`: How much of this model is here. Nil while a running download has
not said, or when the size is unknown; a stopped one counts as none.

#### Stopped means a download failed; others may still run
`OnboardingDownloadPlan.Phase.stopped`: At least one download failed; others may still be running.

#### Autocomplete listed while choosable and once part of download
`OnboardingDownloadPlan.models`: The rows, in order. Autocomplete is listed while it can still be
chosen and once it is part of the download.

#### True while a download runs, also beside a stopped one
`OnboardingDownloadPlan.isDownloading`: A download is running now, also beside one that stopped.

#### Total counts models absent at download start; nil if size unknown
`OnboardingDownloadPlan.totalBytes`: Bytes of the selected models that were not on this Mac when the
download began. Nil when one of them has no known size.

#### Downloaded bytes nil while running download reports no progress
`OnboardingDownloadPlan.downloadedBytes`: Of `totalBytes`, how much has arrived. Nil when a running download
has not reported its progress.

#### Autocomplete option withdrawn once download is under way
`OnboardingDownloadPlan.init`: Once the download is under way the option is no longer offered.

#### Between button and first status, started means running
`OnboardingDownloadPlan.init`: Between the button and the first status the download has no state yet.

#### Remaining is what Download fetches; nil if any size unknown
`OnboardingDownloadPlan.remainingBytes`: What Download will fetch: the selected models that are not here yet.
Nil when one of them has no known size.

#### Fraction 0 to 1 across whole download when sizes and progress known
`OnboardingDownloadPlan.fraction`: 0…1 across the whole download, when sizes and progress are known.

#### Fit check includes headroom; true when a number is unknown
`OnboardingDownloadPlan.fitsOnDisk`: Whether the download and the headroom it needs fit in the free space.
True when either number is unknown.

#### Fun-ASR-Nano reads existing folder; system models live in macOS
`OnboardingDownloadPlan.model`: Fun-ASR-Nano reads a folder the person already has, and system models live in macOS.

#### Estimate from last 30 s speed; silent until 5 s observed or stalled
`DownloadTimeEstimator`: Time left for a download, from how fast the bytes have been arriving over
the last half minute. It says nothing until it has watched for a few
seconds, and nothing while no bytes arrive.

#### Retried download restarts, so earlier speed samples are discarded
`DownloadTimeEstimator.record`: A retried download starts over, so earlier speeds no longer apply.

### `LokalBot/Models/Onboarding/OnboardingFlow.swift`

#### Choices stay draft until finish; permissions and downloads only via named actions
`OnboardingStep`: Setup's three steps, in order. Choices stay a draft until setup finishes;
permissions and downloads happen only through their named actions.

#### Granted since launch; takes effect after restart
`OnboardingPermissionState.allowedAfterRestart`: Granted since this launch; it takes effect after a restart.

#### Refused earlier; macOS will not ask again, only System Settings
`OnboardingPermissionState.turnedOff`: Refused earlier, so macOS will not ask again: only System Settings can
turn it on.

#### Permission step shows only what choices need, with real PermissionManager state
`OnboardingAccess`: Setup's permission step: only what the choices need, each with its real
state from `PermissionManager`.

#### Microphone always; Accessibility for workday; Screen Recording only for screenshots
`OnboardingAccess.permissions`: The microphone always (Record uses it even with detection off),
Accessibility for the workday, Screen Recording only for screenshots.

#### Show Settings picture while a Settings-granted permission is pending
`OnboardingAccess.showsSettingsGuide`: The System Settings picture is worth showing while a permission that
is granted there is still to come.

#### Resume state reopens setup after permission-required restart
`OnboardingResumeState`: What setup needs to reopen where it was after the restart a permission
grant requires: the step and the choices not applied yet.

#### Baseline detects settings changes that invalidate saved draft
`OnboardingResumeState.baseline`: The choices the settings held when the draft was started. When the
settings have changed since, the saved draft no longer describes them.

#### Finished setup reopens only after restart requested from setup
`OnboardingResumeState.reopensAfterRestart`: Set by Restart now. A setup that was already finished once reopens
after a restart only when the person asked for that restart here.

#### Resume state kept in app preferences, test suite when set
`OnboardingResumeStore`: Keeps `OnboardingResumeState` in the app's preferences (the test suite
when one is set), next to the settings it belongs to.

#### Pre-setup install with core permissions granted counts as finished
`OnboardingLaunch.markFinished`: Every core permission is granted and nothing waits: the install
predates setup, so it counts as finished.

#### Restart-interrupted setup continues despite microphone grant
`OnboardingLaunch.decision`: A setup interrupted by a restart continues, even though the
microphone grant that came with it would count as established.

### `LokalBot/Views/Onboarding/GettingStartedCard.swift`

#### First-day steps become Today content when empty; dismissal persisted in AppStorage
`GettingStartedCard`: The first-day steps. On a day with nothing to show yet they are Today's
content; after that they stay under the day until hidden. Hiding is
remembered via `@AppStorage`.

#### Front-load transcription model download so it doesn't ambush first recap
`GettingStartedCard.modelDownloaded`: Transcription-model step: front-load the download so it doesn't
ambush the user's first recap.

#### prepare is idempotent, so racing a first transcription is harmless
`GettingStartedCard.modelLabel`: Get the transcription model onto disk before the first recap needs it.
`prepare` is idempotent, so racing a first transcription is harmless.

### `LokalBot/Views/Onboarding/OnboardingAccessStep.swift`

#### Whether workday keeps text changes what Accessibility reads
`OnboardingAccessStep.readsScreenText`: Whether the workday keeps text, which changes what Accessibility reads.

#### Passes permission and button frame where System Settings helper flies out from
`OnboardingAccessStep.allow`: The permission to ask for, and the button's frame on screen, where the
System Settings helper flies out from.

#### Grants arrive from polling while user is in System Settings
`OnboardingAccessStep.body`: Grants arrive from polling while the user is in System Settings.

### `LokalBot/Views/Onboarding/OnboardingChooseStep.swift`

#### Data-retention note shown for every workday choice; it is what user agrees to
`OnboardingChooseStep.body`: Shown for every workday choice, app names only included:
it is what the person agrees to before picking more.

#### Server configured before setup reopened is named instead of claiming everything local
`OnboardingChooseStep.welcome`: A server set up before setup was reopened is named for what it is.

#### Plain pop-up used; rows with second line drew over arrows in RTL languages
`OnboardingChooseStep.option`: The one option a choice has, on its own line under the description.
What the chosen option means is the pop-up's help, and for the workday,
where it says what is kept, a line of its own. The menu is a plain
pop-up like the app's others: rows with a second line drew over the
pop-up's arrows in right-to-left languages.

### `LokalBot/Views/Onboarding/OnboardingDownloadStep.swift`

#### Download progress reaches only views observing ModelRoles; AppState does not relay it
`OnboardingDownloadStep`: Setup, step 3. Download progress reaches only the views that observe
`ModelRoles`: AppState does not relay it.

#### Time estimate only after speed has been watched for a while
`OnboardingDownloadStep.body`: An estimate only once the speed has been watched for a while.

#### Download begun outside window counts what is missing from first sight
`OnboardingDownloadStep.settle`: A download that began outside this window (before a restart, or from
Settings) counts what is missing from the moment it is first seen.

#### Offer HF-Mirror and ModelScope where huggingface.co is blocked in mainland China
`OnboardingDownloadStep.showsDownloadSource`: huggingface.co is blocked in mainland China, so the first download
offers HF-Mirror and ModelScope there: on a Mac set to that region or to
Simplified Chinese, or once a mirror is already chosen. Settings → Models
always has the same picker.

#### Nil until speed supports an honest estimate
`OnboardingDownloadContent.minutesLeft`: Nil until the speed makes an honest estimate.

#### Server destination is disclosed; this Mac needs no note
`OnboardingDownloadContent.destination`: Where Think runs. A server is disclosed; this Mac needs no note.

#### Sizes carry units so the pair reads the same in every language
`OnboardingDownloadContent.heroAmount`: Sizes carry their unit, so the pair reads the same in every language.

#### True opens the sample meeting when its models are ready
`OnboardingDownloadFooter.finish`: Ends setup; true opens the sample meeting when its models are ready.

### `LokalBot/Views/Onboarding/OnboardingView.swift`

#### Record roles present before download so progress counts only new fetches
`OnboardingDownloadSession.readyBefore`: The roles that were on this Mac when the download began, so the
progress counts only what this download fetches.

#### Setup choices stay a draft; permissions and downloads only via named actions
`OnboardingView`: First-run setup in three steps. Choices stay a draft until setup finishes;
permissions and model downloads happen only through their named actions.

#### Incoming step page arrives from the side the user moves toward
`OnboardingView.forward`: Direction of the last step change, so the incoming page arrives from
the side the user is moving toward.

#### Save resume state only while setup is under way
`OnboardingView.saves`: False until the window has loaded its state, and again once setup
has finished, so nothing is saved for a setup that is not under way.

#### Save on permission grant because a restart may follow
`OnboardingView.body`: A grant is the moment before a restart, asked for here or by macOS.

#### Open sample meeting only when the person saw that option
`OnboardingView.finish`: Applies the choices and ends setup. The sample meeting opens only
when the person saw that option, which is once a download exists.

#### On every open, resume saved setup for these settings or start fresh
`OnboardingView.begin`: Every time the window opens: continue the setup that was under way
for these settings, or start from the settings as they are now.

#### Re-save after the restart the saved state was for has happened
`OnboardingView.begin`: The restart it was saved for has happened.

#### In a window, stepper shares the title bar with traffic lights
`OnboardingFrame.body`: In a window, the steps share the title bar with the traffic
lights and line up with them; elsewhere they get a bar of their own.

#### ZStack lets outgoing and incoming pages overlap during the transition
`OnboardingFrame.body`: The ZStack lets the outgoing and incoming pages overlap
while they cross instead of stacking vertically.

#### Title bar counts toward window height, so content height subtracts it
`OnboardingFrame.body`: The title bar is part of the window's height, so the content gives it up.

#### Read title bar height from AppKit; SwiftUI reported zero on macOS 26
`WindowTitleBarReader`: Reads how far the window's title bar pushes its content down. AppKit
knows this on every system; the geometry SwiftUI reported for it was
zero on macOS 26, which left the stepper in a bar of its own below the
traffic lights and the window a title bar too tall.

#### Clamp reported title bar height to 0...60 so a stray value cannot push the stepper out
`WindowTitleBarReader.ProbeView.report`: A stray value must not push the stepper out of the window.

#### Callers place a Divider between rows
`OnboardingCard`: Rows in one grouped card. Callers place a `Divider()` between rows.

### `LokalBot/Views/Onboarding/PermissionDragGuidance.swift`

#### Installed app identity is the drag payload macOS expects
`PermissionHostApp`: The installed app identity macOS expects as the drag payload.

#### Native file-URL drag source is what System Settings privacy lists accept
`PermissionDragSourceView`: Native file-URL drag source accepted by System Settings privacy lists.

#### NSURL pasteboard writer supplies all file-URL representations System Settings expects
`PermissionDragSourceView.mouseDown`: NSURL supplies every native file-URL pasteboard representation that
System Settings expects for a real application bundle.

### `LokalBot/Views/Onboarding/PermissionRow.swift`

#### Callers must run PermissionManager polling while the row is visible
`PermissionRow`: One permission line in a grouped Form: state icon, title, rationale, and a
Grant button when missing. Shared by Settings, Dictation, and Cotyping so
permission state reads the same everywhere. Callers are responsible for
`PermissionManager.shared.startPolling()` while the row is visible.

#### Grants arrive from polling while user is in System Settings
`PermissionRow.body`: Grants arrive from polling while the user is in System Settings.

### `LokalBotTests/Models/Onboarding/OnboardingFlowTests.swift`

#### A second store on the same preferences models the next launch
`OnboardingFlowTests.testResumeStateSurvivesARestart`: A second store on the same preferences is what the next launch sees.

#### New install opens setup unless every core permission is granted
`OnboardingFlowTests.testLaunchReopensAnInterruptedSetup`: A new install: setup opens unless every core permission is granted.

#### Setup resumes after relaunch for Accessibility even with permissions granted
`OnboardingFlowTests.testLaunchReopensAnInterruptedSetup`: The microphone was granted in setup and LokalBot restarted for Accessibility.

#### Setup reopened from menu bar returns only via its own Restart
`OnboardingFlowTests.testLaunchReopensAnInterruptedSetup`: Setup reopened later from the menu bar: only its own Restart now brings it back.

#### A readiness change that is not the models arriving keeps it waiting
`OnboardingFlowTests.testSampleMeetingChosenInSetupWaitsForItsModels`: A readiness change that is not the models arriving keeps it waiting.

#### After the window only the new, slower speed counts
`OnboardingFlowTests.testTimeLeftForgetsOldSpeedsAndStalledDownloads`: The connection slows to 1 MB/s; after the window only the new speed counts.

#### No bytes for half a minute gives no estimate
`OnboardingFlowTests.testTimeLeftForgetsOldSpeedsAndStalledDownloads`: No bytes for half a minute: no estimate.

#### A retried model restarts, dropping total so earlier speeds no longer apply
`OnboardingFlowTests.testTimeLeftForgetsOldSpeedsAndStalledDownloads`: A retried model starts over, so the total drops and earlier speeds no longer apply.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
