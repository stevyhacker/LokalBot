//! Spell checking for autocomplete's typo offers and seam guard, the
//! counterpart of `NSSpellChecker`: the system's Hunspell dictionaries through
//! spellbook on Linux, `ISpellChecker` on Windows. Only non-words are flagged.
//!
//! Dictionaries load in the background. Until they have, and without any, no
//! word is a typo and [`SpellChecker::languages`] is empty, so every rule that
//! depends on a verdict stands down.

use std::sync::Arc;

/// At most this many languages are checked, the user's own first: a word is a
/// typo only if every one of them flags it.
const MAX_LANGUAGES: usize = 4;

/// A dictionary name's language: "en" for "en_US" or "en-GB".
fn base_language(name: &str) -> String {
    name.split(['_', '-'])
        .next()
        .unwrap_or_default()
        .to_lowercase()
}

/// Which installed dictionaries to use: at most one per language, the
/// `preferred` ones first, then the most usual variant of each other language.
fn choose_languages(mut available: Vec<String>, preferred: &[String]) -> Vec<String> {
    available.sort();
    available.dedup();
    let exact = |want: &str, have: &str| {
        want.replace('-', "_")
            .eq_ignore_ascii_case(&have.replace('-', "_"))
    };
    let mut chosen: Vec<String> = Vec::new();
    let add = |name: &String, chosen: &mut Vec<String>| {
        let base = base_language(name);
        if !chosen.iter().any(|c| base_language(c) == base) {
            chosen.push(name.clone());
        }
    };
    for want in preferred {
        if let Some(name) = available.iter().find(|name| exact(want, name)) {
            add(name, &mut chosen);
        }
    }
    for want in preferred {
        if let Some(name) = available
            .iter()
            .find(|name| base_language(name) == base_language(want))
        {
            add(name, &mut chosen);
        }
    }
    // "en_US" before "en_AU": a language's own country first, then US English.
    for name in &available {
        let base = base_language(name);
        let usual = name.to_lowercase() == format!("{base}_{base}") || name == "en_US";
        if usual {
            add(name, &mut chosen);
        }
    }
    for name in &available {
        add(name, &mut chosen);
    }
    chosen.truncate(MAX_LANGUAGES);
    chosen
}

/// Words a checker can judge whole. `NSSpellChecker` finds the misspelled word
/// inside a token, so "wrld," or "foo-bar" is not flagged whole there; a
/// checker asked about the token would call it a typo.
fn is_checkable(word: &str) -> bool {
    !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_alphabetic() || c == '\'' || c == '\u{2019}')
}

/// Whether a longer word in `sorted` starts with `word`.
#[cfg(any(target_os = "linux", test))]
fn is_prefix_of_any(sorted: &[String], word: &str) -> bool {
    let word = word.to_lowercase();
    let start = sorted.partition_point(|stem| stem.as_str() < word.as_str());
    sorted[start..]
        .iter()
        .take_while(|stem| stem.starts_with(&word))
        .any(|stem| stem.len() > word.len())
}

/// Whether this computer has a dictionary to check against, for Settings.
pub fn has_dictionaries() -> bool {
    backend::has_dictionaries()
}

/// A cheap handle on the system's spell checker. Calls never block for long.
#[derive(Clone)]
pub struct SpellChecker {
    inner: Arc<backend::Backend>,
}

impl SpellChecker {
    /// Starts loading in the background.
    pub fn start() -> Self {
        Self {
            inner: Arc::new(backend::Backend::start()),
        }
    }

    /// The languages in use, as `en_US` or `en-US`. Empty while loading and
    /// when this computer has no dictionary.
    pub fn languages(&self) -> Vec<String> {
        self.inner.languages()
    }

    pub fn is_typo(&self, word: &str) -> bool {
        is_checkable(word) && self.inner.is_typo(word)
    }

    /// Suggestions, best first.
    pub fn guesses(&self, word: &str) -> Vec<String> {
        self.inner.guesses(word)
    }

    /// A longer word starts with `word`.
    pub fn is_completable_prefix(&self, word: &str) -> bool {
        self.inner.is_completable_prefix(word)
    }
}

#[cfg(target_os = "linux")]
mod backend {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    use parking_lot::RwLock;

    use super::{choose_languages, is_prefix_of_any};

    struct Hunspell {
        language: String,
        dictionary: spellbook::Dictionary,
        /// The dictionary's stems, lowercased and sorted.
        stems: Vec<String>,
    }

    pub(super) struct Backend {
        loaded: Arc<RwLock<Vec<Hunspell>>>,
    }

    impl Backend {
        pub(super) fn start() -> Self {
            let loaded: Arc<RwLock<Vec<Hunspell>>> = Arc::default();
            let target = loaded.clone();
            let spawned = std::thread::Builder::new()
                .name("lokalbot-spell".into())
                .spawn(move || {
                    let found = installed();
                    let names: Vec<String> = found.iter().map(|(name, _)| name.clone()).collect();
                    for name in choose_languages(names, &preferred_languages()) {
                        let Some((_, folder)) = found.iter().find(|(n, _)| *n == name) else {
                            continue;
                        };
                        match load(&name, folder) {
                            Some(hunspell) => target.write().push(hunspell),
                            None => log::info!("autocomplete: could not load dictionary {name}"),
                        }
                    }
                });
            if let Err(err) = spawned {
                log::warn!("autocomplete: could not start the spell checker: {err}");
            }
            Self { loaded }
        }

        pub(super) fn languages(&self) -> Vec<String> {
            self.loaded
                .read()
                .iter()
                .map(|h| h.language.clone())
                .collect()
        }

        pub(super) fn is_typo(&self, word: &str) -> bool {
            let word = word.replace('\u{2019}', "'");
            let loaded = self.loaded.read();
            !loaded.is_empty() && loaded.iter().all(|h| !h.dictionary.check(&word))
        }

        pub(super) fn guesses(&self, word: &str) -> Vec<String> {
            let mut guesses = Vec::new();
            for hunspell in self.loaded.read().iter() {
                hunspell.dictionary.suggest(word, &mut guesses);
            }
            guesses
        }

        pub(super) fn is_completable_prefix(&self, word: &str) -> bool {
            self.loaded
                .read()
                .iter()
                .any(|h| is_prefix_of_any(&h.stems, word))
        }
    }

    /// Settings asks on every redraw, so the folders are looked at once.
    pub(super) fn has_dictionaries() -> bool {
        static FOUND: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        *FOUND.get_or_init(|| !installed().is_empty())
    }

    /// The folders Hunspell itself searches.
    fn search_paths() -> Vec<PathBuf> {
        let mut paths: Vec<PathBuf> = std::env::var_os("DICPATH")
            .map(|value| std::env::split_paths(&value).collect())
            .unwrap_or_default();
        if let Some(home) = std::env::var_os("HOME") {
            paths.push(Path::new(&home).join(".local/share/hunspell"));
        }
        for folder in [
            "/usr/share/hunspell",
            "/usr/local/share/hunspell",
            "/usr/share/myspell",
            "/usr/share/myspell/dicts",
        ] {
            paths.push(PathBuf::from(folder));
        }
        paths
    }

    fn installed() -> Vec<(String, PathBuf)> {
        let mut found: Vec<(String, PathBuf)> = Vec::new();
        for folder in search_paths() {
            let Ok(entries) = std::fs::read_dir(&folder) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let is_dic = path.extension().is_some_and(|e| e == "dic");
                let Some(name) = path.file_stem().and_then(|s| s.to_str()) else {
                    continue;
                };
                if is_dic
                    && path.with_extension("aff").exists()
                    && !found.iter().any(|(known, _)| known == name)
                {
                    found.push((name.to_string(), folder.clone()));
                }
            }
        }
        found
    }

    fn preferred_languages() -> Vec<String> {
        let mut languages = Vec::new();
        if let Ok(list) = std::env::var("LANGUAGE") {
            languages.extend(list.split(':').map(str::to_string));
        }
        for variable in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let Ok(value) = std::env::var(variable) {
                languages.push(value);
            }
        }
        languages
            .into_iter()
            .map(|value| value.split(['.', '@']).next().unwrap_or("").to_string())
            .filter(|value| !value.is_empty() && value != "C" && value != "POSIX")
            .collect()
    }

    /// Dictionaries are UTF-8 or say otherwise on their `SET` line.
    fn decode(bytes: &[u8], encoding: &str) -> Option<String> {
        match encoding.to_ascii_uppercase().as_str() {
            "UTF-8" | "UTF8" => String::from_utf8(bytes.to_vec()).ok(),
            "ISO8859-1" | "ISO-8859-1" | "LATIN1" => {
                Some(bytes.iter().map(|b| char::from(*b)).collect())
            }
            _ => None,
        }
    }

    fn encoding_of(aff: &[u8]) -> String {
        aff.split(|b| *b == b'\n')
            .find_map(|line| {
                let line = String::from_utf8_lossy(line);
                let rest = line.trim().strip_prefix("SET ")?.trim().to_string();
                (!rest.is_empty()).then_some(rest)
            })
            .unwrap_or_else(|| "UTF-8".to_string())
    }

    fn load(name: &str, folder: &Path) -> Option<Hunspell> {
        let aff = std::fs::read(folder.join(format!("{name}.aff"))).ok()?;
        let dic = std::fs::read(folder.join(format!("{name}.dic"))).ok()?;
        let encoding = encoding_of(&aff);
        let aff = decode(&aff, &encoding)?;
        let dic = decode(&dic, &encoding)?;
        let dictionary = spellbook::Dictionary::new(&aff, &dic).ok()?;
        Some(Hunspell {
            language: name.to_string(),
            dictionary,
            stems: stems(&dic),
        })
    }

    pub(super) fn stems(dic: &str) -> Vec<String> {
        let mut stems: Vec<String> = dic
            .lines()
            .skip(1)
            .filter_map(|line| {
                let stem = line.split(['/', '\t', ' ']).next()?;
                (!stem.is_empty()).then(|| stem.to_lowercase())
            })
            .collect();
        stems.sort();
        stems.dedup();
        stems
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn encodings_come_from_the_set_line() {
            assert_eq!(encoding_of(b"# x\nSET ISO8859-1\nTRY a\n"), "ISO8859-1");
            assert_eq!(encoding_of(b"TRY a\n"), "UTF-8");
            assert_eq!(decode(&[0x63, 0xE9], "ISO8859-1").as_deref(), Some("cé"));
            assert_eq!(decode(&[0xE9], "UTF-8"), None);
            assert_eq!(decode(b"x", "KOI8-R"), None);
        }

        #[test]
        fn a_dictionary_answers_the_three_questions() {
            let aff = "SET UTF-8\nSFX S Y 1\nSFX S 0 s .\n";
            let dic = "3\nfollow/S\nworld\ntiming\n";
            let dictionary = spellbook::Dictionary::new(aff, dic).unwrap();
            let backend = Backend {
                loaded: Arc::new(RwLock::new(vec![Hunspell {
                    language: "en_US".into(),
                    dictionary,
                    stems: stems(dic),
                }])),
            };
            assert_eq!(backend.languages(), ["en_US"]);
            assert!(!backend.is_typo("follows"));
            assert!(!backend.is_typo("World"));
            assert!(backend.is_typo("wrld"));
            assert!(backend.is_completable_prefix("follo"));
            assert!(backend.is_completable_prefix("FOLLO"));
            assert!(!backend.is_completable_prefix("wrld"));
            assert!(!backend.is_completable_prefix("timing"));
            assert!(backend.guesses("wrld").iter().any(|g| g == "world"));
        }

        /// How the system's own dictionary behaves, when there is one.
        #[test]
        #[ignore = "needs a system dictionary; prints timings"]
        fn system_dictionary_timing() {
            let started = std::time::Instant::now();
            let found = installed();
            let (name, folder) = found.first().expect("a dictionary");
            let hunspell = load(name, folder).expect("it loads");
            println!(
                "{name}: loaded in {} ms, {} stems",
                started.elapsed().as_millis(),
                hunspell.stems.len()
            );
            let started = std::time::Instant::now();
            let mut known = 0;
            for word in ["follow", "recieve", "the", "wrld", "autocomplete", "thier"] {
                known += usize::from(hunspell.dictionary.check(word));
            }
            println!(
                "six checks in {} µs, {known} known",
                started.elapsed().as_micros()
            );
            for word in ["recieve", "wrld", "thier", "folow"] {
                let started = std::time::Instant::now();
                let mut guesses = Vec::new();
                hunspell.dictionary.suggest(word, &mut guesses);
                println!(
                    "{word}: {guesses:?} in {} ms",
                    started.elapsed().as_millis()
                );
            }
        }

        #[test]
        fn no_dictionary_flags_nothing() {
            let backend = Backend {
                loaded: Arc::default(),
            };
            assert!(!backend.is_typo("wrld"));
            assert!(backend.languages().is_empty());
        }
    }
}

#[cfg(windows)]
mod backend {
    use std::sync::Arc;
    use std::time::Duration;

    use crossbeam_channel::{Sender, bounded, unbounded};
    use parking_lot::RwLock;
    use windows::Win32::Globalization::{
        GetUserDefaultLocaleName, ISpellChecker, ISpellCheckerFactory, SpellCheckerFactory,
    };
    use windows::Win32::System::Com::{
        CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
        CoTaskMemFree, CoUninitialize, IEnumString,
    };
    use windows::core::{HSTRING, PWSTR};

    use super::choose_languages;

    /// A slow answer counts as "not a typo": this runs on the worker.
    const REPLY_TIMEOUT: Duration = Duration::from_millis(150);

    /// Windows brings its own dictionaries.
    pub(super) fn has_dictionaries() -> bool {
        true
    }

    enum Question {
        IsTypo(String, Sender<bool>),
        Guesses(String, Sender<Vec<String>>),
        Completable(String, Sender<bool>),
    }

    /// COM objects stay on one thread behind this handle.
    pub(super) struct Backend {
        questions: Sender<Question>,
        languages: Arc<RwLock<Vec<String>>>,
    }

    impl Backend {
        pub(super) fn start() -> Self {
            let (questions, receiver) = unbounded();
            let languages: Arc<RwLock<Vec<String>>> = Arc::default();
            let published = languages.clone();
            let spawned = std::thread::Builder::new()
                .name("lokalbot-spell".into())
                .spawn(move || {
                    // SAFETY: paired with CoUninitialize at the end of this thread.
                    if unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_err() {
                        return;
                    }
                    if let Some(checkers) = checkers(&published) {
                        while let Ok(question) = receiver.recv() {
                            answer(&checkers, question);
                        }
                    }
                    // SAFETY: matches the CoInitializeEx above.
                    unsafe { CoUninitialize() };
                });
            if let Err(err) = spawned {
                log::warn!("autocomplete: could not start the spell checker: {err}");
            }
            Self {
                questions,
                languages,
            }
        }

        pub(super) fn languages(&self) -> Vec<String> {
            self.languages.read().clone()
        }

        fn ask<T>(&self, question: impl FnOnce(Sender<T>) -> Question) -> Option<T> {
            let (reply, answer) = bounded(1);
            self.questions.send(question(reply)).ok()?;
            answer.recv_timeout(REPLY_TIMEOUT).ok()
        }

        pub(super) fn is_typo(&self, word: &str) -> bool {
            self.ask(|reply| Question::IsTypo(word.to_string(), reply))
                .unwrap_or(false)
        }

        pub(super) fn guesses(&self, word: &str) -> Vec<String> {
            self.ask(|reply| Question::Guesses(word.to_string(), reply))
                .unwrap_or_default()
        }

        pub(super) fn is_completable_prefix(&self, word: &str) -> bool {
            self.ask(|reply| Question::Completable(word.to_string(), reply))
                .unwrap_or(false)
        }
    }

    fn enumerate(strings: &IEnumString) -> Vec<String> {
        let mut out = Vec::new();
        loop {
            let mut item = [PWSTR::null()];
            let mut fetched = 0u32;
            // SAFETY: the buffer holds the one element asked for.
            let result = unsafe { strings.Next(&mut item, Some(&mut fetched)) };
            if result.is_err() || fetched == 0 {
                return out;
            }
            // SAFETY: Next returned a valid string, ours to free.
            unsafe {
                if let Ok(text) = item[0].to_string() {
                    out.push(text);
                }
                CoTaskMemFree(Some(item[0].as_ptr() as *const _));
            }
        }
    }

    fn preferred_language() -> Vec<String> {
        let mut buffer = [0u16; 85];
        // SAFETY: the buffer outlives the call.
        let length = unsafe { GetUserDefaultLocaleName(&mut buffer) };
        if length <= 1 {
            return Vec::new();
        }
        vec![String::from_utf16_lossy(&buffer[..length as usize - 1])]
    }

    fn checkers(languages: &RwLock<Vec<String>>) -> Option<Vec<ISpellChecker>> {
        // SAFETY: COM calls on this thread, which initialized COM.
        unsafe {
            let factory: ISpellCheckerFactory =
                CoCreateInstance(&SpellCheckerFactory, None, CLSCTX_INPROC_SERVER).ok()?;
            let supported = enumerate(&factory.SupportedLanguages().ok()?);
            let chosen = choose_languages(supported, &preferred_language());
            let mut checkers = Vec::new();
            let mut names = Vec::new();
            for language in chosen {
                if let Ok(checker) = factory.CreateSpellChecker(&HSTRING::from(language.as_str())) {
                    checkers.push(checker);
                    names.push(language);
                }
            }
            *languages.write() = names;
            Some(checkers)
        }
    }

    fn flags_whole_word(checker: &ISpellChecker, word: &str) -> bool {
        let length = word.encode_utf16().count() as u32;
        // SAFETY: COM calls on the thread that made the checker.
        unsafe {
            let Ok(errors) = checker.Check(&HSTRING::from(word)) else {
                return false;
            };
            let mut error = None;
            if errors.Next(&mut error).0 != 0 {
                return false;
            }
            error.is_some_and(|error| {
                error.StartIndex().is_ok_and(|start| start == 0)
                    && error.Length().is_ok_and(|len| len == length)
            })
        }
    }

    fn suggestions(checker: &ISpellChecker, word: &str) -> Vec<String> {
        // SAFETY: COM calls on the thread that made the checker.
        unsafe {
            checker
                .Suggest(&HSTRING::from(word))
                .map(|strings| enumerate(&strings))
                .unwrap_or_default()
        }
    }

    fn answer(checkers: &[ISpellChecker], question: Question) {
        match question {
            Question::IsTypo(word, reply) => {
                let typo =
                    !checkers.is_empty() && checkers.iter().all(|c| flags_whole_word(c, &word));
                let _ = reply.send(typo);
            }
            Question::Guesses(word, reply) => {
                let guesses = checkers
                    .iter()
                    .flat_map(|c| suggestions(c, &word))
                    .collect();
                let _ = reply.send(guesses);
            }
            Question::Completable(word, reply) => {
                let lower = word.to_lowercase();
                let live = checkers.iter().any(|c| {
                    suggestions(c, &word).iter().any(|guess| {
                        let guess = guess.to_lowercase();
                        guess.len() > lower.len() && guess.starts_with(&lower)
                    })
                });
                let _ = reply.send(live);
            }
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod backend {
    pub(super) fn has_dictionaries() -> bool {
        false
    }

    pub(super) struct Backend;

    impl Backend {
        pub(super) fn start() -> Self {
            Self
        }

        pub(super) fn languages(&self) -> Vec<String> {
            Vec::new()
        }

        pub(super) fn is_typo(&self, _: &str) -> bool {
            false
        }

        pub(super) fn guesses(&self, _: &str) -> Vec<String> {
            Vec::new()
        }

        pub(super) fn is_completable_prefix(&self, _: &str) -> bool {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn one_dictionary_per_language_with_the_users_first() {
        assert_eq!(
            choose_languages(
                names(&["en_AU", "en_GB", "en_US", "de_DE", "sr-Latn"]),
                &names(&["de_AT"])
            ),
            ["de_DE", "en_US", "sr-Latn"]
        );
        assert_eq!(
            choose_languages(names(&["en_GB", "en_US"]), &names(&["en-GB"])),
            ["en_GB"]
        );
        assert_eq!(
            choose_languages(
                names(&["a_A", "b_B", "c_C", "d_D", "e_E", "f_F"]),
                &names(&["f_F"])
            )
            .len(),
            MAX_LANGUAGES
        );
        assert!(choose_languages(Vec::new(), &names(&["en_US"])).is_empty());
    }

    #[test]
    fn only_a_whole_word_can_be_judged() {
        assert!(is_checkable("wrld"));
        assert!(is_checkable("don't"));
        assert!(is_checkable("don\u{2019}t"));
        assert!(!is_checkable("wrld,"));
        assert!(!is_checkable("foo-bar"));
        assert!(!is_checkable(""));
    }

    #[test]
    fn prefixes_are_found_in_sorted_stems() {
        let stems = names(&["follow", "world"]);
        assert!(is_prefix_of_any(&stems, "foll"));
        assert!(!is_prefix_of_any(&stems, "follow"));
        assert!(!is_prefix_of_any(&stems, "zzz"));
    }
}
