import XCTest
@testable import LokalBot

final class LokalBotTestObservation: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        testCase.addTeardownBlock {
            for name in UITestRuntime.takeRefusedUnitTestDownloads() {
                XCTFail("""
                    A unit test started downloading \(name): this test, or background work \
                    an earlier test left running. Give EmbeddingIndex an embedder instead \
                    (AppState already uses EmbeddingIndex.unavailableEmbedder in unit tests).
                    """)
            }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        for name in UITestRuntime.takeRefusedUnitTestDownloads() {
            print("error: a unit test started downloading \(name) after the last test finished")
        }
    }
}
