//! Which languages screen text recognition should read here: the app's and the
//! system's, not every one, because each added language costs time on every
//! capture. Also the pinned `tessdata_fast` file of each language.

/// One language Tesseract can read, with its pinned data file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Language {
    /// The locale it serves, as `lokalbot_i18n` names it where they overlap.
    pub locale: &'static str,
    /// Tesseract's name for it, and the stem of its file.
    pub name: &'static str,
    /// What the language calls itself, shown in Settings.
    pub autonym: &'static str,
    /// Written in Latin letters. Such data also reads English about as well as
    /// `eng` does (97–99% measured), so these don't need `eng` beside them.
    pub latin: bool,
    pub size: u64,
    pub sha256: &'static str,
}

const fn language(
    locale: &'static str,
    name: &'static str,
    autonym: &'static str,
    latin: bool,
    size: u64,
    sha256: &'static str,
) -> Language {
    Language {
        locale,
        name,
        autonym,
        latin,
        size,
        sha256,
    }
}

/// The revision of `tesseract-ocr/tessdata_fast` the files below come from.
pub const TESSDATA_REVISION: &str = "87416418657359cb625c412a48b6e1d6d41c29bd";

/// The app's languages and the most common system ones.
#[rustfmt::skip]
pub const LANGUAGES: [Language; 46] = [
    language("en", "eng", "English", true, 4113088, "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"),
    language("zh-Hans", "chi_sim", "简体中文", false, 2469156, "a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730"),
    language("zh-Hant", "chi_tra", "繁體中文", false, 2366642, "529c5b5797d64b126065cd55f2bb4c7fd7b15790798091b1ff259941a829330b"),
    language("ja", "jpn", "日本語", false, 2471260, "1f5de9236d2e85f5fdf4b3c500f2d4926f8d9449f28f5394472d9e8d83b91b4d"),
    language("ko", "kor", "한국어", false, 1677415, "6b85e11d9bbf07863b97b3523b1b112844c43e713df8b66418a081fd1060b3b2"),
    language("ar", "ara", "العربية", false, 1432056, "e3206d3dc87fd50c24a0fb9f01838615911d25168f4e64415244b67d2bb3e729"),
    language("fa", "fas", "فارسی", false, 431500, "db1c0a91208aff00d3cf1ed2c1d23f76419afd5f024688b4f71adc3f2ce4a505"),
    language("ur", "urd", "اردو", false, 1398718, "62e8250ce2a994106e313a82e26a516a39e2cf159d0ce3c5b5008387fd0d555f"),
    language("he", "heb", "עברית", false, 961404, "11f9e43ab227f786352a50f75c94c2e9906f1baba86d93276da19da7ce0904db"),
    language("hi", "hin", "हिन्दी", false, 1122751, "4c73ffc59d497c186b19d1e90f5d721d678ea6b2e277b719bee4e2af12271825"),
    language("mr", "mar", "मराठी", false, 2118233, "0ba3f2d116972e72fe9e176bc84c38e81dfb6670f4ed1f7f6c8e16a27da7cb61"),
    language("bn", "ben", "বাংলা", false, 855841, "31163084c279aaebd376216f0c3d5c17ad4b5fee8db49dae79c20000b5de5964"),
    language("ta", "tam", "தமிழ்", false, 3237963, "d02fbec24be4b07e32e80d0ccfc3b6b67a3c5d61c9d0a7c8532677990912c6ec"),
    language("te", "tel", "తెలుగు", false, 2769654, "d10691fddd5b67802e1c12800ebb321d3b8bcd8d24a2ac3ff206f93188c04ab5"),
    language("th", "tha", "ไทย", false, 1072600, "294227cc2d1292b0acb28d61d4115c88252b96d466ca90b417cf4cf0c67bf07c"),
    language("ru", "rus", "Русский", false, 3861738, "e16e5e036cce1d9ec2b00063cf8b54472625b9e14d893a169e2b0dedeb4df225"),
    language("uk", "ukr", "Українська", false, 3825102, "d59e53e2bded32f4445f124b4b00240fcac7e8044c003ab822ccb94f0b3db59b"),
    language("bg", "bul", "Български", false, 1675212, "aebc9b0fcc8cfaf8a9f38a02bb7b85052bd850744696a2c11cf0081820e5b21e"),
    language("be", "bel", "Беларуская", false, 3692098, "9c6668a0b202f3dcfe074b64620d108e1902ca7498a40b5a11b4a3da6112d58f"),
    language("mk", "mkd", "Македонски", false, 1600188, "58622bf154830fa62103359938564aeb8112b929759e22a48224f3ecfaac34c6"),
    language("sr", "srp", "Српски", false, 2149931, "aa41ae3d9cc705e60d398ab38a5c3cc8b772c0d420c7d4f0859beb13d0e321b6"),
    language("el", "ell", "Ελληνικά", false, 1419514, "4fba8a0b461038d51f1c20d043d4f2ac38c4e778f1b90830847f7bd8fa3ba726"),
    language("sr-Latn", "srp_latn", "Srpski (latinica)", true, 3281787, "54b2e001bd8a336bdffc249c1487b8b7cb712f0a031f2551930ba050ebefa2a0"),
    language("hr", "hrv", "Hrvatski", true, 4103348, "9e515d9832ce259dbab550b1cc6b998f8b929faf2edacaaca981b05adb130571"),
    language("bs", "bos", "Bosanski", true, 2498242, "6cc8cc87cf1afbfa6a41febb725dbadb14bed96a46685906440a6eb8a7892f04"),
    language("sl", "slv", "Slovenščina", true, 3003829, "b937632c17ce5fdf20535d25feec044da10a0c4c8234f4302d5606fd671cf60d"),
    language("de", "deu", "Deutsch", true, 1525436, "19d219bbb6672c869d20a9636c6816a81eb9a71796cb93ebe0cb1530e2cdb22d"),
    language("fr", "fra", "Français", true, 1130365, "ced037562e8c80c13122dece28dd477d399af80911a28791a66a63ac1e3445ca"),
    language("es", "spa", "Español", true, 2294433, "6f2e04d02774a18f01bed44b1111f2cd7f3ba7ac9dc4373cd3f898a40ea6b464"),
    language("pt", "por", "Português", true, 1982756, "c4932b937207a9514b7514d518b931a99938c02a28a5a5a553f8599ed58b7deb"),
    language("it", "ita", "Italiano", true, 2701314, "b8f89e1e785118dac4d51ae042c029a64edb5c3ee42ef73027a6d412748d8827"),
    language("nl", "nld", "Nederlands", true, 6050296, "ced0e5e046a84c908a6aa7accbef9a232c4a5d9a8276691b81c6ee64d02963f6"),
    language("pl", "pol", "Polski", true, 4765518, "c4476cdbc0e33d898d32345122b7be1cbf85ace15f920f06c7714756e1ef79b2"),
    language("cs", "ces", "Čeština", true, 3795684, "934bcaf97ef3348413263331131c9fa7f55f30db333c711929c124fb635f7e1b"),
    language("sk", "slk", "Slovenčina", true, 4427661, "fbcc400a9c74c6a13d922fcb1211b655d1b165387b675ed75cd2dbd756b974a5"),
    language("hu", "hun", "Magyar", true, 5296273, "35067e7cfe102dcdc953f9a758fdfaa6296b17a1ee6d874ee780fa306430b9fb"),
    language("ro", "ron", "Română", true, 2376323, "9adfde6b51ba4b97efd10ea37c3070fd3fc2bad7815e81f5c3c198cd96216cc9"),
    language("tr", "tur", "Türkçe", true, 4550554, "7393381111e1152420fc4092cb44eef4237580d21b92bf30d7d221aad192c6b7"),
    language("vi", "vie", "Tiếng Việt", true, 531275, "79df64caf7bcfb2a27df5042ecb6121e196eada34da774956995747636d5bfa1"),
    language("id", "ind", "Bahasa Indonesia", true, 1122661, "69786901da87ab8766c1ea7fbb10b28f2110c14da3f6c8f2735df131fba95d88"),
    language("sw", "swa", "Kiswahili", true, 2167651, "395439d1ec308535066cbaea9b15e0e4cc81f8609170af76ab7e7e8d3ec42f3e"),
    language("sv", "swe", "Svenska", true, 4167034, "f7304988d41f833efebcc2d529df54b1903ecebbc3da1faabd19a0fddd4fe586"),
    language("da", "dan", "Dansk", true, 2580059, "acb1fd074487a31d1294fcdfd7d7c673467ffd8aeacb2ccd61ebcbf04eb4e2fa"),
    language("nb", "nor", "Norsk", true, 3610079, "0451eb4f8049ae78196806bf878a389a2f40f1386fe038568cf4441226ba6ef2"),
    language("fi", "fin", "Suomi", true, 7865732, "61a04cd62b507c3d9ae0e1cda399e6715ebf49dea9df47897c8acdcd3bd3e13c"),
    language("ca", "cat", "Català", true, 1146012, "250db73cd5b380d2798581295dc12f20d0828cdb335a65d833d12dfdbf57117d"),
];

/// English, the language every list falls back to.
pub const ENGLISH: &Language = &LANGUAGES[0];

/// The language a locale reads, from forms like `zh_TW.UTF-8`, `sr_RS@latin`,
/// `sr-Cyrl-RS` or `ar-EG`. `None` for a language with no pinned data.
pub fn for_locale(locale: &str) -> Option<&'static Language> {
    let lower = locale.trim().to_lowercase().replace('_', "-");
    let latin_modifier = lower.contains("@latin");
    let base = lower.split(['.', '@']).next().unwrap_or("");
    let parts: Vec<&str> = base.split('-').collect();
    let code = match parts[0] {
        "zh" => {
            let traditional = parts.contains(&"hant")
                || (!parts.contains(&"hans")
                    && parts.iter().any(|part| ["tw", "hk", "mo"].contains(part)));
            if traditional { "zh-Hant" } else { "zh-Hans" }
        }
        "sr" if latin_modifier || parts.contains(&"latn") => "sr-Latn",
        "cnr" => "sr-Latn",
        "arz" => "ar",
        "no" | "nn" => "nb",
        code => code,
    };
    LANGUAGES.iter().find(|language| language.locale == code)
}

/// What to read here: the app's language and the system's first one, with
/// English beside any other script, because windows in those languages still
/// show English (measured on rendered mixed screens: Korean 32% alone, 97%
/// beside English; Arabic 46% and 99%). Script other than Latin comes first.
pub fn wanted(app: &str, system: &[impl AsRef<str>]) -> Vec<&'static Language> {
    let mut languages: Vec<&'static Language> = Vec::new();
    let first_system = system.first().map(|locale| locale.as_ref());
    for locale in std::iter::once(app).chain(first_system) {
        if let Some(language) = for_locale(locale)
            && !languages.contains(&language)
        {
            languages.push(language);
        }
    }
    languages.sort_by_key(|language| language.latin);
    if !languages.iter().any(|language| language.latin) {
        languages.push(ENGLISH);
    }
    languages
}

/// The languages this app and system want, for this process.
pub fn wanted_here() -> Vec<&'static Language> {
    wanted(
        lokalbot_i18n::current().code,
        &lokalbot_i18n::system_preferences(),
    )
}

/// Comparable language and script of a locale or a BCP 47 tag.
fn key(locale: &str) -> (String, &'static str) {
    let lower = locale.trim().to_lowercase().replace('_', "-");
    let parts: Vec<&str> = lower.split('-').collect();
    let script = match parts[0] {
        "zh" => {
            if for_locale(&lower).is_some_and(|language| language.locale == "zh-Hant") {
                "hant"
            } else {
                "hans"
            }
        }
        "sr" => {
            if parts.contains(&"latn") {
                "latn"
            } else {
                "cyrl"
            }
        }
        _ => "",
    };
    (parts[0].to_string(), script)
}

/// The recognizer in `available` (BCP 47 tags) for one of the `wanted` languages,
/// in their order. Windows runs one recognizer at a time, so this is one tag.
pub fn pick_recognizer<'a>(
    wanted: &[&'static Language],
    available: &'a [String],
) -> Option<&'a str> {
    wanted.iter().find_map(|language| {
        let wanted_key = key(language.locale);
        available
            .iter()
            .find(|tag| key(tag) == wanted_key)
            .map(String::as_str)
    })
}

/// A recognizer for this language is among `available`.
pub fn has_recognizer(language: &Language, available: &[String]) -> bool {
    let wanted_key = key(language.locale);
    available.iter().any(|tag| key(tag) == wanted_key)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(languages: &[&Language]) -> Vec<&'static str> {
        languages.iter().map(|language| language.name).collect()
    }

    #[test]
    fn pins_are_well_formed() {
        for language in &LANGUAGES {
            assert_eq!(language.sha256.len(), 64, "{}", language.name);
            assert!(language.sha256.chars().all(|c| c.is_ascii_hexdigit()));
            assert!(language.size > 100_000, "{}", language.name);
        }
        let mut names: Vec<&str> = LANGUAGES.iter().map(|language| language.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), LANGUAGES.len());
        assert_eq!(ENGLISH.name, "eng");
    }

    #[test]
    fn locales_of_every_form_find_their_language() {
        for (locale, name) in [
            ("en_US.UTF-8", "eng"),
            ("en", "eng"),
            ("zh_CN.UTF-8", "chi_sim"),
            ("zh-Hans", "chi_sim"),
            ("zh_TW.UTF-8", "chi_tra"),
            ("zh-Hant-HK", "chi_tra"),
            ("zh-HK", "chi_tra"),
            ("ja_JP.UTF-8", "jpn"),
            ("ko-KR", "kor"),
            ("ar-EG", "ara"),
            ("arz", "ara"),
            ("sr_RS.UTF-8", "srp"),
            ("sr-Cyrl-RS", "srp"),
            ("sr_RS@latin", "srp_latn"),
            ("sr-Latn", "srp_latn"),
            ("nn_NO", "nor"),
            ("de_DE.UTF-8", "deu"),
        ] {
            assert_eq!(for_locale(locale).map(|l| l.name), Some(name), "{locale}");
        }
        assert_eq!(for_locale("xx_YY"), None);
        assert_eq!(for_locale(""), None);
    }

    #[test]
    fn every_app_language_reads_its_own_script_or_english() {
        for app in lokalbot_i18n::LANGUAGES {
            let wanted = wanted(app.code, &[app.code]);
            assert!(!wanted.is_empty(), "{}", app.code);
            // Hausa and Nigerian Pidgin have no data of their own and read as English.
            if !["ha", "pcm"].contains(&app.code) {
                assert!(for_locale(app.code).is_some(), "{}", app.code);
            }
        }
    }

    #[test]
    fn only_the_app_and_first_system_language_are_loaded() {
        // English alone needs one language.
        assert_eq!(names(&wanted("en", &["en_US.UTF-8", "de_DE"])), ["eng"]);
        // Another script comes first, with English beside it.
        assert_eq!(
            names(&wanted("zh-Hans", &["zh_CN.UTF-8"])),
            ["chi_sim", "eng"]
        );
        assert_eq!(names(&wanted("en", &["ru_RU.UTF-8"])), ["rus", "eng"]);
        // Latin data reads English, so nothing is added to it.
        assert_eq!(names(&wanted("de", &["de_DE.UTF-8"])), ["deu"]);
        // The later preferences never count.
        assert_eq!(
            names(&wanted("ja", &["ko_KR", "ru_RU", "ar_SA"])),
            ["jpn", "kor", "eng"]
        );
        // Serbian in both alphabets.
        assert_eq!(
            names(&wanted("sr-Latn", &["sr_RS.UTF-8"])),
            ["srp", "srp_latn"]
        );
        // A language with no data still reads Latin letters.
        assert_eq!(names(&wanted("ha", &[] as &[&str])), ["eng"]);
    }

    #[test]
    fn recognizers_match_language_and_script() {
        let available =
            |tags: &[&str]| -> Vec<String> { tags.iter().map(|tag| tag.to_string()).collect() };
        let simplified = wanted("zh-Hans", &[] as &[&str]);
        assert_eq!(
            pick_recognizer(&simplified, &available(&["en-US", "zh-Hans-CN"])),
            Some("zh-Hans-CN")
        );
        // Traditional is not Simplified: English is what is left.
        assert_eq!(
            pick_recognizer(&simplified, &available(&["en-GB", "zh-Hant-TW"])),
            Some("en-GB")
        );
        // Another script is chosen over Latin, whose recognizer can't read it.
        let japanese_system = wanted("en", &["ja-JP"]);
        assert_eq!(
            pick_recognizer(&japanese_system, &available(&["en-US", "ja-JP"])),
            Some("ja-JP")
        );
        // Both Serbian alphabets are their own recognizers.
        let serbian = wanted("sr-Latn", &[] as &[&str]);
        assert_eq!(
            pick_recognizer(&serbian, &available(&["sr-Cyrl-RS", "sr-Latn-RS"])),
            Some("sr-Latn-RS")
        );
        assert!(pick_recognizer(&simplified, &available(&["de-DE"])).is_none());
        assert!(has_recognizer(ENGLISH, &available(&["en-US"])));
        assert!(!has_recognizer(simplified[0], &available(&["en-US"])));
    }
}
