import Foundation

enum SpokenUndertaking {
    struct Word: Equatable {
        var text: String
        var row: Int
        var range: Range<String.Index>
        var endsSentence = false
        var endsQuestion = false
        var followedByComma = false
        var isCapitalized = false
    }

    struct Cue: Equatable {
        enum Grade { case commitment, offer }
        enum Refusal: Equatable {
            case negated, question, reported, conditionalClause, delegated, conversation, unfulfilled
        }
        var words: Range<Int>
        var grade: Grade
        var refusal: Refusal?
        var namesNoTask = false
        var isAccepted: Bool { refusal == nil }
    }

    struct Actor: Equatable {
        var start: Int
        var label: String
    }

    private static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "er", "eh", "hmm", "mm", "mhm"]

    static func words(_ rows: [String]) -> [Word] {
        var result: [Word] = []
        for (row, text) in rows.enumerated() {
            var index = text.startIndex
            while index < text.endIndex {
                guard !text[index].isWhitespace else { index = text.index(after: index); continue }
                let end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                let chunk = text[index..<end]
                index = end
                guard let first = chunk.firstIndex(where: isWordCharacter),
                      let last = chunk.lastIndex(where: isWordCharacter) else {
                    if chunk.contains(where: { ".!?;".contains($0) }), !result.isEmpty, result[result.count - 1].row == row {
                        result[result.count - 1].endsSentence = true
                        if chunk.contains("?") { result[result.count - 1].endsQuestion = true }
                    }
                    continue
                }
                let core = chunk[first...last]
                let trailing = chunk[chunk.index(after: last)...]
                var word = Word(text: core.lowercased().replacingOccurrences(of: "’", with: "'"), row: row,
                                range: first..<chunk.index(after: last))
                word.endsSentence = trailing.contains { ".!?;".contains($0) }
                word.endsQuestion = trailing.contains("?")
                word.followedByComma = trailing.contains(",")
                word.isCapitalized = core.first?.isUppercase == true
                if let previous = result.last, previous.text == word.text, !previous.endsSentence || dangling.contains(word.text) {
                    result[result.count - 1] = word
                    continue
                }
                if fillers.contains(word.text) {
                    if !result.isEmpty, word.endsSentence || word.followedByComma {
                        result[result.count - 1].endsSentence = result[result.count - 1].endsSentence || word.endsSentence
                        result[result.count - 1].endsQuestion = result[result.count - 1].endsQuestion || word.endsQuestion
                        result[result.count - 1].followedByComma = result[result.count - 1].followedByComma || word.followedByComma
                    }
                    continue
                }
                result.append(word)
            }
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static let adverb = #"(?:(?:also|still|just|really|probably|definitely|actually|then|now|first|certainly|"#
        + #"already|only|even|basically|obviously|honestly|personally|totally|mostly|simply|maybe|do|kind of|sort of) )"#
    private static let cuePatterns: [(NSRegularExpression, Cue.Grade)] = {
        let going = #"(?:going to|gonna|planning to|intending to|about to|supposed to)"#
        let commitment = [
            #"\bi "# + adverb + #"{0,2}(?:will|shall|must|gotta|have to|have got to|need to|got to|plan to|intend to|"#
                + #"commit to|agree to|promise to|am "# + adverb + "{0,2}" + going + #")(?= |$)"#,
            #"\bi'll(?= |$)"#,
            #"\bi'm "# + adverb + "{0,2}" + going + #"(?= |$)"#,
            #"\bi've "# + adverb + #"{0,2}got to(?= |$)"#,
            #"(?<=\band )i (?:are|'re) "# + adverb + #"{0,2}(?:going to|gonna|planning to)(?= |$)"#,
            #"\bmy next step is(?= |$)"#,
            #"\bja (?:ću|cu)(?= |$)"#, #"\bje vais(?= |$)"#, #"\bich werde(?= |$)"#, #"\bvoy a(?= |$)"#, "我会|我會",
        ]
        let offer = [
            #"\bi "# + adverb + #"{0,2}(?:should|can|could|ought to|want to|wanna|aim to|would like to|would love to|"#
                + #"am "# + adverb + #"{0,2}happy to)(?= |$)"#,
            #"\bi'm "# + adverb + #"{0,2}happy to(?= |$)"#,
            #"\bi'd "# + adverb + #"{0,2}(?:like to|love to)(?= |$)"#,
            #"\bi "# + adverb + #"{0,2}(?:have|got) (?:a|an|some|a few|a couple of|two|three|four|five|several|one|many|more|"#
                + #"another|lots of|a lot of|these|those|the|this|that|my) (?:[^ ]+ ){1,5}?to "#
                + #"(?!(?:the|a|an|my|our|your|this|that|be|ask|say|add|me|you|him|her|them|us)(?: |$))[^ ]+"#,
            #"\blet me(?= |$)"#,
            #"\bleave (?:it|that|this) (?:with|to) me(?= |$)"#,
            #"\b(?:that's|that is|it's|it is|this is) on me(?= |$)"#,
            #"\bi'm on it(?= |$)"#,
        ]
        func compiled(_ patterns: [String], _ grade: Cue.Grade) -> [(NSRegularExpression, Cue.Grade)] {
            patterns.compactMap { pattern in (try? NSRegularExpression(pattern: pattern)).map { ($0, grade) } }
        }
        return compiled(commitment, .commitment) + compiled(offer, .offer)
    }()

    private static let sentencePreamble: Set<String> = [
        "yeah", "yes", "yep", "ok", "okay", "so", "and", "but", "then", "also", "well", "right", "sure", "anyway", "still", "just",
    ]
    private static let inversions: Set<String> = [
        "do", "did", "does", "would", "should", "shall", "could", "can", "will", "must", "may", "might",
    ]
    private static let subordinators: Set<String> = ["if", "when", "whenever", "unless", "until", "whether"]
    private static let adverbs: Set<String> = [
        "also", "still", "just", "really", "probably", "definitely", "actually", "then", "now", "first", "certainly",
        "already", "only", "even", "basically", "obviously", "honestly", "personally", "totally", "mostly", "simply", "maybe",
    ]
    private static let tagEndings: Set<String> = ["okay", "ok", "right", "yeah", "yes", "alright", "fine", "cool", "good"]
    private static let dangling: Set<String> = [
        "i", "i'll", "i'm", "i've", "i'd", "we'll", "we're", "you'll", "they'll", "he'll", "she'll",
        "to", "the", "a", "an", "and", "or", "but", "so", "because", "than", "as", "if", "when",
        "my", "our", "your", "their", "his", "of", "for", "with", "on", "at", "in", "into", "from", "by", "about", "before", "after",
        "is", "are", "was", "were", "be", "been", "have", "has", "had", "will", "can", "could", "should", "would",
        "gonna", "gotta", "wanna",
    ]

    static func isDangling(_ word: String) -> Bool { dangling.contains(word) }

    static func cues(in words: [Word]) -> [Cue] {
        guard !words.isEmpty else { return [] }
        var offsets: [Int] = []
        var joined = ""
        for word in words {
            if !joined.isEmpty { joined += " " }
            offsets.append(joined.utf16.count)
            joined += word.text
        }
        func wordIndex(at offset: Int) -> Int {
            var low = 0, high = offsets.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if offsets[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }
        var found: [Cue] = []
        let whole = NSRange(location: 0, length: joined.utf16.count)
        for (regex, grade) in cuePatterns {
            for match in regex.matches(in: joined, range: whole) where match.range.length > 0 {
                let start = wordIndex(at: match.range.location)
                let end = wordIndex(at: match.range.location + match.range.length - 1) + 1
                found.append(Cue(words: start..<end, grade: grade))
            }
        }
        for start in words.indices where start == 0 || words[start - 1].endsSentence {
            var index = start
            while index < words.count, index - start < 3, sentencePreamble.contains(words[index].text) { index += 1 }
            guard index < words.count else { continue }
            let next = index + 1 < words.count ? words[index + 1].text : ""
            if ["have", "need", "got", "going"].contains(words[index].text), next == "to" {
                found.append(Cue(words: index..<(index + 2), grade: .offer))
            } else if ["gonna", "gotta"].contains(words[index].text) {
                found.append(Cue(words: index..<(index + 1), grade: .offer))
            } else if words[index].text == "will", next == "do" {
                found.append(Cue(words: index..<(index + 2), grade: .offer))
            }
        }
        var seen = Set<Int>()
        return found.sorted { $0.words.lowerBound < $1.words.lowerBound }
            .filter { seen.insert($0.words.lowerBound).inserted }
            .map { judged($0, in: words) }
    }

    private static func judged(_ cue: Cue, in words: [Word]) -> Cue {
        var cue = cue
        let phrase = words[cue.words].map(\.text)
        var following: [Word] = []
        var index = cue.words.upperBound
        var open = !words[cue.words.upperBound - 1].endsSentence || dangling.contains(phrase.last ?? "")
        while open, index < words.count, following.count < 8 {
            following.append(words[index])
            open = !words[index].endsSentence
                || (following.count < 3 && (dangling.contains(words[index].text) || adverbs.contains(words[index].text)))
            index += 1
        }
        let tail = Array(following.drop(while: { adverbs.contains($0.text) }))
        let content = tail.map(\.text)
        let before = words[..<cue.words.lowerBound].suffix(3).map(\.text)
        let previous = cue.words.lowerBound > 0 ? words[cue.words.lowerBound - 1] : nil
        let continuesClause = previous.map { !$0.endsSentence && !$0.followedByComma } ?? false

        if ["not", "never"].contains(content.first ?? "") || content.prefix(2) == ["no", "longer"] {
            cue.refusal = .negated
        } else if continuesClause, phrase.first == "i", inversions.contains(previous?.text ?? "") {
            cue.refusal = .question
        } else if endsInQuestion(cue, words: words) {
            cue.refusal = .question
        } else if isReported(before) {
            cue.refusal = .reported
        } else if continuesClause, subordinators.contains(previous?.text ?? "")
                    || ["every time", "each time", "in case", "so that"].contains(before.suffix(2).joined(separator: " ")) {
            cue.refusal = .conditionalClause
        } else if ["should", "could", "must", "would"].contains(where: phrase.contains), ["have", "'ve"].contains(content.first ?? "") {
            cue.refusal = .unfulfilled
        } else if isDelegation(tail) {
            cue.refusal = .delegated
        } else if isConversation(phrase: phrase, tail: content) {
            cue.refusal = .conversation
        }
        cue.namesNoTask = tail.isEmpty || phrase == ["will", "do"] || pointsAtAnEarlierTask(tail)
            || (tail.count <= 2 && ["on me", "on it", "with me", "to me"].contains(phrase.suffix(2).joined(separator: " ")))
        return cue
    }

    private static func pointsAtAnEarlierTask(_ tail: [Word]) -> Bool {
        guard tail.count >= 2, ["that", "it", "this", "those", "them"].contains(tail[1].text) else { return false }
        if tail.count == 2 || tail[1].endsSentence || tail[1].followedByComma { return true }
        return ["on", "but", "and", "so", "tomorrow", "today", "tonight", "later", "now", "then", "after", "before", "if",
                "when", "for", "too", "yeah", "sure", "okay", "this", "next", "by", "right", "soon", "over"].contains(tail[2].text)
    }

    private static func endsInQuestion(_ cue: Cue, words: [Word]) -> Bool {
        guard let end = words[(cue.words.upperBound - 1)...].firstIndex(where: \.endsSentence),
              words[end].endsQuestion else { return false }
        return !(tagEndings.contains(words[end].text) && end >= cue.words.upperBound)
    }

    private static func isReported(_ before: [String]) -> Bool {
        let verbs: Set<String> = ["said", "say", "says", "saying", "thought", "mentioned", "promised", "claimed", "assumed"]
        var words = before
        if words.last == "that" { words.removeLast() }
        guard let last = words.last else { return false }
        if verbs.contains(last) { return true }
        return words.count >= 2 && ["told", "tell"].contains(words[words.count - 2])
    }

    private static func isDelegation(_ tail: [Word]) -> Bool {
        guard tail.count >= 3, ["need", "want", "like", "expect", "require"].contains(tail[0].text) else { return false }
        let object = tail[1]
        guard otherSubjects.contains(object.text) || ["him", "her", "them"].contains(object.text) || object.isCapitalized else {
            return false
        }
        return tail[2...].prefix(2).contains { $0.text == "to" }
    }

    private static func isConversation(phrase: [String], tail: [String]) -> Bool {
        let text = tail.joined(separator: " ")
        if phrase.suffix(2) == ["let", "me"] {
            return ["know", "see", "think", "say", "put", "rephrase", "explain", "clarify", "finish", "stop", "interrupt",
                    "jump", "start", "begin", "repeat", "mention", "ask", "share", "show", "tell", "be"].contains(tail.first ?? "")
        }
        return text.range(of: "^" + conversationRemark, options: .regularExpression) != nil
    }

    static let conversationRemark = #"(?:be (?:a little (?:bit )?|completely |totally |very |really |quite |perfectly |brutally )?"#
        + #"(?:more specific|more clear|clearer|brief|honest|frank|candid|upfront|blunt)\b|share (?:my|the) screen\b|say\b|admit\b|confess\b)"#

    private static let otherSubjects: Set<String> = [
        "you", "he", "she", "they", "we", "someone", "somebody", "everyone", "everybody", "anyone", "anybody",
    ]
    private static let notActors: Set<String> = [
        "i", "it", "that", "this", "those", "these", "there", "which", "what", "who", "something", "everything", "anything",
        "nothing", "things", "stuff", "one", "so", "and", "but", "then", "also", "yeah", "yes", "okay", "ok", "well", "maybe",
        "probably", "hopefully", "now", "today", "tomorrow", "next", "if", "when", "because", "the", "a", "an", "my", "our",
        "your", "their", "his", "her", "not", "just", "still", "really", "actually", "after", "before", "once", "while", "as",
    ]

    private static let determiners: Set<String> = ["the", "a", "an", "my", "our", "your", "their", "his", "her"]

    private static func modalLength(_ words: [Word], at index: Int) -> Int? {
        var index = index
        var skipped = 0
        while index < words.count, skipped < 2, adverbs.contains(words[index].text) { index += 1; skipped += 1 }
        guard index < words.count else { return nil }
        let text = words[index].text
        let next = index + 1 < words.count ? words[index + 1].text : ""
        let third = index + 2 < words.count ? words[index + 2].text : ""
        var length: Int?
        if ["will", "shall", "must", "should", "can", "could"].contains(text) {
            length = 1
        } else if ["have", "has", "need", "needs", "plan", "plans", "got"].contains(text), next == "to" {
            length = 2
        } else if ["is", "are", "am"].contains(text), next == "going", third == "to" {
            length = 3
        } else if text == "is", next == "responsible", third == "for" {
            length = 3
        }
        guard let length, index + length < words.count else { return length.map { $0 + skipped } }
        return words[index + length].text == "be" ? nil : length + skipped
    }

    static func otherActors(in words: [Word]) -> [Actor] {
        var actors: [Actor] = []
        for index in words.indices {
            let word = words[index]
            let previous = index > 0 ? words[index - 1].text : ""
            let startsSentence = index == 0 || words[index - 1].endsSentence
            let startsClause = startsSentence || words[index - 1].followedByComma || ["and", "but", "while"].contains(previous)
            let next = index + 1 < words.count ? words[index + 1].text : ""
            if ["can", "could", "would", "will"].contains(word.text), next == "you", previous != "i" {
                actors.append(.init(start: index, label: "you")); continue
            }
            if word.text == "you", ["need", "want", "like"].contains(previous) && index + 1 < words.count && next == "to"
                || (previous == "sure" && index >= 2 && words[index - 2].text == "make") {
                actors.append(.init(start: index, label: "you")); continue
            }
            if word.text == "please", startsSentence, !next.isEmpty, next != "note" {
                actors.append(.init(start: index, label: "you")); continue
            }
            if otherSubjects.contains(word.text) {
                if !["so", "do", "did", "does", "what", "how", "why", "where", "whether"].contains(previous),
                   modalLength(words, at: index + 1) != nil { actors.append(.init(start: index, label: word.text)) }
                continue
            }
            if let subject = word.text.range(of: "'ll", options: [.backwards, .anchored]).map({ String(word.text[..<$0.lowerBound]) }),
               subject != "i", !notActors.contains(subject) {
                actors.append(.init(start: index, label: subject)); continue
            }
            guard word.text.contains(where: \.isLetter) else { continue }
            if word.isCapitalized, !notActors.contains(word.text), !adverbs.contains(word.text) {
                var end = index + 1
                if end < words.count, words[end].isCapitalized, !notActors.contains(words[end].text),
                   modalLength(words, at: end) == nil { end += 1 }
                if modalLength(words, at: end) != nil { actors.append(.init(start: index, label: word.text)); continue }
            }
            guard startsClause, determiners.contains(word.text) || !notActors.contains(word.text) else { continue }
            for length in 1...3 where index + length < words.count {
                let subject = words[index..<(index + length)].map(\.text)
                guard !subject.contains(where: { $0 == "i" || $0.hasPrefix("i'") || otherSubjects.contains($0) }),
                      !notActors.contains(subject[subject.count - 1]), !adverbs.contains(subject[subject.count - 1]) else { continue }
                if modalLength(words, at: index + length) != nil {
                    actors.append(.init(start: index, label: subject.joined(separator: " "))); break
                }
            }
        }
        var seen = Set<Int>()
        return actors.filter { seen.insert($0.start).inserted }
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "for", "with", "and", "or", "but", "if", "is", "are", "be", "it", "that",
        "this", "i", "you", "we", "they", "he", "she", "will", "can", "should", "have", "has", "need", "going", "get", "got",
        "do", "does", "did", "about", "from", "at", "by", "as", "so", "then", "also", "just", "up", "out", "into", "their",
        "our", "my", "your", "me", "us", "them", "bit", "more", "some", "any", "all", "not", "no", "i'll", "i'm", "please",
    ]

    struct Alignment: Equatable {
        var matches = 0
        var leads = false
        var isAboutTask: Bool { leads || matches >= 2 }
    }

    static func alignment(task: String, clause: some Sequence<Word>) -> Alignment {
        let spoken = Set(clause.map(\.text).filter { !stopwords.contains($0) })
        let wanted = SpokenUndertaking.words([task]).map(\.text).filter { !stopwords.contains($0) }
        var result = Alignment()
        var counted = Set<String>()
        for (position, word) in wanted.enumerated() where spoken.contains(where: { sameStem($0, word) }) {
            if counted.insert(word).inserted { result.matches += 1 }
            if position == 0 { result.leads = true }
        }
        return result
    }

    private static func sameStem(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        if short.count >= 3, long.hasPrefix(short) { return true }
        return lhs.commonPrefix(with: rhs).count >= 5
    }

    static func occurrences(of quote: String, in words: [Word]) -> [Range<Int>] {
        let wanted = SpokenUndertaking.words([quote]).map(\.text)
        guard !wanted.isEmpty, wanted.count <= words.count else { return [] }
        return (0...(words.count - wanted.count)).compactMap { start in
            zip(wanted, words[start...]).allSatisfy { $0 == $1.text } ? start..<(start + wanted.count) : nil
        }
    }
}
