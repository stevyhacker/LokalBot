import Foundation

struct LibrarySearchPrefilter {
    private let terms: [[[UInt8]]]
    private var foldedScalars: [UInt32: [UInt8]?] = [:]
    private let output = Output()

    private static let separator = UInt8(ascii: " ")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let textKey = Array("text".utf8)
    private static let unicodeEscape = Array(#"\u"#.utf8)

    private static let asciiFold: [UInt8] = (0..<128).map { value in
        let byte = UInt8(value)
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return byte | 0x20
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): return byte
        default: return separator
        }
    }

    init?(terms: [String]) {
        var groups: [[[UInt8]]] = []
        for term in terms {
            let words = term.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return nil }
            var group: [[UInt8]] = []
            for word in words {
                let decomposed = word.decomposedStringWithCanonicalMapping
                guard decomposed.unicodeScalars.allSatisfy(Self.isKeptInNeedle) else { return nil }
                group.append(Array(decomposed.utf8))
            }
            groups.append(group)
        }
        self.terms = groups
    }

    mutating func mayMatch(_ text: String) -> Bool {
        output.count = 0
        var text = text
        let readable = text.withUTF8 { appendText($0, from: 0, to: $0.count, jsonEscapes: false) }
        return !readable || containsATerm()
    }

    mutating func mayMatch(transcriptJSON data: Data) -> Bool {
        output.count = 0
        let readable = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            guard memchr(base, 0, raw.count) == nil,
                  memmem(base, raw.count, Self.unicodeEscape, Self.unicodeEscape.count) == nil else { return false }
            return appendTextValues(raw.bindMemory(to: UInt8.self))
        }
        return !readable || containsATerm()
    }

    private mutating func appendTextValues(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let origin = UnsafeRawPointer(base)
        let count = bytes.count
        var index = 0
        var valueIsText = false
        while index < count, let opening = memchr(base + index, Int32(Self.quote), count - index) {
            let start = origin.distance(to: opening) + 1
            var end = start
            while true {
                guard end < count, let found = memchr(base + end, Int32(Self.quote), count - end) else { return false }
                end = origin.distance(to: found)
                var backslashes = 0
                while end - backslashes > start, bytes[end - backslashes - 1] == Self.backslash { backslashes += 1 }
                if backslashes.isMultiple(of: 2) { break }
                end += 1
            }
            var next = end + 1
            while next < count, Self.isJSONWhitespace(bytes[next]) { next += 1 }
            if next < count, bytes[next] == Self.colon {
                valueIsText = end - start == Self.textKey.count
                    && memcmp(base + start, Self.textKey, Self.textKey.count) == 0
            } else {
                if valueIsText {
                    guard appendText(bytes, from: start, to: end, jsonEscapes: true) else { return false }
                    output.append(Self.separator)
                }
                valueIsText = false
            }
            index = end + 1
        }
        return true
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private mutating func appendText(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int,
                                     jsonEscapes: Bool) -> Bool {
        output.reserve(end - start)
        var out = output.bytes
        var written = output.count
        let fold = Self.asciiFold
        var index = start
        while index < end {
            let byte = bytes[index]
            if byte < 0x80 {
                if jsonEscapes, byte == Self.backslash {
                    out[written] = Self.separator
                    index += 2
                } else {
                    out[written] = fold[Int(byte)]
                    index += 1
                }
                written += 1
                continue
            }
            guard let (scalar, length) = Self.decodeUTF8(bytes, at: index, end: end),
                  let folded = foldedBytes(scalar) else { return false }
            index += length
            output.count = written
            output.reserve(folded.count + end - index)
            out = output.bytes
            folded.withUnsafeBufferPointer { out.advanced(by: written).update(from: $0.baseAddress!, count: $0.count) }
            written += folded.count
        }
        output.count = written
        return true
    }

    private static func decodeUTF8(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int, end: Int)
        -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        let length: Int
        let lowest: UInt32
        var value: UInt32
        switch lead {
        case 0xC2...0xDF: length = 2; lowest = 0x80; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF: length = 3; lowest = 0x800; value = UInt32(lead & 0x0F)
        case 0xF0...0xF4: length = 4; lowest = 0x10000; value = UInt32(lead & 0x07)
        default: return nil
        }
        guard index + length <= end else { return nil }
        for offset in 1..<length {
            let continuation = bytes[index + offset]
            guard continuation & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(continuation & 0x3F)
        }
        guard value >= lowest, let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }

    private mutating func foldedBytes(_ scalar: Unicode.Scalar) -> [UInt8]? {
        if let known = foldedScalars[scalar.value] { return known }
        let folded = Self.fold(scalar)
        foldedScalars[scalar.value] = folded
        return folded
    }

    private static func fold(_ scalar: Unicode.Scalar) -> [UInt8]? {
        let folded = String(scalar)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .decomposedStringWithCanonicalMapping
        if isCombining(scalar) {
            let letter = folded.unicodeScalars.contains {
                $0.isASCII ? asciiFold[Int($0.value)] != separator : isLetterOrDigit($0)
            }
            return letter ? nil : []
        }
        var bytes: [UInt8] = []
        for unit in folded.unicodeScalars {
            if unit.isASCII {
                let byte = asciiFold[Int(unit.value)]
                if byte != separator { bytes.append(byte) }
            } else if isLetterOrDigit(unit) {
                bytes.append(contentsOf: String(unit).utf8)
            }
        }
        return bytes
    }

    private static func isKeptInNeedle(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let byte = UInt8(scalar.value)
            return byte != separator && asciiFold[Int(byte)] == byte
        }
        return isLetterOrDigit(scalar)
    }

    private static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return scalar.properties.isGraphemeExtend
        }
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.properties.isGraphemeExtend else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private func containsATerm() -> Bool {
        let haystack = output.bytes
        let count = output.count
        return terms.contains { words in
            words.allSatisfy { word in
                word.withUnsafeBytes { needle in
                    memmem(haystack, count, needle.baseAddress, needle.count) != nil
                }
            }
        }
    }

    private final class Output {
        private(set) var bytes: UnsafeMutablePointer<UInt8>
        private var capacity: Int
        var count = 0

        init() {
            capacity = 64 * 1024
            bytes = .allocate(capacity: capacity)
        }

        deinit { bytes.deallocate() }

        func append(_ byte: UInt8) {
            reserve(1)
            bytes[count] = byte
            count += 1
        }

        func reserve(_ extra: Int) {
            guard count + extra > capacity else { return }
            while capacity < count + extra { capacity *= 2 }
            let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            grown.update(from: bytes, count: count)
            bytes.deallocate()
            bytes = grown
        }
    }
}
