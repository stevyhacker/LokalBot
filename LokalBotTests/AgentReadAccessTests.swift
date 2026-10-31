import XCTest
@testable import LokalBot

/// The one switch for reading LokalBot data and its boxes: it writes and
/// removes the per-kind markers agents check, remembers the boxes while off,
/// and never widens a grant made before it existed.
@MainActor
final class AgentReadAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("read-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("LOKALBOT_STORAGE_ROOT", root.path, 1)
    }

    override func tearDown() {
        unsetenv("LOKALBOT_STORAGE_ROOT")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testOffByDefaultAndTurningOnGrantsOnlyMeetings() {
        let access = makeAccess()
        XCTAssertFalse(access.isEnabled)
        XCTAssertTrue(access.isTicked(.meetings), "the first time, Meetings is ticked")
        XCTAssertFalse(access.isTicked(.files))

        access.setEnabled(true)

        XCTAssertTrue(access.isEnabled)
        XCTAssertEqual(access.granted, [.meetings])
        XCTAssertTrue(AgentAccessGate(root: root).isEnabled)
        XCTAssertFalse(ScreenMemoryAccessGate(root: root).isEnabled)
        XCTAssertFalse(PersonalContextAccessGate(root: root).isEnabled)
        XCTAssertFalse(FilesAccessGate(root: root).isEnabled)
    }

    func testTurningOffRemovesEveryGrantAndTurningOnRestoresTheBoxes() {
        let access = makeAccess()
        access.setEnabled(true)
        access.setTicked(.screenMemory, true)
        access.setScreenScope(.today)
        access.setTicked(.files, true)
        XCTAssertEqual(access.granted, [.meetings, .screenMemory, .files])

        access.setEnabled(false)

        XCTAssertEqual(access.granted, [])
        for marker in [AgentAccessGate(root: root).accessMarkerURL, ScreenMemoryAccessGate(root: root).accessMarkerURL,
                       FilesAccessGate(root: root).accessMarkerURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), marker.lastPathComponent)
        }
        XCTAssertTrue(access.isTicked(.files), "the boxes are remembered")

        let later = makeAccess()   // a relaunch reads the remembered boxes
        later.setEnabled(true)
        XCTAssertEqual(later.granted, [.meetings, .screenMemory, .files])
        XCTAssertEqual(ScreenMemoryAccessGate(root: root).profile.scope, .today)
    }

    func testGrantsFromBeforeTheSwitchShowAsTheyAreAndFilesStaysOff() throws {
        try AgentAccessGate(root: root).enable()
        try ScreenMemoryAccessGate(root: root).enable(profile: .init(scope: .retainedHistory))

        let access = makeAccess()

        XCTAssertTrue(access.isEnabled)
        XCTAssertEqual(access.granted, [.meetings, .screenMemory])
        XCTAssertFalse(access.isTicked(.files))
        XCTAssertFalse(access.isTicked(.personalContext))
        XCTAssertEqual(access.screenScope, .retainedHistory)
    }

    func testTheLastBoxCannotBeUntickedButTheSwitchTurnsEverythingOff() {
        let access = makeAccess()
        access.setEnabled(true)
        XCTAssertFalse(access.canUntick(.meetings))
        access.setTicked(.meetings, false)
        XCTAssertEqual(access.granted, [.meetings])

        access.setTicked(.personalContext, true)
        XCTAssertTrue(access.canUntick(.meetings))
        access.setTicked(.meetings, false)
        XCTAssertEqual(access.granted, [.personalContext])
    }

    func testTickingWhileOffOnlyChangesWhatTurningOnGrants() {
        let access = makeAccess()
        access.setTicked(.files, true)
        access.setTicked(.meetings, false)
        XCTAssertFalse(access.isEnabled)
        XCTAssertFalse(FilesAccessGate(root: root).isEnabled)

        access.setEnabled(true)
        XCTAssertEqual(access.granted, [.files])
    }

    private func makeAccess() -> AgentReadAccess {
        let meetings = AgentAccessManager(storage: StorageManager(), settings: { AppSettings() },
                                          gate: AgentAccessGate(root: root), startEngine: { _, _ in nil })
        let screen = ScreenMemoryAccessManager(gate: ScreenMemoryAccessGate(root: root))
        let personal = PersonalContextAccessManager(gate: PersonalContextAccessGate(root: root), claims: { [] })
        let files = FilesAccessManager(gate: FilesAccessGate(root: root), folders: { ["/tmp"] })
        for start in [meetings.start, screen.start, personal.start, files.start] { start() }
        return AgentReadAccess(meetings: meetings, screenMemory: screen, personalContext: personal, files: files,
                               root: root)
    }
}
