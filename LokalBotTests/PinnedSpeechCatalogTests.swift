import XCTest
@testable import LokalBot

final class PinnedSpeechCatalogTests: XCTestCase {
    func testBundledManifestsCoverEverySelectedLoaderComponent() throws {
        let required: [String: Set<String>] = [
            "parakeetV3": ["Encoder_v2.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json"],
            "parakeetV2": ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json"],
            "sileroVAD": ["silero-vad-unified-256ms-v6.2.1.mlmodelc"],
            "cohere": ["cohere_encoder.mlmodelc", "cohere_decoder_cache_external_v2.mlmodelc", "vocab.json"],
            "community": ["Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc", "Segmentation.mlmodelc", "plda-parameters.json"],
            "whisper": ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "config.json", "generation_config.json"],
            "whisperTokenizer": ["added_tokens.json", "config.json", "merges.txt", "normalizer.json", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.json"],
        ]
        for (name, components) in required {
            let manifest = try PinnedModelSnapshot.catalog(name)
            XCTAssertEqual(manifest.revision.count, 40, name)
            XCTAssertEqual(Set(manifest.files.compactMap { $0.path.split(separator: "/").first.map(String.init) }), components, name)
            XCTAssertEqual(Set(manifest.files.map(\.path)).count, manifest.files.count, name)
            for file in manifest.files {
                XCTAssertGreaterThan(file.bytes, 0, file.path)
                XCTAssertEqual(file.digest.count, file.isGitBlob ? 40 : 64, file.path)
            }
        }
        let cohere = try PinnedModelSnapshot.catalog("cohere")
        XCTAssertEqual(cohere.files.first { $0.path == "vocab.json" }?.remotePath, "vocab.json")
    }
}
