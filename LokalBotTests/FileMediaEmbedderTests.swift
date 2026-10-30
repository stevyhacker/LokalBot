import CoreGraphics
import DigUpKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokalBot

/// The media embedder's requests have the shapes the 30 October parity run
/// qualified, and a server outage stops a pass instead of failing files.
final class FileMediaEmbedderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        MediaEmbedderURLProtocolStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        MediaEmbedderURLProtocolStub.reset()
    }

    func testTextsGoInBatchesWithTheAppsRequestShape() throws {
        MediaEmbedderURLProtocolStub.respond { body in (200, Self.response(count: (body["input"] as? [Any])?.count ?? 0)) }
        let texts = (0..<20).map { "title: none | text: passage \($0)" }

        let vectors = try makeEmbedder().embedTexts(texts)

        XCTAssertEqual(vectors.count, 20)
        let requests = MediaEmbedderURLProtocolStub.requests
        XCTAssertEqual(requests.map { ($0.body["input"] as? [String])?.count }, [16, 4])
        XCTAssertEqual(requests[0].body["input"] as? [String], Array(texts.prefix(16)))
        XCTAssertEqual(requests[0].body["cache_prompt"] as? Bool, false)
        XCTAssertEqual(requests[0].body["model"] as? String, EmbeddingIndex.modelID)
        XCTAssertEqual(requests[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(requests[0].request.url?.path, "/v1/embeddings")
        XCTAssertEqual(vectors[0].count, 768)
        XCTAssertEqual(sqrt(vectors[0].reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-5)
    }

    func testAnImageGoesAsASizedPNGContentPart() throws {
        MediaEmbedderURLProtocolStub.respond { _ in (200, Self.response(count: 1)) }
        let picture = try writePicture(width: 1440, height: 900)

        let made = try makeEmbedder().embedImages([picture.path], budget: 280)

        XCTAssertNotNil(made[0].vector)
        let input = try XCTUnwrap((MediaEmbedderURLProtocolStub.requests.first?.body["input"] as? [[String: Any]])?.first)
        let part = try XCTUnwrap((input["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(part["type"] as? String, "image_url")
        let url = try XCTUnwrap((part["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        let png = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)), 0, nil))
        XCTAssertEqual(image.width, 1008)
        XCTAssertEqual(image.height, 624)
    }

    func testAudioGoesAsAnInputAudioPart() throws {
        MediaEmbedderURLProtocolStub.respond { _ in (200, Self.response(count: 1)) }
        let wav = folder.appendingPathComponent("window.wav")
        try Data("RIFF-test".utf8).write(to: wav)

        let made = try makeEmbedder().embedAudio([wav.path])

        XCTAssertNotNil(made[0].vector)
        let input = try XCTUnwrap((MediaEmbedderURLProtocolStub.requests.first?.body["input"] as? [[String: Any]])?.first)
        let part = try XCTUnwrap((input["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(part["type"] as? String, "input_audio")
        let audio = try XCTUnwrap(part["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual(audio["data"] as? String, Data("RIFF-test".utf8).base64EncodedString())
    }

    func testABrokenFileFailsAloneWithoutARequest() throws {
        MediaEmbedderURLProtocolStub.respond { _ in (200, Self.response(count: 1)) }
        let broken = folder.appendingPathComponent("broken.png")
        try Data("not a picture".utf8).write(to: broken)
        let picture = try writePicture(width: 640, height: 480)

        let made = try makeEmbedder().embedImages([broken.path, picture.path], budget: 140)

        XCTAssertNil(made[0].vector)
        XCTAssertNotNil(made[0].error)
        XCTAssertNotNil(made[1].vector)
        XCTAssertEqual(MediaEmbedderURLProtocolStub.requests.count, 1)
    }

    func testARejectedInputFailsThatFileOnly() throws {
        var calls = 0
        MediaEmbedderURLProtocolStub.respond { _ in
            calls += 1
            return calls == 1 ? (400, Data(#"{"error":"bad image"}"#.utf8)) : (200, Self.response(count: 1))
        }
        let first = try writePicture(width: 640, height: 480)
        let second = try writePicture(width: 640, height: 480)

        let made = try makeEmbedder().embedImages([first.path, second.path], budget: 70)

        XCTAssertNil(made[0].vector)
        XCTAssertTrue(made[0].error?.contains("HTTP 400") == true)
        XCTAssertNotNil(made[1].vector)
    }

    func testAServerErrorStopsThePass() throws {
        MediaEmbedderURLProtocolStub.respond { _ in (503, Data("loading".utf8)) }
        let picture = try writePicture(width: 640, height: 480)
        let embedder = makeEmbedder()

        XCTAssertThrowsError(try embedder.embedImages([picture.path], budget: 140)) {
            XCTAssertTrue($0 is WorkerError)
        }
        XCTAssertThrowsError(try embedder.embedTexts(["title: none | text: x"])) {
            XCTAssertTrue($0 is WorkerError)
        }
    }

    func testTheFingerprintNamesTheModelRuntimeAndProjector() {
        let source = FileMediaEmbedder.workerInfo.vectorSource
        XCTAssertEqual(source, "google/embeddinggemma-2@bfcd298 lokalbot-llama-server-vectors1 text-q8_0+mmproj-q8_0")
        XCTAssertFalse(FileMediaEmbedder.workerInfo.textOnly)
        XCTAssertEqual(FileMediaEmbedder.workerInfo.dim, 768)
    }

    // MARK: - Helpers

    private func makeEmbedder() -> FileMediaEmbedder {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaEmbedderURLProtocolStub.self]
        return FileMediaEmbedder(
            endpoint: .init(baseURL: URL(string: "http://127.0.0.1:1")!, token: "secret"),
            session: URLSession(configuration: configuration))
    }

    private static func response(count: Int) -> Data {
        let vector = (0..<768).map { $0 == 0 ? 2.0 : 0.0 }
        let rows = (0..<count).map { ["index": $0, "embedding": vector] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["data": rows])
    }

    private func writePicture(width: Int, height: Int) throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).png")
        let rgb = (0..<(width * height * 3)).map { UInt8($0 % 256) }
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(rgb) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

private final class MediaEmbedderURLProtocolStub: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: [String: Any]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (([String: Any]) -> (Int, Data))?
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func respond(_ handler: @escaping ([String: Any]) -> (Int, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.lock.lock()
        Self.recorded.append(Recorded(request: request, body: body))
        let handler = Self.handler
        Self.lock.unlock()
        let (status, payload) = handler?(body) ?? (500, Data())
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
