import Foundation

enum LlamaSamplerSpec: Equatable {
    case penalties(lastN: Int32, repeat: Float, freq: Float, present: Float)
    case topK(Int32)
    case topP(Float, minKeep: Int)
    case minP(Float, minKeep: Int)
    case temp(Float)
    case dist(seed: UInt32)

    static func specs(
        temperature: Float,
        topK: Int32,
        topP: Float,
        minP: Float,
        repeatPenalty: Float,
        repeatLastN: Int32,
        seed: UInt32
    ) -> [LlamaSamplerSpec] {
        [
            .penalties(lastN: repeatLastN, repeat: repeatPenalty, freq: 0, present: 0),
            .topK(topK),
            .topP(topP, minKeep: 1),
            .minP(minP, minKeep: 1),
            .temp(temperature),
            .dist(seed: seed),
        ]
    }

    static func specs(from config: CotypingConfiguration) -> [LlamaSamplerSpec] {
        specs(
            temperature: Float(config.temperature),
            topK: Int32(config.topK),
            topP: Float(config.topP),
            minP: Float(config.minP),
            repeatPenalty: Float(config.repeatPenalty),
            repeatLastN: 64,
            seed: UInt32(truncatingIfNeeded: config.seed))
    }
}
