// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! The completion prompt (`CotypingPromptRenderer`) and the request built
//! around it (`CotypingRequestBuilder`).
//!
//! The model is a pure text continuer, not an instruction follower, for
//! every model in the catalog: there is no chat template and no control
//! token besides the BOS llama-server adds. Persona, style and context go
//! into a short conditioning preface, and the text before the caret is the
//! last thing in the prompt, its whitespace intact.

use lokalbot_core::Settings;

use super::{surface, window};
use crate::sanitize;

/// `CotypingConfiguration.standard`: low temperature for stable inline
/// completions; the fixed seed keeps identical context reproducible.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sampling {
    pub temperature: f64,
    pub top_p: f64,
    pub top_k: u32,
    pub min_p: f64,
    pub repeat_penalty: f64,
    pub repeat_last_n: u32,
    pub seed: u32,
}

impl Default for Sampling {
    fn default() -> Self {
        Self {
            temperature: 0.1,
            top_p: 0.7,
            top_k: 20,
            min_p: 0.08,
            repeat_penalty: 1.05,
            repeat_last_n: 64,
            // 0x00C0FFEE, Cotabby's "coffee" seed.
            seed: 0x00C0_FFEE,
        }
    }
}

pub const MAX_PREFIX_CHARACTERS: usize = 2_500;
pub const MAX_PREFIX_WORDS: usize = 500;

/// `AppSettings.cotypingMaxResponseTokens`: ceil(words × 1.3), at least 5,
/// doubled for multi-line, at most 120.
pub fn max_response_tokens(max_words: u32, multi_line: bool) -> usize {
    let language_aware = (max_words as usize * 13).div_ceil(10);
    let base = language_aware.max(5);
    if multi_line {
        (base * 2).min(120)
    } else {
        base.min(120)
    }
}

/// `CotypingPersonalization`: the optional voice cues from Settings → Writing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Personalization {
    pub user_name: Option<String>,
    pub style_note: Option<String>,
    /// "The text is usually written in …" (macOS `cotypingLanguages`).
    pub language_hint: Option<String>,
    /// Glossary and notes (macOS `cotypingExtendedContext`).
    pub extended_context: Option<String>,
    pub multi_line: bool,
    /// Condition on the app and window title. On by default on macOS.
    pub app_context: bool,
}

impl Personalization {
    /// From the Writing settings this port has; the others keep their macOS
    /// defaults (app context on, no language hint or notes).
    pub fn from_settings(settings: &Settings) -> Self {
        Self {
            user_name: non_empty(&settings.cotyping_user_name),
            style_note: non_empty(&settings.cotyping_style_note),
            language_hint: None,
            extended_context: None,
            multi_line: settings.cotyping_multi_line,
            app_context: true,
        }
    }
}

/// The focused field a request is built from (`CotypingField`), as the
/// desktop integration read it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Field {
    pub app_name: String,
    pub app_id: String,
    pub window_title: String,
    pub before: String,
    pub after: String,
    /// Text visible above the field: the conversation being answered.
    pub visible_text: Option<String>,
    pub single_line: bool,
}

/// One generation (`CotypingRequest`): what the model is asked and what the
/// normalizer needs to clean its answer.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    /// Conditioning preface plus the caret prefix.
    pub prompt: String,
    /// The windowed text before the caret, alone.
    pub prefix: String,
    /// Text after the caret.
    pub after: String,
    pub multi_line: bool,
    pub max_tokens: usize,
    /// The word ceiling the normalizer enforces after the model.
    pub max_words: usize,
    pub sampling: Sampling,
    /// The caret is strictly inside a word: the suggestion must continue it.
    pub force_word_continuation: bool,
    /// The word characters right before the caret ("" at a word boundary).
    pub word_prefix: String,
    /// Whether `word_prefix` is a whole word ("the") rather than a fragment
    /// ("follo"). Without a spell checker this stays true, as on macOS for a
    /// language it has no dictionary for.
    pub word_prefix_is_valid_word: bool,
    /// The exact hidden preface in `prompt`, so an echo of it is suppressed.
    pub conditioning_preface: Option<String>,
}

impl Request {
    /// The caret prefix ends on whitespace, so a leading space in the answer
    /// is dropped.
    pub fn preceding_ends_with_whitespace(&self) -> bool {
        self.prefix
            .chars()
            .next_back()
            .is_some_and(char::is_whitespace)
    }
}

/// Context besides the field itself.
#[derive(Clone, Debug, Default)]
pub struct Extras {
    /// Relevant saved facts (`CotypingMemoryContext`).
    pub memory: Option<String>,
    /// Earlier accepted completions in the same document.
    pub learned_examples: Vec<String>,
    pub word_prefix_is_valid_word: bool,
    /// Build a request for a blank field too, to prefill its prompt.
    pub allows_blank_prefix: bool,
}

/// `CotypingRequestBuilder.build`. `None` when there is nothing before the
/// caret to continue.
pub fn build_request(
    field: &Field,
    max_words: u32,
    personalization: &Personalization,
    extras: &Extras,
) -> Option<Request> {
    if !extras.allows_blank_prefix && !window::should_generate(&field.before) {
        return None;
    }
    let prefix = window::truncated_prefix(&field.before, MAX_PREFIX_CHARACTERS, MAX_PREFIX_WORDS);
    let surface_lines = if personalization.app_context {
        surface::compose(&field.app_name, &field.app_id, &field.window_title)
            .map(|s| surface::preface_lines(&s))
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let nearby = field.visible_text.as_deref().and_then(nearby_text);
    let rendered = render(&Context {
        prefix: &prefix,
        surface_lines: &surface_lines,
        user_name: personalization.user_name.as_deref(),
        style_note: personalization.style_note.as_deref(),
        language_hint: personalization.language_hint.as_deref(),
        extended_context: personalization.extended_context.as_deref(),
        memory: extras.memory.as_deref(),
        visible: nearby.as_deref(),
        learned_examples: &extras.learned_examples,
        ..Context::default()
    });
    let multi_line = personalization.multi_line && !field.single_line;
    Some(Request {
        prompt: rendered.prompt,
        word_prefix: window::current_partial_word(&prefix).to_string(),
        prefix,
        after: field.after.clone(),
        multi_line,
        max_tokens: max_response_tokens(max_words, multi_line),
        max_words: max_words.max(1) as usize,
        sampling: Sampling::default(),
        force_word_continuation: window::should_force_continuation(&field.before, &field.after),
        word_prefix_is_valid_word: extras.word_prefix_is_valid_word,
        conditioning_preface: rendered.conditioning_preface,
    })
}

/// The prompt and its exact hidden preface.
#[derive(Clone, Debug, PartialEq)]
pub struct Rendered {
    pub prompt: String,
    pub conditioning_preface: Option<String>,
}

/// What [`render`] folds into the preface; every part is optional.
#[derive(Clone, Copy, Debug, Default)]
pub struct Context<'a> {
    pub prefix: &'a str,
    pub surface_lines: &'a [String],
    pub user_name: Option<&'a str>,
    pub style_note: Option<&'a str>,
    pub language_hint: Option<&'a str>,
    pub extended_context: Option<&'a str>,
    pub clipboard: Option<&'a str>,
    pub memory: Option<&'a str>,
    pub visible: Option<&'a str>,
    pub window: Option<&'a str>,
    pub learned_examples: &'a [String],
}

/// Upper bound on the preface so a long style note never crowds the prompt.
pub const MAX_PREFACE_CHARACTERS: usize = 900;
const MAX_CLIPBOARD_LINE_CHARACTERS: usize = 180;
const MAX_LEARNED_EXAMPLE_CHARACTERS: usize = 120;
/// Heads the focused window's text, one screen line per line.
pub const WINDOW_LABEL: &str = "Visible in this window:";
/// `CotypingWindowText.maximumCharacters`.
const MAX_WINDOW_CHARACTERS: usize = 2_000;

/// `CotypingPromptRenderer.render`.
pub fn render(context: &Context) -> Rendered {
    let prefix = context.prefix;
    // Window text has its own budget and comes first: it changes least
    // while typing, and the server keeps what it read of an unchanged start.
    let window = trimmed(context.window).map(|text| {
        format!(
            "{WINDOW_LABEL}\n{}",
            sanitize::sanitize(text, Some(MAX_WINDOW_CHARACTERS))
        )
    });
    let mut preface: Vec<String> = Vec::new();
    let memory_budget;
    if window.is_some() {
        preface.extend(context.surface_lines.iter().cloned());
        memory_budget = 180;
    } else if let Some(visible) = trimmed(context.visible) {
        preface.push(format!(
            "Current visible text above the field: {}",
            sanitize::sanitize(visible, Some(420))
        ));
        preface.extend(context.surface_lines.iter().cloned());
        memory_budget = 180;
    } else {
        preface.extend(context.surface_lines.iter().cloned());
        memory_budget = 360;
    }
    if let Some(memory) = trimmed(context.memory) {
        preface.push(format!(
            "Relevant saved facts: {}",
            sanitize::sanitize(memory, Some(memory_budget))
        ));
    }
    if let Some(name) = trimmed(context.user_name) {
        preface.push(format!("Written by {name}."));
    }
    if let Some(note) = trimmed(context.style_note) {
        preface.push(format!("Writing style: {note}."));
    }
    if let Some(language) = trimmed(context.language_hint) {
        preface.push(language.to_string());
    }
    if let Some(notes) = trimmed(context.extended_context) {
        preface.push(format!(
            "Notes the writer keeps in mind: {}",
            sanitize::prefix(notes, 300)
        ));
    }
    for example in context.learned_examples {
        if let Some(example) = trimmed(Some(example)) {
            preface.push(format!(
                "Previously accepted completion: {}",
                sanitize::prefix(example, MAX_LEARNED_EXAMPLE_CHARACTERS)
            ));
        }
    }
    if let Some(clip) = trimmed(context.clipboard) {
        preface.push(format!(
            "On the clipboard: {}",
            sanitize::prefix(clip, MAX_CLIPBOARD_LINE_CHARACTERS)
        ));
    }
    if window.is_none() && preface.is_empty() {
        // Nothing to condition on: the model gets the bare text.
        return Rendered {
            prompt: prefix.to_string(),
            conditioning_preface: None,
        };
    }
    let mut preface_text = preface.join("\n");
    if preface_text.chars().count() > MAX_PREFACE_CHARACTERS {
        preface_text = sanitize::prefix(&preface_text, MAX_PREFACE_CHARACTERS);
    }
    if let Some(window) = window {
        preface_text = if preface_text.is_empty() {
            window
        } else {
            format!("{window}\n\n{preface_text}")
        };
    }
    // A blank line separates the preface from the live text, with no label
    // the model could echo. The prefix stays the final bytes.
    Rendered {
        prompt: format!("{preface_text}\n\n{prefix}"),
        conditioning_preface: Some(preface_text),
    }
}

fn trimmed(text: Option<&str>) -> Option<&str> {
    text.map(str::trim).filter(|t| !t.is_empty())
}

fn non_empty(text: &str) -> Option<String> {
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// `CotypingVisibleContext`: at most three excerpts within 420 characters,
/// nearest the field first, kept in reading order and joined with " | ".
/// Lines that look like credentials or prompt instructions are left out.
pub fn nearby_text(visible: &str) -> Option<String> {
    const MAX_CHARACTERS: usize = 420;
    const MAX_EXCERPTS: usize = 3;
    let mut excerpts: Vec<String> = Vec::new();
    let mut remaining = MAX_CHARACTERS as isize;
    for line in visible.lines().rev() {
        if excerpts.len() >= MAX_EXCERPTS || remaining <= 0 {
            break;
        }
        if line.trim().is_empty() || line.chars().count() > 8_000 || is_sensitive(line) {
            continue;
        }
        // A line without a letter or digit (a rule, an emoji reaction) adds
        // nothing (`CotypingWindowText.cleaned`).
        let Some(cleaned) =
            sanitized_context(line).filter(|t| t.chars().any(char::is_alphanumeric))
        else {
            continue;
        };
        let budget = (remaining as usize).min(240);
        let text = sanitize::sanitize(&cleaned, Some(budget));
        if text.is_empty() || excerpts.contains(&text) {
            continue;
        }
        remaining -= text.chars().count() as isize + 3;
        excerpts.push(text);
    }
    excerpts.reverse();
    (!excerpts.is_empty()).then(|| excerpts.join(" | "))
}

/// `CotypingSecureFieldDetector.sensitiveMarkers`.
const SENSITIVE_MARKERS: [&str; 13] = [
    "secure",
    "password",
    "passcode",
    "passphrase",
    "cvv",
    "cvc",
    "security code",
    "verification code",
    "one-time code",
    "one time code",
    "social security",
    "card number",
    "credit card",
];

pub(crate) fn is_sensitive(text: &str) -> bool {
    let lower = text.to_lowercase();
    SENSITIVE_MARKERS.iter().any(|m| lower.contains(m))
}

/// `CotypingMemoryContext.sanitized`: no secrets, no prompt-injection
/// phrasing, whitespace collapsed. `None` when nothing safe is left.
pub fn sanitized_context(text: &str) -> Option<String> {
    if text.is_empty() || sanitize::redaction(text).1 > 0 {
        return None;
    }
    let lower = text.to_lowercase();
    const INJECTION: [&str; 10] = [
        "<|",
        "[inst]",
        "[system]",
        "ignore previous",
        "ignore all previous",
        "system prompt",
        "assistant:",
        "system:",
        "developer:",
        "previously accepted completion:",
    ];
    if INJECTION.iter().any(|m| lower.contains(m)) {
        return None;
    }
    let cleaned = sanitize::collapse(&sanitize::sanitize(text, None));
    (!cleaned.is_empty()).then_some(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bare(prefix: &str) -> Context<'_> {
        Context {
            prefix,
            ..Context::default()
        }
    }

    #[test]
    fn bare_prefix_when_there_is_no_preface() {
        let rendered = render(&bare("Hello wo"));
        assert_eq!(rendered.prompt, "Hello wo");
        assert_eq!(rendered.conditioning_preface, None);
        assert_eq!(render(&bare("Hello wo  \n\t")).prompt, "Hello wo  \n\t");
    }

    #[test]
    fn persona_style_and_language_come_in_order() {
        let persona = render(&Context {
            user_name: Some("Jacob"),
            ..bare("x")
        });
        assert_eq!(persona.prompt, "Written by Jacob.\n\nx");
        let full = render(&Context {
            user_name: Some("Ada"),
            style_note: Some("concise"),
            language_hint: Some("Writes in German."),
            ..bare("the caret text")
        });
        assert_eq!(
            full.prompt,
            "Written by Ada.\nWriting style: concise.\nWrites in German.\n\nthe caret text"
        );
        assert_eq!(
            render(&Context {
                user_name: Some("   "),
                ..bare("x")
            })
            .prompt,
            "x"
        );
    }

    #[test]
    fn render_exposes_the_exact_hidden_preface() {
        let lines = vec!["An email being written in Mail.".to_string()];
        let rendered = render(&Context {
            surface_lines: &lines,
            user_name: Some("Ada"),
            clipboard: Some("release plan"),
            ..bare("the caret text")
        });
        let preface = rendered.conditioning_preface.clone().unwrap();
        assert_eq!(
            preface,
            "An email being written in Mail.\nWritten by Ada.\nOn the clipboard: release plan"
        );
        assert_eq!(rendered.prompt, preface + "\n\nthe caret text");
    }

    #[test]
    fn learned_examples_language_and_notes_enter_the_preface() {
        let examples: Vec<String> = (1..=5).map(|i| format!("example {i}")).collect();
        let prompt = render(&Context {
            learned_examples: &examples,
            ..bare("Thanks")
        })
        .prompt;
        for example in &examples {
            assert!(prompt.contains(&format!("Previously accepted completion: {example}")));
        }
        let prompt = render(&Context {
            language_hint: Some("The text is usually written in German."),
            extended_context: Some("Acme = our product"),
            ..bare("Dear team")
        })
        .prompt;
        assert!(prompt.contains("The text is usually written in German."));
        assert!(prompt.contains("Notes the writer keeps in mind: Acme = our product"));
        assert!(prompt.ends_with("Dear team"));
    }

    #[test]
    fn visible_text_comes_first_with_its_own_budget() {
        let lines = vec!["Topic: Q3 planning".to_string()];
        let rendered = render(&Context {
            surface_lines: &lines,
            visible: Some("Ana: Can you send the deck?"),
            memory: Some("Deck owner: Ana"),
            ..bare("Sure, ")
        });
        assert_eq!(
            rendered.prompt,
            "Current visible text above the field: Ana: Can you send the deck?\nTopic: Q3 planning\nRelevant saved facts: Deck owner: Ana\n\nSure, "
        );
        let window = render(&Context {
            window: Some("line one\nline two"),
            user_name: Some("Ada"),
            ..bare("x")
        });
        assert_eq!(
            window.prompt,
            "Visible in this window:\nline one\nline two\n\nWritten by Ada.\n\nx"
        );
    }

    fn field(before: &str) -> Field {
        Field {
            app_name: "Notes".into(),
            app_id: "notes".into(),
            before: before.into(),
            ..Field::default()
        }
    }

    #[test]
    fn builds_requests_from_the_field() {
        let personalization = Personalization::default();
        let extras = Extras {
            word_prefix_is_valid_word: true,
            ..Extras::default()
        };
        assert!(build_request(&field("   "), 4, &personalization, &extras).is_none());
        let request = build_request(&field("Hello there"), 12, &personalization, &extras).unwrap();
        assert_eq!(request.prefix, "Hello there");
        assert_eq!(request.prompt, "Hello there");
        assert_eq!(request.max_words, 12);
        assert_eq!(request.max_tokens, 16);
        assert!(!request.multi_line);
        assert_eq!(request.conditioning_preface, None);
        let mid = build_request(&field("I want to rec"), 4, &personalization, &extras).unwrap();
        assert_eq!(mid.word_prefix, "rec");
        let boundary = build_request(&field("I want to "), 4, &personalization, &extras).unwrap();
        assert_eq!(boundary.word_prefix, "");
        assert!(boundary.prompt.ends_with("I want to "));
    }

    #[test]
    fn personalization_and_surface_enter_the_prompt() {
        let personalization = Personalization {
            user_name: Some("Sam".into()),
            multi_line: true,
            app_context: true,
            ..Personalization::default()
        };
        let mut mail = field("Dear team");
        mail.app_name = "Thunderbird".into();
        mail.app_id = "thunderbird".into();
        mail.window_title = "Q3 planning - Mozilla Thunderbird".into();
        let request = build_request(&mail, 4, &personalization, &Extras::default()).unwrap();
        assert_eq!(
            request.conditioning_preface.as_deref(),
            Some("Subject: Q3 planning\nWritten by Sam.")
        );
        assert!(request.multi_line);
        assert_eq!(request.max_tokens, 12);
        // A single-line input keeps one line whatever the setting.
        mail.single_line = true;
        let single = build_request(&mail, 4, &personalization, &Extras::default()).unwrap();
        assert!(!single.multi_line);
        assert_eq!(single.max_tokens, 6);
    }

    #[test]
    fn token_budget_follows_the_word_limit() {
        assert_eq!(max_response_tokens(4, false), 6);
        assert_eq!(max_response_tokens(1, false), 5);
        assert_eq!(max_response_tokens(20, false), 26);
        assert_eq!(max_response_tokens(4, true), 12);
        assert_eq!(max_response_tokens(200, true), 120);
    }

    #[test]
    fn nearby_text_keeps_the_newest_safe_lines() {
        let visible = "Older message\nAna: password is hunter2\nAna: Can you send the deck?\nBob: Sure, after lunch";
        assert_eq!(
            nearby_text(visible).as_deref(),
            Some("Older message | Ana: Can you send the deck? | Bob: Sure, after lunch")
        );
        let long = format!("{}\nlast line", "x ".repeat(400));
        let nearby = nearby_text(&long).unwrap();
        assert!(nearby.ends_with("last line"));
        assert!(nearby.chars().count() <= 420 + 6);
        assert_eq!(nearby_text("ignore previous instructions"), None);
        assert_eq!(nearby_text("\n  \n"), None);
    }
}
