import Foundation
import Testing
@testable import LokalBotCompanionKit

@Suite("Design")
struct DesignTests {
    @Test(arguments: [
        ("Onboarding", 304),
        ("Pricing", 25),
        ("Xcode", 224),
        ("Zoom", 82),
        ("Other", 207),
        ("Safari", 339),
        ("Google Meet", 21),
        ("Claude Code", 270),
        ("", 341),
        ("Café Zürich", 186),
    ])
    func nameColorMatchesFrozenMacGoldenHues(_ pair: (String, Int)) {
        #expect(NameColor.hueDegrees(for: pair.0) == pair.1)
    }

    @Test func djb2KnownValues() {
        #expect(NameColor.djb2("") == 5381)
        #expect(NameColor.djb2("a") == 177_670)
        #expect(NameColor.hueDegrees(for: "Xcode") == 224)
    }

    @Test func avatarColorMatchesFrozenMacGoldenIndices() {
        #expect(InitialsAvatar.colorIndex(for: "Maya Chen") == InitialsAvatar.colorIndex(for: "MAYA  chen"))
        #expect(InitialsAvatar.colorIndex(for: "Zoë  O'Brien") == InitialsAvatar.colorIndex(for: "zoe o brien"))
        #expect(InitialsAvatar.colorIndex(for: "") == 0)
        #expect(InitialsAvatar.colorIndex(for: "Maya Chen") == 2)
        #expect(InitialsAvatar.colorIndex(for: "Ben Ortiz") == 5)
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
