import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The answer to a question asked in the meeting, read from something the
/// person had on screen earlier. Built for the Meta Global AI Developer
/// Hackathon (2026).
struct RadarScreenAnswer: Codable, Equatable, Sendable {
    var text: String
    /// What the screenshot says, as read on this Mac; the model's quote had
    /// to match it.
    var quote: String
    var snapshotID: Int64
    var capturedAt: Date
    var app: String
    var windowTitle: String
    /// The crop Muse saw, relative to the meeting folder.
    var image: String
    var model: String
}

/// A screen capture local search found for a question.
struct RadarScreenCapture: Sendable {
    let snapshotID: Int64
    let capturedAt: Date
    let app: String
    let windowTitle: String
    /// The decrypted image (HEIC, PNG or JPEG), read only when needed.
    let imageData: @Sendable () async -> Data?
}

/// Screen memory as the radar sees it: captures from before now whose text
/// matches a question. Search runs on this Mac.
@MainActor
protocol RadarScreenSource: AnyObject {
    func captures(for question: String, before: Date, limit: Int) async -> [RadarScreenCapture]
}

/// The part of a capture that is sent, and its text as read on this Mac.
struct RadarScreenCrop: Sendable {
    let jpeg: Data
    let text: String
}

/// Screen answers: when Live Radar catches a question, local screen search
/// finds earlier captures that mention it, Vision on this Mac crops each one
/// to the rows that do, and Muse Spark reads the crops. An answer counts only
/// when its quote is in the crop's own text, so the model can't invent one.
/// Off by default; only the crops (with their app, window title, and time)
/// are sent.
enum RadarScreenAnswers {
    static let maximumCrops = 3
    static let maximumCropWidth = 1_600
    static let folderName = "radar-answers"

    static let system = """
    You answer a question that was just asked in a meeting, using only the screenshots attached. \
    They are crops of the person's own screen from before the question, found by searching their screen history.

    - Answer only when one screenshot plainly shows the answer. Give it in a few words, as the person would say it, \
    and the number of that image.
    - Quote the whole line the answer is on, its label and its value together (for example "Trial to paid, \
    September 4.1%"), copied character for character from the image.
    - Use the meeting date to read relative words like "last month".
    - If no screenshot answers the question, reply with an empty answer, image 0, and an empty quote. Never guess or \
    use outside knowledge.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["answer", "image", "quote"],
        "properties": [
            "answer": ["type": "string"],
            "image": ["type": "integer"],
            "quote": ["type": "string"],
        ],
    ]

    private static let stopWords: Set<String> = [
        "what", "when", "where", "which", "who", "whom", "whose", "why", "how", "does", "did", "do", "was", "were",
        "is", "are", "the", "our", "your", "their", "this", "that", "these", "those", "with", "from", "about", "have",
        "has", "had", "will", "would", "could", "should", "there", "they", "them", "and", "for", "any", "way",
        "question", "open", "asked", "know", "remember", "again", "anyone", "someone", "still",
    ]

    /// Words worth finding on screen: no question words or fillers, three or
    /// more letters, or any number.
    static func terms(_ question: String) -> [String] {
        var seen = Set<String>()
        return MeetingRadarAnalyzer.normalized(question).split(separator: " ").map(String.init).filter { word in
            (word.count >= 3 || word.contains(where: \.isNumber)) && !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    /// What to look for: the question as the radar wrote it, plus the words
    /// actually said.
    static func question(_ item: RadarItem) -> String {
        item.text == item.quote ? item.quote : "\(item.text) (“\(item.quote)”)"
    }

    /// Local search, then cropping on this Mac: up to `maximumCrops` captures
    /// whose text mentions the question's words.
    @MainActor
    static func crops(for question: String, from source: RadarScreenSource,
                      before: Date = Date()) async -> [(capture: RadarScreenCapture, crop: RadarScreenCrop)] {
        let terms = terms(question)
        var crops: [(capture: RadarScreenCapture, crop: RadarScreenCrop)] = []
        for capture in await source.captures(for: question, before: before, limit: 6) {
            guard crops.count < maximumCrops, !Task.isCancelled else { break }
            guard let data = await capture.imageData(),
                  let crop = await Task.detached(priority: .userInitiated, operation: { Self.crop(data, terms: terms) }).value
            else { continue }
            crops.append((capture, crop))
        }
        return crops
    }

    // MARK: - Cropping

    /// Loads Vision's text recognizer ahead of the first question. Its very
    /// first use on a Mac can take many seconds.
    nonisolated static func warmUp() {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage() else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
    }

    /// Reads the capture's text on this Mac and keeps a band around the lines
    /// that mention the question's words, as wide as the text in it. Nil when
    /// none do.
    nonisolated static func crop(_ data: Data, terms: [String]) -> RadarScreenCrop? {
        guard !terms.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
        let scored = lines.map { line -> (line: (text: String, box: CGRect), score: Int) in
            let words = Set(MeetingRadarAnalyzer.normalized(line.text).split(separator: " ").map(String.init))
            return (line, terms.filter { words.contains($0) }.count)
        }
        let best = scored.map(\.score).max() ?? 0
        guard best > 0 else { return nil }
        // The strongest matches, and the band around them, at most half the
        // screen tall, centered on the best one when they spread wider.
        let matched = scored.filter { $0.score >= max(1, best - 1) }.map(\.line.box)
        let top = scored.first { $0.score == best }!.line.box
        let pad = 0.06
        var band = matched.reduce(top) { $0.union($1) }.insetBy(dx: 0, dy: -pad)
        if band.height > 0.5 {
            band = CGRect(x: 0, y: top.midY - 0.25, width: 1, height: 0.5)
        }
        band = CGRect(x: 0, y: max(0, band.minY), width: 1, height: min(1, band.maxY) - max(0, band.minY))
        let inside = lines.filter { band.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        // Only as wide as the text in the band, so the crop stays readable
        // in the narrow radar pane and leaves the rest of the screen out.
        let columns = inside.map(\.box).reduce(top) { $0.union($1) }
        band.origin.x = max(0, columns.minX - 0.03)
        band.size.width = min(1, columns.maxX + 0.03) - band.origin.x
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision's origin is bottom-left; CGImage cropping is top-left.
        let pixels = CGRect(x: band.minX * width, y: (1 - band.maxY) * height,
                            width: band.width * width, height: band.height * height).integral
        guard let cropped = image.cropping(to: pixels), let jpeg = jpegData(cropped) else { return nil }
        return RadarScreenCrop(jpeg: jpeg, text: readingOrder(inside))
    }

    /// Top to bottom, and left to right within a row, so a label and its value
    /// on one row read as one line.
    static func readingOrder(_ lines: [(text: String, box: CGRect)]) -> String {
        var rows: [[(text: String, box: CGRect)]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - line.box.midY) < max(last.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        var output = image
        if image.width > maximumCropWidth {
            let scale = CGFloat(maximumCropWidth) / CGFloat(image.width)
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Request and grounding

    static func messages(question: String, meetingTitle: String, meetingDate: Date,
                         crops: [(capture: RadarScreenCapture, crop: RadarScreenCrop)]) -> [[String: Any]] {
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "Meeting: \(meetingTitle), \(meetingDate.formatted(date: .complete, time: .shortened))\nQuestion: \(question)",
        ]]
        for (index, entry) in crops.enumerated() {
            let title = entry.capture.windowTitle.isEmpty ? "" : " — \(entry.capture.windowTitle)"
            content.append(["type": "text", "text": "Image \(index + 1): \(entry.capture.app)\(title), on screen "
                + entry.capture.capturedAt.formatted(date: .abbreviated, time: .shortened)])
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64," + entry.crop.jpeg.base64EncodedString()]])
        }
        return [["role": "system", "content": system], ["role": "user", "content": content]]
    }

    /// The answer and which crop it came from, when its quote is in that
    /// crop's own text.
    static func answer(from reply: String, crops: [RadarScreenCrop]) -> (text: String, quote: String, index: Int)? {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = (object["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let quote = (object["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let image = object["image"] as? Int,
              !answer.isEmpty, crops.indices.contains(image - 1) else { return nil }
        guard quoteIsOnScreen(quote, text: crops[image - 1].text) else { return nil }
        return (answer, quote, image - 1)
    }

    /// The whole quote in the crop's text, ignoring case and punctuation, or
    /// most of a longer quote's words, as radar quotes are checked.
    static func quoteIsOnScreen(_ quote: String, text: String) -> Bool {
        let quoteText = MeetingRadarAnalyzer.normalized(quote)
        guard !quoteText.isEmpty else { return false }
        let screen = " " + MeetingRadarAnalyzer.normalized(text) + " "
        if screen.contains(" " + quoteText + " ") { return true }
        return quoteText.split(separator: " ").count >= 3
            && text.split(separator: "\n").contains { MeetingRadarAnalyzer.quoteMatches(quote, line: String($0)) }
    }
}

/// Screen memory through the app's activity store: OCR search on this Mac,
/// captures from before the question, never LokalBot's own windows.
@MainActor
final class LibraryRadarScreenSource: RadarScreenSource {
    private let store: ActivityStore

    init(store: ActivityStore) {
        self.store = store
    }

    func captures(for question: String, before: Date, limit: Int) async -> [RadarScreenCapture] {
        let query = RadarScreenAnswers.terms(question).joined(separator: " ")
        guard !query.isEmpty else { return [] }
        let filter = ScreenSearchFilter(interval: DateInterval(start: .distantPast, end: before))
        let hits = store.searchOCR(query, limit: limit * 3, matchAll: false, dropStopWords: true, filter: filter)
        guard !hits.isEmpty, let key = try? ScreenshotService.encryptionKey() else { return [] }
        return hits.filter { !$0.app.localizedCaseInsensitiveContains("LokalBot") }.prefix(limit).compactMap { hit in
            guard let shot = store.screenshot(id: hit.snapshotID), shot.hasPixels else { return nil }
            let path = shot.path
            return RadarScreenCapture(
                snapshotID: hit.snapshotID, capturedAt: hit.ts, app: hit.app, windowTitle: hit.windowTitle,
                imageData: { ScreenshotService.decryptedData(path: path, key: key) })
        }
    }
}
