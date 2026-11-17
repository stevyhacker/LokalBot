import Foundation
import libzstd

/// Codex compresses rollouts it is done with to `<name>.jsonl.zst`, so most
/// of a long-time user's history is compressed. A compressed transcript is
/// decompressed a piece at a time, never whole: one rollout can hold
/// gigabytes of tool output.
enum CodingAgentCompressedTranscript {
    private static let readSize = 4 << 20
    private static let outputSize = 4 << 20

    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl"
    }

    /// The path the transcript has uncompressed, which names it either way.
    static func plainPath(of url: URL) -> String {
        isCompressed(url) ? url.deletingPathExtension().path : url.path
    }

    /// A time no later than the rollout's first record. Compressing gives the
    /// file a new creation date, the time it was last written, so the start
    /// comes from its name, `rollout-2026-10-19T08-23-26-<id>.jsonl.zst`.
    /// The name is in the local time where Codex ran, so a day before its
    /// date covers every zone.
    static func startBound(of url: URL) -> Date {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-"),
              let day = CodingAgentTimestamp.date("\(name.dropFirst(8).prefix(10))T00:00:00Z")
        else { return .distantPast }
        return day.addingTimeInterval(-86_400)
    }

    /// Hands `body` the transcript's lines in batches that end on a line
    /// break; the last batch holds a final line without one. Returns the
    /// decompressed size. A file that ends inside a frame is unreadable.
    @discardableResult
    static func forEachBatch(of url: URL, _ body: (CodingAgentJSONLines) -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let stream = ZSTD_createDStream() else { throw DecodeError(description: "no zstd decoder") }
        defer { ZSTD_freeDStream(stream) }
        let initialized = ZSTD_initDStream(stream)
        if ZSTD_isError(initialized) != 0 { throw decodeError(initialized) }

        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: outputSize, alignment: 1)
        defer { output.deallocate() }
        var pending = Data()
        var total = 0
        // Zero once a frame has ended and all of it has been written out.
        var inFrame = false

        while let input = try autoreleasepool(invoking: { try handle.read(upToCount: readSize) }),
              !input.isEmpty {
            try input.withUnsafeBytes { raw in
                var source = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                // Zstd keeps the last byte of a frame until the frame's output is
                // all written, so this loop also drains a full output buffer.
                while source.pos < source.size {
                    var target = ZSTD_outBuffer(dst: output.baseAddress, size: output.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &target, &source)
                    if ZSTD_isError(result) != 0 { throw decodeError(result) }
                    inFrame = result != 0
                    guard target.pos > 0 else { continue }
                    total += target.pos
                    let searchFrom = pending.endIndex
                    pending.append(output.baseAddress!.assumingMemoryBound(to: UInt8.self), count: target.pos)
                    if let newline = pending[searchFrom...].lastIndex(of: 0x0A) {
                        let cut = pending.index(after: newline)
                        autoreleasepool { body(CodingAgentJSONLines(data: pending[pending.startIndex..<cut])) }
                        pending = Data(pending[cut...])
                    }
                }
            }
        }
        if inFrame { throw DecodeError(description: "the file ends inside a zstd frame") }
        if !pending.isEmpty {
            autoreleasepool { body(CodingAgentJSONLines(data: pending)) }
        }
        return total
    }

    private static func decodeError(_ code: Int) -> DecodeError {
        DecodeError(description: String(cString: ZSTD_getErrorName(code)))
    }
}
