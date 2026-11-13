import XCTest
@testable import LokalBot

final class LlamaSamplerSpecTests: XCTestCase {
    func testStandardConfigMapsToOrderedChain() {
        let specs = LlamaSamplerSpec.specs(from: .standard)
        XCTAssertEqual(specs, [
            .penalties(lastN: 64, repeat: 1.05, freq: 0, present: 0),
            .topK(20),
            .topP(0.7, minKeep: 1),
            .minP(0.08, minKeep: 1),
            .temp(0.1),
            .dist(seed: 0x00C0_FFEE),
        ])
    }

    func testExplicitParamsPreserveSamplerOrder() {
        let specs = LlamaSamplerSpec.specs(
            temperature: 0.2, topK: 40, topP: 0.9, minP: 0.05,
            repeatPenalty: 1.1, repeatLastN: 64, seed: 42)
        XCTAssertEqual(specs.map(\.order), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(specs.last, .dist(seed: 42))
    }
}

private extension LlamaSamplerSpec {
    var order: Int {
        switch self {
        case .penalties: 0
        case .topK: 1
        case .topP: 2
        case .minP: 3
        case .temp: 4
        case .dist: 5
        }
    }
}
