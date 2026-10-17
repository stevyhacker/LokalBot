// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Inline `:shortcode:` emoji autocomplete. A trimmed port of Cotabby's emoji
/// subsystem: instead of a bundled gemoji JSON + a separate picker panel, this
/// uses a curated in-source catalog and reuses cotyping's ghost overlay (the top
/// match shows inline; the accept key replaces the typed `:query` with the glyph).
///
/// Detection mirrors Cotabby's trigger rules: a `:` only opens a query at a word
/// boundary (start of field or after whitespace), so `http://`, `12:30`, and
/// `foo::bar` never trigger. Both `:roc` (open, prefix match) and `:rocket:`
/// (closed, exact match) are supported.
enum CotypingEmoji {
    struct Match: Equatable, Sendable {
        /// Characters to delete back from the caret (the `:query` or `:query:`).
        let typedLength: Int
        let glyph: String
        let shortcode: String
    }

    /// Best emoji for the trailing `:query` at the caret, or nil.
    static func match(trailing precedingText: String) -> Match? {
        guard let token = scanTrailingToken(in: precedingText) else { return nil }
        // Open queries need ≥2 chars to avoid noise; closed `:q:` may be exact.
        if !token.closed, token.query.count < 2 { return nil }
        guard let hit = bestMatch(for: token.query, exactOnly: token.closed) else { return nil }
        return Match(typedLength: token.typedLength, glyph: hit.glyph, shortcode: hit.shortcode)
    }

    /// Length of the trailing `:query[:]` token at the caret (regardless of
    /// whether it matches an emoji) — used to delete it on accept.
    static func trailingTokenLength(in precedingText: String) -> Int? {
        scanTrailingToken(in: precedingText)?.typedLength
    }

    // MARK: - Trailing token scan

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
        // Word boundary before the opening colon: start of field or whitespace.
        let colonIndex = start - 1
        if colonIndex > 0, !chars[colonIndex - 1].isWhitespace { return nil }
        return Token(query: query, typedLength: query.count + (closed ? 2 : 1), closed: closed)
    }

    /// Alias characters gemoji allows (`+1`, `-1`, `e-mail`-style underscores).
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }

    // MARK: - Matching

    private static func bestMatch(for rawQuery: String, exactOnly: Bool) -> (glyph: String, shortcode: String)? {
        let query = rawQuery.lowercased()
        // Synonyms (intent words) map to a canonical shortcode, exact only.
        let resolved = synonyms[query] ?? query
        if let glyph = lookup(resolved) { return (glyph, resolved) }
        if let entry = catalog.first(where: { $0.0 == query }) { return (entry.1, entry.0) }
        guard !exactOnly else { return nil }
        // Prefix match in popularity order (catalog is ordered most-common first).
        if let entry = catalog.first(where: { $0.0.hasPrefix(query) }) { return (entry.1, entry.0) }
        return nil
    }

    private static func lookup(_ shortcode: String) -> String? {
        catalog.first { $0.0 == shortcode }?.1
    }

    /// Intent/slang overlay (what people type → canonical shortcode).
    private static let synonyms: [String: String] = [
        "thumbsup": "+1", "thumbsdown": "-1", "lol": "joy", "lmao": "rofl",
        "omg": "scream", "ty": "pray", "thanks": "pray", "love": "heart",
        "yes": "white_check_mark", "no": "x", "celebrate": "tada", "party": "tada",
        "congrats": "tada", "idea": "bulb", "done": "white_check_mark",
    ]

    /// Curated catalog, ordered roughly by popularity so the first prefix match
    /// is the most likely intent. Not exhaustive — covers the common long tail.
    static let catalog: [(String, String)] = [
        // Faces
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
        // Hearts
        ("heart", "❤️"), ("orange_heart", "🧡"), ("yellow_heart", "💛"), ("green_heart", "💚"),
        ("blue_heart", "💙"), ("purple_heart", "💜"), ("black_heart", "🖤"), ("broken_heart", "💔"),
        ("two_hearts", "💕"), ("sparkling_heart", "💖"), ("heartpulse", "💗"), ("heartbeat", "💓"),
        ("cupid", "💘"), ("gift_heart", "💝"),
        // Hands
        ("+1", "👍"), ("-1", "👎"), ("ok_hand", "👌"), ("punch", "👊"), ("fist", "✊"),
        ("v", "✌️"), ("wave", "👋"), ("raised_hands", "🙌"), ("pray", "🙏"), ("clap", "👏"),
        ("muscle", "💪"), ("point_up", "☝️"), ("point_down", "👇"), ("point_left", "👈"),
        ("point_right", "👉"), ("handshake", "🤝"), ("writing_hand", "✍️"), ("nail_care", "💅"),
        // Symbols / emphasis
        ("fire", "🔥"), ("star", "⭐"), ("star2", "🌟"), ("sparkles", "✨"), ("zap", "⚡"),
        ("boom", "💥"), ("dizzy", "💫"), ("sweat_drops", "💦"), ("droplet", "💧"), ("dash", "💨"),
        ("100", "💯"), ("white_check_mark", "✅"), ("heavy_check_mark", "✔️"), ("x", "❌"),
        ("warning", "⚠️"), ("question", "❓"), ("exclamation", "❗"), ("eyes", "👀"), ("brain", "🧠"),
        // Celebration / objects
        ("tada", "🎉"), ("confetti_ball", "🎊"), ("balloon", "🎈"), ("gift", "🎁"),
        ("trophy", "🏆"), ("medal", "🏅"), ("crown", "👑"), ("gem", "💎"), ("rocket", "🚀"),
        ("bulb", "💡"), ("lock", "🔒"), ("key", "🔑"), ("mag", "🔍"),
        // Food / nature
        ("coffee", "☕"), ("beer", "🍺"), ("beers", "🍻"), ("pizza", "🍕"), ("hamburger", "🍔"),
        ("birthday", "🎂"), ("sunny", "☀️"), ("moon", "🌙"), ("rainbow", "🌈"),
        ("snowflake", "❄️"), ("dog", "🐶"), ("cat", "🐱"),
        // Comms
        ("musical_note", "🎵"), ("notes", "🎶"), ("calendar", "📅"), ("email", "📧"),
        ("phone", "📱"), ("computer", "💻"), ("checkered_flag", "🏁"),
    ]
}
