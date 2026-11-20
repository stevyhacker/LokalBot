# 0014. Mac app: Capture

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Capture/`, `LokalBotTests/Services/Capture/`.

## Decisions

### `LokalBot/Services/Capture/CaptureEnvironment.swift`

#### Value type for replay; property names match NSRunningApplication
`RunningApp`: A running application as a value, so traces can record and replay it.
Property names match `NSRunningApplication`, so detection helpers compile
unchanged when their parameter type switches.

#### Privacy recheck after pixels taken reads secure fields and addresses, node-limited
`AccessibilitySource.readPrivacy`: Secure fields and page addresses without text, over at most
`nodeLimit` elements: a capture's recheck after its pixels were taken.

#### Recorded and replayed environments answer with their metadata read
`AccessibilitySource.readWindow`: Recorded and replayed environments answer with their metadata read.

#### Recorded and replayed environments answer with their full read
`AccessibilitySource.readPrivacy`: Recorded and replayed environments answer with their full read.

#### Capture only windows from the most recent onScreenWindows call
`WindowSource.captureImage`: Captures a window returned by the most recent `onScreenWindows()`.

#### Live wraps OS calls; tests and UI host install replay; Debug can record
`CaptureEnvironment`: Every OS boundary the capture, tracking, and detection services read.
Live wraps today's calls; tests and the UI background host install a
replay; Debug builds can install a recorder. Services read `current`.

### `LokalBot/Services/Capture/CaptureTrace.swift`

#### Recorded traces are scrubbed before being written
`CaptureTrace`: A recorded sequence of capture-environment answers. Recorded traces are
scrubbed before they are written (`CaptureTraceScrubber`).

### `LokalBot/Services/Capture/CaptureTraceScrubber.swift`

#### Scrub to structure-preserving consonant placeholders; keep allowlist matching JSON file
`CaptureTraceScrubber`: Replaces every personal string in a capture trace with a structure-
preserving placeholder before the trace is written. Letters become
consonants (so any vowel in a scrubbed field reveals unscrubbed text),
digits stay digits, punctuation stays, so detection patterns such as Meet
codes survive while content does not. Keep `allowlist` equal to
`Scripts/test/record-capture/scrub-allowlist.json`.

#### Detection apps keep their helper processes (ID followed by dot)
`CaptureTraceScrubber.Allowlist.bundleIDs`: Detection-relevant apps; their helper processes (an allowed ID
followed by ".") are kept too.

#### Fail closed: unparseable scrubbed URL never keeps the original
`CaptureTraceScrubber`: Fail closed: an unparseable scrubbed URL never keeps the original.

### `LokalBot/Services/Capture/LiveCaptureEnvironment.swift`

#### Cache running apps; refresh on launch/quit or 30 s; avoids 40-70 ms main-thread stalls
`RunningApplicationCache`: `RunningApp` values for NSWorkspace's running applications. Each property
read on an `NSRunningApplication` is a synchronous LaunchServices round
trip, and NSWorkspace hands back fresh objects on every call for the
~100 processes without a bundle id. The meeting detector mapped all ~200
apps twice per 2-second tick on the main thread, which a live profile on
2026-10-01 showed as 40–70 ms stalls every tick.

The list is now read once and kept until an app launches or quits
(NSWorkspace posts both), or at most `maximumAge`. Every caller looks apps
up by bundle id; the processes that churn have none. Values are also kept
per application object, retained while cached so an identifier is never
reused, so a refresh only reads apps it has not seen.

#### Keep last SCWindow list so capture uses the selected SCWindow
`LiveWindowSource`: Keeps the last ScreenCaptureKit window list so a capture uses the same
`SCWindow` the selection came from, exactly as before the seam existed.

#### Bound source frame to 1,500 px; native 5K/6K IOSurface inflated memory
`LiveWindowSource.captureImage`: Bound the source frame before ScreenCaptureKit allocates it. Vision
receives this same readable 1,500 px frame in the worker; requesting
a native 5K/6K IOSurface only inflated transient memory.

#### Window-only filter captures just the AX-checked window; display capture includes unchecked content
`LiveWindowSource.captureImage`: This filter contains only the AX-checked window. Display capture,
even with app exclusions, can include unchecked background domains.

### `LokalBot/Services/Capture/RecordingCaptureEnvironment.swift`

#### finish(to:) scrubs and writes; nothing unscrubbed is written
`CaptureTraceRecorder`: Wraps the live environment and records every answer with its time.
`finish(to:)` scrubs and writes the trace; nothing unscrubbed is written.

#### Record as metadata read, matching how replay answers
`RecordingCaptureEnvironment.Accessibility.readWindow`: Recorded as a metadata read, which is what replay answers it with.

#### Record as full read, matching how replay answers
`RecordingCaptureEnvironment.Accessibility.readPrivacy`: Recorded as a full read, which is what replay answers it with.

#### Pixels are never recorded in traces
`RecordingCaptureEnvironment.captureImage`: pixels are never recorded

### `LokalBot/Services/Capture/ReplayCaptureEnvironment.swift`

#### Sleep warps virtual time so waits like 750 ms retry run instantly
`VirtualCaptureClock`: Virtual time for replay. `sleep` warps time forward (flows that wait, like
the 750 ms capture retry, run instantly and deterministically); timers
fire when a test advances the clock.

#### Fire due timers in time then creation order, letting started work run
`VirtualCaptureClock.advance`: Fires due timers in time order (ties by creation order), letting work
they start run between firings.

#### UI background host replays at real time times speed with scaled timers
`RealTimeReplayClock`: Wall-clock replay for the UI background host: trace time advances with
real time × speed; timers and sleeps use the live clock, scaled.

#### Replay mirrors live reader: canonical room URL, never answers for another room
`ReplayCaptureEnvironment.browserMeetingSnapshot`: Like the live reader, only a supported room document answers, under
its canonical URL, and a read for one room never answers with another.

### `LokalBotTests/Services/Capture/CaptureTraceScrubberTests.swift`

#### Foreign-host meeting helpers need own scrub entries or traces lose the call process
`testForeignMeetingHelpersSurviveScrubbing`: Helpers outside their host's namespace need their own entries, or a
recorded Feishu or DingTalk trace loses the process that carries the call.

#### Test bundle holds a copy of scrub-allowlist.json that must match Swift
`testSwiftAllowlistMatchesTheSharedJSON`: A copy of Scripts/test/record-capture/scrub-allowlist.json; see project.yml.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
