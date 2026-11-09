//! The rolling live transcript while dictating (`DictationLiveTranscript`,
//! `DictationPreviewWindowPlanner`, `DictationPreviewTextStitcher`), and the
//! check that pasted text reached its field (`DictationInsertionCheck`).

use unicode_segmentation::UnicodeSegmentation as _;

use crate::notes::view::normalized_text;

const SENTENCE_ENDS: &[char] = &[
    '.', '!', '?', '。', '！', '？', '؟', '۔', '｡', '።', '।', '॥',
];
const OVERLAP_SECONDS: f64 = 2.5;
const MAX_NEW_AUDIO_SECONDS: f64 = 6.0;
const MAX_OVERLAP_WORDS: usize = 32;
const MIN_OVERLAP_WORDS: usize = 2;
const MAX_OVERLAP_GRAPHEMES: usize = 64;
const MIN_OVERLAP_GRAPHEMES: usize = 4;

/// The text the live panel shows: settled words and the tail that may change.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LiveTranscript {
    pub committed: String,
    pub tentative: String,
}

impl LiveTranscript {
    pub fn is_empty(&self) -> bool {
        self.committed.is_empty() && self.tentative.is_empty()
    }

    pub fn final_text(text: &str) -> Self {
        Self {
            committed: text.to_string(),
            tentative: String::new(),
        }
    }

    /// Whole sentences are settled; without one, all but the last six of more
    /// than eight words.
    pub fn preview(text: &str) -> Self {
        let normalized = normalized_text(text);
        if normalized.is_empty() {
            return Self::default();
        }
        if normalized.ends_with(SENTENCE_ENDS) {
            return Self {
                committed: normalized,
                tentative: String::new(),
            };
        }
        if let Some((index, boundary)) = normalized.rmatch_indices(SENTENCE_ENDS).next() {
            let split = index + boundary.len();
            return Self {
                committed: normalized[..split].trim().to_string(),
                tentative: normalized[split..].trim().to_string(),
            };
        }
        let words: Vec<&str> = normalized.split(' ').filter(|w| !w.is_empty()).collect();
        if words.len() <= 8 {
            return Self {
                committed: String::new(),
                tentative: normalized,
            };
        }
        let (settled, tail) = words.split_at(words.len() - 6);
        Self {
            committed: settled.join(" "),
            tentative: tail.join(" "),
        }
    }
}

/// One preview pass's audio, in seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WindowRange {
    pub start: f64,
    pub end: f64,
}

/// Each pass starts slightly before the last one ended, so the model hears
/// enough to finish a word that crossed the boundary, without decoding the
/// whole growing recording again.
pub fn window_range(previous_end: f64, current_end: f64) -> Option<WindowRange> {
    let previous = previous_end.max(0.0);
    if current_end <= previous {
        return None;
    }
    Some(WindowRange {
        start: (previous - OVERLAP_SECONDS).max(0.0),
        end: current_end.min(previous + MAX_NEW_AUDIO_SECONDS),
    })
}

/// Audio that must have arrived since the last pass before another runs.
pub fn minimum_advance(duration: f64) -> f64 {
    if duration < 10.0 { 1.25 } else { 2.0 }
}

/// How long to rest after a pass, as a longer recording costs more.
pub fn interval_after(duration: f64) -> f64 {
    (duration / 8.0).clamp(1.4, 4.0)
}

/// Joins overlapping windows. The newest window replaces the matched suffix,
/// so revised capitalization or punctuation at the boundary wins; a window
/// with no trustworthy overlap is appended rather than risking visible speech.
pub fn stitch(previous: &str, incoming: &str) -> String {
    let old_text = normalized_text(previous);
    let new_text = normalized_text(incoming);
    if old_text.is_empty() {
        return new_text;
    }
    if new_text.is_empty() {
        return old_text;
    }
    let old_words: Vec<&str> = old_text.split_whitespace().collect();
    let new_words: Vec<&str> = new_text.split_whitespace().collect();
    let upper = MAX_OVERLAP_WORDS.min(old_words.len()).min(new_words.len());
    if upper >= MIN_OVERLAP_WORDS {
        for count in (MIN_OVERLAP_WORDS..=upper).rev() {
            let start = old_words.len() - count;
            let matches = (0..count).all(|offset| {
                let key = word_key(new_words[offset]);
                !key.is_empty() && word_key(old_words[start + offset]) == key
            });
            if matches {
                let mut joined = old_words[..start].to_vec();
                joined.extend(&new_words);
                return joined.join(" ");
            }
        }
    }
    // The character fallback is for unsegmented scripts only. On ordinary
    // text it mistakes a word's suffix for the start of another word
    // (broadcast / cast iron).
    if (old_words.len() == 1 || new_words.len() == 1)
        && has_unsegmented_script(&old_text)
        && has_unsegmented_script(&new_text)
        && let Some(stitched) = stitch_by_grapheme(&old_text, &new_text)
    {
        return stitched;
    }
    format!("{old_text} {new_text}")
}

struct SemanticGrapheme {
    key: String,
    start: usize,
    unsegmented: bool,
}

/// Ignores punctuation and spacing while matching, keeping each grapheme's
/// place so the output has the newest window verbatim from the overlap on.
fn semantic_graphemes(text: &str) -> Vec<SemanticGrapheme> {
    text.grapheme_indices(true)
        .filter_map(|(start, grapheme)| {
            let key = word_key(grapheme);
            (!key.is_empty()).then(|| SemanticGrapheme {
                key,
                start,
                unsegmented: has_unsegmented_script(grapheme),
            })
        })
        .collect()
}

fn stitch_by_grapheme(previous: &str, incoming: &str) -> Option<String> {
    let old = semantic_graphemes(previous);
    let new = semantic_graphemes(incoming);
    let upper = MAX_OVERLAP_GRAPHEMES.min(old.len()).min(new.len());
    if upper < MIN_OVERLAP_GRAPHEMES {
        return None;
    }
    for count in (MIN_OVERLAP_GRAPHEMES..=upper).rev() {
        let start = old.len() - count;
        let matches = (0..count).all(|offset| old[start + offset].key == new[offset].key);
        let overlaps_unsegmented = (0..count).any(|offset| old[start + offset].unsegmented);
        if matches && overlaps_unsegmented {
            let prefix = &previous[..old[start].start];
            return Some(normalized_text(&format!("{prefix}{incoming}")));
        }
    }
    None
}

fn has_unsegmented_script(text: &str) -> bool {
    text.chars().any(is_unsegmented_script)
}

/// Scripts that commonly omit spaces between words. Deliberately narrower
/// than "non-Latin": Arabic, Cyrillic and Devanagari use word separators.
fn is_unsegmented_script(c: char) -> bool {
    matches!(u32::from(c),
        0x0E00..=0x0EFF // Thai and Lao
        | 0x1000..=0x109F // Myanmar
        | 0x1780..=0x17FF // Khmer
        | 0x3040..=0x30FF // Hiragana and Katakana
        | 0x31F0..=0x31FF // Katakana phonetic extensions
        | 0x3400..=0x4DBF // CJK extension A
        | 0x4E00..=0x9FFF // CJK unified ideographs
        | 0xA9E0..=0xA9FF // Myanmar extended-B
        | 0xAA60..=0xAA7F // Myanmar extended-A
        | 0xF900..=0xFAFF // CJK compatibility ideographs
        | 0xFF66..=0xFF9F // Halfwidth Katakana
        | 0x20000..=0x2FA1F // CJK extensions and compatibility supplement
        | 0x30000..=0x323AF) // CJK extensions G through I
}

/// Case and diacritics folded, letters and digits only.
fn word_key(word: &str) -> String {
    lokalbot_core::ids::fold(word)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// Whether pasted dictation reached the field (`DictationInsertionVerdict`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertionVerdict {
    Landed,
    Missing,
    /// The field could not be read; nothing is claimed.
    Unknown,
}

/// When to read the field after the paste, in milliseconds. An app can take a
/// moment to publish the change.
pub const READ_DELAYS_MS: [u64; 3] = [250, 650, 1_200];
/// Letters and digits from the end of the insertion that must appear.
const PROBE_LENGTH: usize = 24;

/// Compares letters and digits only, so spacing, punctuation, emoji and
/// Markdown changes do not matter, and scripts without spaces between words
/// match inside a longer run.
pub fn insertion_verdict(text_before_caret: Option<&str>, inserted: &str) -> InsertionVerdict {
    let Some(before) = text_before_caret else {
        return InsertionVerdict::Unknown;
    };
    let sent = significant(inserted);
    if sent.is_empty() {
        return InsertionVerdict::Unknown;
    }
    let sent: Vec<char> = sent.chars().collect();
    let probe: String = sent[sent.len().saturating_sub(PROBE_LENGTH)..]
        .iter()
        .collect();
    let keep = inserted.chars().count() + 400;
    let chars: Vec<char> = before.chars().collect();
    let tail: String = chars[chars.len().saturating_sub(keep)..].iter().collect();
    if significant(&tail).contains(&probe) {
        InsertionVerdict::Landed
    } else {
        InsertionVerdict::Missing
    }
}

fn significant(text: &str) -> String {
    word_key(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_settles_sentences_and_older_words() {
        assert_eq!(LiveTranscript::preview("  "), LiveTranscript::default());
        assert_eq!(
            LiveTranscript::preview("Hello there."),
            LiveTranscript {
                committed: "Hello there.".into(),
                tentative: String::new()
            }
        );
        assert_eq!(
            LiveTranscript::preview("Hello there. And then we"),
            LiveTranscript {
                committed: "Hello there.".into(),
                tentative: "And then we".into()
            }
        );
        assert_eq!(
            LiveTranscript::preview("one two three"),
            LiveTranscript {
                committed: String::new(),
                tentative: "one two three".into()
            }
        );
        assert_eq!(
            LiveTranscript::preview("one two three four five six seven eight nine"),
            LiveTranscript {
                committed: "one two three".into(),
                tentative: "four five six seven eight nine".into()
            }
        );
    }

    #[test]
    fn windows_overlap_and_stay_bounded() {
        assert_eq!(window_range(5.0, 4.0), None);
        assert_eq!(
            window_range(0.0, 3.0),
            Some(WindowRange {
                start: 0.0,
                end: 3.0
            })
        );
        assert_eq!(
            window_range(10.0, 30.0),
            Some(WindowRange {
                start: 7.5,
                end: 16.0
            })
        );
        assert_eq!(minimum_advance(9.0), 1.25);
        assert_eq!(minimum_advance(10.0), 2.0);
        assert_eq!(interval_after(2.0), 1.4);
        assert_eq!(interval_after(16.0), 2.0);
        assert_eq!(interval_after(100.0), 4.0);
    }

    #[test]
    fn stitching_replaces_the_overlap() {
        assert_eq!(stitch("", "hello there"), "hello there");
        assert_eq!(stitch("hello there", ""), "hello there");
        assert_eq!(
            stitch("we should move the", "Move the review to Friday."),
            "we should Move the review to Friday."
        );
        assert_eq!(
            stitch("completely different", "words arrive here"),
            "completely different words arrive here"
        );
        // One shared word is not enough, and word suffixes never match.
        assert_eq!(
            stitch("the broadcast", "cast iron pans"),
            "the broadcast cast iron pans"
        );
    }

    #[test]
    fn unsegmented_scripts_stitch_by_character() {
        assert_eq!(
            stitch("今天天气很好我们", "天气很好我们去公园"),
            "今天天气很好我们去公园"
        );
        assert_eq!(stitch("broadcast", "cast iron"), "broadcast cast iron");
    }

    #[test]
    fn insertion_is_judged_from_letters_and_digits() {
        use InsertionVerdict::*;
        assert_eq!(insertion_verdict(None, "hello"), Unknown);
        assert_eq!(insertion_verdict(Some("anything"), "…"), Unknown);
        assert_eq!(
            insertion_verdict(Some("Dear Maya, Friday works."), "friday works"),
            Landed
        );
        assert_eq!(
            insertion_verdict(Some("Dear Maya,"), "friday works"),
            Missing
        );
        assert_eq!(
            insertion_verdict(Some("“Čudno” – reče."), "cudno, rece"),
            Landed
        );
        let far = format!("friday works{}", " x".repeat(600));
        assert_eq!(insertion_verdict(Some(&far), "friday works"), Missing);
    }
}
