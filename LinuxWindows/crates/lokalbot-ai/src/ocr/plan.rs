//! Which engine reads, from what this computer has. No I/O here, so both
//! platforms' rules are tested on either.

use super::languages::{self, Language};
use super::{OCR_LANGUAGES_ID, OCR_MODEL_ID};

/// The engine that reads now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reader {
    None,
    Ocrs,
    /// The system's `tesseract`, with language data from its own folder or, if
    /// `library`, from `<library>/models/tesseract`.
    Tesseract {
        library: bool,
        languages: Vec<&'static str>,
    },
    /// `Windows.Media.Ocr`, with the recognizer of this language tag.
    Windows {
        tag: String,
    },
}

/// What to do with what this computer has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub reader: Reader,
    /// What the reader reads, where it can say.
    pub reading: Vec<&'static Language>,
    /// What this app and system want that nothing here reads yet.
    pub missing: Vec<&'static Language>,
    /// The download that would help, which only the person can start.
    pub download: Option<&'static str>,
    /// Reading `missing` needs the Tesseract program.
    pub needs_program: bool,
}

/// What Linux has: the `tesseract` program, the languages it lists, the language
/// data in the library, and the ocrs models.
#[derive(Clone, Copy, Debug)]
pub struct TesseractSetup<'a> {
    pub wanted: &'a [&'static Language],
    pub program: bool,
    pub system: &'a [String],
    pub library: &'a [&'static str],
    pub ocrs: bool,
}

/// The Linux rules. English with the ocrs models stays with ocrs: Tesseract is
/// faster there, yet reads coloured interfaces worse (83% against 98% measured).
/// Anything else goes to Tesseract, which reads it and ocrs can't. Without
/// Tesseract, or the data it needs, whatever can read does so until the person
/// downloads the rest.
pub fn with_tesseract(setup: TesseractSetup<'_>) -> Plan {
    let TesseractSetup {
        wanted,
        program,
        system,
        library,
        ocrs,
    } = setup;
    let english_only = wanted
        .iter()
        .all(|language| *language == languages::ENGLISH);
    let ocrs_reader = || if ocrs { Reader::Ocrs } else { Reader::None };
    if english_only && ocrs {
        return Plan {
            reader: Reader::Ocrs,
            reading: Vec::new(),
            missing: Vec::new(),
            download: None,
            needs_program: false,
        };
    }
    if !program {
        let missing: Vec<&'static Language> = wanted
            .iter()
            .copied()
            .filter(|language| *language != languages::ENGLISH)
            .collect();
        return Plan {
            reader: ocrs_reader(),
            reading: Vec::new(),
            needs_program: !missing.is_empty(),
            missing,
            download: (!ocrs).then_some(OCR_MODEL_ID),
        };
    }
    let in_system: Vec<&'static Language> = wanted
        .iter()
        .copied()
        .filter(|language| system.iter().any(|name| name == language.name))
        .collect();
    let in_library: Vec<&'static Language> = wanted
        .iter()
        .copied()
        .filter(|language| library.contains(&language.name))
        .collect();
    // One run reads from one folder, so the fuller one wins.
    let library_is_fuller = in_library.len() > in_system.len();
    let best = if library_is_fuller {
        &in_library
    } else {
        &in_system
    };
    let missing: Vec<&'static Language> = wanted
        .iter()
        .copied()
        .filter(|language| !best.contains(language))
        .collect();
    let latin_only_with_ocrs = ocrs && best.iter().all(|language| *language == languages::ENGLISH);
    if best.is_empty() || (latin_only_with_ocrs && !missing.is_empty()) {
        // Data for no wanted language, but English still reads Latin letters.
        if !ocrs && system.iter().any(|name| name == languages::ENGLISH.name) {
            return Plan {
                reader: Reader::Tesseract {
                    library: false,
                    languages: vec![languages::ENGLISH.name],
                },
                reading: vec![languages::ENGLISH],
                missing,
                download: Some(OCR_LANGUAGES_ID),
                needs_program: false,
            };
        }
        return Plan {
            reader: ocrs_reader(),
            reading: Vec::new(),
            missing,
            download: Some(OCR_LANGUAGES_ID),
            needs_program: false,
        };
    }
    Plan {
        reader: Reader::Tesseract {
            library: library_is_fuller,
            languages: best.iter().map(|language| language.name).collect(),
        },
        reading: best.clone(),
        download: (!missing.is_empty()).then_some(OCR_LANGUAGES_ID),
        missing,
        needs_program: false,
    }
}

/// The Windows rules: the recognizer built into Windows for a language wanted
/// here, otherwise ocrs, otherwise any recognizer installed, since it needs no
/// download. Nothing at all offers the ocrs download.
pub fn with_windows(wanted: &[&'static Language], recognizers: &[String], ocrs: bool) -> Plan {
    let missing: Vec<&'static Language> = wanted
        .iter()
        .copied()
        .filter(|language| {
            *language != languages::ENGLISH && !languages::has_recognizer(language, recognizers)
        })
        .collect();
    let tag = languages::pick_recognizer(wanted, recognizers).or_else(|| {
        (!ocrs)
            .then(|| recognizers.first().map(String::as_str))
            .flatten()
    });
    match tag {
        Some(tag) => Plan {
            reader: Reader::Windows {
                tag: tag.to_string(),
            },
            reading: languages::for_locale(tag).into_iter().collect(),
            missing,
            download: None,
            needs_program: false,
        },
        None => Plan {
            reader: if ocrs { Reader::Ocrs } else { Reader::None },
            reading: Vec::new(),
            missing,
            download: (!ocrs).then_some(OCR_MODEL_ID),
            needs_program: false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ocr::languages::wanted;

    fn system(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    fn setup<'a>(
        wanted: &'a [&'static Language],
        program: bool,
        in_system: &'a [String],
        library: &'a [&'static str],
        ocrs: bool,
    ) -> Plan {
        with_tesseract(TesseractSetup {
            wanted,
            program,
            system: in_system,
            library,
            ocrs,
        })
    }

    fn tesseract(library: bool, languages: &[&'static str]) -> Reader {
        Reader::Tesseract {
            library,
            languages: languages.to_vec(),
        }
    }

    const NOTHING: &[&str] = &[];

    #[test]
    fn english_with_ocrs_is_what_it_is_today() {
        let english = wanted("en", NOTHING);
        for program in [false, true] {
            let plan = setup(&english, program, &system(&["eng"]), &[], true);
            assert_eq!(plan.reader, Reader::Ocrs);
            assert_eq!(plan.download, None);
            assert!(plan.missing.is_empty() && !plan.needs_program);
        }
    }

    #[test]
    fn english_without_anything_offers_ocrs() {
        let english = wanted("en", NOTHING);
        let plan = setup(&english, false, &[], &[], false);
        assert_eq!(plan.reader, Reader::None);
        assert_eq!(plan.download, Some(OCR_MODEL_ID));
        assert!(!plan.needs_program);
    }

    #[test]
    fn english_reads_with_installed_tesseract_and_nothing_to_download() {
        let english = wanted("en", NOTHING);
        let plan = setup(&english, true, &system(&["eng", "osd"]), &[], false);
        assert_eq!(plan.reader, tesseract(false, &["eng"]));
        assert_eq!(plan.download, None);
    }

    #[test]
    fn another_script_uses_the_system_data_when_it_has_everything() {
        let chinese = wanted("zh-Hans", NOTHING);
        let plan = setup(&chinese, true, &system(&["chi_sim", "eng"]), &[], true);
        assert_eq!(plan.reader, tesseract(false, &["chi_sim", "eng"]));
        assert_eq!(plan.download, None);
        assert!(plan.missing.is_empty());
    }

    #[test]
    fn another_script_uses_downloaded_data() {
        let chinese = wanted("zh-Hans", NOTHING);
        let plan = setup(
            &chinese,
            true,
            &system(&["eng"]),
            &["chi_sim", "eng"],
            false,
        );
        assert_eq!(plan.reader, tesseract(true, &["chi_sim", "eng"]));
        assert_eq!(plan.download, None);
    }

    #[test]
    fn missing_language_data_is_offered_while_latin_is_read() {
        let russian = wanted("ru", NOTHING);
        // No ocrs: Tesseract reads what it has.
        let plan = setup(&russian, true, &system(&["eng"]), &[], false);
        assert_eq!(plan.reader, tesseract(false, &["eng"]));
        assert_eq!(plan.download, Some(OCR_LANGUAGES_ID));
        assert_eq!(plan.missing[0].name, "rus");
        // With ocrs: it stays until the data arrives.
        let plan = setup(&russian, true, &system(&["eng"]), &[], true);
        assert_eq!(plan.reader, Reader::Ocrs);
        assert_eq!(plan.download, Some(OCR_LANGUAGES_ID));
        // Nothing yet: no engine, and the download is offered.
        let plan = setup(&russian, true, &[], &[], false);
        assert_eq!(plan.reader, Reader::None);
        assert_eq!(plan.download, Some(OCR_LANGUAGES_ID));
        assert_eq!(plan.missing.len(), 2);
    }

    #[test]
    fn without_the_program_another_script_says_so_and_ocrs_is_offered() {
        let japanese = wanted("ja", NOTHING);
        let plan = setup(&japanese, false, &[], &["jpn", "eng"], false);
        assert_eq!(plan.reader, Reader::None);
        assert_eq!(plan.download, Some(OCR_MODEL_ID));
        assert!(plan.needs_program);
        assert_eq!(plan.missing[0].name, "jpn");
        let plan = setup(&japanese, false, &[], &[], true);
        assert_eq!(plan.reader, Reader::Ocrs);
        assert_eq!(plan.download, None);
        assert!(plan.needs_program);
    }

    #[test]
    fn accented_latin_prefers_tesseract_over_ocrs() {
        // ocrs reads only ASCII, so German needs its own data.
        let german = wanted("de", NOTHING);
        let plan = setup(&german, true, &system(&["deu"]), &[], true);
        assert_eq!(plan.reader, tesseract(false, &["deu"]));
        let plan = setup(&german, true, &[], &[], true);
        assert_eq!(plan.reader, Reader::Ocrs);
        assert_eq!(plan.download, Some(OCR_LANGUAGES_ID));
        // Without ocrs, the English data that came with the program still reads.
        let plan = setup(&german, true, &system(&["eng", "osd"]), &[], false);
        assert_eq!(plan.reader, tesseract(false, &["eng"]));
        assert_eq!(plan.download, Some(OCR_LANGUAGES_ID));
        assert_eq!(plan.missing[0].name, "deu");
    }

    fn tags(names: &[&str]) -> Vec<String> {
        system(names)
    }

    #[test]
    fn windows_prefers_its_own_recognizer_and_needs_no_download() {
        let chinese = wanted("zh-Hans", NOTHING);
        let plan = with_windows(&chinese, &tags(&["en-US", "zh-Hans-CN"]), true);
        assert_eq!(
            plan.reader,
            Reader::Windows {
                tag: "zh-Hans-CN".into()
            }
        );
        assert_eq!(plan.reading[0].name, "chi_sim");
        assert!(plan.missing.is_empty());
        assert_eq!(plan.download, None);
    }

    #[test]
    fn windows_says_which_language_pack_is_missing() {
        let chinese = wanted("zh-Hans", NOTHING);
        let plan = with_windows(&chinese, &tags(&["en-US"]), false);
        assert_eq!(
            plan.reader,
            Reader::Windows {
                tag: "en-US".into()
            }
        );
        assert_eq!(plan.missing[0].name, "chi_sim");
        assert_eq!(plan.download, None);
    }

    #[test]
    fn windows_falls_back_to_ocrs_then_any_recognizer_then_the_download() {
        let hindi = wanted("hi", NOTHING);
        let plan = with_windows(&hindi, &tags(&["de-DE"]), true);
        assert_eq!(plan.reader, Reader::Ocrs);
        let plan = with_windows(&hindi, &tags(&["de-DE"]), false);
        assert_eq!(
            plan.reader,
            Reader::Windows {
                tag: "de-DE".into()
            }
        );
        let plan = with_windows(&hindi, &[], true);
        assert_eq!(plan.reader, Reader::Ocrs);
        assert_eq!(plan.download, None);
        let plan = with_windows(&hindi, &[], false);
        assert_eq!(plan.reader, Reader::None);
        assert_eq!(plan.download, Some(OCR_MODEL_ID));
        assert_eq!(plan.missing[0].name, "hin");
    }
}
