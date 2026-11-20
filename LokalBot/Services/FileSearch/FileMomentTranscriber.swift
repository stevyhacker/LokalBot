import AVFoundation
import Foundation

@MainActor
final class FileMomentTranscriber {
    static let window: TimeInterval = 30
    static let cacheLimit = 64

    typealias Transcribe = @MainActor (_ clip: URL) async throws -> String

    var isAvailable: () -> Bool
    private let transcribe: Transcribe
    private var cache: [String: String] = [:]
    private var order: [String] = []

    init(isAvailable: @escaping () -> Bool, transcribe: @escaping Transcribe) {
        self.isAvailable = isAvailable
        self.transcribe = transcribe
    }

    static func live(settings: @escaping () -> AppSettings, isRecording: @escaping () -> Bool) -> FileMomentTranscriber {
        FileMomentTranscriber(
            isAvailable: { ModelReadinessSnapshot.transcriptionReady(settings()) && !isRecording() },
            transcribe: { clip in
                let configuration = settings()
                let transcript = try await configuration.transcriptionEngine().transcribe(
                    audio: clip, language: configuration.transcriptionLanguage.code, prompt: nil)
                return transcript.segments.map(\.text).joined(separator: " ")
            })
    }

    func passage(for hit: FileSearchHit) async -> String? {
        guard hit.kind == .audio || hit.kind == .video, let start = hit.seconds, isAvailable() else { return nil }
        let modified = (try? hit.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(hit.path)|\(modified)|\(Int(start))"
        if let cached = cache[key] { return cached }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-moment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let clip = folder.appendingPathComponent("moment.m4a")
            try await Self.exportClip(of: hit.url, from: start, duration: Self.window, to: clip)
            let text = try await transcribe(clip).trimmingCharacters(in: .whitespacesAndNewlines)
            remember(text, for: key)
            return text.isEmpty ? nil : text
        } catch {
            lokalbotLog("file search: could not transcribe a moment: \(error.localizedDescription)")
            return nil
        }
    }

    private func remember(_ text: String, for key: String) {
        cache[key] = text
        order.append(key)
        if order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
    }

    nonisolated static func exportClip(of url: URL, from start: TimeInterval, duration: TimeInterval,
                                       to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let total = try await asset.load(.duration).seconds
        let begin = max(0, min(start, max(0, total - 0.5)))
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: begin, preferredTimescale: 600),
            duration: CMTime(seconds: min(duration, max(0.5, total - begin)), preferredTimescale: 600))
        try await exporter.export(to: output, as: .m4a)
    }
}
