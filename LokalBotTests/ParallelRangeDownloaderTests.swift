import Darwin
import XCTest
@testable import LokalBot

/// End-to-end ranged downloads against an in-process server, so the bytes
/// that reach the partial file (and how many times they are written) are
/// checked through the same URLSession path the app uses.
final class ParallelRangeDownloaderTests: XCTestCase {
    private let url = URL(string: "https://models.example/model.gguf")!
    private var stashDirectory: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        RangeServerStub.reset()
        stashDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-ranged-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServerStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: stashDirectory)
        RangeServerStub.reset()
        super.tearDown()
    }

    /// macOS flags an app once it dirties gigabytes of file-backed memory a
    /// day. Each byte of a model must be written once: landing every part in
    /// a download task's temp file and then copying it into the partial wrote
    /// it twice (137 GB in one 0.10.8 session).
    func testRangedDownloadWritesEachByteToDiskOnce() async throws {
        let blob = Self.numberedBytes(count: 48 * 1024 * 1024)
        RangeServerStub.configure(blob: blob)

        let before = try Self.logicalWriteBytes()
        let staged = try await download(partSize: 4 * 1024 * 1024, maxConcurrentParts: 4)
        let written = try Self.logicalWriteBytes() - before

        XCTAssertLessThan(
            written, UInt64(blob.count) * 3 / 2,
            "a \(blob.count)-byte download dirtied \(written) bytes of files")
        XCTAssertEqual(try Data(contentsOf: staged), blob)
    }

    /// A failed part stops the attempt, completed parts survive it, and the
    /// retry fetches only what is missing while still assembling exact bytes.
    func testRetryFetchesOnlyMissingPartsAndAssemblesExactBytes() async throws {
        let partSize: Int64 = 256 * 1024
        let blob = Self.numberedBytes(count: 3 * 1024 * 1024 + 123)
        let failingStart = partSize * 2
        RangeServerStub.configure(blob: blob, failingRangeStarts: [failingStart])

        // One part at a time, so parts 0 and 1 finish before part 2 fails.
        do {
            _ = try await download(partSize: partSize, maxConcurrentParts: 1)
            XCTFail("the failing part must stop the first attempt")
        } catch ParallelRangeDownloader.DownloadError.unexpectedRangeStatus(let status) {
            XCTAssertEqual(status, 500)
        }

        let manifestURL = stashDirectory.appendingPathComponent(
            "LokalBot-resume-\(ParallelRangeDownloader.stashName(for: url)).json")
        let state = try JSONDecoder().decode(
            ParallelRangeDownloader.ResumeState.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(state.completedParts, [0, 1])
        let totalParts = ParallelRangeDownloader.ranges(
            totalBytes: Int64(blob.count), partSize: partSize).count

        RangeServerStub.configure(blob: blob)
        let staged = try await download(partSize: partSize, maxConcurrentParts: 3)

        let retried = RangeServerStub.rangeRequests
        XCTAssertEqual(retried.count, totalParts - 2)
        XCTAssertFalse(retried.contains("bytes=0-\(partSize - 1)"))
        XCTAssertTrue(retried.contains("bytes=\(failingStart)-\(failingStart + partSize - 1)"))
        XCTAssertEqual(try Data(contentsOf: staged), blob)
    }

    /// A server that answers a ranged GET with the whole file must be
    /// refused before any of that body lands at the part's offset.
    func testWholeFileAnswerToARangeIsRejectedBeforeWriting() async throws {
        let blob = Self.numberedBytes(count: 1024 * 1024)
        RangeServerStub.configure(blob: blob, ignoresRanges: true)

        do {
            _ = try await download(partSize: 256 * 1024, maxConcurrentParts: 2)
            XCTFail("a 200 answer to a ranged request must fail the download")
        } catch ParallelRangeDownloader.DownloadError.unexpectedRangeStatus(let status) {
            XCTAssertEqual(status, 200)
        }

        let partial = ParallelRangeDownloader.stashPartialURL(for: url, in: stashDirectory)
        let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 0)
    }

    private func download(partSize: Int64, maxConcurrentParts: Int) async throws -> URL {
        try await ParallelRangeDownloader.download(
            from: url,
            session: session,
            partSize: partSize,
            maxConcurrentParts: maxConcurrentParts,
            minimumRangedBytes: 1,
            stashDirectory: stashDirectory,
            progress: { _ in })
    }

    /// Every 4-byte word holds its own index, so a part written at the wrong
    /// offset cannot compare equal.
    private static func numberedBytes(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            let words = buffer.bindMemory(to: UInt32.self)
            for index in words.indices {
                words[index] = UInt32(truncatingIfNeeded: index)
            }
        }
        return data
    }

    /// The counter macOS's disk-writes report reads: bytes of file-backed
    /// memory this process has dirtied.
    private static func logicalWriteBytes() throws -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.ri_logical_writes
    }
}

/// Serves HEAD and `Range: bytes=a-b` GETs for one in-memory file, like the
/// Hugging Face CDN, in 64 KB chunks so each part arrives in many callbacks.
private final class RangeServerStub: URLProtocol {
    private struct State {
        var blob = Data()
        var ignoresRanges = false
        var failingRangeStarts: Set<Int64> = []
        var rangeRequests: [String] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func configure(blob: Data, ignoresRanges: Bool = false,
                          failingRangeStarts: Set<Int64> = []) {
        lock.withLock {
            state = State(blob: blob, ignoresRanges: ignoresRanges,
                          failingRangeStarts: failingRangeStarts)
        }
    }

    static func reset() {
        lock.withLock { state = State() }
    }

    static var rangeRequests: [String] {
        lock.withLock { state.rangeRequests }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let isHead = request.httpMethod == "HEAD"
        let current: State = Self.lock.withLock {
            if !isHead, let rangeHeader { Self.state.rangeRequests.append(rangeHeader) }
            return Self.state
        }
        let total = current.blob.count

        if isHead {
            respond(status: 200, headers: [
                "Content-Length": "\(total)",
                "Accept-Ranges": "bytes",
                "ETag": "\"stub-etag\"",
            ], body: nil)
            return
        }
        guard !current.ignoresRanges, let rangeHeader,
              let (start, end) = Self.parse(rangeHeader), end < total else {
            respond(status: 200, headers: ["Content-Length": "\(total)"], body: current.blob)
            return
        }
        if current.failingRangeStarts.contains(Int64(start)) {
            respond(status: 500, headers: ["Content-Length": "0"], body: nil)
            return
        }
        let slice = current.blob.subdata(in: start..<(end + 1))
        respond(status: 206, headers: [
            "Content-Length": "\(slice.count)",
            "Content-Range": "bytes \(start)-\(end)/\(total)",
        ], body: slice)
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String], body: Data?) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            let chunk = 64 * 1024
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunk, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func parse(_ header: String) -> (Int, Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]),
              start <= end else { return nil }
        return (start, end)
    }
}
