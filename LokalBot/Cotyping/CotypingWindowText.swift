import CoreGraphics
import CryptoKit
import Foundation

/// Text read from the focused window's pixels for the "Use the focused window
/// as context" grant. Accessibility exposes little of what browsers, Electron
/// and Qt apps show; on-device text recognition sees every line. This is the
/// pure half: which recognized lines enter the prompt, in what order, and when
/// a newer read replaces the one in use. `CotypingWindowTextCapture` reads.
enum CotypingWindowText {
    /// One recognized line in AX global coordinates (origin at the top left).
    struct Line: Equatable, Sendable {
        var text: String
        var frame: CGRect
    }

    /// An on-screen window as ScreenCaptureKit lists it.
    struct WindowCandidate: Equatable, Sendable {
        var processID: pid_t
        var title: String?
        var frame: CGRect
        var layer: Int
    }

    /// About 500–700 prompt tokens: a typical chat or mail pane whole. The
    /// model reads it once when the window changes and reuses it while typing.
    static let maximumCharacters = 2_000
    static let maximumLineCharacters = 300
    /// Lines this close to the field are its border, label or placeholder.
    static let fieldMargin: CGFloat = 4
    /// Message bubbles sit a little inside or outside the field's edges.
    static let columnSlack: CGFloat = 24
    /// How long text that scrolled out of view may stay in use.
    static let maximumHeldAge: TimeInterval = 60
    /// New text shorter than this (a timestamp, a typing indicator) does not
    /// replace the text in use, which would make the model read it all again.
    static let minimumAddedCharacters = 12

    /// Identifies what text recognition would read from a window image apart
    /// from the field being typed in (its draft and blinking caret), whose
    /// lines a prompt never uses. Equal fingerprints let a reread reuse the
    /// last lines instead of recognizing the same window again (150–250 ms).
    /// The frames are part of it because they place the lines.
    static func fingerprint(of image: CGImage, windowFrame: CGRect, fieldFrame: CGRect) -> Data? {
        guard image.width > 0, image.height > 0, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        // Area-averaged to 512 pixels wide, a changed word still changes pixels.
        let width = 512
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Rows are stored top first, like the global coordinates of both frames.
        let field = fieldFrame.insetBy(dx: -fieldMargin, dy: -fieldMargin).intersection(windowFrame)
        if !field.isNull, !field.isEmpty {
            let scaleX = Double(width) / windowFrame.width
            let scaleY = Double(height) / windowFrame.height
            let minX = max(0, Int(((field.minX - windowFrame.minX) * scaleX).rounded(.down)) - 1)
            let maxX = min(width, Int(((field.maxX - windowFrame.minX) * scaleX).rounded(.up)) + 1)
            let minY = max(0, Int(((field.minY - windowFrame.minY) * scaleY).rounded(.down)) - 1)
            let maxY = min(height, Int(((field.maxY - windowFrame.minY) * scaleY).rounded(.up)) + 1)
            if minX < maxX {
                for row in minY..<maxY { pixels.replaceSubrange(row * width + minX..<row * width + maxX,
                                                               with: repeatElement(0, count: maxX - minX)) }
            }
        }
        var hasher = SHA256()
        for value in [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height,
                      fieldFrame.minX, fieldFrame.minY, fieldFrame.width, fieldFrame.height] {
            withUnsafeBytes(of: Double(value)) { hasher.update(bufferPointer: $0) }
        }
        pixels.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize())
    }

    /// The lines a prompt gets, in reading order. The draft itself never
    /// enters: it is already the text before the caret. Lines in the field's
    /// column above it come first, nearest the field first, so a long
    /// conversation keeps its newest messages; the rest of the window (titles,
    /// sidebars, panes beside or below the field) fills what is left and is
    /// placed before them, so the conversation ends right where the draft begins.
    static func excerpts(
        from lines: [Line], fieldFrame: CGRect, windowFrame: CGRect,
        maximumCharacters: Int = maximumCharacters
    ) -> [CotypingVisibleContext.Excerpt] {
        let field = fieldFrame.insetBy(dx: -fieldMargin, dy: -fieldMargin)
        let column = (fieldFrame.minX - columnSlack)...(fieldFrame.maxX + columnSlack)
        var above: [CotypingVisibleContext.Excerpt] = []
        var rest: [CotypingVisibleContext.Excerpt] = []
        for (index, line) in lines.enumerated() {
            guard valid(line.frame), line.frame.intersects(windowFrame), !line.frame.intersects(field),
                  let text = cleaned(line.text) else { continue }
            let excerpt = CotypingVisibleContext.Excerpt(id: "line-\(index)", frame: line.frame, text: text)
            if column.contains(line.frame.midX), line.frame.midY < fieldFrame.minY {
                above.append(excerpt)
            } else {
                rest.append(excerpt)
            }
        }
        var remaining = maximumCharacters
        // Stop at the first line that does not fit, so the kept part has no holes.
        func take(_ ordered: [CotypingVisibleContext.Excerpt]) -> [CotypingVisibleContext.Excerpt] {
            var kept: [CotypingVisibleContext.Excerpt] = []
            for excerpt in ordered {
                let cost = excerpt.text.count + 1
                guard cost <= remaining else { break }
                kept.append(excerpt)
                remaining -= cost
            }
            return kept
        }
        let conversation = take(above.sorted(by: nearestFirst))
        let surroundings = take(rest.sorted(by: readingOrder))
        return surroundings + conversation.sorted(by: readingOrder)
    }

    /// Whether a newer read should replace the window text in use. Rereading
    /// an unchanged window changes nothing, and lines that only scrolled out
    /// of view stay for a while, so the model's reading of the prompt survives
    /// typing; new text (a reply arriving) replaces it at once.
    static func shouldReplace(
        _ current: CotypingVisibleContext.Snapshot?, with new: CotypingVisibleContext.Snapshot,
        heldFor age: TimeInterval
    ) -> Bool {
        guard let current, !current.excerpts.isEmpty, age < maximumHeldAge,
              current.target.windowTitle == new.target.windowTitle,
              current.target.sourceURL == new.target.sourceURL else { return true }
        let known = Set(current.excerpts.map { comparable($0.text) })
        var added = 0
        for excerpt in new.excerpts where !known.contains(comparable(excerpt.text)) {
            added += excerpt.text.count
        }
        return added >= minimumAddedCharacters
    }

    /// The window a capture reads: the focused one's process and frame, and
    /// its title when the frame alone is ambiguous. Nil rather than a guess.
    static func windowIndex(in candidates: [WindowCandidate], processID: pid_t,
                            title: String?, frame: CGRect) -> Int? {
        let matches = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.processID == processID && candidate.layer == 0
                && abs(candidate.frame.minX - frame.minX) <= 2 && abs(candidate.frame.minY - frame.minY) <= 2
                && abs(candidate.frame.width - frame.width) <= 2 && abs(candidate.frame.height - frame.height) <= 2
        }
        if matches.count == 1 { return matches[0] }
        let titled = matches.filter { (candidates[$0].title ?? "") == (title ?? "") }
        return titled.count == 1 ? titled[0] : nil
    }

    /// A Vision bounding box (normalized, origin at the bottom left) in the
    /// AX coordinates of the window the image shows.
    static func frame(ofNormalized box: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + box.minX * windowFrame.width,
               y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
               width: box.width * windowFrame.width,
               height: box.height * windowFrame.height)
    }

    /// Identifies one field's window between reads. Field height and position
    /// are left out because a reply box grows as you type; a different title
    /// is another document, tab or conversation, whose text is not reused.
    static func key(processID: pid_t, role: String, windowTitle: String, fieldFrame: CGRect) -> String {
        [String(processID), role, windowTitle,
         String(Int(fieldFrame.minX.rounded())), String(Int(fieldFrame.width.rounded()))]
            .joined(separator: "\u{1f}")
    }

    /// Drops credential-bearing lines rather than teaching the model to
    /// complete a redaction marker, and lines with no letters or digits.
    static func cleaned(_ raw: String) -> String? {
        guard !CotypingSecureFieldDetector.isSecure(
            role: nil, subrole: nil, roleDescription: nil, title: raw, descriptionLabel: nil),
              let text = CotypingMemoryContext.sanitized(raw),
              text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(text.prefix(maximumLineCharacters))
    }

    /// Bottom-most first: the line just above the field is the newest message.
    private static func nearestFirst(_ left: CotypingVisibleContext.Excerpt,
                                     _ right: CotypingVisibleContext.Excerpt) -> Bool {
        left.frame.maxY == right.frame.maxY ? left.frame.minX < right.frame.minX : left.frame.maxY > right.frame.maxY
    }

    private static func readingOrder(_ left: CotypingVisibleContext.Excerpt,
                                     _ right: CotypingVisibleContext.Excerpt) -> Bool {
        left.frame.minY == right.frame.minY ? left.frame.minX < right.frame.minX : left.frame.minY < right.frame.minY
    }

    private static func comparable(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}
