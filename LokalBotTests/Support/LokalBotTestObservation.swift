import XCTest
@testable import LokalBot

/// The test bundle's principal class (`NSPrincipalClass` in project.yml), so
/// XCTest creates it before the first test runs.
///
/// Unit tests share the app's code but must stay off the network. A model
/// download a test reaches is refused (`UITestRuntime.refuseDownloadInUnitTests`)
/// and fails that test here. Background work can outlive the test that started
/// it, so a refusal can also surface in the next test to finish.
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
