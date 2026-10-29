import Foundation

/// Header and body text helpers shared by every mail provider.
enum EmailText {
    // MARK: Addresses

    /// Parses an address-list header (`To`, `Cc`, `From`): display names in
    /// quotes may contain commas, and groups (`team: a@x, b@y;`) are
    /// flattened. Entries without an `@` are dropped.
    static func addresses(_ header: String) -> [EmailAddress] {
        var results: [EmailAddress] = []
        for entry in splitAddressList(header) {
            if let address = address(entry) { results.append(address) }
        }
        return results
    }

    static func address(_ entry: String) -> EmailAddress? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        // A group label ends at an unquoted colon: "Team: ana@x.com".
        if let colon = unquotedIndex(of: ":", in: text), !text[..<colon].contains("@") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "; \t"))
        guard !text.isEmpty else { return nil }
        let name: String?
        let rawAddress: String
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            rawAddress = String(text[text.index(after: open)..<close])
            name = cleanDisplayName(String(text[..<open]))
        } else {
            rawAddress = text
            name = nil
        }
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = address.firstIndex(of: "@"), at != address.startIndex,
              address.index(after: at) != address.endIndex,
              !address.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," }) else {
            return nil
        }
        return EmailAddress(name: name, address: address)
    }

    private static func cleanDisplayName(_ raw: String) -> String? {
        var name = decodeEncodedWords(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Splits at commas outside quotes and angle brackets.
    private static func splitAddressList(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                escaped = true
                current.append(character)
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                angleDepth += 1
                current.append(character)
            case ">" where !inQuotes:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            case "," where !inQuotes && angleDepth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unquotedIndex(of target: Character, in text: String) -> String.Index? {
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "<" && !inQuotes { return nil }
            if character == target && !inQuotes { return index }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: Encoded words (RFC 2047)

    /// Decodes `=?charset?B?…?=` and `=?charset?Q?…?=` words. Whitespace
    /// between two adjacent encoded words is dropped, as the RFC requires.
    /// Text without encoded words is returned unchanged.
    static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in matches {
            let gap = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasEncoded && gap.allSatisfy(\.isWhitespace)) {
                output += gap
            }
            let charset = source.substring(with: match.range(at: 1))
            let encoding = source.substring(with: match.range(at: 2)).uppercased()
            let payload = source.substring(with: match.range(at: 3))
            if let decoded = decodeWord(payload, encoding: encoding, charset: charset) {
                output += decoded
                previousWasEncoded = true
            } else {
                output += source.substring(with: match.range)
                previousWasEncoded = false
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    private static func decodeWord(_ payload: String, encoding: String, charset: String) -> String? {
        let bytes: Data?
        if encoding == "B" {
            var padded = payload
            while padded.count % 4 != 0 { padded += "=" }
            bytes = Data(base64Encoded: padded)
        } else {
            bytes = quotedPrintableBytes(payload.replacingOccurrences(of: "_", with: " "))
        }
        guard let bytes else { return nil }
        return decode(bytes, charset: charset)
    }

    private static func quotedPrintableBytes(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        let scalars = Array(text.utf8)
        var index = 0
        while index < scalars.count {
            let byte = scalars[index]
            if byte == UInt8(ascii: "="), index + 2 < scalars.count,
               let value = UInt8(String(bytes: scalars[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(value)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return Data(bytes)
    }

    // MARK: Charsets

    /// Decodes body or header bytes in their declared charset (Serbian mail
    /// still arrives as Windows-1250 or ISO-8859-2), then UTF-8, then Latin-1
    /// so text is never lost.
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = stringEncoding(charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stringEncoding(_ charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        if name == "utf-8" || name == "utf8" { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// The `charset` parameter of a `Content-Type` header value.
    static func charset(fromContentType contentType: String?) -> String? {
        parameter("charset", in: contentType)
    }

    static func parameter(_ name: String, in headerValue: String?) -> String? {
        guard let headerValue else { return nil }
        for part in headerValue.split(separator: ";").dropFirst() {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            let value = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: New text in a message

    /// Lines that start the quoted history of a reply: Gmail, Apple Mail and
    /// Outlook headers in the languages LokalBot's users write in most.
    private static let replyHeaderPatterns: [NSRegularExpression] = [
        #"^On .{4,240} wrote:$"#,
        #"^Am .{4,240} schrieb .{0,120}:$"#,
        #"^Le .{4,240} a écrit\s?:$"#,
        #"^El .{4,240} escribió:$"#,
        #"^Il giorno .{4,240} ha scritto:$"#,
        #"^.{4,240} (je )?(napisao|napisala|написао|написала)( je)?:$"#,
        #"^-{2,}\s*(Original Message|Forwarded message|Prosleđena poruka|Weitergeleitete Nachricht)\s*-{2,}$"#,
        #"^_{10,}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let signOffPatterns: [NSRegularExpression] = [
        #"^Sent from my .{2,40}$"#,
        #"^(Poslato|Poslano) (sa|s) (mog|moga|mojeg) .{2,40}$"#,
        #"^Von meinem .{2,40} gesendet$"#,
        #"^Get Outlook for .{2,20}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// What the sender wrote in this message: the text above the quoted
    /// history, without `>` lines, the signature after `-- `, or mobile
    /// sign-offs. The whole body is kept on disk; this is only for display
    /// and prompts.
    static func conversationText(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "--" || line == "-- " || lines[index] == "-- " { break }
            if matches(line, replyHeaderPatterns) { break }
            // Gmail wraps a long "On … wrote:" header onto a second line.
            if line.hasPrefix("On "), index + 1 < lines.count,
               matches(line + " " + lines[index + 1].trimmingCharacters(in: .whitespaces), replyHeaderPatterns) {
                break
            }
            // Outlook: "From: …" followed within a few lines by "Sent:" or "Date:".
            if line.hasPrefix("From: "),
               lines[(index + 1)..<min(lines.count, index + 5)].contains(where: {
                   let next = $0.trimmingCharacters(in: .whitespaces)
                   return next.hasPrefix("Sent: ") || next.hasPrefix("Date: ")
               }) {
                break
            }
            if !line.hasPrefix(">") && !matches(line, signOffPatterns) {
                kept.append(lines[index])
            }
            index += 1
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ line: String, _ patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return patterns.contains { $0.firstMatch(in: line, range: range) != nil }
    }

    // MARK: HTML

    private static let skippedElements: Set<String> = ["script", "style", "head", "title", "noscript", "template"]
    /// Elements that start a new line.
    private static let lineElements: Set<String> = [
        "div", "tr", "li", "blockquote", "section", "article", "header", "footer",
    ]
    /// Elements that also leave a blank line around them.
    private static let paragraphElements: Set<String> = [
        "p", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "pre",
    ]

    /// Readable text from an HTML body. It is a tokenizer, not a renderer:
    /// nothing is fetched, no image or tracking pixel loads, and links keep
    /// only their text. Quoted history inside `<blockquote>` keeps a `> `
    /// prefix so later passes can tell it from new text.
    static func plainText(fromHTML html: String) -> String {
        var lines: [String] = []
        var line = ""
        var quoteDepth = 0
        var lineDepth = 0
        var skipping: String?
        var index = html.startIndex

        func endLine() {
            let trimmed = collapseSpaces(line)
            if !trimmed.isEmpty {
                lines.append(String(repeating: "> ", count: lineDepth) + trimmed)
            }
            line = ""
            lineDepth = quoteDepth
        }

        /// One blank line, never two in a row.
        func blankLine() {
            endLine()
            if lines.last?.isEmpty == false { lines.append("") }
        }

        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let tag = html[html.index(after: index)..<close]
                index = html.index(after: close)
                if tag.hasPrefix("!--") {
                    if !tag.hasSuffix("--"), let end = html[index...].range(of: "-->") {
                        index = end.upperBound
                    }
                    continue
                }
                let closing = tag.hasPrefix("/")
                let name = tag.drop(while: { $0 == "/" })
                    .prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
                if let skipped = skipping {
                    if closing && name == skipped { skipping = nil }
                    continue
                }
                if !closing && skippedElements.contains(name) && !tag.hasSuffix("/") {
                    skipping = name
                    continue
                }
                if name == "br" {
                    // A second <br> in a row is a paragraph break.
                    if collapseSpaces(line).isEmpty { blankLine() } else { endLine() }
                } else if paragraphElements.contains(name) {
                    blankLine()
                } else if lineElements.contains(name) {
                    endLine()
                    if name == "blockquote" {
                        quoteDepth = closing ? max(0, quoteDepth - 1) : quoteDepth + 1
                        lineDepth = quoteDepth
                    }
                    if name == "li" && !closing { line = "• " }
                }
                continue
            }
            if skipping != nil {
                index = html.index(after: index)
                continue
            }
            if character == "&", let semicolon = html[index...].prefix(12).firstIndex(of: ";") {
                let entity = String(html[html.index(after: index)..<semicolon])
                if let decoded = decodeEntity(entity) {
                    line += decoded
                    index = html.index(after: semicolon)
                    continue
                }
            }
            if character.isNewline {
                line.append(" ")
            } else {
                line.append(character)
            }
            index = html.index(after: index)
        }
        endLine()
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func collapseSpaces(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character == "\u{00A0}" {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                result.append(character)
                pendingSpace = false
            }
        }
        return result
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "bull": "•", "middot": "·", "euro": "€", "copy": "©",
    ]

    private static func decodeEntity(_ entity: String) -> String? {
        if let named = namedEntities[entity.lowercased()] { return named }
        guard entity.hasPrefix("#") else { return nil }
        let digits = entity.dropFirst()
        let value = digits.lowercased().hasPrefix("x")
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
