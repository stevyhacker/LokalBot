import XCTest
@testable import LokalBot

final class ScreenRewindStateTests: XCTestCase {
    func testThumbnailSizingUsesStableBoundedBuckets() {
        XCTAssertEqual(ScreenThumbnailSizing.maxPixelSize(forHeight: 42), 256)
        XCTAssertEqual(ScreenThumbnailSizing.maxPixelSize(forHeight: 84), 512)
        XCTAssertEqual(ScreenThumbnailSizing.maxPixelSize(forHeight: 150), 1_024)
        XCTAssertEqual(ScreenThumbnailSizing.maxPixelSize(forHeight: 320), 1_600)
    }

    func testAdjacentNearDuplicatesCollapseToNewestRepresentative() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let shots = [
            shot(id: 1, at: base, group: 1),
            shot(id: 2, at: base.addingTimeInterval(5), group: 1),
            shot(id: 3, at: base.addingTimeInterval(10), group: 3),
        ]

        let frames = ScreenRewindSequence.frames(from: shots)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].screenshot.id, 2)
        XCTAssertEqual(frames[0].duplicateCount, 2)
        XCTAssertEqual(frames[1].screenshot.id, 3)
    }

    func testRangeNormalizesReverseSelectionAndIncludesGroupedCaptures() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let frames = ScreenRewindSequence.frames(from: [
            shot(id: 1, at: base, group: 1),
            shot(id: 2, at: base.addingTimeInterval(5), group: 1),
            shot(id: 3, at: base.addingTimeInterval(10), group: 3),
        ])

        let interval = try XCTUnwrap(ScreenRewindSequence.deletionInterval(
            frames: frames, firstIndex: 1, lastIndex: 0))
        XCTAssertEqual(interval.start, base)
        XCTAssertGreaterThan(interval.end, base.addingTimeInterval(10))
        XCTAssertEqual(ScreenRewindSequence.captureCount(
            frames: frames, firstIndex: 1, lastIndex: 0), 3)
    }

    private func shot(id: Int64, at date: Date, group: Int64?) -> ActivityStore.Screenshot {
        ActivityStore.Screenshot(
            id: id, ts: date, path: "/tmp/\(id).enc", app: "Xcode",
            perceptualHash: UInt64(id), similarityGroupID: group)
    }
}
