import AVFoundation
import CryptoKit

/// Independently closed PCM checkpoints. Only the serial audio writer calls
/// append/close. Manifest failure never removes the surviving chunks.
final class AudioRecoveryJournal {
    struct Segment: Codable {
        var file: String
        var startFrame: Int64
        var frames: Int64
        var sha256: String
    }
    struct Manifest: Codable {
        struct Padding: Codable {
            var startFrame: Int64
            var frames: Int64
        }
        var version = 1
        var sampleRate: Double
        var channels: AVAudioChannelCount
        var segments: [Segment] = []
        var createdAt = Date()
        var padding: [Padding] = []
    }
    struct Recovery: Codable {
        var sourceSignature: String
        var frames: Int64
        var complete: Bool
        var outputSize: Int
        var outputDate: Date
    }

    static let checkpointSeconds: Double = 2
    let directory: URL
    private let format: AVAudioFormat
    private var manifest: Manifest
    private var file: AVAudioFile?
    private var segmentURL: URL?
    private var segmentStart: Int64 = 0
    private var framesWritten: Int64 = 0
    private var failedWrite = false
    private(set) var failureDescription: String?

    init(previewURL: URL, format: AVAudioFormat) throws {
        directory = Self.directory(for: previewURL)
        self.format = format
        manifest = Manifest(sampleRate: format.sampleRate, channels: format.channelCount)
        // Never overwrite an earlier attempt's journal.
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func directory(for previewURL: URL) -> URL {
        previewURL.deletingPathExtension().appendingPathExtension("recovery")
    }

    static func recoveredURL(for previewURL: URL) -> URL {
        previewURL.deletingPathExtension().appendingPathExtension("recovered.caf")
    }

    static func receiptURL(for previewURL: URL) -> URL {
        recoveredURL(for: previewURL).appendingPathExtension("json")
    }

    func append(_ buffer: AVAudioPCMBuffer, isPadding: Bool = false) throws {
        guard !failedWrite else { throw CocoaError(.fileWriteUnknown) }
        guard buffer.frameLength > 0 else { return }
        do {
            if file == nil {
                segmentStart = framesWritten
                let url = directory.appendingPathComponent("frame-\(segmentStart)-\(UUID().uuidString).caf")
                file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                segmentURL = url
            }
            try file?.write(from: buffer)
            if isPadding {
                if let last = manifest.padding.last, last.startFrame + last.frames == framesWritten {
                    manifest.padding[manifest.padding.count - 1].frames += Int64(buffer.frameLength)
                } else {
                    manifest.padding.append(.init(startFrame: framesWritten, frames: Int64(buffer.frameLength)))
                }
            }
            framesWritten += Int64(buffer.frameLength)
        } catch {
            // A partial write cannot be resumed at a guessed frame offset.
            failedWrite = true
            failureDescription = error.localizedDescription
            checkpoint()
            throw error
        }
        if Double(framesWritten - segmentStart) / format.sampleRate >= Self.checkpointSeconds {
            checkpoint()
        }
    }

    func close() { checkpoint() }

    private func checkpoint() {
        file?.close()
        file = nil
        guard let url = segmentURL else { return }
        segmentURL = nil
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
            let reader = try AVAudioFile(forReading: url)
            guard reader.length > 0 else { return }
            let digest = Self.digest(try Data(contentsOf: url))
            manifest.segments.append(.init(file: url.lastPathComponent, startFrame: segmentStart,
                                           frames: reader.length, sha256: digest))
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            if !failedWrite { failureDescription = nil }
        } catch { failureDescription = error.localizedDescription }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func receipt(previewURL: URL) -> Recovery? {
        (try? Data(contentsOf: receiptURL(for: previewURL)))
            .flatMap { try? JSONDecoder().decode(Recovery.self, from: $0) }
    }

    /// Decode the contiguous prefix, including an unmanifested last chunk left
    /// by process death. Corruption never hides an earlier verified interval or
    /// compresses a gap. Incomplete recovery retains every original chunk.
    static func recover(previewURL: URL) throws -> URL? {
        let directory = directory(for: previewURL)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        let chunks: [(URL, Int64)] = files.compactMap { url in
            let parts = url.lastPathComponent.split(separator: "-")
            guard parts.count >= 3, parts[0] == "frame", url.pathExtension == "caf",
                  let frame = Int64(parts[1]), frame >= 0,
                  (try? url.resourceValues(forKeys: keys).isSymbolicLink) == false else { return nil }
            return (url, frame)
        }.sorted { $0.1 < $1.1 }
        guard !chunks.isEmpty else {
            guard var cached = verifiedReceipt(previewURL: previewURL) else { return nil }
            cached.complete = false
            try JSONEncoder().encode(cached).write(to: receiptURL(for: previewURL), options: .atomic)
            return recoveredURL(for: previewURL)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try? Data(contentsOf: manifestURL)
        let manifest = data.flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        let signature = digest(Data((try chunks.map { url, _ in
            let values = try url.resourceValues(forKeys: keys)
            return "\(url.lastPathComponent):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")).utf8) + (data ?? Data()))
        let output = recoveredURL(for: previewURL)
        if let cached = receipt(previewURL: previewURL), cached.sourceSignature == signature,
           let values = try? output.resourceValues(forKeys: keys), values.isSymbolicLink == false,
           cached.outputSize == values.fileSize, cached.outputDate == values.contentModificationDate {
            return output
        }
        do {
            return try reconstruct(chunks: chunks, manifest: manifest, signature: signature, previewURL: previewURL)
        } catch {
            // A previous reconstruction can now be the only surviving copy.
            guard var cached = verifiedReceipt(previewURL: previewURL) else { throw error }
            cached.complete = false
            cached.sourceSignature = signature
            try JSONEncoder().encode(cached).write(to: receiptURL(for: previewURL), options: .atomic)
            return output
        }
    }

    private static func verifiedReceipt(previewURL: URL) -> Recovery? {
        let output = recoveredURL(for: previewURL)
        guard let cached = receipt(previewURL: previewURL),
              let values = try? output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]),
              values.isSymbolicLink == false, values.fileSize == cached.outputSize,
              values.contentModificationDate == cached.outputDate,
              AudioFileInspector.fullyDecodedDuration(at: output) != nil else { return nil }
        return cached
    }

    private static func reconstruct(chunks: [(URL, Int64)], manifest: Manifest?, signature: String,
                                    previewURL: URL) throws -> URL? {
        let directory = directory(for: previewURL)
        let temporary = directory.appendingPathComponent("reconstruct-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = try AVAudioFile(forReading: chunks[0].0)
        let format = first.processingFormat
        guard chunks[0].1 == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: format.settings)
        var frames: Int64 = 0
        var complete = manifest != nil
        if let manifest {
            complete = manifest.version == 1 && manifest.sampleRate == format.sampleRate
                && manifest.channels == format.channelCount
                && manifest.segments.count == chunks.count
                && manifest.segments.allSatisfy { segment in chunks.contains { $0.0.lastPathComponent == segment.file } }
        }
        for (url, start) in chunks {
            do {
                let reader = try AVAudioFile(forReading: url)
                guard reader.processingFormat == format, reader.length > 0, start == frames else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if let committed = manifest?.segments.first(where: { $0.file == url.lastPathComponent }) {
                    guard committed.startFrame == start, committed.frames == reader.length,
                          committed.sha256 == digest(try Data(contentsOf: url)) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                while reader.framePosition < reader.length {
                    try reader.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    try writer?.write(from: buffer)
                    frames += Int64(buffer.frameLength)
                }
            } catch { complete = false; break }
        }
        writer?.close()
        writer = nil
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let output = recoveredURL(for: previewURL)
        if var cached = verifiedReceipt(previewURL: previewURL), cached.frames > frames {
            // Never replace a previously verified full reconstruction with a
            // shorter prefix after a chunk is damaged or goes missing.
            cached.complete = false
            cached.sourceSignature = signature
            try JSONEncoder().encode(cached).write(to: receiptURL(for: previewURL), options: .atomic)
            return output
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
        let values = try output.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let receipt = Recovery(sourceSignature: signature, frames: frames, complete: complete,
                               outputSize: values.fileSize ?? 0, outputDate: values.contentModificationDate ?? .distantPast)
        try JSONEncoder().encode(receipt).write(to: receiptURL(for: previewURL), options: .atomic)
        return output
    }
}

enum AudioWriteSafety {
    /// Failure of the primary encoder cannot suppress the PCM copy.
    static func write(recovery: () -> Bool, primary: () throws -> Void) -> (saved: Bool, error: String?) {
        let recovered = recovery()
        do {
            try primary()
            return (true, nil)
        } catch { return (recovered, error.localizedDescription) }
    }
}
