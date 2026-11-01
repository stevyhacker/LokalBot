import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Design")
struct DesignTests {
    /// The Mac's `CaptureStyle.color(for:)` hash, copied verbatim
    /// (LokalBot/Views/CaptureView.swift).
    static func macHue(_ app: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in app.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return hash % 360
    }

    @Test(arguments: ["", "a", "Xcode", "Onboarding", "Pricing", "Google Meet", "Claude Code",
                      "Visual Studio Code — Insiders", "Ünïcödé 日本語", "Other"])
    func nameColorMatchesTheMac(_ name: String) {
        #expect(UInt64(NameColor.hueDegrees(for: name)) == Self.macHue(name))
    }

    @Test func djb2KnownValues() {
        #expect(NameColor.djb2("") == 5381)
        #expect(NameColor.djb2("a") == 5381 * 33 + 97)
        // Long names wrap in 64 bits, as on the Mac.
        #expect(NameColor.djb2(String(repeating: "x", count: 64)) == {
            var hash: UInt64 = 5381
            for _ in 0..<64 { hash = hash &* 33 &+ 120 }
            return hash
        }())
        #expect(NameColor.hueDegrees(for: "Xcode") == Int(NameColor.djb2("Xcode") % 360))
    }

    /// The Mac's `InitialsAvatar.color(for:)` index, with
    /// `PeopleDirectory.normalized` (LokalBot/Views/PeopleWorkspaceView.swift).
    @Test(arguments: ["Maya Chen", "Ben Ortiz", "Priya Nair", "Alex Romero", "Zoë  O'Brien", ""])
    func avatarColorMatchesTheMac(_ name: String) {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let hash = normalized.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        #expect(InitialsAvatar.colorIndex(for: name) == hash % 8)
    }

    @Test func initials() {
        #expect(InitialsAvatar.initials("Maya Chen") == "MC")
        #expect(InitialsAvatar.initials("Priya van der Nair") == "PN")
        #expect(InitialsAvatar.initials("Ben") == "B")
        #expect(InitialsAvatar.initials("") == "")
    }

    @Test func speakerPaletteFollowsTokens() {
        #expect(LBTokens.speakers.count == 8)
        #expect(LBTokens.speakers[0] == LBTokens.Colors.accentText)
    }

    @Test func proportionSegmentsFoldTheTailIntoOther() {
        let shares = [TimeShare(name: "A", seconds: 50), TimeShare(name: "Other", seconds: 10), TimeShare(name: "B", seconds: 40)]
        let segments = ProportionBarMath.segments(shares, cap: 1)
        #expect(segments.map(\.label) == ["A", "Other"])
        #expect(segments.map(\.seconds) == [50, 50])
        #expect(abs(segments.map(\.fraction).reduce(0, +) - 1) < 0.0001)
        #expect(ProportionBarMath.segments([]).isEmpty)
    }

    @Test func networkRoutes() {
        #expect(NetworkRoute(address: "100.101.102.103:17890") == .tailscale)
        #expect(NetworkRoute(address: "100.63.0.1:17890") == .localNetwork)
        #expect(NetworkRoute(address: "macbook.tail1234.ts.net:17890") == .tailscale)
        #expect(NetworkRoute(address: "[fd7a:115c:a1e0::1]:17890") == .tailscale)
        #expect(NetworkRoute(address: "192.168.1.20:17890") == .localNetwork)
        #expect(NetworkRoute(address: "fe80::1") == .localNetwork)
        #expect(NetworkRoute(address: nil) == nil)
    }
}
