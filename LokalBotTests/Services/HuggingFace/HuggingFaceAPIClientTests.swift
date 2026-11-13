import Foundation
import XCTest
@testable import LokalBot

final class HuggingFaceAPIClientTests: XCTestCase {
    override func tearDown() {
        HuggingFaceURLProtocolStub.reset()
        super.tearDown()
    }

    func testFilesRequestsBlobMetadataAndDecodesLFSChecksum() async throws {
        let checksum = String(repeating: "a", count: 64)
        HuggingFaceURLProtocolStub.responseData = Data(
            """
            {
              "sha": "0123456789abcdef",
              "siblings": [
                {
                  "rfilename": "models/example-Q4_K_M.gguf",
                  "lfs": { "sha256": "\(checksum)", "size": 123456 }
                },
                { "rfilename": "README.md" }
              ]
            }
            """.utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HuggingFaceURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let files = try await HuggingFaceAPIClient(session: session)
            .files(modelID: "owner/repository")

        let request = try XCTUnwrap(HuggingFaceURLProtocolStub.lastRequest)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/models/owner/repository")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "blobs" })?.value,
            "true")

        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(file.id, "models/example-Q4_K_M.gguf")
        XCTAssertEqual(file.sizeBytes, 123456)
        XCTAssertEqual(file.revision, "0123456789abcdef")
        XCTAssertEqual(file.sha256, checksum)
        XCTAssertTrue(file.downloadURL.absoluteString.contains("/0123456789abcdef/"))
    }
}

private final class HuggingFaceURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedResponseData = Data()
    nonisolated(unsafe) private static var storedLastRequest: URLRequest?

    static var responseData: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedResponseData
        }
        set {
            lock.lock()
            storedResponseData = newValue
            lock.unlock()
        }
    }

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequest
    }

    static func reset() {
        lock.lock()
        storedResponseData = Data()
        storedLastRequest = nil
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data: Data
        Self.lock.lock()
        Self.storedLastRequest = request
        data = Self.storedResponseData
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
