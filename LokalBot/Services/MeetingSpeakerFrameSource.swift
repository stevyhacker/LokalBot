import CoreImage
import Foundation
import ScreenCaptureKit
import Vision

/// A single latest-frame slot. Pixels never leave this object or reach storage.
final class MeetingSpeakerFrameSource: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        var buffer: CVPixelBuffer
        var hostTime: Double
    }
    private let lock = NSLock()
    private var latest: Frame?
    private var activeStreamID: ObjectIdentifier?
    private var stream: SCStream?
    private var windowID: CGWindowID?
    private var windowSize: CGSize?
    private let queue = DispatchQueue(label: "lokalbot.meeting-speaker.frames", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor func start(window: SCWindow) async throws {
        if windowID == window.windowID, windowSize == window.frame.size { return }
        await stop()
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        // AX rectangles exclude the window shadow. Keep the capture in the
        // same coordinate space, including when a window is smaller than output.
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.preservesAspectRatio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        let scale = min(2, 2_048 / max(1, window.frame.width), sqrt(2_097_152 / max(1, window.frame.width * window.frame.height)))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        let created = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        windowID = window.windowID
        windowSize = window.frame.size
        stream = created
        activate(created)
        do { try await created.startCapture() } catch { await stop(); throw error }
    }

    @MainActor func stop() async {
        let old = stream
        stream = nil
        windowID = nil
        windowSize = nil
        activate(nil)
        try? await old?.stopCapture()
        clear()
    }
    private func clear() { lock.lock(); latest = nil; lock.unlock() }
    private func activate(_ stream: SCStream?) {
        lock.lock()
        activeStreamID = stream.map(ObjectIdentifier.init)
        latest = nil
        lock.unlock()
    }
    func frame() -> Frame? { lock.lock(); defer { lock.unlock() }; return latest }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let status = metadata[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let ticks = metadata[.displayTime] as? UInt64,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = Frame(buffer: pixels, hostTime: RecordingAudioClock.hostSeconds(ticks))
        lock.lock()
        if activeStreamID == ObjectIdentifier(stream) { latest = frame }
        lock.unlock()
    }

    private func crop(_ tile: MeetingParticipantTile, in frame: Frame, window: CGRect, minimumSize: CGFloat = 60) -> CGImage? {
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let scaleX = image.extent.width / window.width
        let scaleY = image.extent.height / window.height
        let local = CGRect(x: (tile.frame.minX - window.minX) * scaleX,
            y: image.extent.height - (tile.frame.maxY - window.minY) * scaleY,
            width: tile.frame.width * scaleX, height: tile.frame.height * scaleY).integral
        guard image.extent.contains(local), local.width >= minimumSize, local.height >= minimumSize,
              let crop = context.createCGImage(image, from: local) else { return nil }
        return crop
    }

    /// Only text in the bottom-left name strip can corroborate an AX candidate.
    static func recognizesName(_ name: String, in crop: CGImage) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 0.85, height: min(0.30, 80 / Double(crop.height)))
        guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil else { return false }
        return request.results?.contains(where: {
            guard let text = $0.topCandidates(1).first, text.confidence >= 0.85 else { return false }
            return ParticipantObservation.nameKey(text.string) == ParticipantObservation.nameKey(name)
        }) == true
    }

    func verifiesName(_ tile: MeetingParticipantTile, in frame: Frame, window: CGRect) -> Bool {
        guard let crop = crop(tile, in: frame, window: window) else { return false }
        return Self.recognizesName(tile.name, in: crop)
    }

    /// Runs off the main actor. Names can be retained even when a tile is silent.
    func activeTile(_ tile: MeetingParticipantTile, in frame: Frame, window: CGRect, verifyName: Bool) -> Bool {
        guard let crop = crop(tile, in: frame, window: window),
              !verifyName || Self.recognizesName(tile.name, in: crop) else { return false }
        if Self.hasActiveBorderAndEqualizer(crop) { return true }
        guard let indicatorFrame = tile.activityIndicatorFrame else { return false }
        var outlined = tile
        outlined.frame = tile.frame.insetBy(dx: -4, dy: -4).intersection(window)
        var badge = tile
        badge.frame = indicatorFrame
        guard let outline = self.crop(outlined, in: frame, window: window),
              let indicator = self.crop(badge, in: frame, window: window, minimumSize: 12) else { return false }
        return Self.hasSpeakingOutline(outline) && Self.hasSpeakingBadge(indicator)
    }

    /// Current Meet themes pair a blue/peach outline with a blue audio badge
    /// in the named People row. Neither a border nor an unmuted mic suffices.
    static func hasSpeakingOutline(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width >= 80, height >= 60, width * height <= 4_194_304 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard render(image, into: &pixels, width: width, height: height) else { return false }
        func colored(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            let red = Int(pixels[i]), green = Int(pixels[i + 1]), blue = Int(pixels[i + 2])
            return (blue > 175 && blue - red > 30 && green > 110)
                || (red > 220 && green > 130 && blue > 110 && red - blue > 35)
        }
        let band = min(12, max(4, Int(Double(min(width, height)) * 0.015)))
        let xs = stride(from: width / 8, to: width * 7 / 8, by: max(1, width / 100))
        let ys = stride(from: height / 8, to: height * 7 / 8, by: max(1, height / 100))
        let top = xs.filter { x in (0..<band).contains { colored(x, $0) } }.count
        let bottom = xs.filter { x in (0..<band).contains { colored(x, height - 1 - $0) } }.count
        let left = ys.filter { y in (0..<band).contains { colored($0, y) } }.count
        let right = ys.filter { y in (0..<band).contains { colored(width - 1 - $0, y) } }.count
        guard [top, bottom].allSatisfy({ Double($0) / Double(Array(xs).count) > 0.7 }),
              [left, right].allSatisfy({ Double($0) / Double(Array(ys).count) > 0.7 }) else { return false }
        // A solid theme-colored picture is not an outline.
        let interior = (1..<8).flatMap { x in (1..<8).map { y in colored(x * width / 8, y * height / 8) } }
        return interior.filter { $0 }.count < interior.count / 2
    }

    static func hasSpeakingBadge(_ image: CGImage) -> Bool {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard render(image, into: &pixels, width: size, height: size) else { return false }
        func blue(_ x: Int, _ y: Int) -> Bool {
            let i = (y * size + x) * 4
            return pixels[i + 2] > 170 && pixels[i + 1] > 120 && Int(pixels[i + 2]) - Int(pixels[i]) > 15
        }
        func ink(_ x: Int, _ y: Int) -> Bool {
            let i = (y * size + x) * 4
            return pixels[i] < 100 && pixels[i + 1] < 120 && pixels[i + 2] < 150
        }
        let bluePixels = (6..<26).flatMap { x in (6..<26).map { y in blue(x, y) } }.filter { $0 }.count
        guard bluePixels > 180 else { return false }
        let heights = (0..<size).map { x in (10..<22).filter { ink(x, $0) }.count }
        var runs: [[Int]] = []
        for x in 6..<26 where heights[x] >= 2 {
            if runs.last?.last == x - 1 { runs[runs.count - 1].append(x) } else { runs.append([x]) }
        }
        guard runs.count == 3, runs.allSatisfy({ (1...5).contains($0.count) }) else { return false }
        // Three resting dots also appear on an idle unmuted participant.
        let bars = runs.map { run in run.map { heights[$0] }.max() ?? 0 }
        return (bars.max() ?? 0) >= 6 && (bars.max() ?? 0) - (bars.min() ?? 0) >= 2
    }

    private static func render(_ image: CGImage, into pixels: inout [UInt8], width: Int, height: Int) -> Bool {
        pixels.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
    }

    static func hasActiveBorderAndEqualizer(_ image: CGImage) -> Bool {
        // Shape + border jointly: a pinned blue tile, presenter highlight, or
        // arbitrary blue image alone is insufficient. Unsupported themes abstain.
        let width = 160, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        func blue(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset + 2] > 150 && Int(pixels[offset + 2]) - Int(pixels[offset]) > 55 && pixels[offset + 1] > 85
        }
        let horizontal = (8..<(width - 8)).filter { blue($0, 1) || blue($0, 2) }.count
        let vertical = (8..<(height - 8)).filter { blue(1, $0) || blue(2, $0) }.count
        guard horizontal > 100, vertical > 55 else { return false }
        // Three separated narrow columns with a taller middle bar in a corner.
        for originX in [8, width - 28] {
            for originY in [8, height - 28] {
                let columns = (0..<20).map { x in (0..<20).filter { y in blue(originX + x, originY + y) }.count }
                var runs: [[Int]] = []
                for (index, count) in columns.enumerated() where count >= 3 && count <= 15 {
                    if let last = runs.last?.last, index == last + 1 { runs[runs.count - 1].append(index) } else { runs.append([index]) }
                }
                if runs.count == 3, runs.allSatisfy({ (1...4).contains($0.count) }),
                   let middle = runs[1].map({ columns[$0] }).max(),
                   middle >= 7, middle > (runs[0].map { columns[$0] }.max() ?? 0),
                   middle > (runs[2].map { columns[$0] }.max() ?? 0) { return true }
            }
        }
        return false
    }
}
