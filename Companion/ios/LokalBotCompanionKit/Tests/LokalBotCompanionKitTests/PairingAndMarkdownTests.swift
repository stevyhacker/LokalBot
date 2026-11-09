import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Pairing payload")
struct PairingPayloadTests {
    static func link(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields)
        return "lokalbot://pair?d=" + Base64URL.encode(data)
    }

    static let key = Base64URL.encode(Data(repeating: 7, count: 32))
    static var valid: [String: Any] { [
        "v": 1, "macName": "Stevan's MacBook Pro", "macKey": key,
        "addrs": ["192.168.1.20", "100.101.102.103", "macbook.tail1234.ts.net"], "port": 17890,
        "pid": Base64URL.encode(Data(repeating: 1, count: 16)), "psk": Base64URL.encode(Data(repeating: 2, count: 32)),
        "exp": 1_793_440_000,
    ] }

    @Test func parsesALinkInsidePastedText() async throws {
        let payload = try PairingPayload.parse("Pair with: \(try Self.link(Self.valid)) (expires in 5 min)")
        #expect(payload.macName == "Stevan's MacBook Pro")
        #expect(payload.addresses.count == 3)
        #expect(payload.port == 17890)
        #expect(payload.expiresAt == Date(timeIntervalSince1970: 1_793_440_000))
        #expect(!payload.isExpired(at: Date(timeIntervalSince1970: 1_793_439_000)))
    }

    @Test func rejectsOtherTextAndBrokenLinks() async throws {
        #expect(throws: PairingPayload.ParseError.notAPairingLink) { try PairingPayload.parse("https://lokalbot.app") }
        #expect(throws: PairingPayload.ParseError.unreadable) { try PairingPayload.parse("lokalbot://pair?d=%%%") }
        var shortKey = Self.valid
        shortKey["macKey"] = Base64URL.encode(Data(repeating: 7, count: 16))
        #expect(throws: PairingPayload.ParseError.unreadable) { try PairingPayload.parse(try Self.link(shortKey)) }
        var future = Self.valid
        future["v"] = 2
        #expect(throws: PairingPayload.ParseError.unsupportedVersion(2)) { try PairingPayload.parse(try Self.link(future)) }
    }

    @Test func fingerprintIsTheFirst16HexOfSHA256() {
        // SHA-256 of 32 zero bytes starts 66687aadf862bd77.
        #expect(KeyFingerprint.fingerprint(publicKey: Data(count: 32)) == "66687aadf862bd77")
        #expect(KeyFingerprint.fingerprint(base64Key: Base64URL.encode(Data(count: 32))) == "66687aadf862bd77")
        #expect(KeyFingerprint.fingerprint(base64Key: Data(count: 32).base64EncodedString()) == "66687aadf862bd77")
    }
}

@Suite("Markdown")
struct MarkdownTests {
    @Test func blocks() {
        let document = MarkdownDocument("""
        ## Recap
        The team cut onboarding
        to three steps.

        - **You:** Send the deck
        - Ben: Simplify
          the import step
        1. First
        2) Second
        > Quoted
        """)
        #expect(document.blocks == [
            .heading(level: 2, text: "Recap"),
            .paragraph("The team cut onboarding to three steps."),
            .bullets(["**You:** Send the deck", "Ben: Simplify the import step"]),
            .numbered(["First", "Second"]),
            .quote("Quoted"),
        ])
    }

    @Test func recapIsTheRecapSection() async throws {
        let store = try FixtureStore.sampleLibrary()
        let meeting = try #require(await store.meeting(id: "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"))
        let recap = try #require(SummaryPresentation.recap(meeting.summaryMarkdown))
        #expect(recap.blocks.count == 1)
        guard case .paragraph(let text) = recap.blocks[0] else { Issue.record("paragraph"); return }
        #expect(text.hasPrefix("The team cut onboarding from five steps to three"))
    }

    @Test func recapWithoutHeadingDropsStructuredSections() {
        let recap = SummaryPresentation.recap("Short call.\n\n## Action items\n- Do it\n### Detail\n- more\n\n## Notes\nKeep this.")
        #expect(recap?.blocks == [.paragraph("Short call."), .heading(level: 2, text: "Notes"), .paragraph("Keep this.")])
        #expect(SummaryPresentation.recap("  \n") == nil)
        #expect(SummaryPresentation.recap(nil) == nil)
    }
}
