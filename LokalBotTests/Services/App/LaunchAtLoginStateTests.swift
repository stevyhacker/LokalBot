import XCTest
@testable import LokalBot

@MainActor
final class LaunchAtLoginStateTests: XCTestCase {
    /// SwiftUI reads the toggle's value on every update; none of those reads
    /// may reach the service-management daemon.
    func testReadingTheValueNeverAsksTheSystem() async {
        let system = FakeLoginItem(enabled: true)
        let state = LaunchAtLoginState(read: system.read, write: system.write)
        for _ in 0..<100 { _ = state.isEnabled }
        XCTAssertEqual(system.reads, 0)

        state.refresh()
        await state.settle()
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(system.reads, 1)
    }

    func testTogglesApplyInOrderAndPublishTheRegisteredValue() async {
        let system = FakeLoginItem(enabled: false)
        let state = LaunchAtLoginState(read: system.read, write: system.write)
        state.setEnabled(true)
        XCTAssertTrue(state.isEnabled)
        state.setEnabled(false)
        state.setEnabled(true)
        await state.settle()
        XCTAssertEqual(system.writes, [true, false, true])
        XCTAssertTrue(state.isEnabled)
    }

    func testRejectedRegistrationTurnsTheToggleBackOff() async {
        let system = FakeLoginItem(enabled: false, rejectsWrites: true)
        let state = LaunchAtLoginState(read: system.read, write: system.write)
        state.setEnabled(true)
        await state.settle()
        XCTAssertFalse(state.isEnabled)
    }
}

private final class FakeLoginItem: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private let rejectsWrites: Bool
    private var readCount = 0
    private var writeLog: [Bool] = []

    init(enabled: Bool, rejectsWrites: Bool = false) {
        self.enabled = enabled
        self.rejectsWrites = rejectsWrites
    }

    var reads: Int { lock.withLock { readCount } }
    var writes: [Bool] { lock.withLock { writeLog } }

    var read: @Sendable () -> Bool {
        { [self] in lock.withLock { readCount += 1; return enabled } }
    }

    var write: @Sendable (Bool) -> Void {
        { [self] value in
            lock.withLock {
                writeLog.append(value)
                if !rejectsWrites { enabled = value }
            }
        }
    }
}
