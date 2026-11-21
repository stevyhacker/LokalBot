// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingEmoji {
    struct Match: Equatable, Sendable {
        let typedLength: Int
        let glyph: String
        let shortcode: String
    }

    static func match(trailing precedingText: String) -> Match? {
        guard let token = scanTrailingToken(in: precedingText) else { return nil }
        if !token.closed, token.query.count < 2 { return nil }
        guard let hit = bestMatch(for: token.query, exactOnly: token.closed) else { return nil }
        return Match(typedLength: token.typedLength, glyph: hit.glyph, shortcode: hit.shortcode)
    }

    static func trailingTokenLength(in precedingText: String) -> Int? {
        scanTrailingToken(in: precedingText)?.typedLength
    }

    private struct Token { let query: String; let typedLength: Int; let closed: Bool }

    private static func scanTrailingToken(in text: String) -> Token? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        var end = chars.count
        var closed = false
        if chars[end - 1] == ":" {
            closed = true
            end -= 1
        }
        var start = end
        while start > 0, isNameCharacter(chars[start - 1]) { start -= 1 }
        let query = String(chars[start..<end])
        guard !query.isEmpty, start > 0, chars[start - 1] == ":" else { return nil }
        let colonIndex = start - 1
        if colonIndex > 0, !chars[colonIndex - 1].isWhitespace { return nil }
        return Token(query: query, typedLength: query.count + (closed ? 2 : 1), closed: closed)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }

    private static func bestMatch(for rawQuery: String, exactOnly: Bool) -> (glyph: String, shortcode: String)? {
        let query = rawQuery.lowercased()
        let resolved = synonyms[query] ?? query
        if let glyph = lookup(resolved) { return (glyph, resolved) }
        if let entry = catalog.first(where: { $0.0 == query }) { return (entry.1, entry.0) }
        guard !exactOnly else { return nil }
        if let entry = catalog.first(where: { $0.0.hasPrefix(query) }) { return (entry.1, entry.0) }
        return nil
    }

    private static func lookup(_ shortcode: String) -> String? {
        catalog.first { $0.0 == shortcode }?.1
    }

    private static let synonyms: [String: String] = [
        "thumbsup": "+1", "thumbsdown": "-1", "lol": "joy", "lmao": "rofl",
        "omg": "scream", "ty": "pray", "thanks": "pray", "love": "heart",
        "yes": "white_check_mark", "no": "x", "celebrate": "tada", "party": "tada",
        "congrats": "tada", "idea": "bulb", "done": "white_check_mark",
    ]

    static let catalog: [(String, String)] = [
        ("joy", "😂"), ("rofl", "🤣"), ("smile", "😄"), ("smiley", "😃"), ("grin", "😁"),
        ("laughing", "😆"), ("sweat_smile", "😅"), ("slightly_smiling_face", "🙂"),
        ("wink", "😉"), ("blush", "😊"), ("heart_eyes", "😍"), ("kissing_heart", "😘"),
        ("yum", "😋"), ("stuck_out_tongue", "😛"), ("stuck_out_tongue_winking_eye", "😜"),
        ("sunglasses", "😎"), ("nerd_face", "🤓"), ("thinking", "🤔"), ("neutral_face", "😐"),
        ("expressionless", "😑"), ("smirk", "😏"), ("unamused", "😒"), ("roll_eyes", "🙄"),
        ("grimacing", "😬"), ("relieved", "😌"), ("pensive", "😔"), ("sleepy", "😪"),
        ("sleeping", "😴"), ("mask", "😷"), ("sob", "😭"), ("cry", "😢"), ("disappointed", "😞"),
        ("worried", "😟"), ("confused", "😕"), ("fearful", "😨"), ("weary", "😩"),
        ("tired_face", "😫"), ("scream", "😱"), ("angry", "😠"), ("rage", "😡"),
        ("triumph", "😤"), ("flushed", "😳"), ("astonished", "😲"), ("open_mouth", "😮"),
        ("exploding_head", "🤯"), ("partying_face", "🥳"), ("pleading_face", "🥺"),
        ("cowboy_hat_face", "🤠"), ("smiling_imp", "😈"), ("skull", "💀"), ("ghost", "👻"),
        ("alien", "👽"), ("robot", "🤖"), ("poop", "💩"), ("clown_face", "🤡"),
        ("heart", "❤️"), ("orange_heart", "🧡"), ("yellow_heart", "💛"), ("green_heart", "💚"),
        ("blue_heart", "💙"), ("purple_heart", "💜"), ("black_heart", "🖤"), ("broken_heart", "💔"),
        ("two_hearts", "💕"), ("sparkling_heart", "💖"), ("heartpulse", "💗"), ("heartbeat", "💓"),
        ("cupid", "💘"), ("gift_heart", "💝"),
        ("+1", "👍"), ("-1", "👎"), ("ok_hand", "👌"), ("punch", "👊"), ("fist", "✊"),
        ("v", "✌️"), ("wave", "👋"), ("raised_hands", "🙌"), ("pray", "🙏"), ("clap", "👏"),
        ("muscle", "💪"), ("point_up", "☝️"), ("point_down", "👇"), ("point_left", "👈"),
        ("point_right", "👉"), ("handshake", "🤝"), ("writing_hand", "✍️"), ("nail_care", "💅"),
        ("fire", "🔥"), ("star", "⭐"), ("star2", "🌟"), ("sparkles", "✨"), ("zap", "⚡"),
        ("boom", "💥"), ("dizzy", "💫"), ("sweat_drops", "💦"), ("droplet", "💧"), ("dash", "💨"),
        ("100", "💯"), ("white_check_mark", "✅"), ("heavy_check_mark", "✔️"), ("x", "❌"),
        ("warning", "⚠️"), ("question", "❓"), ("exclamation", "❗"), ("eyes", "👀"), ("brain", "🧠"),
        ("tada", "🎉"), ("confetti_ball", "🎊"), ("balloon", "🎈"), ("gift", "🎁"),
        ("trophy", "🏆"), ("medal", "🏅"), ("crown", "👑"), ("gem", "💎"), ("rocket", "🚀"),
        ("bulb", "💡"), ("lock", "🔒"), ("key", "🔑"), ("mag", "🔍"),
        ("coffee", "☕"), ("beer", "🍺"), ("beers", "🍻"), ("pizza", "🍕"), ("hamburger", "🍔"),
        ("birthday", "🎂"), ("sunny", "☀️"), ("moon", "🌙"), ("rainbow", "🌈"),
        ("snowflake", "❄️"), ("dog", "🐶"), ("cat", "🐱"),
        ("musical_note", "🎵"), ("notes", "🎶"), ("calendar", "📅"), ("email", "📧"),
        ("phone", "📱"), ("computer", "💻"), ("checkered_flag", "🏁"),
    ]
}
