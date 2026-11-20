# 0119. Companion end-to-end tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Companion/e2e/`.

## Decisions

### `Companion/e2e/android_trip.py`

#### uiautomator dump fails while screen is busy; callers retry
`android_trip.nodes`: The dump fails while the screen is busy; the callers wait and ask again.

#### Tap the suggested question once; a second would ask twice
`android_trip.ask_a_question`: Once only: a second tap would ask twice while the first answer streams.

### `Companion/e2e/harness.py`

#### Whether the host asks before allowing a device, as a computer does
`Host.asks`: Whether it asks before allowing a device, as a person's computer does; allow() answers.

### `Companion/e2e/ios_trip.py`

#### Separate launch because a change needs the meeting on the phone
`ios_trip.pair_and_change_an_action`: A separate launch, because a change needs the meeting to be on the phone.

#### Wait long enough for an attempt to fail without costing the only copy
`ios_trip.keep_while_the_computer_is_away`: Long enough for an attempt to fail, which must not cost the only copy.

### `Companion/e2e/own_emulator.py`

#### Emulator takes even console ports up to 5682, next port for adb
`own_emulator.CONSOLE_PORTS`: The emulator takes even console ports up to 5682 and uses the next one for adb.

#### Mirror android-emulator-runner boot settings so tests see the same
`own_emulator.AFTER_BOOT`: What android-emulator-runner does on GitHub's runners, so the test sees the same.

#### Max transport port below the emulator's makes adb server look at none
`own_emulator.environment`: Below the first emulator's port, it makes the server look at none.

#### SIGTERM handler so cancelled CI jobs do not leave the emulator running
`own_emulator.main`: A cancelled CI job ends with SIGTERM, and the emulator shouldn't outlive it.

### `Companion/e2e/test_harness.py`

#### adb servers scan up to 5585; emulator refuses ports above 5682
`test_harness console ports`: adb servers scan up to 5585; the emulator refuses anything above 5682.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
