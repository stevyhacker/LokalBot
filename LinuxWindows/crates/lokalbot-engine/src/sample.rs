pub struct Sample {
    pub id: &'static str,
    pub language: &'static str,
    pub title: &'static str,
    pub file_name: &'static str,
    pub audio: &'static [u8],
}

pub const ENGLISH: Sample = Sample {
    id: "orders-api/en",
    language: "en",
    title: "Sample: Orders API delivery window",
    file_name: "orders-api.en.m4a",
    audio: include_bytes!("../../../../LokalBot/Resources/SampleMeeting/orders-api.en.m4a"),
};

pub(crate) const SAMPLES: &[Sample] = &[
    ENGLISH,
    Sample {
        id: "orders-api/de",
        language: "de",
        title: "Beispiel: delivery window in der Orders API",
        file_name: "orders-api.de.m4a",
        audio: include_bytes!("../../../../LokalBot/Resources/SampleMeeting/orders-api.de.m4a"),
    },
    Sample {
        id: "orders-api/zh",
        language: "zh",
        title: "示例：Orders API 的 delivery window",
        file_name: "orders-api.zh.m4a",
        audio: include_bytes!("../../../../LokalBot/Resources/SampleMeeting/orders-api.zh.m4a"),
    },
    Sample {
        id: "orders-api/sr-Latn",
        language: "sr-Latn",
        title: "Primer: delivery window u Orders API-ju",
        file_name: "orders-api.sr-Latn.m4a",
        audio: include_bytes!(
            "../../../../LokalBot/Resources/SampleMeeting/orders-api.sr-Latn.m4a"
        ),
    },
];

pub fn for_language(language: &str) -> &'static Sample {
    let base = language.split(['-', '_']).next().unwrap_or(language);
    SAMPLES
        .iter()
        .find(|s| s.language.eq_ignore_ascii_case(language))
        .or_else(|| {
            SAMPLES
                .iter()
                .find(|s| s.language.eq_ignore_ascii_case(base))
        })
        .unwrap_or(&ENGLISH)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCRIPTS: [&str; 4] = [
        include_str!("../../../../LokalBot/Resources/SampleMeeting/script.en.json"),
        include_str!("../../../../LokalBot/Resources/SampleMeeting/script.de.json"),
        include_str!("../../../../LokalBot/Resources/SampleMeeting/script.zh.json"),
        include_str!("../../../../LokalBot/Resources/SampleMeeting/script.sr-Latn.json"),
    ];

    #[test]
    fn matches_the_bundled_scripts() {
        assert_eq!(SAMPLES.len(), SCRIPTS.len());
        for (sample, script) in SAMPLES.iter().zip(SCRIPTS) {
            let script: serde_json::Value = serde_json::from_str(script).unwrap();
            assert_eq!(script["sampleID"], sample.id);
            assert_eq!(script["language"], sample.language);
            assert_eq!(script["title"], sample.title);
            assert_eq!(script["audio"], sample.file_name);
            assert_eq!(&sample.audio[4..8], b"ftyp", "{}", sample.file_name);
        }
    }

    #[test]
    fn follows_the_interface_language_then_english() {
        assert_eq!(for_language("en").id, "orders-api/en");
        assert_eq!(for_language("de").id, "orders-api/de");
        assert_eq!(for_language("de-AT").id, "orders-api/de");
        assert_eq!(for_language("zh-Hans").id, "orders-api/zh");
        assert_eq!(for_language("zh-Hant").id, "orders-api/zh");
        assert_eq!(for_language("sr-Latn").id, "orders-api/sr-Latn");
        assert_eq!(for_language("SR-latn").id, "orders-api/sr-Latn");
        assert_eq!(for_language("fr").id, "orders-api/en");
        assert_eq!(for_language("ja").id, "orders-api/en");
    }
}
