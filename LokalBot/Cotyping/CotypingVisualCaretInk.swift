import CoreGraphics

/// Measures a recognized line from the image's own pixels. The recognition that
/// reads Cyrillic gives only word boxes, which ran up to 6 pt past the text, and
/// the one with character boxes cannot read it and lost whole words from either
/// end (16 pt, measured 2026-11-02). A field's text sits on a flat background,
/// so its ink says where the text starts and ends, whatever the letters are.
nonisolated enum CotypingVisualCaretInk {
    /// An image as 8-bit gray, top row first.
    struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn: Bool = pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// A line's ink, in pixels from the image's top-left corner.
    struct Line: Equatable {
        /// The columns its text covers, without the app's caret.
        var columns: Range<Int>
        /// The rows its text covers.
        var rows: Range<Int>
        /// The first row below the letters that sit on the baseline.
        var baselineRow: Int
        var caretColumns: Range<Int>?
        /// Words its text has, counted from the gaps between its ink.
        var wordCount = 1
    }

    /// Letters as thin and straight as a caret: at the end of the line, only
    /// reaching below the baseline tells the caret from one of them.
    private static let caretLikeLetters: Set<Character> = ["l", "I", "1", "|", "i", "і", "ї", "j", "ј", "!", "t", "f"]
    /// Wider than this is not a caret, in points. Carets seen are 1 to 2 pt, and
    /// a capture scaled up from a 1x display blurs them by half a point a side.
    private static let widestCaret: CGFloat = 3.5
    /// How far below the baseline a caret reaches at least, in points.
    private static let caretDescent: CGFloat = 1.2
    /// Pixels at the edge of the image are the field's border, if it has one.
    private static let edgeMargin: CGFloat = 2
    /// A gap wider than this share of the capitals' height is between words. At
    /// 14 pt, letters leave up to 2 pt and a space 4 pt or more.
    private static let wordGap: CGFloat = 0.3

    /// The ink of the line recognition boxed as `line`. Boxes are normalized,
    /// with y up, as recognition gives them. Nil when the line is not on a flat
    /// background, so that its ink cannot be told from what is behind it.
    static func measure(
        _ bitmap: Bitmap, line: CGRect, firstWord: CGRect, lastWord: CGRect,
        pixelsPerPoint: CGFloat, lastTypedLetter: Character?
    ) -> Line? {
        let width = CGFloat(bitmap.width), height = CGFloat(bitmap.height)
        let lineHeight = line.height * height
        // Below the box too, where a caret reaches: boxes follow the letters.
        let rows = max(0, Int((1 - line.maxY) * height))..<min(bitmap.height, Int((1 - line.minY) * height + lineHeight / 10))
        let wordEnd = Int(lastWord.maxX * width)
        let margin = Int(edgeMargin * pixelsPerPoint)
        let first = max(margin, Int(firstWord.minX * width - 2 * pixelsPerPoint))
        // Past the last word, as far as a caret after a few typed spaces.
        let last = min(bitmap.width - margin, Int(lastWord.maxX * width + lineHeight * 1.5))
        guard rows.count >= 3, first < last,
              let band = Band(bitmap: bitmap, rows: rows, columns: first..<last) else { return nil }

        let runs = band.runs()
        // Ink past the word's box is not its text. It can still be the caret.
        let textRuns = runs.prefix { $0.lowerBound <= wordEnd }
        guard let lastTextRun = textRuns.last, let baselineRow = band.baselineRow(of: textRuns) else { return nil }
        let textTop = band.rows(of: textRuns)?.lowerBound ?? rows.lowerBound
        let caretBottom = baselineRow + Int((caretDescent * pixelsPerPoint).rounded(.up))

        var caret: Range<Int>?
        if runs.count >= 2, let run = runs.last,
           band.isCaretShaped(
            run, textTop: textTop, baselineRow: baselineRow, caretBottom: caretBottom,
            widest: Int(widestCaret * pixelsPerPoint), lastTypedLetter: lastTypedLetter) {
            caret = run
        } else if lastTypedLetter != "]" {
            caret = band.caretOnTheEnd(
                of: lastTextRun, top: textTop + (baselineRow - textTop) / 10, bottom: caretBottom,
                widest: Int(widestCaret * pixelsPerPoint), blur: Int(pixelsPerPoint))
        }

        // The text ends before the caret, on the same run when it touches the last letter.
        var textEnd = lastTextRun.upperBound
        if let caret, caret.lowerBound < textEnd {
            let runBefore = caret.lowerBound == lastTextRun.lowerBound ? textRuns.dropLast().last : nil
            textEnd = runBefore?.upperBound ?? caret.lowerBound
        }
        guard runs[0].lowerBound < textEnd else { return nil }
        let textRows = band.rows(of: textRuns.filter { $0 != caret }) ?? rows
        let smallestWordGap = max(2, Int(wordGap * CGFloat(baselineRow - textTop)))
        let textRunEnds = runs.prefix { $0.lowerBound < textEnd }
        let gaps = zip(textRunEnds, textRunEnds.dropFirst()).filter { $1.lowerBound - $0.upperBound >= smallestWordGap }
        return Line(
            columns: runs[0].lowerBound..<textEnd, rows: textRows, baselineRow: baselineRow, caretColumns: caret,
            wordCount: gaps.count + 1)
    }

    /// The rows of one recognized line, against its background.
    private struct Band {
        let bitmap: Bitmap
        let rows: Range<Int>
        let columns: Range<Int>
        let background: Int
        let threshold: Int

        init?(bitmap: Bitmap, rows: Range<Int>, columns: Range<Int>) {
            var histogram = [Int](repeating: 0, count: 256)
            for y in rows {
                for x in columns { histogram[Int(bitmap.pixels[y * bitmap.width + x])] += 1 }
            }
            guard let background = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) else { return nil }
            // Text covers well under half of its line; more than that is a picture.
            let flat = histogram[max(0, background - 3)...min(255, background + 3)].reduce(0, +)
            guard flat * 5 >= rows.count * columns.count * 2 else { return nil }
            let contrast = histogram.indices.filter { histogram[$0] > 0 }.map { abs($0 - background) }.max() ?? 0
            guard contrast >= 40 else { return nil }
            self.bitmap = bitmap
            self.rows = rows
            self.columns = columns
            self.background = background
            // Well below full contrast: at 1x a thin stroke is never drawn solid.
            threshold = max(24, contrast * 3 / 10)
        }

        func isInk(_ x: Int, _ y: Int) -> Bool {
            abs(Int(bitmap.pixels[y * bitmap.width + x]) - background) >= threshold
        }

        /// Runs of columns with ink in them, left to right.
        func runs() -> [Range<Int>] {
            var result: [Range<Int>] = []
            var start: Int?
            for x in columns {
                if rows.contains(where: { isInk(x, $0) }) {
                    if start == nil { start = x }
                } else if let begun = start {
                    result.append(begun..<x)
                    start = nil
                }
            }
            if let begun = start { result.append(begun..<columns.upperBound) }
            return result
        }

        /// The rows `runs` have ink in, top to bottom.
        func rows(of runs: some Sequence<Range<Int>>) -> Range<Int>? {
            let inked = rows.filter { y in runs.contains { $0.contains { isInk($0, y) } } }
            guard let top = inked.first, let bottom = inked.last else { return nil }
            return top..<(bottom + 1)
        }

        /// Most letters end on the baseline, so ink falls off most just below it.
        func baselineRow(of runs: some Sequence<Range<Int>>) -> Int? {
            let profile = rows.map { y in runs.reduce(0) { $0 + $1.filter { isInk($0, y) }.count } }
            guard profile.count >= 2 else { return nil }
            var best: (row: Int, fall: Int)?
            for index in max(1, profile.count / 2)..<profile.count {
                let fall = profile[index - 1] - profile[index]
                if fall > (best?.fall ?? 0) { best = (rows.lowerBound + index, fall) }
            }
            return best?.row ?? rows.upperBound
        }

        /// A run on its own that looks like the app's caret: a thin, straight bar
        /// as tall as the capitals. It reaches below the baseline as a letter that
        /// shape does not, unless it could not be one of the letters typed.
        func isCaretShaped(
            _ run: Range<Int>, textTop: Int, baselineRow: Int, caretBottom: Int,
            widest: Int, lastTypedLetter: Character?
        ) -> Bool {
            guard run.count <= widest else { return false }
            let inked = rows.filter { y in run.contains { isInk($0, y) } }
            guard let top = inked.first, let bottom = inked.last else { return false }
            let height = bottom + 1 - top
            guard inked.count * 10 >= height * 9, height * 10 >= (baselineRow - textTop) * 9 else { return false }
            // Most of its box is ink, unlike a bracket or a slash, which reach as far.
            let inkPixels = rows.reduce(0) { total, y in total + run.filter { isInk($0, y) }.count }
            guard inkPixels * 10 >= run.count * height * 7 else { return false }
            if bottom + 1 >= caretBottom { return true }
            guard let lastTypedLetter else { return false }
            return !CotypingVisualCaretInk.caretLikeLetters.contains(lastTypedLetter)
        }

        /// The app's caret touching the last letter, so one run with it: columns
        /// on the run's right edge with ink all the way from the top of the
        /// capitals to below the baseline. No letter ends that way on its right,
        /// and of what else is typed only "]" does.
        func caretOnTheEnd(of run: Range<Int>, top: Int, bottom: Int, widest: Int, blur: Int) -> Range<Int>? {
            guard top < bottom, rows.contains(bottom - 1), rows.contains(top) else { return nil }
            var x = run.upperBound - 1
            var caretEnd: Int?
            while x >= run.lowerBound {
                let isFull = (top..<bottom).allSatisfy { isInk(x, $0) }
                if isFull {
                    if caretEnd == nil { caretEnd = x + 1 }
                } else if caretEnd != nil {
                    break
                } else if run.upperBound - x > blur {
                    return nil
                }
                x -= 1
            }
            guard x >= run.lowerBound, caretEnd != nil else { return nil }
            let caret = (x + 1)..<run.upperBound
            return caret.count <= widest ? caret : nil
        }
    }
}
