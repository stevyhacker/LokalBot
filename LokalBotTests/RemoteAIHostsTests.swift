import XCTest
@testable import LokalBot

/// The sidebar's privacy summary lists every server AI content goes to.
final class RemoteAIHostsTests: XCTestCase {
    func testAutocompleteOnAServerIsNotOnThisMac() {
        var settings = AppSettings()
        settings.summarizerBackend = .builtIn
        XCTAssertEqual(settings.remoteAIHosts, [], "everything on this Mac")

        settings.cotypingEnabled = true
        settings.cotypingBackend = .server
        settings.cotypingServerBaseURL = "https://complete.example.com/v1"
        XCTAssertEqual(settings.remoteAIHosts, ["complete.example.com"],
                       "typing goes to the autocomplete server while Think stays local")

        settings.cotypingEnabled = false
        XCTAssertEqual(settings.remoteAIHosts, [], "nothing is sent while autocomplete is off")

        settings.cotypingEnabled = true
        settings.cotypingServerBaseURL = "http://127.0.0.1:8080/v1"
        XCTAssertEqual(settings.remoteAIHosts, [], "a server on this Mac is on this Mac")
        settings.cotypingServerBaseURL = ""
        XCTAssertEqual(settings.remoteAIHosts, [], "no server set up yet")
    }

    func testEachServerIsNamedOnce() {
        var settings = AppSettings()
        settings.summarizerBackend = .openAICompatible
        settings.openAIBaseURL = "https://models.example.com/v1"
        settings.approvedRemoteInferenceOrigins = ["https://models.example.com"]
        settings.cotypingEnabled = true
        settings.cotypingBackend = .thinkServer
        XCTAssertEqual(settings.remoteAIHosts, ["models.example.com"])
    }
}
