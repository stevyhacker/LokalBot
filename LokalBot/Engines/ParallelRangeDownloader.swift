import CryptoKit
import Foundation

/// Downloads large static files through parallel HTTP byte ranges, falling
/// back to a single streamed GET when the server can't do ranges (or the file
/// is small enough that ranges don't pay off).
///
/// Hugging Face's CDN supports `Accept-Ranges: bytes` for the GGUF files in the
/// model catalog. A single `URLSessionDownloadTask` can sit well below the
/// user's available bandwidth on fast links, while a small number of ranged
/// requests usually keeps the pipe busier. Callers still validate the final
/// bytes before installing the model. Either way the caller gets one temp-file
/// URL back with progress reported throughout — there is exactly one download
/// path to reason about.
///
/// Each range streams straight into the partial file at its own offset, so
/// every model byte is written to disk once. Landing a range in a download
/// task's temp file and copying it into place wrote every byte twice: half of
/// the 137 GB a 0.10.8 build wrote on 2026-10-14 was that copy.
///
/// Ranged downloads are resumable: the partially assembled file and a small
/// manifest of completed parts live at a stable per-URL path, so a failed,
/// cancelled, or app-quit download picks up where it stopped instead of
/// re-fetching 17 GB from byte zero. Pass `stashDirectory` to keep that state
/// somewhere durable (the temp default can be reaped by macOS between runs).
enum ParallelRangeDownloader {

    /// Completed-part bookkeeping persisted next to the partial file. The
    /// stored URL/size/partSize must match the current request exactly or the
    /// stash is discarded — a changed upstream file must never be stitched
    /// together from two different versions.
    struct ResumeState: Codable, Equatable {
        let url: String
        let totalBytes: Int64
        let partSize: Int64
        let validator: String?
        var completedParts: [Int]

        init(url: String, totalBytes: Int64, partSize: Int64,
             validator: String? = nil, completedParts: [Int]) {
            self.url = url
            self.totalBytes = totalBytes
            self.partSize = partSize
            self.validator = validator
            self.completedParts = completedParts
        }
    }
    struct Progress: Sendable {
        let bytesWritten: Int64
        let totalBytes: Int64

        var fractionCompleted: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
        }
    }

    struct ByteRange: Equatable, Sendable {
        let index: Int
        let start: Int64
        let end: Int64

        var length: Int64 { end - start + 1 }
    }

    private enum FallbackRequired: Error {
        case unsupported
    }

    enum DownloadError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case invalidContentLength
        case unexpectedRangeStatus(Int)
        case wrongPartSize(expected: Int64, actual: Int64)
        case assemblySizeMismatch(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "Download failed: invalid server response."
            case .httpStatus(let status):
                "Download failed (HTTP \(status))."
            case .invalidContentLength:
                "Download failed: server did not report a valid file size."
            case .unexpectedRangeStatus(let status):
                "Download failed: server did not honor byte ranges (HTTP \(status))."
            case .wrongPartSize(let expected, let actual):
                "Download failed: received \(actual) bytes for a \(expected)-byte chunk."
            case .assemblySizeMismatch(let expected, let actual):
                "Download failed: assembled \(actual) bytes for a \(expected)-byte model."
            }
        }
    }

    static let minimumAcceleratedSize: Int64 = 256 * 1024 * 1024
    static let defaultPartSize: Int64 = 64 * 1024 * 1024
    static let defaultMaxConcurrentParts = 6

    static func ranges(totalBytes: Int64, partSize: Int64 = defaultPartSize) -> [ByteRange] {
        guard totalBytes > 0, partSize > 0 else { return [] }
        var out: [ByteRange] = []
        var start: Int64 = 0
        var index = 0
        while start < totalBytes {
            let end = min(start + partSize - 1, totalBytes - 1)
            out.append(.init(index: index, start: start, end: end))
            start = end + 1
            index += 1
        }
        return out
    }

    /// Downloads `url` to a temp file, ranged when the server supports it and
    /// the file is large enough, else via one streamed GET. Returns the temp
    /// URL; the caller validates and installs it.
    static func download(
        from url: URL,
        session: URLSession,
        partSize: Int64 = defaultPartSize,
        maxConcurrentParts: Int = defaultMaxConcurrentParts,
        minimumRangedBytes: Int64 = ParallelRangeDownloader.minimumAcceleratedSize,
        stashDirectory: URL? = nil,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        do {
            return try await downloadRanged(
                from: url, session: session, partSize: partSize,
                maxConcurrentParts: maxConcurrentParts,
                minimumRangedBytes: minimumRangedBytes,
                stashDirectory: stashDirectory, progress: progress)
        } catch is FallbackRequired {
            return try await downloadWhole(from: url, session: session, progress: progress)
        }
    }

    /// Stable per-URL name for resume state, so a retried download finds its
    /// earlier partial file no matter how it was initiated.
    static func stashName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the resumable partial for `url` lives inside `stashDirectory`.
    static func stashPartialURL(for url: URL, in stashDirectory: URL) -> URL {
        stashDirectory.appendingPathComponent("LokalBot-resume-\(stashName(for: url)).partial")
    }

    /// Disk bytes already held by the resume stash for `url` (0 when none).
    /// The disk-space precheck credits these against the expected size: a
    /// valid stash resumes and only the remainder is fetched, and an
    /// invalidated one is deleted before parts move — freeing the same bytes
    /// on the same volume — so either way the extra space a retry needs is
    /// expected − stashed. Allocated size, not logical size: parts write at
    /// their offsets, so the partial is sparse until the tail parts land.
    static func stashedByteCount(for url: URL, stashDirectory: URL) -> Int64 {
        let values = try? stashPartialURL(for: url, in: stashDirectory)
            .resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    private static func downloadRanged(
        from url: URL,
        session: URLSession,
        partSize: Int64,
        maxConcurrentParts: Int,
        minimumRangedBytes: Int64,
        stashDirectory: URL?,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let probe = try await probe(url: url, session: session)
        guard probe.supportsByteRanges,
              probe.totalBytes >= minimumRangedBytes else {
            throw FallbackRequired.unsupported
        }

        let fileManager = FileManager.default
        let stashDir = stashDirectory ?? fileManager.temporaryDirectory
        let assembled = stashPartialURL(for: url, in: stashDir)
        let manifestURL = stashDir.appendingPathComponent("LokalBot-resume-\(stashName(for: url)).json")
        try fileManager.createDirectory(at: stashDir, withIntermediateDirectories: true)

        let byteRanges = ranges(totalBytes: probe.totalBytes, partSize: partSize)
        guard !byteRanges.isEmpty else { throw DownloadError.invalidContentLength }

        // On success the assembled file is handed to the caller and the
        // manifest deleted; on any failure (including cancellation) both stay
        // behind so the next attempt resumes instead of starting over.
        var completed: Set<Int> = []
        if let data = try? Data(contentsOf: manifestURL),
           let state = try? JSONDecoder().decode(ResumeState.self, from: data),
           state.url == url.absoluteString,
           state.totalBytes == probe.totalBytes,
           state.partSize == partSize,
           probe.validator != nil,
           state.validator == probe.validator,
           fileManager.fileExists(atPath: assembled.path) {
            completed = Set(state.completedParts).intersection(byteRanges.map(\.index))
        } else {
            try? fileManager.removeItem(at: assembled)
            try? fileManager.removeItem(at: manifestURL)
        }
        if !fileManager.fileExists(atPath: assembled.path) {
            _ = fileManager.createFile(atPath: assembled.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: assembled)
        defer { try? output.close() }

        var state = ResumeState(url: url.absoluteString, totalBytes: probe.totalBytes,
                                partSize: partSize, validator: probe.validator,
                                completedParts: completed.sorted())
        try await downloadParts(
            byteRanges,
            skipping: completed,
            url: url,
            session: session,
            fileDescriptor: output.fileDescriptor,
            totalBytes: probe.totalBytes,
            maxConcurrentParts: max(1, maxConcurrentParts),
            progress: progress,
            partCompleted: { index in
                state.completedParts.append(index)
                if let data = try? JSONEncoder().encode(state) {
                    try? data.write(to: manifestURL, options: .atomic)
                }
            })

        let actual = fileSize(assembled)
        guard actual == probe.totalBytes else {
            // Corrupt stash (e.g. the partial file was truncated behind our
            // back) — throw it away so the next attempt starts clean.
            try? fileManager.removeItem(at: assembled)
            try? fileManager.removeItem(at: manifestURL)
            throw DownloadError.assemblySizeMismatch(expected: probe.totalBytes, actual: actual)
        }

        try? fileManager.removeItem(at: manifestURL)
        progress(.init(bytesWritten: probe.totalBytes, totalBytes: probe.totalBytes))
        return assembled
    }

    /// Single download-task GET for servers without byte-range support (or
    /// files below the acceleration threshold). URLSession streams directly
    /// to disk instead of iterating every byte in Swift.
    private static func downloadWhole(
        from url: URL,
        session: URLSession,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")

        progress(.init(bytesWritten: 0, totalBytes: -1))
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        let expectedBytes = parseContentLength(http)
        let actualBytes = fileSize(temporary)
        if expectedBytes > 0, actualBytes != expectedBytes {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadError.assemblySizeMismatch(
                expected: expectedBytes, actual: actualBytes)
        }

        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("LokalBot-download-\(UUID().uuidString)", isDirectory: false)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        progress(.init(bytesWritten: actualBytes, totalBytes: max(expectedBytes, actualBytes)))
        return destination
    }

    private struct Probe: Sendable {
        let totalBytes: Int64
        let supportsByteRanges: Bool
        let validator: String?
    }

    private static func probe(url: URL, session: URLSession) async throws -> Probe {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 405 || http.statusCode == 501 {
                throw FallbackRequired.unsupported
            }
            throw DownloadError.httpStatus(http.statusCode)
        }

        let totalBytes = parseContentLength(http)
        guard totalBytes > 0 else { throw FallbackRequired.unsupported }
        let supportsByteRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?
            .localizedCaseInsensitiveContains("bytes") == true
        let validator = http.value(forHTTPHeaderField: "X-Linked-Etag")
            ?? http.value(forHTTPHeaderField: "ETag")
            ?? http.value(forHTTPHeaderField: "X-Repo-Commit")
            ?? http.value(forHTTPHeaderField: "Last-Modified")
        return Probe(
            totalBytes: totalBytes,
            supportsByteRanges: supportsByteRanges,
            validator: validator)
    }

    private static func parseContentLength(_ response: HTTPURLResponse) -> Int64 {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let header = response.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int64(header) {
            return parsed
        }
        if let linkedSize = response.value(forHTTPHeaderField: "X-Linked-Size"),
           let parsed = Int64(linkedSize) {
            return parsed
        }
        return -1
    }

    private static func downloadParts(
        _ byteRanges: [ByteRange],
        skipping alreadyCompleted: Set<Int> = [],
        url: URL,
        session: URLSession,
        fileDescriptor: Int32,
        totalBytes: Int64,
        maxConcurrentParts: Int,
        progress: @escaping @Sendable (Progress) -> Void,
        partCompleted: (Int) -> Void = { _ in }
    ) async throws {
        let remaining = byteRanges.filter { !alreadyCompleted.contains($0.index) }
        try await withThrowingTaskGroup(of: ByteRange.self) { group in
            var iterator = remaining.makeIterator()
            var active = 0
            var completedBytes: Int64 = byteRanges
                .filter { alreadyCompleted.contains($0.index) }
                .reduce(0) { $0 + $1.length }
            var completedParts = alreadyCompleted.count
            progress(.init(bytesWritten: completedBytes, totalBytes: totalBytes))

            func addNextPart() {
                guard let range = iterator.next() else { return }
                active += 1
                group.addTask {
                    try await downloadPart(
                        range, totalBytes: totalBytes,
                        from: url, into: fileDescriptor, session: session)
                    return range
                }
            }

            for _ in 0..<min(maxConcurrentParts, remaining.count) {
                addNextPart()
            }

            while active > 0 {
                guard let range = try await group.next() else { break }
                active -= 1
                completedBytes += range.length
                completedParts += 1
                partCompleted(range.index)
                progress(.init(bytesWritten: completedBytes, totalBytes: totalBytes))
                addNextPart()
            }

            guard completedParts == byteRanges.count else {
                throw DownloadError.assemblySizeMismatch(
                    expected: totalBytes,
                    actual: completedBytes)
            }
        }
    }

    /// Fetches one byte range and writes it at its offset in the partial
    /// file as it arrives. Returns once every byte of the range is written.
    private static func downloadPart(
        _ range: ByteRange,
        totalBytes: Int64,
        from url: URL,
        into fileDescriptor: Int32,
        session: URLSession
    ) async throws {
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppIdentifiers.bundleID, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")

        let writer = RangeWriter(range: range, totalBytes: totalBytes, fileDescriptor: fileDescriptor)
        let task = session.dataTask(with: request)
        task.delegate = writer
        try await withTaskCancellationHandler {
            try await writer.run(task)
        } onCancel: {
            task.cancel()
        }
    }

    /// Why a ranged response must not be written, or nil when it is exactly
    /// the requested range of the probed file.
    private static func rangeResponseError(
        _ response: URLResponse, range: ByteRange, totalBytes: Int64
    ) -> Error? {
        guard let http = response as? HTTPURLResponse else {
            return DownloadError.invalidResponse
        }
        guard http.statusCode == 206 else {
            return DownloadError.unexpectedRangeStatus(http.statusCode)
        }
        guard contentRangeMatches(
            http.value(forHTTPHeaderField: "Content-Range"),
            range: range,
            totalBytes: totalBytes) else {
            return DownloadError.invalidResponse
        }
        return nil
    }

    private static func contentRangeMatches(
        _ header: String?, range: ByteRange, totalBytes: Int64
    ) -> Bool {
        guard let header else { return false }
        return header.lowercased() == "bytes \(range.start)-\(range.end)/\(totalBytes)"
    }

    /// `pwrite` at an absolute offset: concurrent parts share one descriptor
    /// and never move a shared file position.
    private static func writeFully(
        _ bytes: UnsafeRawBufferPointer, to fileDescriptor: Int32, at offset: Int64
    ) throws {
        guard var cursor = bytes.baseAddress else { return }
        var remaining = bytes.count
        var position = off_t(offset)
        while remaining > 0 {
            let written = pwrite(fileDescriptor, cursor, remaining, position)
            if written < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            cursor = cursor.advanced(by: written)
            remaining -= written
            position += off_t(written)
        }
    }

    /// Delegate for one ranged data task. It checks the response before any
    /// byte lands, then writes each chunk at its final offset. URLSession
    /// serializes a task's callbacks on the session's delegate queue; the
    /// lock covers the hand-off to the task awaiting `run`.
    private final class RangeWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let range: ByteRange
        private let totalBytes: Int64
        private let fileDescriptor: Int32
        private let lock = NSLock()
        private var received: Int64 = 0
        private var failure: Error?
        private var continuation: CheckedContinuation<Void, Error>?
        /// Held when the task completes before `run` is waiting, e.g. one
        /// cancelled before it was resumed.
        private var outcome: Result<Void, Error>?

        init(range: ByteRange, totalBytes: Int64, fileDescriptor: Int32) {
            self.range = range
            self.totalBytes = totalBytes
            self.fileDescriptor = fileDescriptor
            super.init()
        }

        func run(_ task: URLSessionDataTask) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let finished: Result<Void, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    return nil
                }
                if let finished {
                    continuation.resume(with: finished)
                } else {
                    task.resume()
                }
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            // A server that ignores Range answers 200 with the whole file;
            // writing that at this part's offset would corrupt the partial.
            if let error = ParallelRangeDownloader.rangeResponseError(
                response, range: range, totalBytes: totalBytes) {
                record(error)
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let offset: Int64? = lock.withLock {
                guard failure == nil else { return nil }
                let end = received + Int64(data.count)
                guard end <= range.length else {
                    failure = DownloadError.wrongPartSize(expected: range.length, actual: end)
                    return nil
                }
                let start = range.start + received
                received = end
                return start
            }
            guard let offset else {
                dataTask.cancel()
                return
            }
            do {
                try data.withUnsafeBytes {
                    try ParallelRangeDownloader.writeFully($0, to: fileDescriptor, at: offset)
                }
            } catch {
                record(error)
                dataTask.cancel()
            }
        }

        /// Never copy a part into URLCache: that would be a second disk write.
        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            willCacheResponse proposedResponse: CachedURLResponse,
            completionHandler: @escaping (CachedURLResponse?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (waiter, result): (CheckedContinuation<Void, Error>?, Result<Void, Error>) = lock.withLock {
                let settled: Result<Void, Error>
                if let failure {
                    settled = .failure(failure)
                } else if let error {
                    settled = .failure(error)
                } else if received != range.length {
                    settled = .failure(DownloadError.wrongPartSize(
                        expected: range.length, actual: received))
                } else {
                    settled = .success(())
                }
                let pending = continuation
                continuation = nil
                if pending == nil { outcome = settled }
                return (pending, settled)
            }
            waiter?.resume(with: result)
        }

        private func record(_ error: Error) {
            lock.withLock {
                if failure == nil { failure = error }
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        if let number = size as? NSNumber { return number.int64Value }
        if let integer = size as? Int64 { return integer }
        if let integer = size as? Int { return Int64(integer) }
        return -1
    }
}
