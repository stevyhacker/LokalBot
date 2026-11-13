# Redesign Phase 3 — Capture Pillar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the Meetings and Timeline sections into one **Capture** section (spec §2.2): a Day ⇄ Library scope toggle in the content column, meetings rendered as first-class teal blocks in the day track, and a selection-driven detail pane (meeting → detail view, block → block card + scoped screenshots, nothing → day overview with per-app proportion bar + digest). The inspector's Ask tab moves to the Ask pillar as a day-scope chip.

**Architecture:** Pure policy types first (`CaptureScope`/`CaptureScopePolicy`, `CaptureInspectorState`, `CaptureTrackItem`, `ProportionBarMath`) so scope defaults, selection resolution, and track interleaving are unit-testable without AX or views — the same decomposition pattern Cotyping uses. Then `TimelineView.swift` is replaced by `CaptureView.swift` (content column: scope bar, day view, hour track with a meeting lane) and `CaptureDetailView.swift` (selection-driven inspector), with the meeting list extracted to `MeetingListView.swift` unchanged. `AppState.NavSection` gains `.capture`; `.meetings`/`.timeline` become legacy capture-name aliases.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest/XCUITest, XcodeGen.

## Global Constraints

- Nothing leaves the Mac — this is a pure UI change; no new network surface (spec §4).
- Native-first: `NavigationSplitView`, system materials, segmented Pickers stay (spec §4).
- Meeting detail view (`MeetingDetailView`) is **unchanged** this round (spec §4).
- Row-level accessibility ids stay stable: `meeting.list`, `meeting.row.*`, `timeline.track`, `search.hit.*`, `chat.*`. Only section-level ids change (spec §3.4): `sidebar.meetings` + `sidebar.timeline` → `sidebar.capture`; `timeline.inspector` (the four-tab control) is removed.
- `NavSection(captureName:)` accepts both old and new names: `"capture"`, `"meetings"`, `"timeline"` → `.capture` (spec §2.1, §6). Unknown names return nil → callers fall back to the `.capture` default.
- Library scope = the existing grouped-by-day meeting list, **unchanged behavior** (multi-select, delete, live-recording row) (spec §2.2).
- Scope default (spec open question 2, resolved yes): Day when the selected day has activity blocks, Library otherwise — applied only when no scope was explicitly chosen yet.
- `xcodegen generate` after every task that adds/removes source files; never `git add` the `.xcodeproj`.
- `git checkout -- default.profraw` before every commit (test runs regenerate it).
- Unit tests: `xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test` (scheme "LokalBot"). UI tests: `Scripts/test/ui-tests.sh` — run at Tasks 9–10 only; Tasks 4–8 gate on build + unit tests (navigation is mid-rewire in between).
- Commit style: imperative sentence case + `Claude-Session:` trailer.
- Branch: `redesign-phase3` off `redesign-phase2` (stacked; PR targets `redesign-phase2`).
- Known pre-existing failure exempt from gates: `SettingsUITests.testPermissionRepairPaneRendersCorePermissions` (fails on master).

---

### Task 1: Capture scope + inspector-state policies

**Files:**
- Create: `LokalBot/Models/CaptureState.swift`
- Test: `LokalBotTests/CaptureStateTests.swift`

**Interfaces:**
- Produces: `CaptureScope` (`.day`/`.library`, `String` raw values `"Day"`/`"Library"`, `CaseIterable`, `Identifiable`), `CaptureScopePolicy.resolve(current: CaptureScope?, hasBlocks: Bool) -> CaptureScope`, `CaptureInspectorState` (`.overview`, `.meeting(Meeting.ID)`, `.multiSelection(count: Int)`, `.block(ActivityBlock.ID)`) with `CaptureInspectorState.resolve(meetingIDs: Set<Meeting.ID>, blockSelection: ActivityBlock.ID?) -> CaptureInspectorState`. Note `ActivityBlock.ID == Int64`, `Meeting.ID == UUID`.

- [ ] **Step 0: Create the branch**

```bash
git checkout -b redesign-phase3
```

- [ ] **Step 1: Write the failing tests**

`LokalBotTests/CaptureStateTests.swift`:

```swift
import XCTest
@testable import LokalBot

/// The Capture section's pure policies (spec §2.2 + §6): the Day⇄Library
/// scope default and the selection→inspector-state resolution, testable
/// without any view or AppState.
final class CaptureStateTests: XCTestCase {

    // MARK: Scope policy (open question 2 — resolved yes)

    func testFirstVisitWithBlocksDefaultsToDay() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: nil, hasBlocks: true), .day)
    }

    func testFirstVisitWithoutBlocksDefaultsToLibrary() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: nil, hasBlocks: false), .library)
    }

    func testExplicitScopeSticksRegardlessOfBlocks() {
        XCTAssertEqual(CaptureScopePolicy.resolve(current: .library, hasBlocks: true), .library)
        XCTAssertEqual(CaptureScopePolicy.resolve(current: .day, hasBlocks: false), .day)
    }

    // MARK: Inspector state (meeting vs. block vs. none)

    func testSingleMeetingSelectionWinsOverBlock() {
        let id = UUID()
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [id], blockSelection: 7),
            .meeting(id))
    }

    func testMultiSelectionMapsToCount() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [UUID(), UUID()], blockSelection: nil),
            .multiSelection(count: 2))
    }

    func testBlockSelectionWithoutMeetingSelection() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: 42),
            .block(42))
    }

    func testNothingSelectedIsOverview() {
        XCTAssertEqual(
            CaptureInspectorState.resolve(meetingIDs: [], blockSelection: nil),
            .overview)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/CaptureStateTests
```
Expected: build FAILS ("cannot find 'CaptureScopePolicy' in scope").

- [ ] **Step 3: Write the implementation**

`LokalBot/Models/CaptureState.swift`:

```swift
import Foundation

/// Which surface the Capture content column shows (spec §2.2): the
/// hour-track Day view or the grouped-by-day meeting Library.
enum CaptureScope: String, CaseIterable, Identifiable {
    case day = "Day"
    case library = "Library"
    var id: String { rawValue }
}

/// Pure scope-default policy: the first visit lands on Day when the selected
/// day has activity blocks and on Library otherwise (spec open question 2 —
/// resolved yes); once a scope is set (user toggle or deep link) it sticks.
enum CaptureScopePolicy {
    static func resolve(current: CaptureScope?, hasBlocks: Bool) -> CaptureScope {
        current ?? (hasBlocks ? .day : .library)
    }
}

/// What the Capture detail pane shows, resolved from the two selection
/// sources (spec §2.2): meeting selection wins, then an activity block,
/// then the day overview. Multi-selected meetings keep the bulk-delete card.
enum CaptureInspectorState: Equatable {
    case overview
    case meeting(Meeting.ID)
    case multiSelection(count: Int)
    case block(ActivityBlock.ID)

    static func resolve(meetingIDs: Set<Meeting.ID>,
                        blockSelection: ActivityBlock.ID?) -> CaptureInspectorState {
        if meetingIDs.count == 1, let id = meetingIDs.first { return .meeting(id) }
        if meetingIDs.count > 1 { return .multiSelection(count: meetingIDs.count) }
        if let blockSelection { return .block(blockSelection) }
        return .overview
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Models/CaptureState.swift LokalBotTests/CaptureStateTests.swift
git commit -m "Add Capture scope and inspector-state policies"
```

---

### Task 2: Capture track items (meetings interleaved with activity)

**Files:**
- Create: `LokalBot/Models/CaptureTrackItem.swift`
- Test: `LokalBotTests/CaptureTrackItemTests.swift`

**Interfaces:**
- Consumes: `ActivityBlock` (`LokalBot/Services/ActivityTracker.swift`: `id: Int64`, `app`, `title`, `start`, `end`, computed `duration`), `Meeting` (`startedAt`, `endedAt: Date?`, `recordedDuration: TimeInterval?`).
- Produces: `CaptureTrackItem` enum (`.activity(ActivityBlock)` / `.meeting(Meeting, end: Date)`), `id: String`, `start`/`end: Date`, `duration: TimeInterval`, `CaptureTrackItem.items(blocks:meetings:now:) -> [CaptureTrackItem]` (start-ordered merge), `CaptureTrackItem.meetingEnd(_:now:) -> Date`.

- [ ] **Step 1: Write the failing tests**

`LokalBotTests/CaptureTrackItemTests.swift`:

```swift
import XCTest
@testable import LokalBot

/// The Capture day track merges activity blocks and meetings into one
/// start-ordered stream (spec §2.2: meetings render as first-class blocks).
/// Pure, so the interleaving and the in-progress-meeting end rule are
/// testable without views.
final class CaptureTrackItemTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_750_000_000)

    private func block(id: Int64, startOffset: TimeInterval,
                       endOffset: TimeInterval) -> ActivityBlock {
        ActivityBlock(id: id, app: "Xcode", title: "CaptureView.swift",
                      start: base.addingTimeInterval(startOffset),
                      end: base.addingTimeInterval(endOffset))
    }

    private func meeting(startOffset: TimeInterval, endOffset: TimeInterval?,
                         recorded: TimeInterval? = nil) -> Meeting {
        var m = Meeting(id: UUID(), title: "Standup", appName: "Zoom",
                        startedAt: base.addingTimeInterval(startOffset),
                        endedAt: endOffset.map { base.addingTimeInterval($0) },
                        relativePath: "meetings/2026/07/03-standup")
        m.recordedDuration = recorded
        return m
    }

    func testItemsInterleaveSortedByStart() {
        let items = CaptureTrackItem.items(
            blocks: [block(id: 1, startOffset: 0, endOffset: 600),
                     block(id: 2, startOffset: 3_600, endOffset: 4_200)],
            meetings: [meeting(startOffset: 1_800, endOffset: 2_700)],
            now: base.addingTimeInterval(7_200))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.start),
                       [base, base.addingTimeInterval(1_800), base.addingTimeInterval(3_600)])
        if case .meeting = items[1] {} else {
            XCTFail("middle item should be the meeting")
        }
    }

    func testEndedMeetingUsesEndedAt() {
        let m = meeting(startOffset: 0, endOffset: 1_500, recorded: 900)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(9_999)),
                       base.addingTimeInterval(1_500))
    }

    func testUnendedMeetingFallsBackToRecordedDuration() {
        let m = meeting(startOffset: 0, endOffset: nil, recorded: 900)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(9_999)),
                       base.addingTimeInterval(900))
    }

    func testLiveMeetingEndsAtNow() {
        let m = meeting(startOffset: 0, endOffset: nil)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base.addingTimeInterval(300)),
                       base.addingTimeInterval(300))
    }

    func testLiveMeetingGetsMinimumVisibleSpan() {
        // A meeting that just started must not produce a zero-height block.
        let m = meeting(startOffset: 0, endOffset: nil)
        XCTAssertEqual(CaptureTrackItem.meetingEnd(m, now: base),
                       base.addingTimeInterval(60))
    }

    func testIDsAreDistinctAcrossKinds() {
        let items = CaptureTrackItem.items(
            blocks: [block(id: 5, startOffset: 0, endOffset: 60)],
            meetings: [meeting(startOffset: 0, endOffset: 60)],
            now: base)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/CaptureTrackItemTests
```
Expected: build FAILS ("cannot find 'CaptureTrackItem' in scope").

- [ ] **Step 3: Write the implementation**

`LokalBot/Models/CaptureTrackItem.swift`:

```swift
import Foundation

/// One block in the Capture day track: an app activity block, or a meeting
/// rendered as a first-class teal block (spec §2.2). Pure so the
/// interleaving and the in-progress-meeting end rule are unit-testable.
enum CaptureTrackItem: Identifiable {
    case activity(ActivityBlock)
    case meeting(Meeting, end: Date)

    var id: String {
        switch self {
        case .activity(let block): "block-\(block.id)"
        case .meeting(let meeting, _): "meeting-\(meeting.id.uuidString)"
        }
    }

    var start: Date {
        switch self {
        case .activity(let block): block.start
        case .meeting(let meeting, _): meeting.startedAt
        }
    }

    var end: Date {
        switch self {
        case .activity(let block): block.end
        case .meeting(_, let end): end
        }
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Merge a day's activity blocks and meetings into one start-ordered
    /// track.
    static func items(blocks: [ActivityBlock], meetings: [Meeting],
                      now: Date) -> [CaptureTrackItem] {
        let meetingItems = meetings.map {
            CaptureTrackItem.meeting($0, end: meetingEnd($0, now: now))
        }
        return (blocks.map(CaptureTrackItem.activity) + meetingItems)
            .sorted { $0.start < $1.start }
    }

    /// A meeting's track end: `endedAt`, else the recorded audio length,
    /// else "now" for a live meeting — never less than a minute past start
    /// so a just-started meeting still gets a visible block.
    static func meetingEnd(_ meeting: Meeting, now: Date) -> Date {
        if let ended = meeting.endedAt { return ended }
        if let recorded = meeting.recordedDuration {
            return meeting.startedAt.addingTimeInterval(recorded)
        }
        return max(now, meeting.startedAt.addingTimeInterval(60))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Models/CaptureTrackItem.swift LokalBotTests/CaptureTrackItemTests.swift
git commit -m "Add Capture track items merging meetings into the day track"
```

---

### Task 3: ProportionBar component

**Files:**
- Create: `LokalBot/Support/ProportionBar.swift`
- Test: `LokalBotTests/ProportionBarMathTests.swift`

**Interfaces:**
- Produces: `ProportionBarMath.Segment` (`label: String`, `fraction: Double`, Equatable), `ProportionBarMath.segments(perApp: [(label: String, seconds: TimeInterval)], cap: Int = 6) -> [Segment]`, and the `ProportionBar` view (`segments: [(segment: ProportionBarMath.Segment, color: Color)]`, `height: CGFloat = 10`). Same math/view split as `LiveWaveformMath`/`LiveWaveform`.

- [ ] **Step 1: Write the failing tests**

`LokalBotTests/ProportionBarMathTests.swift`:

```swift
import XCTest
@testable import LokalBot

/// The day overview's per-app proportion bar (spec §3.2): per-app seconds
/// become ordered fractions of the tracked total, with a long tail folded
/// into "Other".
final class ProportionBarMathTests: XCTestCase {

    func testFractionsAreOrderedAndSumToOne() {
        let segments = ProportionBarMath.segments(
            perApp: [("Xcode", 3_000), ("Safari", 1_000)])
        XCTAssertEqual(segments.map(\.label), ["Xcode", "Safari"])
        XCTAssertEqual(segments[0].fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.fraction }, 1.0, accuracy: 0.001)
    }

    func testTailFoldsIntoOther() {
        let apps = (1...8).map { ("App\($0)", TimeInterval(100)) }
        let segments = ProportionBarMath.segments(perApp: apps, cap: 6)
        XCTAssertEqual(segments.count, 7)
        XCTAssertEqual(segments.last?.label, "Other")
        XCTAssertEqual(segments.last!.fraction, 0.25, accuracy: 0.001)
    }

    func testZeroTotalProducesEmptyBar() {
        XCTAssertTrue(ProportionBarMath.segments(perApp: []).isEmpty)
        XCTAssertTrue(ProportionBarMath.segments(perApp: [("Xcode", 0)]).isEmpty)
    }

    func testZeroSecondAppsAreDropped() {
        let segments = ProportionBarMath.segments(perApp: [("Xcode", 600), ("Idle", 0)])
        XCTAssertEqual(segments.map(\.label), ["Xcode"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/ProportionBarMathTests
```
Expected: build FAILS ("cannot find 'ProportionBarMath' in scope").

- [ ] **Step 3: Write the implementation**

`LokalBot/Support/ProportionBar.swift`:

```swift
import SwiftUI

/// Math behind the per-app proportion bar, separated from the view for unit
/// tests (same pattern as `LiveWaveformMath`).
enum ProportionBarMath {
    struct Segment: Equatable {
        let label: String
        let fraction: Double
    }

    /// Per-app seconds → ordered fractions of the whole, folding everything
    /// past `cap` apps into an "Other" segment. Zero totals produce an empty
    /// bar rather than NaN fractions.
    static func segments(perApp: [(label: String, seconds: TimeInterval)],
                         cap: Int = 6) -> [Segment] {
        let positive = perApp.filter { $0.seconds > 0 }
        let total = positive.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let sorted = positive.sorted { $0.seconds > $1.seconds }
        let top = sorted.prefix(cap).map {
            Segment(label: $0.label, fraction: $0.seconds / total)
        }
        let rest = sorted.dropFirst(cap).reduce(0) { $0 + $1.seconds }
        guard rest > 0 else { return top }
        return top + [Segment(label: "Other", fraction: rest / total)]
    }
}

/// Horizontal stacked proportion bar (spec §3.2): one rounded track whose
/// segments show each app's share of the tracked day. Colors come from the
/// caller so the bar stays in the same family as the hour track.
struct ProportionBar: View {
    let segments: [(segment: ProportionBarMath.Segment, color: Color)]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { pair in
                    Rectangle()
                        .fill(pair.element.color)
                        .frame(width: max(1, geo.size.width * pair.element.segment.fraction))
                }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.4))
        .clipShape(Capsule())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Support/ProportionBar.swift LokalBotTests/ProportionBarMathTests.swift
git commit -m "Add ProportionBar design-system component"
```

---

### Task 4: NavSection gains .capture + AppState deep-link wiring

**Files:**
- Modify: `LokalBot/LokalBotApp.swift` (NavSection enum ~line 114, published nav state ~line 185, `openAsk` ~line 202, `openSearchHit` ~line 547)
- Test: `LokalBotTests/NavSectionMappingTests.swift` (update in place)

**Interfaces:**
- Consumes: `CaptureScope` (Task 1).
- Produces: `NavSection.capture` case (keep `.meetings`/`.timeline` cases until Task 6 so `MainWindowView` still compiles; they are no longer produced by `init?(captureName:)`); `@Published var captureScope: CaptureScope?`; `@Published var askDayScope: Date?`; `func openMeeting(_ id: Meeting.ID)` (selects the meeting, forces Library scope, navigates to `.capture`); `func openAsk(query: String = "", dayScope: Date? = nil)`. Later tasks rely on these exact names.

- [ ] **Step 1: Update the mapping tests to the final spec semantics**

Replace the body of `LokalBotTests/NavSectionMappingTests.swift` with:

```swift
import XCTest
@testable import LokalBot

/// The NavSection migration mapping (spec §2.1): capture names from the
/// UI-test host env and deep links resolve to sections, with legacy
/// pre-merge names mapping onto the merged pillars.
final class NavSectionMappingTests: XCTestCase {

    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "capture"), .capture)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .models)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    func testLegacyMeetingsAndTimelineNamesMapToCapture() {
        XCTAssertEqual(AppState.NavSection(captureName: "meetings"), .capture)
        XCTAssertEqual(AppState.NavSection(captureName: "Timeline"), .capture)
    }

    func testLegacyTypeNamesMapToType() {
        XCTAssertEqual(AppState.NavSection(captureName: "dictation"), .type)
        XCTAssertEqual(AppState.NavSection(captureName: "Cotyping"), .type)
    }

    func testLegacySearchAndChatNamesMapToAsk() {
        XCTAssertEqual(AppState.NavSection(captureName: "search"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "chat"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "Search"), .ask)
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(AppState.NavSection(captureName: "bogus"))
        XCTAssertNil(AppState.NavSection(captureName: ""))
    }

    func testTypeTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.TypeTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.TypeTab(captureName: "Cotyping"), .cotyping)
        XCTAssertNil(AppState.TypeTab(captureName: "type"))
        XCTAssertNil(AppState.TypeTab(captureName: "capture"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/NavSectionMappingTests
```
Expected: build FAILS ("type 'AppState.NavSection' has no member 'capture'").

- [ ] **Step 3: Implement in `LokalBot/LokalBotApp.swift`**

3a. Replace the `NavSection` enum body:

```swift
    enum NavSection: Hashable {
        case capture, meetings, timeline, type, ask, models, settings
        // `.meetings` / `.timeline` are legacy cases kept only until the
        // Capture surface lands (Task 6 removes them); `captureName` already
        // resolves their names onto `.capture` (spec §2.1).

        /// Section names accepted from the UI-test capture environment and
        /// deep links. Legacy pre-merge names keep working: "meetings" and
        /// "timeline" land on the merged Capture section, "dictation" and
        /// "cotyping" on Type, "search"/"chat" on Ask (spec §2.1).
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "capture", "meetings", "timeline": self = .capture
            case "type", "dictation", "cotyping": self = .type
            case "ask", "search", "chat": self = .ask
            case "models": self = .models
            case "settings": self = .settings
            default: return nil
            }
        }
    }
```

3b. Below `@Published var pendingSeek: TimeInterval?` add:

```swift
    /// Capture's Day⇄Library scope. Nil until first resolved by
    /// `CaptureScopePolicy` (Day when the day has activity, else Library);
    /// deep links force `.library` so the meeting list is visible.
    @Published var captureScope: CaptureScope?

    /// A day handed to the Ask section (the old Timeline "Ask" tab, spec
    /// §2.2): rendered as a removable chip, and prepended to escalated
    /// queries so the assistant scopes its answer to that day.
    @Published var askDayScope: Date?
```

3c. Replace `openAsk` with:

```swift
    /// Navigate to the Ask section, optionally pre-filling the query and/or
    /// scoping it to a day (Capture's "Ask about this day").
    func openAsk(query: String = "", dayScope: Date? = nil) {
        askPrefill = query.isEmpty ? nil : query
        askDayScope = dayScope
        navSection = .ask
    }
```

3d. Add next to `openAsk` and rewrite `openSearchHit`:

```swift
    /// Open one meeting in Capture's Library scope — the deep-link target
    /// for search hits, menu-bar recents, and palette recents.
    func openMeeting(_ id: Meeting.ID) {
        selectedMeetingIDs = [id]
        captureScope = .library
        navSection = .capture
    }
```

```swift
    /// Search hit → open the meeting; transcript hits seek the player.
    func openSearchHit(_ hit: SearchIndex.Hit) {
        if hit.kind == .segment {
            pendingSeek = hit.start
        }
        openMeeting(hit.meetingID)
    }
```

(Leave `@Published var navSection: NavSection = .meetings` and the `navSection = .meetings` fallback at ~line 553 alone — Task 6 flips them with the UI.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/NavSectionMappingTests
```
Expected: PASS (6 tests). Note: `openSearchHit` now routes to `.capture`, which `MainWindowView` doesn't render yet — that's fine until Task 6; UI tests don't run until Task 9.

- [ ] **Step 5: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/LokalBotApp.swift LokalBotTests/NavSectionMappingTests.swift
git commit -m "Map legacy meetings and timeline names onto a capture section"
```

---

### Task 5: Extract MeetingListView

**Files:**
- Create: `LokalBot/Views/MeetingListView.swift`
- Modify: `LokalBot/Views/MainWindowView.swift` (remove `meetingList`, `groupedMeetings`, `dayLabel`, `meetingRow`; the else-branch uses the new view)

**Interfaces:**
- Produces: `struct MeetingListView: View` with `@EnvironmentObject var app: AppState` and `@Binding var pendingDelete: Set<Meeting.ID>?`. Behavior and accessibility ids (`meeting.list`, `meeting.row.*`) identical to today's `meetingList`. Column width/title stay at the call site.

- [ ] **Step 1: Create `LokalBot/Views/MeetingListView.swift`**

Move the following members out of `MainWindowView` verbatim (they are currently at `MainWindowView.swift:182-255`), changing only the wrapper type and the two hoisted modifiers (`navigationSplitViewColumnWidth`, `navigationTitle` — set by the caller from Task 6 on):

```swift
import SwiftUI

/// The meeting library list — live recording first, then finished meetings
/// grouped by day. Capture's Library scope (spec §2.2: unchanged behavior —
/// multi-select, delete, the live-recording overlay). Deletion is confirmed
/// by the host window's dialog via `pendingDelete`.
struct MeetingListView: View {
    @EnvironmentObject var app: AppState
    @Binding var pendingDelete: Set<Meeting.ID>?

    var body: some View {
        List(selection: $app.selectedMeetingIDs) {
            ForEach(groupedMeetings, id: \.label) { group in
                Section {
                    ForEach(group.items) { meeting in
                        meetingRow(meeting).tag(meeting.id)
                    }
                } header: {
                    SectionHeader(text: group.label)
                }
            }
        }
        .accessibilityIdentifier("meeting.list")
        .overlay(alignment: .topTrailing) {
            if app.isRecording {
                HStack(spacing: 6) {
                    StatusDot(color: Brand.recording, size: 7)
                    Text("recording…").font(.caption)
                    LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .hudCapsule()
                .padding(10)
            }
        }
        .contextMenu(forSelectionType: Meeting.ID.self) { ids in
            Button("Delete \(ids.count > 1 ? "\(ids.count) meetings" : "meeting")…",
                   role: .destructive) {
                pendingDelete = ids
            }
        }
        .onDeleteCommand {
            if !app.selectedMeetingIDs.isEmpty { pendingDelete = app.selectedMeetingIDs }
        }
    }

    /// Live recording first, then finished meetings, grouped by day.
    private var groupedMeetings: [(label: String, items: [Meeting])] {
        let calendar = Calendar.current
        let all = (app.currentMeeting.map { [$0] } ?? []) + app.meetings
        let groups = Dictionary(grouping: all) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { day in
            (Self.dayLabel(day), groups[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let datePart = day.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        if Calendar.current.isDateInToday(day) { return "TODAY — \(datePart)" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY — \(datePart)" }
        return "\(day.formatted(.dateTime.weekday(.wide)).uppercased()) — \(datePart)"
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let live = meeting.endedAt == nil
        let time = live ? "in progress"
                        : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let duration = live ? "\(max(1, Int(Date().timeIntervalSince(meeting.startedAt) / 60))) min"
                            : meeting.durationLabel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if live { StatusDot(color: Brand.recording, size: 9) }
                Text(meeting.title).font(.headline)
            }
            Text("\(meeting.appName) · \(time) · \(duration)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meeting.title)
        .accessibilityIdentifier("meeting.row.\(meeting.id.uuidString)")
    }
}
```

- [ ] **Step 2: Point `MainWindowView` at it**

In `MainWindowView.swift`, delete the `meetingList`, `groupedMeetings`, `dayLabel(_:)`, and `meetingRow(_:)` members, and replace the final else branch of `navigation` with:

```swift
        } else {
            NavigationSplitView {
                sidebar
            } content: {
                MeetingListView(pendingDelete: $pendingDelete)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                    .navigationTitle("Meetings")
            } detail: {
                detailPane
            }
        }
```

- [ ] **Step 3: Build + run the full unit suite**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
```
Expected: PASS (633 tests: 623 prior + 7 + 6 + 4 new, minus the 6 rewritten NavSection ones netting +0 there).

- [ ] **Step 4: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Views/MeetingListView.swift LokalBot/Views/MainWindowView.swift
git commit -m "Extract MeetingListView from the main window"
```

---

### Task 6: The Capture surface (content column + detail pane + rewire)

**Files:**
- Create: `LokalBot/Views/CaptureView.swift` (replaces `TimelineView.swift`: `CaptureModel`, `CaptureStyle`, `CaptureContentView`, `CaptureDayView`, private `CaptureTrackView`)
- Create: `LokalBot/Views/CaptureDetailView.swift` (`CaptureDetailView`, private `ThumbnailView`/`ThumbnailCache` moved from TimelineView)
- Delete: `LokalBot/Views/TimelineView.swift`
- Modify: `LokalBot/Views/MainWindowView.swift` (navigation, sidebar, `@StateObject`, `detailPane` removal, `sidebarSelection` fallback, GettingStartedCard button)
- Modify: `LokalBot/LokalBotApp.swift` (remove legacy `.meetings`/`.timeline` cases, default `navSection = .capture`)

**Interfaces:**
- Consumes: `CaptureScope`/`CaptureScopePolicy`/`CaptureInspectorState` (Task 1), `CaptureTrackItem` (Task 2), `ProportionBar`/`ProportionBarMath` (Task 3), `MeetingListView(pendingDelete:)` (Task 5), `app.openAsk(dayScope:)` (Task 4), `StatTile`, `StatusDot`, `MarkdownText`, `MeetingDetailView`, `GettingStartedCard`.
- Produces: `CaptureModel` (ObservableObject: `day`, `blocks`, `shots`, `selection: ActivityBlock.ID?`, `digest`, `generating`, `digestError`, `selectedBlock`, `moveDay(by:)`, `reload(app:)`, `meetings(in:)`, `generateDigest(app:)`, `copyDigest(_:)`, `exportDigest(_:)`), `CaptureContentView(model:pendingDelete:)`, `CaptureDetailView(model:pendingDelete:)`, `CaptureStyle.color(for:)`/`CaptureStyle.hm(_:)` (renamed `TimelineStyle`). Accessibility: `capture.scope` (segmented Day/Library), `timeline.track` (kept), `capture.meeting.<uuid>` (meeting blocks), `capture.askDay`.

- [ ] **Step 1: Create `LokalBot/Views/CaptureView.swift`**

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Capture pillar — Meetings and Timeline merged into one chronological
/// surface (spec §2.2). The content column carries a Day⇄Library scope
/// toggle: Day is the hour-indexed track with meetings rendered as
/// first-class teal blocks beside app-colored activity blocks; Library is
/// the unchanged grouped-by-day meeting list. Both columns share
/// `CaptureModel`; the detail pane (`CaptureDetailView`) is selection-driven.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var day = Date()
    @Published var blocks: [ActivityBlock] = []
    @Published var shots: [ActivityStore.Screenshot] = []
    @Published var selection: ActivityBlock.ID?
    @Published var digest: String?
    @Published var generating = false
    @Published var digestError: String?

    var selectedBlock: ActivityBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.id == selection }
    }

    func moveDay(by value: Int) {
        day = Calendar.current.date(byAdding: .day, value: value, to: day)
            ?? day.addingTimeInterval(TimeInterval(value) * 86_400)
    }

    func reload(app: AppState) {
        blocks = app.activityStore.blocks(on: day)
        shots = app.activityStore.screenshots(on: day)
        digest = try? String(contentsOf: journalURL(app: app), encoding: .utf8)
        digestError = nil
        selection = nil
        app.captureScope = CaptureScopePolicy.resolve(current: app.captureScope,
                                                      hasBlocks: !blocks.isEmpty)
    }

    /// The selected day's meetings, live recording included, for the track
    /// and the overview stats.
    func meetings(in app: AppState) -> [Meeting] {
        ((app.currentMeeting.map { [$0] } ?? []) + app.meetings)
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
    }

    private func journalURL(app: AppState) -> URL {
        let name = day.formatted(.iso8601.year().month().day())
        return app.storage.rootURL.appendingPathComponent("journal/\(name).md")
    }

    func generateDigest(app: AppState) async {
        generating = true
        defer { generating = false }
        let todays = meetings(in: app).filter { $0.endedAt != nil }
        let ocr = app.activityStore.ocrText(on: day)
        do {
            let (text, _) = try await app.pipeline.generateDayDigest(
                for: day, blocks: blocks, meetings: todays, ocr: ocr, config: app.settings)
            digest = text
        } catch {
            digestError = error.localizedDescription
        }
    }

    /// Copy the raw digest Markdown to the clipboard. The rendered text is
    /// selectable too, but one click grabs the whole document without a
    /// fiddly multi-line drag across the per-line Markdown layout.
    func copyDigest(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export the digest to a user-chosen `.md` file via the standard save
    /// panel. The digest is already auto-saved to `journal/<date>.md`; this
    /// drops a shareable copy wherever the user picks.
    func exportDigest(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Export Day Digest"
        panel.nameFieldStringValue = "\(day.formatted(.iso8601.year().month().day())).md"
        panel.canCreateDirectories = true
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            digestError = "Export failed — \(error.localizedDescription)"
        }
    }
}

/// Shared Capture styling helpers (block colors, duration labels).
enum CaptureStyle {
    /// Stable per-app color from the name hash.
    static func color(for app: String) -> Color {
        var hash: UInt64 = 5381
        for byte in app.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.78)
    }

    static func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Content column — scope toggle over Day track / Library list

struct CaptureContentView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    @Binding var pendingDelete: Set<Meeting.ID>?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: scope) {
                ForEach(CaptureScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityIdentifier("capture.scope")
            Divider()
            switch scope.wrappedValue {
            case .day:
                CaptureDayView(model: model)
            case .library:
                MeetingListView(pendingDelete: $pendingDelete)
            }
        }
        .navigationTitle("Capture")
        .task(id: model.day.formatted(date: .numeric, time: .omitted)) {
            model.reload(app: app)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if scope.wrappedValue == .day {
                    Button {
                        app.sampler.isPaused.toggle()
                    } label: {
                        Label(app.sampler.isPaused ? "Resume Tracking" : "Pause Tracking",
                              systemImage: app.sampler.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button {
                        model.reload(app: app)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var scope: Binding<CaptureScope> {
        Binding(get: { app.captureScope ?? .library },
                set: { app.captureScope = $0 })
    }
}

// MARK: - Day view — header, summary rail, hour track

struct CaptureDayView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel

    var body: some View {
        let meetings = model.meetings(in: app)
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.blocks.isEmpty && meetings.isEmpty {
                ContentUnavailableView(
                    "No activity recorded",
                    systemImage: "clock",
                    description: Text(app.settings.trackingEnabled
                        ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                        : "Day tracking is off — enable it in Settings."))
                    .frame(maxHeight: .infinity)
            } else {
                summaryRail(meetings: meetings)
                Divider()
                CaptureTrackView(
                    items: CaptureTrackItem.items(blocks: model.blocks,
                                                  meetings: meetings,
                                                  now: Date()),
                    blockSelection: model.selection,
                    selectedMeetingIDs: app.selectedMeetingIDs,
                    onSelectBlock: { id in
                        model.selection = id
                        if id != nil { app.selectedMeetingIDs = [] }
                    },
                    onSelectMeeting: { id in
                        model.selection = nil
                        app.selectedMeetingIDs = app.selectedMeetingIDs == [id] ? [] : [id]
                    })
                    .accessibilityIdentifier("timeline.track")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.moveDay(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            DatePicker("", selection: $model.day, displayedComponents: .date)
                .labelsHidden().fixedSize()
            Button { model.moveDay(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .disabled(Calendar.current.isDateInToday(model.day))
            Spacer()
        }
    }

    private func summaryRail(meetings: [Meeting]) -> some View {
        let total = model.blocks.reduce(0) { $0 + $1.duration }
        let apps = Set(model.blocks.map(\.app)).count
        return HStack(spacing: 8) {
            StatTile(icon: "clock", value: CaptureStyle.hm(total), label: "tracked")
            StatTile(icon: "square.grid.2x2", value: "\(apps)", label: apps == 1 ? "app" : "apps")
            StatTile(icon: "camera.viewfinder", value: "\(model.shots.count)", label: "screens")
            if !meetings.isEmpty {
                StatTile(icon: "waveform", value: "\(meetings.count)",
                         label: meetings.count == 1 ? "meeting" : "meetings")
            }
            Spacer()
        }
    }
}

/// Vertical, hour-indexed track (calendar day-view metaphor). Meetings get a
/// dedicated teal lane on the left edge of the block area so they never
/// occlude the activity blocks they overlap (a meeting and its app's
/// activity cover the same minutes); activity blocks keep the remaining lane
/// width. With no meetings, activity blocks span the full lane as before.
private struct CaptureTrackView: View {
    let items: [CaptureTrackItem]
    let blockSelection: ActivityBlock.ID?
    let selectedMeetingIDs: Set<Meeting.ID>
    let onSelectBlock: (ActivityBlock.ID?) -> Void
    let onSelectMeeting: (Meeting.ID) -> Void

    private let pointsPerHour: CGFloat = 100
    private let gutter: CGFloat = 56

    private var hasMeetings: Bool {
        items.contains { if case .meeting = $0 { true } else { false } }
    }

    var body: some View {
        let start = trackStart
        let hours = hourCount(from: start)
        let height = CGFloat(hours) * pointsPerHour
        ScrollView {
            GeometryReader { geo in
                let laneWidth = max(40, geo.size.width - gutter)
                let meetingLane = hasMeetings ? max(96, laneWidth * 0.28) : 0
                let activityX = gutter + (meetingLane > 0 ? meetingLane + 6 : 0)
                let activityWidth = max(40, laneWidth - (meetingLane > 0 ? meetingLane + 6 : 0))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(0..<hours), id: \.self) { i in
                        let y = CGFloat(i) * pointsPerHour
                        Rectangle().fill(.quaternary.opacity(0.4))
                            .frame(width: laneWidth, height: 1)
                            .offset(x: gutter, y: y)
                        Text(hourLabel(start, i))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: y - 6)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .activity(let block):
                            activityView(block, start: start, x: activityX, width: activityWidth)
                        case .meeting(let meeting, let end):
                            meetingView(meeting, end: end, start: start,
                                        x: gutter, width: max(96, meetingLane))
                        }
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }

    @ViewBuilder
    private func activityView(_ block: ActivityBlock, start: Date,
                              x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(block.start.timeIntervalSince(start) / 3600) * pointsPerHour
        let h = max(5, CGFloat(block.duration / 3600) * pointsPerHour)
        let isSelected = blockSelection == block.id
        RoundedRectangle(cornerRadius: 4)
            .fill(CaptureStyle.color(for: block.app).opacity(isSelected ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                if h >= 20 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.app).font(.caption.weight(.medium)).lineLimit(1)
                        if !block.title.isEmpty && h >= 38 {
                            Text(block.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: width, height: h, alignment: .topLeading)
            .offset(x: x, y: y)
            .help("\(block.app)\(block.title.isEmpty ? "" : " — \(block.title)")\n\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))")
            .onTapGesture { onSelectBlock(isSelected ? nil : block.id) }
    }

    @ViewBuilder
    private func meetingView(_ meeting: Meeting, end: Date, start: Date,
                             x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(meeting.startedAt.timeIntervalSince(start) / 3600) * pointsPerHour
        let duration = end.timeIntervalSince(meeting.startedAt)
        let h = max(24, CGFloat(duration / 3600) * pointsPerHour)
        let isSelected = selectedMeetingIDs == [meeting.id]
        RoundedRectangle(cornerRadius: 4)
            .fill(Brand.teal.opacity(isSelected ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.caption2)
                        Text(meeting.title).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    if h >= 38 {
                        Text(meeting.durationLabel).font(.caption2).opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.top, 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: width, height: h, alignment: .topLeading)
            .offset(x: x, y: y)
            .help("\(meeting.title)\n\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(meeting.durationLabel)")
            .onTapGesture { onSelectMeeting(meeting.id) }
            .accessibilityIdentifier("capture.meeting.\(meeting.id.uuidString)")
    }

    private var trackStart: Date {
        let first = items.first?.start ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateInterval(of: .hour, for: first)?.start ?? first
    }

    private func hourCount(from start: Date) -> Int {
        let last = items.map(\.end).max() ?? start.addingTimeInterval(3600)
        return max(1, Int(ceil(last.timeIntervalSince(start) / 3600)))
    }

    private func hourLabel(_ start: Date, _ i: Int) -> String {
        start.addingTimeInterval(Double(i) * 3600).formatted(date: .omitted, time: .shortened)
    }
}
```

- [ ] **Step 2: Create `LokalBot/Views/CaptureDetailView.swift`**

```swift
import SwiftUI
import AppKit

/// The Capture detail pane — a selection-driven inspector (spec §2.2): a
/// selected meeting opens the unchanged `MeetingDetailView`, a selected
/// activity block gets its card + per-app context + block-scoped
/// screenshots, and no selection shows the day overview (stat tiles,
/// per-app proportion bar + totals, digest) in Day scope or the
/// getting-started card in Library scope.
struct CaptureDetailView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    @Binding var pendingDelete: Set<Meeting.ID>?

    var body: some View {
        switch CaptureInspectorState.resolve(meetingIDs: app.selectedMeetingIDs,
                                             blockSelection: model.selection) {
        case .meeting:
            if let meeting = app.selectedMeeting {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                noSelection
            }
        case .multiSelection(let count):
            ContentUnavailableView {
                Label("\(count) meetings selected", systemImage: "checklist")
            } description: {
                Text("Press ⌫ or right-click to delete them.")
            } actions: {
                Button("Delete \(count) meetings", role: .destructive) {
                    pendingDelete = app.selectedMeetingIDs
                }
            }
        case .block:
            if let block = model.selectedBlock {
                blockDetail(block)
            } else {
                noSelection
            }
        case .overview:
            noSelection
        }
    }

    /// Library keeps the getting-started card as its empty state (it is the
    /// new-user landing surface); Day shows the day overview.
    @ViewBuilder private var noSelection: some View {
        if (app.captureScope ?? .library) == .day {
            dayOverview
        } else {
            GettingStartedCard()
        }
    }

    // MARK: - Day overview (absorbs the old Totals + Digest tabs)

    private var dayOverview: some View {
        let meetings = model.meetings(in: app)
        let perApp = Dictionary(grouping: model.blocks, by: \.app)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Day overview").font(.title3.bold())
                HStack(spacing: 8) {
                    StatTile(icon: "clock",
                             value: CaptureStyle.hm(perApp.reduce(0) { $0 + $1.value }),
                             label: "tracked")
                    StatTile(icon: "square.grid.2x2", value: "\(perApp.count)",
                             label: perApp.count == 1 ? "app" : "apps")
                    StatTile(icon: "camera.viewfinder", value: "\(model.shots.count)",
                             label: "screens")
                    if !meetings.isEmpty {
                        StatTile(icon: "waveform", value: "\(meetings.count)",
                                 label: meetings.count == 1 ? "meeting" : "meetings")
                    }
                }
                if !perApp.isEmpty {
                    totalsSection(perApp)
                }
                Button {
                    app.openAsk(dayScope: model.day)
                } label: {
                    Label("Ask about this day", systemImage: "sparkle.magnifyingglass")
                }
                .accessibilityIdentifier("capture.askDay")
                Divider()
                digestSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func totalsSection(_ perApp: [(key: String, value: TimeInterval)]) -> some View {
        let total = perApp.reduce(0) { $0 + $1.value }
        let segments = ProportionBarMath.segments(
            perApp: perApp.map { (label: $0.key, seconds: $0.value) })
        let top = perApp.prefix(12)
        let rest = perApp.dropFirst(12)
        let restSeconds = rest.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Time by app — \(CaptureStyle.hm(total)) tracked").font(.headline)
            ProportionBar(segments: segments.map {
                ($0, $0.label == "Other" ? Color(nsColor: .tertiaryLabelColor)
                                         : CaptureStyle.color(for: $0.label))
            })
            .padding(.vertical, 2)
            ForEach(top, id: \.key) { appName, seconds in
                totalsRow(CaptureStyle.color(for: appName), appName, seconds, of: total)
            }
            if !rest.isEmpty {
                totalsRow(Color(nsColor: .tertiaryLabelColor),
                          "Other (\(rest.count) app\(rest.count == 1 ? "" : "s"))",
                          restSeconds, of: total)
            }
        }
    }

    private func totalsRow(_ swatch: Color, _ label: String, _ seconds: TimeInterval,
                           of total: TimeInterval) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: swatch, size: 9)
            Text(label).font(.body).lineLimit(1)
            Spacer()
            Text(CaptureStyle.hm(seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(String(format: "%2.0f%%", seconds / max(total, 1) * 100))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Day digest").font(.headline)
                if model.generating { ProgressView().controlSize(.small) }
                Spacer()
                if let digest = model.digest {
                    Button { model.copyDigest(digest) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy the digest to the clipboard")
                    Button { model.exportDigest(digest) } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Save the digest as a Markdown file")
                }
            }
            Button(model.digest == nil ? "Generate digest" : "Regenerate") {
                Task { await model.generateDigest(app: app) }
            }
            .disabled(model.generating)
            if let digestError = model.digestError {
                Label(digestError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let digest = model.digest {
                MarkdownText(digest)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Activity block detail (card + per-app context + screenshots)

    private func blockDetail(_ block: ActivityBlock) -> some View {
        let scoped = model.shots.filter { $0.ts >= block.start && $0.ts <= block.end }
        let sameApp = model.blocks.filter { $0.app == block.app }
        let appTotal = sameApp.reduce(0) { $0 + $1.duration }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                blockCard(block)
                HStack(spacing: 8) {
                    StatTile(icon: "clock", value: CaptureStyle.hm(appTotal),
                             label: "in \(block.app) today")
                    StatTile(icon: "rectangle.stack", value: "\(sameApp.count)",
                             label: sameApp.count == 1 ? "block" : "blocks")
                }
                Text("Screenshots (\(scoped.count))").font(.headline)
                if scoped.isEmpty {
                    Text("None during this block.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(scoped) { shot in
                            ThumbnailView(path: shot.path)
                                .help("\(shot.app) — \(shot.ts.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func blockCard(_ block: ActivityBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: CaptureStyle.color(for: block.app), size: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.app).font(.subheadline.weight(.semibold))
                if !block.title.isEmpty {
                    Text(block.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { model.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear selection")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }
}

/// Decoded-thumbnail cache, keyed by encrypted-file path. Decoding a HEIC and
/// AES-opening it is not free; caching means each screenshot is decrypted once
/// per session no matter how often the grid is rebuilt or scrolled.
private enum ThumbnailCache {
    static let shared = NSCache<NSString, NSImage>()
}

/// One screenshot thumbnail: decrypts off the main actor on first appearance,
/// caches the result, and shows a placeholder until it's ready. Combined with
/// `LazyVGrid`, only on-screen thumbnails are ever decoded.
private struct ThumbnailView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.object(forKey: path as NSString) {
            image = cached
            return
        }
        guard let key = try? ScreenshotService.encryptionKey() else { return }
        let filePath = path
        let data = await Task.detached(priority: .utility) {
            ScreenshotService.decryptedData(path: filePath, key: key)
        }.value
        guard let data, let decoded = NSImage(data: data) else { return }
        ThumbnailCache.shared.setObject(decoded, forKey: path as NSString)
        image = decoded
    }
}
```

- [ ] **Step 3: Delete `LokalBot/Views/TimelineView.swift`**

```bash
git rm LokalBot/Views/TimelineView.swift
```

- [ ] **Step 4: Rewire `MainWindowView.swift`**

4a. Replace the `@StateObject` (line 9-10):

```swift
    /// Shared by the Capture section's two columns (content ↔ detail).
    @StateObject private var capture = CaptureModel()
```

4b. Replace the whole `navigation` builder:

```swift
    /// Master/detail sections (Capture, Ask) use the native three-column
    /// split; single-surface sections (forms) use two.
    @ViewBuilder private var navigation: some View {
        if app.navSection == .capture {
            NavigationSplitView {
                sidebar
            } content: {
                CaptureContentView(model: capture, pendingDelete: $pendingDelete)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } detail: {
                CaptureDetailView(model: capture, pendingDelete: $pendingDelete)
            }
        } else if app.navSection == .type {
            NavigationSplitView {
                sidebar
            } detail: {
                TypeView()
            }
        } else if app.navSection == .ask {
            NavigationSplitView {
                sidebar
            } content: {
                ChatConversationList()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                AskView()
            }
        } else if app.navSection == .models {
            NavigationSplitView {
                sidebar
            } detail: {
                ModelsView()
            }
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                SettingsView()
            }
        }
    }
```

4c. Replace the sidebar "Library" section (Meetings + Timeline rows collapse into Capture):

```swift
            Section("Library") {
                Label("Capture", systemImage: "waveform.circle")
                    .tag(AppState.NavSection.capture)
                    .accessibilityIdentifier("sidebar.capture")
                Label("Ask", systemImage: "sparkle.magnifyingglass")
                    .tag(AppState.NavSection.ask)
                    .accessibilityIdentifier("sidebar.ask")
            }
```

4d. Delete the `detailPane` builder entirely (its meeting/multi-select/getting-started logic now lives in `CaptureDetailView`).

4e. Update the selection fallback:

```swift
    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(get: { app.navSection }, set: { app.navSection = $0 ?? .capture })
    }
```

4f. In `GettingStartedCard` (same file, ~line 848), replace the day-tracking button action:

```swift
                            Button("Turn on day tracking") {
                                app.captureScope = .day
                                app.navSection = .capture
                            }
```

- [ ] **Step 5: Finish the NavSection migration in `LokalBotApp.swift`**

5a. The enum loses its legacy cases and the interim comment:

```swift
    enum NavSection: Hashable {
        case capture, type, ask, models, settings

        /// Section names accepted from the UI-test capture environment and
        /// deep links. Legacy pre-merge names keep working: "meetings" and
        /// "timeline" land on the merged Capture section, "dictation" and
        /// "cotyping" on Type, "search"/"chat" on Ask (spec §2.1).
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "capture", "meetings", "timeline": self = .capture
            case "type", "dictation", "cotyping": self = .type
            case "ask", "search", "chat": self = .ask
            case "models": self = .models
            case "settings": self = .settings
            default: return nil
            }
        }
    }
```

5b. Default section (line ~185): `@Published var navSection: NavSection = .capture`

5c. Compile-error sweep: `grep -rn "\.meetings\b\|\.timeline\b" LokalBot/ --include="*.swift"` — the remaining producers are `CommandPaletteView.swift` (3 sites) and `MenuBarView.swift` (1 site). Fix them minimally here so the build is green (Task 8 finishes the palette UX):
  - `CommandPaletteView.swift:72` (`nav.meetings` action) → `app.navSection = .capture`
  - `CommandPaletteView.swift:76` (`nav.timeline` action) → `{ app.captureScope = .day; app.navSection = .capture }`
  - `CommandPaletteView.swift:99` (recent-meeting row) → `app.openMeeting(meeting.id)` (replaces both the `navSection` and `selectedMeetingIDs` lines)
  - `MenuBarView.swift:215` (recent row) → `app.openMeeting(meeting.id)` (replaces both lines; keep `WindowAccess.shared.open("main")`)

- [ ] **Step 6: Build + run the full unit suite**

```bash
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
```
Expected: PASS. If the build surfaces stale references to `TimelineModel`/`TimelineDayView`/`TimelineInspectorView`/`TimelineStyle`, they were missed in Step 4 — fix them there, do not reintroduce the types.

- [ ] **Step 7: Commit**

```bash
git checkout -- default.profraw
git add -A LokalBot/Views/ LokalBot/LokalBotApp.swift
git commit -m "Merge Meetings and Timeline into the Capture section"
```

---

### Task 7: Ask day-scope chip

**Files:**
- Modify: `LokalBot/Views/AskView.swift` (`facetRow` ~line 97, `escalate()` ~line 148)

**Interfaces:**
- Consumes: `app.askDayScope: Date?` (Task 4), `chipChrome()` (DesignSystem).
- Produces: a removable `ask.dayScope` chip; escalated queries carry the day so the agent's existing `activity_summary` tool (which accepts a date) scopes the answer. No ChatAgent/ChatViewModel changes.

- [ ] **Step 1: Add the chip to `facetRow`**

Insert before the `Spacer()` in `facetRow`:

```swift
            if let day = app.askDayScope {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                    Button { app.askDayScope = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear day scope")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .chipChrome()
                .help("Questions sent to the assistant are scoped to this day.")
                .accessibilityIdentifier("ask.dayScope")
            }
```

- [ ] **Step 2: Scope escalated queries**

Replace `escalate()`:

```swift
    /// ↵ or the pinned row: hand the query to the assistant and switch the
    /// pane to the conversation (the send appends messages, which flips the
    /// router to `.conversation`; clearing the query keeps it there). A day
    /// scope from Capture is prepended so the agent reaches for its
    /// activity-summary tool with the right date.
    private func escalate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isResponding else { return }
        if let day = app.askDayScope {
            model.send("About my day on \(day.formatted(date: .long, time: .omitted)): \(q)")
        } else {
            model.send(q)
        }
        query = ""
    }
```

- [ ] **Step 3: Build + targeted tests**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test -only-testing:LokalBotTests/AskRoutingTests
```
Expected: PASS (routing untouched; this verifies the file still compiles into the suite).

- [ ] **Step 4: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Views/AskView.swift
git commit -m "Add day-scope chip to Ask for Capture handoff"
```

---

### Task 8: Command palette Capture rows

**Files:**
- Modify: `LokalBot/Views/CommandPaletteView.swift` (~lines 72-77)

**Interfaces:**
- Consumes: `app.openMeeting(_:)`, `app.captureScope` (Task 4). Step 5c of Task 6 already made these sites compile; this task finalizes ids/titles.

- [ ] **Step 1: Rename the palette rows to the new IA**

Replace the two Library nav items (previously `nav.meetings` / `nav.timeline`):

```swift
            .init(id: "nav.capture", icon: "waveform.circle", title: "Go to Capture",
                  subtitle: "Library", action: { app.navSection = .capture }),
            .init(id: "nav.ask", icon: "sparkle.magnifyingglass", title: "Go to Ask",
                  subtitle: "Library", action: { app.openAsk() }),
            .init(id: "nav.capture.day", icon: "calendar.day.timeline.left", title: "Go to Day timeline",
                  subtitle: "Library", action: {
                app.captureScope = .day
                app.navSection = .capture
            }),
```

(Keep the recent-meeting rows on `app.openMeeting(meeting.id)` from Task 6 Step 5c.)

- [ ] **Step 2: Build + full unit suite**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git checkout -- default.profraw
git add LokalBot/Views/CommandPaletteView.swift
git commit -m "Point command palette navigation at the Capture section"
```

---

### Task 9: UI-test migration

**Files:**
- Modify: `LokalBotUITests/MainWindowUITests.swift`
- Modify: `LokalBotUITests/SettingsAndTimelineUITests.swift` (the `TimelineEmptyStateUITests` class)
- Modify: `LokalBotUITests/CotypingSettingsUITests.swift` (~line 155)

**Interfaces:**
- Consumes: `sidebar.capture`, `capture.scope` (segmented Day/Library), `timeline.track` (unchanged), `meeting.list`/`meeting.row.*` (unchanged), `capture.meeting.<uuid>`. Fixture facts: `SyntheticFixture.plant()` seeds activity blocks for **today** (Xcode block titled "TimelineView.swift" at 9:00–10:30) plus designReview/standup today and planning yesterday; `plant(includeActivity: false)` seeds meetings only → Capture defaults to Library.

- [ ] **Step 1: `MainWindowUITests` — setUp + Library helper**

1a. The launch wait can no longer expect `meeting.list` (activity is seeded, so Capture defaults to Day). Replace the setUp assertion:

```swift
        // Wait until the main window has rendered the Capture scope control —
        // every test starts from a known surface, otherwise XCUITest races
        // the initial `loadMeetings()` + reindex sweep. (With seeded activity
        // the default scope is Day, so the meeting list is NOT on screen yet.)
        XCTAssertTrue(app.descendants(matching: .any)["capture.scope"]
            .waitForExistence(timeout: 10), "capture scope control never rendered")
```

1b. Add a helper next to `clickSidebar`:

```swift
    /// Switch Capture to Library scope and wait for the meeting list —
    /// the precondition for every list/detail/delete test.
    private func openLibrary() {
        clickSidebar("sidebar.capture")
        let picker = app.descendants(matching: .any)["capture.scope"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "capture scope control missing")
        let segment = picker.buttons["Library"].exists
            ? picker.buttons["Library"] : picker.radioButtons["Library"]
        segment.click()
        XCTAssertTrue(app.outlines["meeting.list"].waitForExistence(timeout: 4),
                      "meeting list did not render in Library scope")
    }
```

1c. Prepend `openLibrary()` as the first line of every test that reads `meeting.list` or calls `selectMeeting`/`selectTwo` (find them with `grep -n "meeting.list\|selectMeeting\|selectTwo" LokalBotUITests/MainWindowUITests.swift`): `testMeetingListRendersAllSyntheticMeetings`, `testMeetingDetailTabsLoadSummaryAndTranscript`, and the delete/multi-select tests.

1d. `testSidebarNavigationSwitchesSections`: replace the final stanza:

```swift
        clickSidebar("sidebar.capture")
        XCTAssertTrue(app.descendants(matching: .any)["capture.scope"]
            .waitForExistence(timeout: 4),
                      "capture section did not come back")
```

1e. Replace `testTimelineRendersActivityTrackAndInspector` with:

```swift
    /// Capture's Day scope renders the merged surface from the seeded
    /// `activity_blocks` + meetings: the hour track (with a seeded block
    /// title and a meeting block in the teal lane) on the left, and the day
    /// overview's per-app totals in the detail pane — the old inspector's
    /// four-tab control is gone (spec §2.2).
    func testCaptureDayRendersTrackAndOverview() {
        clickSidebar("sidebar.capture")
        // Seeded activity → the scope policy defaults to Day.
        XCTAssertTrue(textWithContent("Time by app").firstMatch.waitForExistence(timeout: 6),
                      "day-overview totals headline missing — seeded activity did not load")
        XCTAssertTrue(textWithContent("Xcode").firstMatch.exists,
                      "seeded activity app 'Xcode' missing from Capture")
        XCTAssertFalse(textWithContent("No activity recorded").firstMatch.exists,
                       "empty state shown despite seeded activity blocks")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"].exists,
                      "hour track identifier missing")
        // The block *title* renders only inside the hour track (totals rows
        // show app names, never titles), so this pins down the track itself.
        XCTAssertTrue(textWithContent("TimelineView.swift").firstMatch.exists,
                      "seeded block title missing from the hour track")
        // Meetings are first-class track blocks now (spec §2.2).
        XCTAssertTrue(app.descendants(matching: .any)["capture.meeting.\(fixture.designReview.id.uuidString)"].exists,
                      "seeded meeting block missing from the track's meeting lane")
        // The four-tab inspector is gone.
        XCTAssertFalse(app.descendants(matching: .any)["timeline.inspector"].exists,
                       "legacy inspector segmented control should be removed")
    }
```

1f. Add the new scope-toggle test (spec §6):

```swift
    /// The Day⇄Library scope control swaps the Capture content column both
    /// ways: Day shows the hour track, Library shows the grouped meeting
    /// list (spec §6: "Capture Day⇄Library toggle").
    func testCaptureScopeTogglesBetweenDayAndLibrary() {
        clickSidebar("sidebar.capture")
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 6), "Day scope should be the default with seeded activity")

        openLibrary()
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "hour track should leave the screen in Library scope")

        let picker = app.descendants(matching: .any)["capture.scope"]
        let daySegment = picker.buttons["Day"].exists
            ? picker.buttons["Day"] : picker.radioButtons["Day"]
        daySegment.click()
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 4), "hour track did not come back in Day scope")
    }
```

- [ ] **Step 2: `TimelineEmptyStateUITests` → Capture default-scope test**

Replace the test method (setUp already waits on `meeting.list`, which is now the *assertion* that Library is the no-activity default):

```swift
    /// With no activity blocks seeded, Capture defaults to Library scope
    /// (spec open question 2 — resolved yes): the meeting list is the launch
    /// surface and no phantom track renders. Switching to Day still shows
    /// the seeded meetings as first-class track blocks (spec §2.2) rather
    /// than the empty state.
    func testCaptureWithoutActivityDefaultsToLibrary() {
        XCTAssertTrue(app.outlines["meeting.list"].exists,
                      "Library scope (meeting list) should be the no-activity default")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.track"].exists,
                       "activity track should not render in Library scope")

        let picker = app.descendants(matching: .any)["capture.scope"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "capture scope control missing")
        let daySegment = picker.buttons["Day"].exists
            ? picker.buttons["Day"] : picker.radioButtons["Day"]
        daySegment.click()

        // Meetings alone still populate the day track (meetings-as-blocks).
        XCTAssertTrue(app.descendants(matching: .any)["timeline.track"]
            .waitForExistence(timeout: 6),
                      "day track with meeting blocks missing")
        XCTAssertFalse(UITestHarness.staticText(containing: "No activity recorded", in: app).exists,
                       "empty state shown despite seeded meetings in the track")
    }
```

Also update the class doc comment to describe Capture, and remove the old `testTimelineEmptyStateDoesNotRenderPopulatedTrackOrInspector` (this replaces it). Rename the class to `CaptureDefaultScopeUITests` and update its `suitePrefix` string to `"CaptureDefaultScope"`.

- [ ] **Step 3: `CotypingSettingsUITests` (~line 155)**

In `testTypeTabPersistsAcrossNavigation`, replace the Meetings hop:

```swift
        UITestHarness.clickSidebar("sidebar.capture", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["capture.scope"].waitForExistence(timeout: 6),
                      "capture section did not render")
```

- [ ] **Step 4: Stale-selector sweep**

```bash
grep -rn "sidebar.meetings\|sidebar.timeline\|timeline.inspector" LokalBotUITests/
```
Expected: no hits (except comments updated or removed).

- [ ] **Step 5: Run the touched UI test classes**

```bash
Scripts/test/ui-tests.sh MainWindowUITests
Scripts/test/ui-tests.sh CaptureDefaultScopeUITests
Scripts/test/ui-tests.sh CotypingSettingsUITests/testTypeTabPersistsAcrossNavigation
```
Expected: PASS. (Machine must stay awake; a 40+ minute duration in the xcresult means sleep, not a real failure — re-run.)

- [ ] **Step 6: Commit**

```bash
git checkout -- default.profraw
git add LokalBotUITests/
git commit -m "Migrate UI tests to the Capture section"
```

---

### Task 10: Full verification + ledger

- [ ] **Step 1: Full unit suite**

```bash
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' test
```
Expected: PASS (~640 tests).

- [ ] **Step 2: Full UI suite**

```bash
Scripts/test/ui-tests.sh
```
Expected: PASS, except the known pre-existing `SettingsUITests.testPermissionRepairPaneRendersCorePermissions` (fails on master; not gating).

- [ ] **Step 3: Whole-branch review**

- `git diff redesign-phase2...HEAD --stat` — confirm scope: Models/, Support/ProportionBar, Views/{Capture*,MeetingListView,MainWindow,Ask,CommandPalette,MenuBar}, LokalBotApp, tests only.
- `grep -rn "navSection = .meetings\|navSection = .timeline\|NavSection.meetings\|NavSection.timeline" LokalBot/` — expect zero hits.
- Confirm preserved ids: `meeting.list`, `meeting.row.`, `timeline.track`, `search.hit.`, `chat.new` still present in sources.

- [ ] **Step 4: Restore profraw, ledger, commit any review fixes**

```bash
git checkout -- default.profraw
```
Append to `.superpowers/sdd/progress.md`: Phase 3 tasks 1-10 complete with commit ranges.

- [ ] **Step 5: Finish the branch**

Use superpowers:finishing-a-development-branch. Per Phase 1/2 precedent: push `redesign-phase3` and open a PR targeting `redesign-phase2`.
