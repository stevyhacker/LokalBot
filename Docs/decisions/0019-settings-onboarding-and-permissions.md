# 0019. Settings, onboarding and permissions

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers how the Mac app and the Windows and Linux app store and load settings, run first-time setup, ask for operating-system permissions, record which servers may receive data, and show the user what leaves the computer. It also covers the app lock in the Android and iOS phone apps. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Stored settings

### An unreadable stored value resets only its own field

Settings load field by field, so one bad value never resets all of them. Every stored key is tried, including ones the defaults leave out when unset (`agentReasoningLevel`), because an unreadable value there would otherwise fail the final decode and reset every setting. Keys the Windows and Linux app doesn't model always decode, into `other`. On the Mac a key whose value has the wrong shape resets that field to its default.

Where: `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings::load_field_by_field`), `LokalBotTests/Models/Settings/AppSettingsTests.swift` (`AppSettingsTests.testCorruptFieldFallsBackToDefaultAndIsReported`).

### A setting that fell back to its default is announced by name

Settings corruption is a privacy event, not a cosmetic one: a field like screenshot capture silently resetting to its default changes what the app records. `AppSettings.corruptedSettingsKeys` names each setting whose stored value was present but unreadable; it is transient, never encoded, and empty in the normal case, including when an older build's blob only lacks newer keys. When it is non-empty, `AppState` shows a one-time notice that says exactly what fell back.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.corruptedSettingsKeys`), `LokalBot/AppState.swift` (`AppState.init`), `LokalBotTests/Models/Settings/AppSettingsTests.swift` (`AppSettingsTests.testCorruptFieldFallsBackToDefaultAndIsReported`).

### A model switch is applied as a narrow patch

Applying or undoing a model switch must never overwrite privacy choices, credentials, or unrelated edits made during a download, so it goes through a deliberately narrow patch instead of writing the whole settings value.

Where: `LokalBot/Models/ModelSetup/ModelSettingsState.swift` (`ModelSelectionPatch`).

## Launch at login

### Settings binds launch at login to a cached registration read off the main thread

`SMAppService.status` is a synchronous round trip to the service-management daemon. `LaunchAtLogin.Toggle` bound it directly, and SwiftUI re-reads a toggle's binding on every view-graph update while it is visible, so General blocked the main thread thousands of times per minute. `LaunchAtLoginState` now reads and writes off the main thread, one at a time, and publishes only the latest result; the toggle binds that cache, never `SMAppService` itself.

Where: `LokalBot/Services/App/LaunchAtLoginState.swift` (`LaunchAtLoginState`), `LokalBot/Views/Settings/SettingsView.swift` (`LaunchAtLoginToggleRow`).

### Windows reports launch at login as off when the user disabled the startup entry

An `Explorer\StartupApproved\Run` entry starts with an even byte while the item is enabled and an odd one after the user disabled it in Task Manager or Settings, and the reported launch-at-login state honors that mark.

Where: `LinuxWindows/crates/lokalbot-platform/src/autostart.rs` (`windows_startup_approved`).

## Permissions

### Only the microphone is required to finish onboarding

The core promise, recording your side of a call, cannot work without the microphone, so it is the only permission onboarding requires. Every other permission is requested when its feature is turned on: Accessibility when day tracking or cotyping turns on (it also improves browser-meeting detection), Screen Recording when screenshots turn on, and Input Monitoring when the dictation and cotyping shortcuts arm.

Where: `LokalBot/Services/Permissions/PermissionManager.swift` (`AppPermission.coreCases`).

### System-audio capture is not listed as a permission

System-audio capture rides on the `com.apple.security.device.audio-input` entitlement, not a TCC prompt, so it is intentionally absent from the macOS privacy permissions LokalBot lists.

Where: `LokalBot/Services/Permissions/PermissionManager.swift` (`AppPermission`).

### Permission metadata and TCC reads stay off the main actor

`AppPermission` holds only metadata and stateless TCC reads, so it stays off `@MainActor` and its titles and grant checks are unit-testable on any thread. The observable cache lives on `PermissionManager`.

Where: `LokalBot/Services/Permissions/PermissionManager.swift` (`AppPermission`, `PermissionManager`).

### Reading permission status never shows a system prompt

Grant checks query the real TCC state without prompting. Screen Recording uses the preflight probe rather than `CGRequestScreenCaptureAccess`, so reading its status can never surface the system dialog as a side effect.

Where: `LokalBot/Services/Permissions/PermissionManager.swift` (`AppPermission.isGranted`).

### Launch-time readiness checks never list the legacy `~/Documents` model cache

Readiness checks run at launch, and listing the legacy `~/Documents` Whisper cache there made macOS ask for Documents access. They look only at the Application Support cache; preparing Whisper migrates the legacy cache instead.

Where: `LokalBot/Engines/TranscriptionModelStore.swift` (`TranscriptionModelStore.whisperModelDirectories`).

### Granting Accessibility mid-session relaunches the app

Accessibility grants only take effect at process launch, so a grant made mid-session needs a restart. The app spawns a fresh instance with `open -n`, then terminates the current one a beat later.

Where: `LokalBot/Services/Permissions/PermissionManager.swift` (`PermissionManager.relaunch`).

### A microphone that is found counts as allowed only on Linux

Windows lists microphones that its privacy switch keeps apps away from, so finding a microphone there does not mean LokalBot may use it.

Where: `LinuxWindows/crates/lokalbot-app/src/access.rs` (`a_found_microphone_counts_as_allowed_only_on_linux`).

## Coding-agent sessions

### Coding-agent sessions are read only after the user chose it

The user chooses whether coding-agent sessions go into day memory. On the Mac setup shows this choice, so a new install reads nothing until setup is finished, and from then on the settings alone decide. Windows and Linux installs saved the enabled key as true without ever asking, so reading there also needs `coding_agent_evidence_confirmed`, a key the Mac does not have.

Where: `LokalBot/Services/CodingAgents/CodingAgentEvidenceIngestor.swift` (`CodingAgentEvidenceIngestor.Configuration.init(settings:onboardingFinished:)`), `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings::coding_agent_evidence_confirmed`).

## What leaves the computer

### Transcription servers are approved separately from Think servers

`approvedRemoteTranscriptionOrigins` holds the origins the user approved to receive meeting, dictation and live preview audio. It is separate from `approvedRemoteInferenceOrigins`, so approving a Think server never sends it audio.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.approvedRemoteTranscriptionOrigins`).

### The Privacy & permissions page follows PRIVACY.md sentence by sentence

Privacy & permissions is the one place that shows what LokalBot may use on the computer and what leaves it. Each permission says which features use it and where it stands, each server that receives something is listed with the control that revokes it, and sharing with agents and with phones is summed up and opens its own page, where its consent lives. `PRIVACY.md` is the contract for every sentence on the page.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/privacy.rs` (`SettingsPage::privacy_sections`, `SettingsPrivacySections`).

### The plugin listing never claims that nothing leaves the computer

Remote model servers the user approves do receive library content, so a test fails if the OpenAI plugin listing promises that nothing leaves the computer.

Where: `Scripts/tests/test_openai_plugin.py` (`test_listing_does_not_promise_nothing_leaves_the_computer`).

### An API key is reported as saved only after it reads back from Keychain

Model connections acknowledge that a key was saved only after reading it back from Keychain.

Where: `LokalBot/Views/ModelSetup/ModelConnectionsView.swift` (`ModelConnectionsView.apiKeyControl`).

## Phone app lock

### On Android only a quick restart may skip the app lock

Restored state says "unlocked" for as long as Android keeps it, which can be days after it ended the process. Only a restart soon after the app was left may skip the lock.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/MainActivity.kt` (`MainActivity.onCreate`).

### Turning the app lock on asks for authentication once

Turning the lock on asks once, so nobody locks themselves out.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/MainActivity.kt` (`MainActivity.onCreate`).

### Android keeps the library out of the recents picture while the lock is on

The lock only comes down after a while in the background, and the system takes the recents picture on the way out, so with the lock on the recents screen shows no picture of the library. Android 13 can leave just that picture out, so the person's own screenshots still work, as on iOS. Earlier versions can only mark the whole window secure, which stops screenshots too.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/MainActivity.kt` (`keepOutOfRecents`).

### On iOS the lock cover is its own window, raised before the scene deactivates

A cover inside a window's own view tree lies under that window's sheets, the recording screen, alerts and menus, which would stay readable while the app is locked and in the app switcher, so the cover sits in a window of its own above all of them. iOS shows a window in the app switcher from `sceneWillDeactivate` on and takes its picture once it is in the background, so the cover goes up before that call returns instead of waiting for the next view update.

Where: `Companion/ios/App/Platform/LockCoverWindows.swift` (`LockCoverWindows`, `LockCoverWindows.sceneWillDeactivate`).

### With the lock on, a queued-answer notification names the question but not the answer

When the computer answers a question that was queued while it was away, the banner shows on the lock screen and over other apps, where App Lock doesn't reach. With the lock on it names the question and leaves the answer for inside the app, as the Android app does.

Where: `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/QueuedAnswerBanner.swift` (`QueuedAnswerBanner`).

## Consequences

- A new setting must decode on its own and, if unreadable, fall back visibly: a corrupt value resets one field and is announced by name, and a narrow patch like `ModelSelectionPatch` must not start writing privacy choices or credentials.
- A new permission-gated feature asks for its permission when it is turned on, not during onboarding, and any status or readiness check must not trigger a system prompt; a new place that sends data out needs its own approval, a line on the Privacy & permissions page and a matching sentence in `PRIVACY.md`.
- In the phone apps, every new window, sheet, notification or piece of restored state is a way past the app lock; check the app switcher, recents, banners and process restore when adding one.
