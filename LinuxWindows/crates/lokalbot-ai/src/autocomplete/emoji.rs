// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Inline `:shortcode:` emoji (`CotypingEmoji`): a curated catalog instead
//! of gemoji. A `:` opens a query only at a word boundary, so `http://`,
//! `12:30` and `foo::bar` never trigger. Both `:roc` (open, prefix match,
//! two characters at least) and `:rocket:` (closed, exact) work.

use super::text::{grapheme_count, is_word_char};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmojiMatch {
    /// User-perceived characters of the typed `:query` or `:query:`.
    pub typed_length: usize,
    pub glyph: &'static str,
    pub shortcode: &'static str,
}

/// The best emoji for the `:query` right before the caret.
pub fn match_trailing(before: &str) -> Option<EmojiMatch> {
    let token = scan_trailing_token(before)?;
    if !token.closed && token.query.chars().count() < 2 {
        return None;
    }
    let (shortcode, glyph) = best_match(token.query, token.closed)?;
    Some(EmojiMatch {
        typed_length: token.typed_length,
        glyph,
        shortcode,
    })
}

/// The ghost text macOS shows for an emoji: the glyph and its shortcode.
pub fn ghost(before: &str, suggestion: &str) -> Option<String> {
    let hit = match_trailing(before)?;
    (hit.glyph == suggestion).then(|| format!("{} :{}:", hit.glyph, hit.shortcode))
}

struct Token<'a> {
    query: &'a str,
    typed_length: usize,
    closed: bool,
}

fn scan_trailing_token(text: &str) -> Option<Token<'_>> {
    let (body, closed) = match text.strip_suffix(':') {
        Some(body) => (body, true),
        None => (text, false),
    };
    let start = body
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_name_char(*c))
        .last()
        .map_or(body.len(), |(i, _)| i);
    let query = &body[start..];
    let opener = body[..start].strip_suffix(':')?;
    if query.is_empty() {
        return None;
    }
    // A word boundary before the opening colon: the start or whitespace.
    if opener
        .chars()
        .next_back()
        .is_some_and(|c| !c.is_whitespace())
    {
        return None;
    }
    Some(Token {
        query,
        typed_length: grapheme_count(query) + if closed { 2 } else { 1 },
        closed,
    })
}

/// The alias characters gemoji allows (`+1`, `-1`, `e-mail`).
fn is_name_char(c: char) -> bool {
    is_word_char(c) || matches!(c, '_' | '+' | '-')
}

fn best_match(raw: &str, exact_only: bool) -> Option<(&'static str, &'static str)> {
    let query = raw.to_lowercase();
    let resolved = SYNONYMS
        .iter()
        .find(|(word, _)| *word == query)
        .map_or(query.as_str(), |(_, code)| *code);
    if let Some(entry) = CATALOG.iter().find(|(code, _)| *code == resolved) {
        return Some(*entry);
    }
    if exact_only {
        return None;
    }
    // The catalog is ordered most-common first, so the first prefix match wins.
    CATALOG
        .iter()
        .find(|(code, _)| code.starts_with(&query))
        .copied()
}

/// What people type for an intent → the canonical shortcode, exact only.
const SYNONYMS: [(&str, &str); 15] = [
    ("thumbsup", "+1"),
    ("thumbsdown", "-1"),
    ("lol", "joy"),
    ("lmao", "rofl"),
    ("omg", "scream"),
    ("ty", "pray"),
    ("thanks", "pray"),
    ("love", "heart"),
    ("yes", "white_check_mark"),
    ("no", "x"),
    ("celebrate", "tada"),
    ("party", "tada"),
    ("congrats", "tada"),
    ("idea", "bulb"),
    ("done", "white_check_mark"),
];

/// Ordered roughly by popularity.
#[rustfmt::skip]
const CATALOG: &[(&str, &str)] = &[
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
    // Symbols and emphasis
    ("fire", "🔥"), ("star", "⭐"), ("star2", "🌟"), ("sparkles", "✨"), ("zap", "⚡"),
    ("boom", "💥"), ("dizzy", "💫"), ("sweat_drops", "💦"), ("droplet", "💧"), ("dash", "💨"),
    ("100", "💯"), ("white_check_mark", "✅"), ("heavy_check_mark", "✔️"), ("x", "❌"),
    ("warning", "⚠️"), ("question", "❓"), ("exclamation", "❗"), ("eyes", "👀"), ("brain", "🧠"),
    // Celebration and objects
    ("tada", "🎉"), ("confetti_ball", "🎊"), ("balloon", "🎈"), ("gift", "🎁"),
    ("trophy", "🏆"), ("medal", "🏅"), ("crown", "👑"), ("gem", "💎"), ("rocket", "🚀"),
    ("bulb", "💡"), ("lock", "🔒"), ("key", "🔑"), ("mag", "🔍"),
    // Food and nature
    ("coffee", "☕"), ("beer", "🍺"), ("beers", "🍻"), ("pizza", "🍕"), ("hamburger", "🍔"),
    ("birthday", "🎂"), ("sunny", "☀️"), ("moon", "🌙"), ("rainbow", "🌈"),
    ("snowflake", "❄️"), ("dog", "🐶"), ("cat", "🐱"),
    // Communication
    ("musical_note", "🎵"), ("notes", "🎶"), ("calendar", "📅"), ("email", "📧"),
    ("phone", "📱"), ("computer", "💻"), ("checkered_flag", "🏁"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_and_closed_queries() {
        let rocket = match_trailing("Ship it :roc").unwrap();
        assert_eq!(
            (rocket.glyph, rocket.shortcode, rocket.typed_length),
            ("🚀", "rocket", 4)
        );
        let closed = match_trailing(":rocket:").unwrap();
        assert_eq!((closed.glyph, closed.typed_length), ("🚀", 8));
        assert_eq!(match_trailing("thanks :tada:").unwrap().glyph, "🎉");
        assert_eq!(match_trailing("good :+1").unwrap().glyph, "👍");
        assert_eq!(match_trailing("haha :lol").unwrap().glyph, "😂");
    }

    #[test]
    fn colons_inside_words_numbers_and_urls_never_trigger() {
        assert_eq!(match_trailing("see http://ex"), None);
        assert_eq!(match_trailing("at 12:30"), None);
        assert_eq!(match_trailing("foo::bar"), None);
        assert_eq!(
            match_trailing("x :r"),
            None,
            "open queries need two characters"
        );
        assert_eq!(match_trailing("x :zzzz"), None);
        assert_eq!(
            match_trailing("x :roc:"),
            None,
            "closed queries match exactly"
        );
    }

    #[test]
    fn the_ghost_names_the_shortcode() {
        assert_eq!(ghost("Ship it :roc", "🚀").as_deref(), Some("🚀 :rocket:"));
        assert_eq!(ghost("Ship it :roc", " now"), None);
    }
}
