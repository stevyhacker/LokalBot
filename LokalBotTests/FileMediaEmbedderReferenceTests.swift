import DigUpKit
import XCTest
@testable import LokalBot

/// DigUp's reference inputs through the app's own path (ImageIO decoding,
/// `FileImageSizing`, PNG content parts, the media llama-server with the app's
/// arguments) must reproduce DigUp's reference vectors at cosine ≥ 0.999, the
/// bar DigUp sets for runtimes that agree. JPEG inputs get 0.998: DigUp's
/// reference decodes them with stb_image and the app with ImageIO, and the two
/// decoders differ on 27% of the photo's pixels (mean 0.2 levels). Measured on
/// 30 October with ImageIO-decoded pixels in Pillow's path too: photo-140
/// 0.99964 and frame-70 0.99860, the same as this test, while text, the PNG
/// screenshot and speech match at 1.0. Run it for every llama.cpp update:
/// a failure means bump `FileMediaEmbedder.vectorVersion` (every file index
/// then reads its files again) or keep the old llama.cpp.
///
/// Needs both model files in one folder: set `LOKALBOT_MEDIA_EMBEDDER_MODELS`
/// (pass `TEST_RUNNER_LOKALBOT_MEDIA_EMBEDDER_MODELS` through xcodebuild) to a
/// folder holding `embeddinggemma-2-Q8_0.gguf` and
/// `mmproj-embeddinggemma-2-Q8_0.gguf`. Skipped otherwise. The fixtures are
/// DigUp's (MIT; `Fixtures/MediaEmbedderReference/LICENSE.DigUp`).
final class FileMediaEmbedderReferenceTests: XCTestCase {
    private static let agreement: Float = 0.999
    private static let jpegAgreement: Float = 0.998
    private static let jpegInputs: Set<String> = ["photo-140", "frame-70"]
    private static let port = 17_919

    func testDigUpsReferenceInputsMakeItsReferenceVectors() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_MEDIA_EMBEDDER_MODELS"] else {
            throw XCTSkip("Set LOKALBOT_MEDIA_EMBEDDER_MODELS to a folder with the text model and projector.")
        }
        let models = URL(fileURLWithPath: path, isDirectory: true)
        let model = models.appendingPathComponent(EmbeddingIndex.modelFile)
        let projector = models.appendingPathComponent(FileSearchModels.projectorFile)
        guard LocalLlamaServerAuthentication.readMarker(port: Self.port) == nil else {
            throw XCTSkip("Needs the unused private port \(Self.port).")
        }
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/MediaEmbedderReference"))
            .deletingLastPathComponent()
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures
            .appendingPathComponent("vectors.json")))

        let server = LlamaServer(port: Self.port, contextTokens: 2_048,
                                 extraArgs: FileMediaEmbedderRuntime.serverArguments(projector: projector))
        do {
            try await server.ensureRunning(modelAt: model)
            let token = await server.authenticationToken()
            let endpoint = FileMediaEmbedder.Endpoint(
                baseURL: URL(string: "http://127.0.0.1:\(Self.port)")!, token: token)
            let made = try await Task.detached { try Self.vectors(endpoint: endpoint, fixtures: fixtures) }.value
            XCTAssertEqual(Set(made.keys), Set(reference.vectors.keys))
            for (name, vector) in made.sorted(by: { $0.key < $1.key }) {
                guard let expected = reference.vectors[name] else { continue }
                let cosine = zip(vector, expected).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    / (Self.norm(vector) * Self.norm(expected))
                let bar = Self.jpegInputs.contains(name) ? Self.jpegAgreement : Self.agreement
                XCTAssertGreaterThanOrEqual(cosine, bar, "\(name) moved from \(reference.madeWith)'s vector")
                print("media embedder reference \(name): cosine \(cosine)")
            }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private struct Reference: Decodable {
        let madeWith: String
        let vectors: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case madeWith = "made_with", vectors
        }
    }

    /// DigUp's `ReferenceVectorTests` inputs, word for word.
    private static func vectors(endpoint: FileMediaEmbedder.Endpoint, fixtures: URL) throws -> [String: [Float]] {
        let embedder = FileMediaEmbedder(endpoint: endpoint)
        let texts: [(String, String)] = [
            ("query", Prompts.query("payment declined error")),
            ("query-bn", Prompts.query("ইলিশ মাছ রান্না")),
            ("query-ar", Prompts.query("متى تغلق المكتبة")),
            ("document", Prompts.document(title: "Tokyo itinerary", text: "Flight to Tokyo Haneda on November 3. "
                + "Then the train to Kamakura to see the Great Buddha, and back for dinner in Shibuya.")),
            ("document-long", Prompts.document(title: nil, text: (1...60).map {
                "Note \($0): the review moved to room \($0 % 7 + 2) because the projector in the main hall failed "
                    + "again, and the team agreed to send the slides the night before."
            }.joined(separator: " "))),
        ]
        var made: [String: [Float]] = [:]
        for ((name, _), vector) in zip(texts, try embedder.embedTexts(texts.map(\.1))) { made[name] = vector }
        for (name, file, budget) in [("screen-280", "screen.png", 280), ("photo-140", "photo.jpg", 140),
                                     ("frame-70", "photo.jpg", 70)] {
            let embedding = try embedder.embedImages([fixtures.appendingPathComponent(file).path], budget: budget)[0]
            made[name] = try XCTUnwrap(embedding.vector, "\(file): \(embedding.error ?? "no vector")")
        }
        let speech = try embedder.embedAudio([fixtures.appendingPathComponent("speech.wav").path])[0]
        made["speech"] = try XCTUnwrap(speech.vector, "speech.wav: \(speech.error ?? "no vector")")
        return made
    }

    private static func norm(_ vector: [Float]) -> Float {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
