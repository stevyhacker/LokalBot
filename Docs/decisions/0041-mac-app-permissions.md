# 0041. Mac app: Permissions

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Permissions/`.

## Decisions

### `LokalBot/Services/Permissions/PermissionGuidanceController.swift`

#### Owns cross-app walkthrough; PermissionManager stays source of grant state
`PermissionGuidanceController`: Owns the cross-app permission walkthrough while `PermissionManager` remains
the single source of truth for grant state.

#### Native grant first; drag guidance only for panes accepting app bundles
`PermissionGuidanceController.requestAccess`: Requests the native grant first, then adds Cotabby-style drag guidance
only for privacy panes that accept an application bundle as a file URL.

#### Non-view callers never dismiss, so walkthrough ends itself
`PermissionGuidanceController.refreshPosition`: Callers that are not a view (a setting changed from the command
line) never dismiss, so the walkthrough has to end itself.

### `LokalBot/Services/Permissions/PermissionManager.swift`

#### System-audio rides audio-input entitlement, not TCC; enum stays off MainActor
`AppPermission`: The macOS privacy permissions LokalBot can use. System-audio capture rides
on the `com.apple.security.device.audio-input` entitlement, so it is not a
TCC prompt and is intentionally absent here.

Pure metadata plus stateless TCC reads: the enum stays off `@MainActor` so
its logic (titles, grant checks) is unit-testable on any thread, while the
observable cache lives on `PermissionManager`.

#### Input Monitoring is for cotyping keystrokes and accept key
`AppPermission.inputMonitoring`: Cotyping only — detects keystrokes and consumes the accept key.

#### Only microphone gates onboarding; others requested when feature enabled
`AppPermission.coreCases`: The only permission required to finish onboarding: the microphone, which
the core promise (record your side of a call) cannot work without.
Everything else is requested at the moment its feature is enabled —
Accessibility when day tracking or cotyping turns on (it also improves
browser-meeting detection), Screen Recording when screenshots turn on,
Input Monitoring when the dictation/cotyping shortcuts arm.

#### Accessibility reads only window titles; workday keeps app names only
`AppPermission.onboardingReason`: One-line reason beside the permission in setup. Accessibility reads
only window titles while the workday keeps app names only.

#### Grants made while running apply only at next launch
`AppPermission.needsRelaunchAfterGrant`: A grant made while LokalBot runs reaches these only at the next launch.

#### Microphone uses modal prompt; other panes get draggable-app walkthrough
`AppPermission.guidanceStyle`: Microphone access is granted through Apple's modal prompt. The other
privacy lists accept an application bundle, so LokalBot can provide the
same draggable-app walkthrough as Cotabby.

#### Screen Recording uses preflight so reading never prompts
`AppPermission.isGranted`: Real TCC state, queried without ever prompting the user.

Screen Recording uses the *preflight* probe rather than
`CGRequestScreenCaptureAccess` precisely so that reading status can never
surface the system dialog as a side effect.

#### macOS never re-prompts denied microphone; show recovery path
`AppPermission.requiresSettingsRecovery`: macOS will not show the microphone prompt again after an explicit
denial. Onboarding uses this to replace a misleading Allow button with
a direct, clearly labelled recovery path.

#### Prompt is a no-op once decided; pair with openSettings
`AppPermission.request`: Fires the native permission prompt. This is a no-op once the system has
already decided (a denied permission can only be changed in System
Settings), so callers pair it with `PermissionManager.openSettings(for:)`.

#### Microphone grant is async and surfaces via PermissionManager.granted
`AppPermission.request`: Empty completion on purpose: the grant arrives asynchronously and
is surfaced through `PermissionManager.granted`, not this callback.

#### Accessibility prompt:true shows Open System Settings dialog on first ask
`AppPermission.request`: `prompt: true` shows the "Open System Settings" dialog on first ask.

#### Optional because URL(string:) can fail; callers skip when nil
`AppPermission.settingsURL`: Deep link to this permission's System Settings pane. Optional because
`URL(string:)` is failable; callers skip opening when it is `nil`.

#### Single permission state; poll only while UI visible since TCC posts no notifications
`PermissionManager`: Single source of truth for LokalBot's permission state.

Folds the three ad-hoc TCC checks once scattered across views and services
into one observable cache so every surface reads the same value. A short poll
is the only way to notice a grant the user just made over in System Settings
(TCC posts no change notification), so the manager exposes explicit
`startPolling()`/`stopPolling()` driven by the permissions UI's lifecycle —
an established user pays zero idle main-thread wakeups once that UI is closed.

#### Cached grant state published so SwiftUI redraws on flips
`PermissionManager.granted`: Cached grant state, refreshed by `refresh()` and the poll. Published so
SwiftUI surfaces redraw the moment a permission flips.

#### Refused permissions macOS will not ask again; only Settings enables
`PermissionManager.turnedOff`: Permissions macOS will not ask for again because they were refused:
only System Settings can turn them on.

#### Launch snapshot shows permissions granted since that may need relaunch
`PermissionManager.grantedAtLaunch`: What was granted when this launch first read the permissions. A
permission granted since then may need a relaunch to take effect.

#### Republish only on change since @Published fires on identical assignment
`PermissionManager.refresh`: Re-reads every permission and republishes only on a real change. TCC
reads are cheap, but `@Published` fires on assignment even when the value
is identical, so the diff avoids redrawing surfaces on every poll tick.

#### Refresh after prompt for sync grants; microphone picked up by poll
`PermissionManager.request`: Triggers the native prompt for `permission`, then refreshes so any
synchronous grant (Accessibility, Screen Recording) is reflected at once.
The asynchronous microphone grant is picked up by the next poll tick.

#### Only onboarding-required microphone counts; optional grants never block
`PermissionManager.allGranted`: Whether every onboarding-required permission (just the microphone) is
currently granted. Optional grants never block this.

#### Consumer-counted 1.5 s poll reflects grants made in System Settings
`PermissionManager.startPolling`: Adds one permission-surface consumer and arms a ~1.5s catch-up poll so the
UI reflects grants made over in System Settings.

#### Timer survives until last permission surface disappears
`PermissionManager.stopPolling`: Releases one polling consumer. The timer survives while another permission
surface is still visible, then tears down once the last one disappears.

#### Accessibility grant needs relaunch; spawn via open -n then terminate
`PermissionManager.relaunch`: Re-launches LokalBot. Accessibility grants only take effect at process
launch, so granting it mid-session needs a restart to apply. Spawns a
fresh instance via `open -n`, then terminates this one a beat later.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
