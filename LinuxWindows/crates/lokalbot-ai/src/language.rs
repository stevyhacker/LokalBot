//! Summary language (`Models/SummaryLanguage.swift`, `LanguageCode.swift`).
//!
//! `match` resolves the transcript to a concrete language by voting over
//! windows sampled across the meeting, so a foreign-language opening never
//! decides the whole meeting. Detection uses `whatlang` instead of Apple's
//! `NLLanguageRecognizer`; a language outside the summary presets keeps the
//! prompt's own "the transcript's language" rule.

use whatlang::Lang;

use lokalbot_core::Transcript;

const WINDOW_CHARACTERS: usize = 400;
const MAXIMUM_SAMPLES: usize = 32;
const MINIMUM_LETTERS: usize = 12;
const FULL_VOTE_LETTERS: f64 = 80.0;

/// `summaryDisplayName` for a stored language code, or `None` for unknown codes.
pub fn display_name(code: &str) -> Option<&'static str> {
    Some(match code.trim() {
        "en" => "English",
        "zh" => "Simplified Chinese (Mandarin)",
        "zh-Hant" => "Traditional Chinese (Mandarin)",
        "yue" => "Cantonese",
        "ja" => "Japanese",
        "ko" => "Korean",
        "es" => "Spanish",
        "fr" => "French",
        "de" => "German",
        "pt" => "Portuguese (Brazil)",
        "pt-PT" => "Portuguese (Portugal)",
        "ru" => "Russian",
        "ar" => "Arabic",
        "hi" => "Hindi",
        "it" => "Italian",
        "nl" => "Dutch",
        "tr" => "Turkish",
        "pl" => "Polish",
        "sv" => "Swedish",
        "da" => "Danish",
        "no" => "Norwegian (Bokmål)",
        "nn" => "Norwegian (Nynorsk)",
        "sr" => "Serbian",
        "th" => "Thai",
        "vi" => "Vietnamese",
        _ => return None,
    })
}

/// The language name the prompts carry for the `summaryLanguage` setting
/// (`match`, a code, or `custom:<name>`); `None` means "the transcript's
/// language".
pub fn prompt_language(setting: &str, transcript: &Transcript) -> Option<String> {
    let setting = setting.trim();
    if let Some(custom) = setting.strip_prefix("custom:") {
        let name = custom.trim();
        return (!name.is_empty()).then(|| name.to_string());
    }
    if setting.is_empty() || setting.eq_ignore_ascii_case("match") {
        let passages: Vec<String> = transcript
            .segments
            .iter()
            .map(|s| Transcript::display_text(&s.text))
            .collect();
        return detect(&passages).map(str::to_string);
    }
    display_name(setting)
        .map(str::to_string)
        .or_else(|| Some(setting.to_string()))
}

fn letters(text: &str) -> usize {
    text.chars().filter(|c| c.is_alphabetic()).count()
}

fn windows(text: &str) -> Vec<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let chars: Vec<char> = trimmed.chars().collect();
    chars
        .chunks(WINDOW_CHARACTERS)
        .map(|c| c.iter().collect())
        .collect()
}

fn distributed(samples: Vec<String>) -> Vec<String> {
    let material: Vec<String> = samples
        .into_iter()
        .filter(|s| letters(s) >= MINIMUM_LETTERS)
        .collect();
    if material.len() <= MAXIMUM_SAMPLES {
        return material;
    }
    (0..MAXIMUM_SAMPLES)
        .map(|slot| {
            let position = slot as f64 * (material.len() - 1) as f64 / (MAXIMUM_SAMPLES - 1) as f64;
            material[position.round() as usize].clone()
        })
        .collect()
}

/// A preset language name for the dominant language, `None` when the
/// winner is not a preset (or nothing could be detected).
pub fn detect(passages: &[String]) -> Option<&'static str> {
    let samples = distributed(passages.iter().flat_map(|p| windows(p)).collect());
    if samples.is_empty() {
        return Some("English");
    }
    let mut votes: Vec<(Option<&'static str>, f64, f64)> = Vec::new();
    for sample in &samples {
        let Some((name, confidence)) = recognized(sample) else {
            continue;
        };
        let material = (letters(sample) as f64 / FULL_VOTE_LETTERS).min(1.0);
        match votes.iter_mut().find(|(n, _, _)| *n == name) {
            Some(entry) => {
                entry.1 += material;
                entry.2 += confidence * material;
            }
            None => votes.push((name, material, confidence * material)),
        }
    }
    votes.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal))
            .then_with(|| (b.0 == Some("English")).cmp(&(a.0 == Some("English"))))
    });
    match votes.first() {
        Some((name, _, _)) => *name,
        None => Some("English"),
    }
}

/// Mostly-English meetings get the English-only wording checks.
pub fn is_mostly_english(transcript: &Transcript) -> bool {
    let text: String = transcript
        .segments
        .iter()
        .map(|s| Transcript::display_text(&s.text))
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let samples = distributed(windows(&text));
    let (mut english, mut total) = (0.0, 0.0);
    for sample in &samples {
        let Some(info) = whatlang::detect(sample) else {
            continue;
        };
        let material = (letters(sample) as f64 / FULL_VOTE_LETTERS).min(1.0);
        total += material;
        if info.lang() == Lang::Eng {
            english += material;
        }
    }
    total == 0.0 || english * 2.0 >= total
}

/// One sample's language as a preset name (or `None` for a non-preset one).
fn recognized(sample: &str) -> Option<(Option<&'static str>, f64)> {
    if let Some(chinese) = chinese_script(sample) {
        return Some((Some(chinese), 1.0));
    }
    let info = whatlang::detect(sample)?;
    let name = match info.lang() {
        Lang::Eng => Some("English"),
        Lang::Jpn => Some("Japanese"),
        Lang::Kor => Some("Korean"),
        Lang::Spa => Some("Spanish"),
        Lang::Fra => Some("French"),
        Lang::Deu => Some("German"),
        Lang::Por => Some("Portuguese (Brazil)"),
        Lang::Rus => Some("Russian"),
        Lang::Ara => Some("Arabic"),
        Lang::Hin => Some("Hindi"),
        Lang::Ita => Some("Italian"),
        Lang::Nld => Some("Dutch"),
        Lang::Tur => Some("Turkish"),
        Lang::Pol => Some("Polish"),
        Lang::Swe => Some("Swedish"),
        Lang::Dan => Some("Danish"),
        Lang::Nob => Some("Norwegian (Bokmål)"),
        Lang::Tha => Some("Thai"),
        Lang::Vie => Some("Vietnamese"),
        Lang::Cmn => Some("Simplified Chinese (Mandarin)"),
        _ => None,
    };
    Some((name, info.confidence()))
}

/// Simplified vs Traditional Chinese is a matter of script.
fn chinese_script(text: &str) -> Option<&'static str> {
    let mut han = 0usize;
    let mut bopomofo = 0usize;
    let mut letters = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            letters += 1;
        }
        let v = c as u32;
        if (0x3400..=0x4DBF).contains(&v)
            || (0x4E00..=0x9FFF).contains(&v)
            || (0xF900..=0xFAFF).contains(&v)
            || (0x20000..=0x2CEAF).contains(&v)
        {
            han += 1;
        } else if (0x3100..=0x312F).contains(&v) || (0x31A0..=0x31BF).contains(&v) {
            bopomofo += 1;
        }
    }
    let signal = han + bopomofo;
    if signal == 0 {
        return None;
    }
    // Kana alongside Han is Japanese, not Chinese.
    if text.chars().any(|c| ('\u{3040}'..='\u{30FF}').contains(&c)) {
        return None;
    }
    let ratio = signal as f64 / letters.max(signal) as f64;
    if !(signal >= 8 && (ratio >= 0.08 || signal >= 20)) {
        return None;
    }
    let traditional = text
        .chars()
        .filter(|c| TRADITIONAL_ONLY.contains(*c))
        .count();
    let simplified = text
        .chars()
        .filter(|c| SIMPLIFIED_ONLY.contains(*c))
        .count();
    if bopomofo > 0 || traditional > simplified {
        Some("Traditional Chinese (Mandarin)")
    } else {
        Some("Simplified Chinese (Mandarin)")
    }
}

/// Common characters that exist in only one script.
const TRADITIONAL_ONLY: &str = "們這個來說對時會國過後還沒麼樣開關問題點機發現實業經長東學電當應見頭話動門車書間無聽讓錢與為處買賣寫議論聯繫辦網";
const SIMPLIFIED_ONLY: &str = "们这个来说对时会国过后还没么样开关问题点机发现实业经长东学电当应见头话动门车书间无听让钱与为处买卖写议论联系办网";

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::model::Segment;

    fn transcript(texts: &[&str]) -> Transcript {
        Transcript {
            segments: texts
                .iter()
                .enumerate()
                .map(|(i, t)| Segment {
                    start: i as f64,
                    end: i as f64 + 1.0,
                    speaker: "them".into(),
                    text: t.to_string(),
                    confidence: None,
                    timing_precision: None,
                    attribution: None,
                })
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn settings_map_to_prompt_names() {
        let english = transcript(&[
            "We need to ship the release before Friday and update the documentation for customers.",
        ]);
        assert_eq!(
            prompt_language("match", &english).as_deref(),
            Some("English")
        );
        assert_eq!(prompt_language("de", &english).as_deref(), Some("German"));
        assert_eq!(
            prompt_language("custom:Klingon", &english).as_deref(),
            Some("Klingon")
        );
        assert!(is_mostly_english(&english));
        let german = transcript(&[
            "Wir müssen die neue Version vor Freitag veröffentlichen und die Dokumentation für die Kunden aktualisieren.",
        ]);
        assert_eq!(prompt_language("match", &german).as_deref(), Some("German"));
        assert!(!is_mostly_english(&german));
        let chinese = transcript(&["我们这个项目需要在星期五之前发布新的版本，还要更新文档。"]);
        assert_eq!(
            prompt_language("match", &chinese).as_deref(),
            Some("Simplified Chinese (Mandarin)")
        );
    }

    #[test]
    fn a_foreign_opening_does_not_decide_the_meeting() {
        let mut texts =
            vec!["Bonjour à tous, merci d'être venus aujourd'hui pour cette réunion importante."];
        let english = "The search cluster needs a failover benchmark before we enable cluster mode next week.";
        texts.extend(std::iter::repeat_n(english, 8));
        assert_eq!(
            prompt_language("match", &transcript(&texts)).as_deref(),
            Some("English")
        );
    }
}
