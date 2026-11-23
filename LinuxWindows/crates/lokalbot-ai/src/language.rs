use whatlang::Lang;

use lokalbot_core::Transcript;

const WINDOW_CHARACTERS: usize = 400;
const MAXIMUM_SAMPLES: usize = 32;
const MINIMUM_LETTERS: usize = 12;
const FULL_VOTE_LETTERS: f64 = 80.0;

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
        "uk" => "Ukrainian",
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
        "bs" => "Bosnian",
        "hr" => "Croatian",
        "cnr" => "Montenegrin",
        "sr" => "Serbian",
        "bcms" => "Bosnian, Croatian, Montenegrin, Serbian",
        "th" => "Thai",
        "vi" => "Vietnamese",
        _ => return None,
    })
}

pub fn prompt_name(code: &str) -> Option<&'static str> {
    Some(match code.trim() {
        "sr" => "Serbian, in the script the source text uses (Latin or Cyrillic)",
        "cnr" => "Montenegrin, in the script the source text uses (Latin or Cyrillic)",
        "bcms" => {
            "the transcript's own language (Bosnian, Croatian, Montenegrin or Serbian), keeping its ijekavian or ekavian forms and its script"
        }
        other => return display_name(other),
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotesLanguage {
    pub name: String,
    pub prompt: String,
}

impl NotesLanguage {
    fn named(name: &str) -> Self {
        let code = name.trim();
        Self {
            name: display_name(code).unwrap_or(code).to_string(),
            prompt: prompt_name(code).unwrap_or(code).to_string(),
        }
    }
}

pub fn notes_language(setting: &str, transcript: &Transcript) -> Option<NotesLanguage> {
    let setting = setting.trim();
    if let Some(custom) = setting.strip_prefix("custom:") {
        let name = custom.trim();
        return (!name.is_empty()).then(|| NotesLanguage {
            name: name.to_string(),
            prompt: name.to_string(),
        });
    }
    if setting.is_empty() || setting.eq_ignore_ascii_case("match") {
        let passages: Vec<String> = transcript
            .segments
            .iter()
            .map(|s| Transcript::display_text(&s.text))
            .collect();
        return detect(&passages).map(NotesLanguage::named);
    }
    Some(NotesLanguage::named(setting))
}

pub fn prompt_language(setting: &str, transcript: &Transcript) -> Option<String> {
    notes_language(setting, transcript).map(|language| language.prompt)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DailySummaryLanguage {
    pub name: String,
    pub fallback_locale: &'static str,
}

impl Default for DailySummaryLanguage {
    fn default() -> Self {
        Self::resolve("en", "en", &["en"])
    }
}

impl DailySummaryLanguage {
    pub fn from_settings(settings: &lokalbot_core::Settings) -> Self {
        Self::resolve(
            &settings.summary_language,
            &settings.app_language,
            &lokalbot_i18n::system_preferences(),
        )
    }

    pub fn resolve(notes: &str, interface: &str, preferred: &[impl AsRef<str>]) -> Self {
        let app = lokalbot_i18n::resolve(interface, preferred);
        let notes = notes.trim();
        let name = notes
            .strip_prefix("custom:")
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| prompt_name(notes))
            .unwrap_or(app.english_name)
            .to_string();
        let catalog = match notes {
            "zh" => "zh-Hans",
            "sr" | "cnr" => "sr-Latn",
            other => other,
        };
        let fallback_locale = lokalbot_i18n::LANGUAGES
            .iter()
            .find(|language| language.code == catalog)
            .map_or(app.code, |language| language.code);
        Self {
            name,
            fallback_locale,
        }
    }

    pub fn system(&self, base: &str) -> String {
        format!(
            "{base}\n\nWrite all human-readable titles, notes, summaries, recommendations, and memory text in {}. Keep JSON keys, status enum values, identifiers, source markers, proper names, and quoted source text unchanged. This output-language rule also applies when the evidence is in another language.",
            self.name
        )
    }

    pub fn text<'a>(&self, key: &'a str) -> &'a str {
        lokalbot_i18n::translate(self.fallback_locale, key)
    }

    pub fn uses_english_catalog(&self) -> bool {
        self.fallback_locale == "en"
    }
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

pub fn detect(passages: &[String]) -> Option<&'static str> {
    let samples = distributed(passages.iter().flat_map(|p| windows(p)).collect());
    if samples.is_empty() {
        return Some("en");
    }
    let mut votes: Vec<(&'static str, f64, f64)> = Vec::new();
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
            .then_with(|| (b.0 == "en").cmp(&(a.0 == "en")))
    });
    Some(votes.first().map_or("en", |(code, _, _)| *code))
}

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

fn recognized(sample: &str) -> Option<(&'static str, f64)> {
    if let Some(chinese) = chinese_script(sample) {
        return Some((chinese, 1.0));
    }
    let info = whatlang::detect(sample)?;
    let code = match info.lang() {
        Lang::Eng => "en",
        Lang::Jpn => "ja",
        Lang::Kor => "ko",
        Lang::Spa => "es",
        Lang::Fra => "fr",
        Lang::Deu => "de",
        Lang::Por => "pt",
        Lang::Rus => "ru",
        Lang::Ukr => "uk",
        Lang::Ara => "ar",
        Lang::Hin => "hi",
        Lang::Ita => "it",
        Lang::Nld => "nl",
        Lang::Tur => "tr",
        Lang::Pol => "pl",
        Lang::Swe => "sv",
        Lang::Dan => "da",
        Lang::Nob => "no",
        Lang::Hrv | Lang::Srp => "bcms",
        Lang::Tha => "th",
        Lang::Vie => "vi",
        Lang::Cmn => "zh",
        other => other.eng_name(),
    };
    Some((code, info.confidence()))
}

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
        Some("zh-Hant")
    } else {
        Some("zh")
    }
}

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
    #[test]
    fn a_serbian_croatian_meeting_gets_the_shared_name_and_keeps_its_variant() {
        let meeting = transcript(&[
            "Dobro jutro, drago mi je da smo se čuli danas prije podne.",
            "Ja radim kao softverski inženjer već desetak godina, uglavnom za strane firme.",
            "Projekat je trenutno u fazi testiranja i imamo prve korisnike na Linuxu i Windowsu.",
            "Mislim da bi trebalo prvo da završimo dokumentaciju, pa onda da pričamo o investiciji.",
            "neka alternativa.",
            "Ne znam da li si stigao da pogledaš tekst koji sam ti poslao prošle sedmice.",
            "Proces kod nas obično traje tri ili četiri sastanka prije konačne odluke.",
            "Ajde, čujemo se sljedeće nedjelje, pa ćemo vidjeti šta dalje.",
        ]);
        let language = notes_language("match", &meeting).unwrap();
        assert_eq!(language.name, "Bosnian, Croatian, Montenegrin, Serbian");
        assert!(
            language
                .prompt
                .contains("keeping its ijekavian or ekavian forms and its script")
        );
        let cyrillic = transcript(&[
            "Видјећемо се сутра, па ћемо причати о пројекту и документацији.",
            "Мислим да ће тестирање бити готово до краја мјесеца.",
            "Ја ћу ти послати документацију чим је завршим.",
            "Шта ћемо са инвестицијом, то ћемо одлучити касније.",
        ]);
        assert_eq!(
            notes_language("match", &cyrillic).unwrap().name,
            "Bosnian, Croatian, Montenegrin, Serbian"
        );
        let croatian = notes_language("hr", &meeting).unwrap();
        assert_eq!(
            (croatian.name.as_str(), croatian.prompt.as_str()),
            ("Croatian", "Croatian")
        );
        let serbian = notes_language("sr", &meeting).unwrap();
        assert_eq!(serbian.name, "Serbian");
        assert_eq!(
            serbian.prompt,
            "Serbian, in the script the source text uses (Latin or Cyrillic)"
        );
    }

    #[test]
    fn a_language_outside_the_menu_keeps_its_own_name() {
        let czech = transcript(&[
            "Myslím, že musíme dokončit projekt do pátku a poslat zprávu klientovi.",
            "Zítra se sejdeme znovu a probereme rozpočet na příští rok.",
        ]);
        assert_eq!(prompt_language("match", &czech).as_deref(), Some("Czech"));
        let ukrainian = transcript(&[
            "Думаю, нам потрібно завершити проєкт до п'ятниці та надіслати звіт клієнту.",
            "Завтра ми зустрінемося знову й обговоримо бюджет на наступний рік.",
        ]);
        assert_eq!(
            prompt_language("match", &ukrainian).as_deref(),
            Some("Ukrainian")
        );
    }

    #[test]
    fn daily_language_prefers_notes_and_resolves_system_without_translating_sources() {
        let french = DailySummaryLanguage::from_settings(&lokalbot_core::Settings {
            summary_language: "fr".into(),
            app_language: "ru".into(),
            ..lokalbot_core::Settings::default()
        });
        assert_eq!(french.name, "French");
        assert_eq!(french.fallback_locale, "fr");
        let russian = DailySummaryLanguage::resolve("match", "system", &["ru-RU", "en"]);
        assert_eq!(russian.name, "Russian");
        assert_eq!(russian.fallback_locale, "ru");
        let serbian = DailySummaryLanguage::resolve("sr", "en", &["en"]);
        assert_eq!(
            serbian.name,
            "Serbian, in the script the source text uses (Latin or Cyrillic)"
        );
        assert_eq!(serbian.fallback_locale, "sr-Latn");
        let custom = DailySummaryLanguage::resolve("custom:Klingon", "ru", &["en"]);
        assert_eq!(custom.name, "Klingon");
        assert_eq!(custom.fallback_locale, "ru");
    }
}
