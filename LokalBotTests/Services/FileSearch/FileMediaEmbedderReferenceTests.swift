import DigUpKit
import XCTest
@testable import LokalBot

final class FileMediaEmbedderReferenceTests: XCTestCase {
    private static let agreement: Float = 0.999
    private static let jpegAgreement: Float = 0.998
    private static let jpegInputs: Set<String> = ["photo-140", "frame-70"]
    private static let port = 17_919

    func testDigUpsReferenceInputsMakeItsReferenceVectors() async throws {
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/MediaEmbedderReference"))
            .deletingLastPathComponent()
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures
            .appendingPathComponent("vectors.json")))

        let made = try await Self.withServer { try Self.vectors(endpoint: $0, fixtures: fixtures) }

        XCTAssertEqual(Set(made.keys), Set(reference.vectors.keys))
        for (name, vector) in made.sorted(by: { $0.key < $1.key }) {
            guard let expected = reference.vectors[name] else { continue }
            let cosine = Self.cosine(vector, expected)
            let bar = Self.jpegInputs.contains(name) ? Self.jpegAgreement : Self.agreement
            XCTAssertGreaterThanOrEqual(cosine, bar, "\(name) moved from \(reference.madeWith)'s vector")
            print("media embedder reference \(name): cosine \(cosine)")
        }
    }

    func testATextLongerThanTheBatchIsCutLikeDigUpCutsIt() async throws {
        let page = Prompts.document(title: "zastava-1906-08-10-str2", text: String(
            repeating: "Српска застава, лист за политику и књижевност, излази сваког дана осим недеље. ", count: 100))

        let made = try await Self.withServer { endpoint in
            try FileMediaEmbedder(endpoint: endpoint).embedTexts([page + " Крај.", page + " A different ending."])
        }

        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(Self.cosine(made[0], made[1]), 1, accuracy: 1e-6)
    }

    private static func withServer<T: Sendable>(
        _ body: @escaping @Sendable (FileMediaEmbedder.Endpoint) throws -> T) async throws -> T {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_MEDIA_EMBEDDER_MODELS"] else {
            throw XCTSkip("Set LOKALBOT_MEDIA_EMBEDDER_MODELS to a folder with the text model and projector.")
        }
        let models = URL(fileURLWithPath: path, isDirectory: true)
        let model = models.appendingPathComponent(EmbeddingIndex.modelFile)
        let projector = models.appendingPathComponent(FileSearchModels.projectorFile)
        guard LocalLlamaServerAuthentication.readMarker(port: port) == nil else {
            throw XCTSkip("Needs the unused private port \(port).")
        }
        let server = LlamaServer(port: port, contextTokens: 2_048,
                                 extraArgs: FileMediaEmbedderRuntime.serverArguments(projector: projector))
        do {
            try await server.ensureRunning(modelAt: model)
            let token = await server.authenticationToken()
            let endpoint = FileMediaEmbedder.Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token)
            let made = try await Task.detached { try body(endpoint) }.value
            await server.stop()
            return made
        } catch {
            await server.stop()
            throw error
        }
    }

    private struct Reference: Decodable {
        let madeWith: String
        let vectors: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case madeWith = "made_with", vectors
        }
    }

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

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 } / (norm(lhs) * norm(rhs))
    }

    private static func norm(_ vector: [Float]) -> Float {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
