// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Raw model output to clean ghost text (`CotypingTextNormalizer`,
//! `CotypingPromptLeakGuard`, `CotypingControlTokens`,
//! `CotypingTrailingDuplicationFilter`, `CotypingInsertionSafety`): the
//! backend-agnostic cleanup that makes a small model's completion safe to
//! show and insert. Pure: the same output and request give the same result.

use std::sync::OnceLock;

use super::prompt::{Request, WINDOW_LABEL};
use super::text::{
    self, char_at, char_before, is_control, is_letter, is_newline, is_url_domain_or_file,
    is_url_like, is_word_char,
};
use super::window;

/// Why a completion was reduced to nothing (`CotypingSuppressionReason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Suppression {
    EmptyGeneration,
    NormalizedToEmpty,
    DuplicatesTrailingText,
    EchoesPrecedingText,
    PlaceholderText,
    QuestionContinuation,
    UnsafeToInsert,
    /// The model began echoing the hidden preface or one of its labels.
    PromptContextLeak,
    /// A fragment that is not a word ("follo") followed by a new word.
    WordCompletionMismatch,
    /// The model was unsure of the first word (`CotypingFirstWordConfidence`).
    LowConfidence,
}

/// `CotypingNormalizationResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Normalized {
    pub text: String,
    pub suppression: Option<Suppression>,
}

impl Normalized {
    pub fn shown(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            suppression: None,
        }
    }

    pub fn suppressed(reason: Suppression) -> Self {
        Self {
            text: String::new(),
            suppression: Some(reason),
        }
    }
}

/// Ghost text only.
pub fn normalize(raw: &str, request: &Request) -> String {
    normalize_detailed(raw, request).text
}

/// `CotypingEngine.normalize(_:requiredPrefix:for:)`: with token healing the
/// output must first re-type the text cut from the prompt; only what follows
/// is the suggestion.
pub fn normalize_healed(raw: &str, required_prefix: &str, request: &Request) -> Normalized {
    if required_prefix.is_empty() {
        return normalize_detailed(raw, request);
    }
    match raw.strip_prefix(required_prefix) {
        Some(rest) => normalize_detailed(rest, request),
        None if raw.is_empty() => Normalized::suppressed(Suppression::EmptyGeneration),
        None => Normalized::suppressed(Suppression::WordCompletionMismatch),
    }
}

/// The full pipeline, in Cotabby's order: control tokens, think blocks,
/// prompt and prefix echoes, scaffolding labels, line collapse, mid-word
/// rules, trailing duplication, echoed words, spacing, safety.
pub fn normalize_detailed(raw: &str, request: &Request) -> Normalized {
    let raw_had_content = !raw.trim().is_empty();
    let mut normalized = raw.replace('\r', "");

    normalized = sanitize_control_tokens(&normalized);
    normalized = strip_think_blocks(&normalized);

    if !request.prompt.is_empty()
        && let Some(rest) = normalized.strip_prefix(request.prompt.as_str())
    {
        normalized = trim_controls_and_newlines(rest).to_string();
    }
    if !request.prefix.is_empty()
        && let Some(rest) = normalized.strip_prefix(request.prefix.as_str())
    {
        normalized = rest.to_string();
    }

    // The model put a line break between the typed text and its completion.
    // The break goes; one space takes its place further down.
    let began_on_new_line = normalized
        .chars()
        .take_while(|c| c.is_whitespace())
        .any(is_newline);
    normalized = trim_controls_and_newlines(&normalized).to_string();
    normalized = normalized.trim_matches(is_newline).to_string();
    normalized = strip_leading_scaffolding_labels(&normalized);
    normalized = strip_benign_inline_markup(&normalized);
    normalized = normalized.trim_matches(is_newline).to_string();

    // Instruction-tuned models used as raw continuers sometimes restart from
    // the hidden prompt head; compare with the exact rendered preface.
    if detects_prompt_leak(&normalized, request.conditioning_preface.as_deref()) {
        return Normalized::suppressed(Suppression::PromptContextLeak);
    }

    if request.multi_line {
        if let Some(blank) = normalized.find("\n\n") {
            normalized.truncate(blank);
        }
        let trimmed_len = normalized.trim_end().len();
        normalized.truncate(trimmed_len);
    } else if let Some(line_end) = normalized.find('\n') {
        normalized.truncate(line_end);
    }

    // Mid-word: never re-type the fragment the caret sits in, and strictly
    // inside a word never begin with whitespace.
    let partial = window::current_partial_word(&request.prefix);
    let partial_chars = partial.chars().count();
    if partial_chars >= 2
        && normalized.chars().count() > partial_chars
        && let Some(rest) = strip_prefix_ignoring_case(&normalized, partial)
    {
        normalized = rest.to_string();
    }
    if request.force_word_continuation {
        normalized = normalized.trim_start().to_string();
        if !is_plausible_mid_word_continuation(&normalized, &request.after) {
            return Normalized::suppressed(Suppression::UnsafeToInsert);
        }
    }
    // Caret at the end of a fragment that is not a word: a new word after it
    // would leave broken text ("follo" + " up on that").
    if !request.force_word_continuation
        && request.word_prefix.chars().count() >= 2
        && !request.word_prefix_is_valid_word
        && normalized.chars().next().is_some_and(char::is_whitespace)
    {
        return Normalized::suppressed(Suppression::WordCompletionMismatch);
    }

    if !request.force_word_continuation && duplicates_trailing_text(&normalized, &request.after) {
        return Normalized::suppressed(Suppression::DuplicatesTrailingText);
    }

    let before_echo_strip = normalized.clone();
    normalized = strip_echo_prefix(&normalized, &request.prefix);
    let collapsed_by_echo = !before_echo_strip.is_empty() && normalized.is_empty();

    normalized = strip_stylistic_ellipses(&normalized);

    // Spacing, after echo stripping (which can expose a leading space).
    if request.preceding_ends_with_whitespace() {
        normalized = normalized.trim_start().to_string();
    }
    // Without its line break the completion would be glued to the typed
    // text: two words run together, or a comma loses its space.
    let extends_fragment =
        request.word_prefix.chars().count() >= 2 && !request.word_prefix_is_valid_word;
    if began_on_new_line
        && !request.force_word_continuation
        && !extends_fragment
        && !request.preceding_ends_with_whitespace()
        && !request.prefix.is_empty()
        && normalized.chars().next().is_some_and(is_word_char)
    {
        normalized.insert(0, ' ');
    }
    normalized = insert_missing_sentence_boundary_spaces(&normalized);

    if begins_new_question(&normalized, &request.prefix) {
        return Normalized::suppressed(Suppression::QuestionContinuation);
    }
    normalized = conservative_single_line_continuation(&normalized, request);
    if contains_placeholder_text(&normalized) {
        return Normalized::suppressed(Suppression::PlaceholderText);
    }

    if !is_safe_to_insert(&normalized) {
        let reason = if collapsed_by_echo {
            Suppression::EchoesPrecedingText
        } else if !normalized.trim().is_empty() {
            Suppression::UnsafeToInsert
        } else if raw_had_content {
            Suppression::NormalizedToEmpty
        } else {
            Suppression::EmptyGeneration
        };
        return Normalized::suppressed(reason);
    }
    Normalized::shown(normalized)
}

/// `trimmingCharacters(in: .controlCharacters.union(.newlines))`.
fn trim_controls_and_newlines(text: &str) -> &str {
    text.trim_matches(|c: char| is_control(c) || is_newline(c))
}

/// `text` without `prefix`, compared case-insensitively.
fn strip_prefix_ignoring_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let mut rest = text;
    for expected in prefix.chars() {
        let mut chars = rest.chars();
        let actual = chars.next()?;
        if !actual.to_lowercase().eq(expected.to_lowercase()) {
            return None;
        }
        rest = chars.as_str();
    }
    Some(rest)
}

fn conservative_single_line_continuation(text: &str, request: &Request) -> String {
    if request.multi_line {
        return text.to_string();
    }
    let mut working = text;
    if let Some(end) = first_sentence_boundary_before_new_thought(text) {
        working = &text[..end];
    }
    limit_words(working, request.max_words.clamp(1, 30))
}

/// The byte just past the first `.`, `!` or `?` that is followed by
/// whitespace and ends a sentence.
fn first_sentence_boundary_before_new_thought(text: &str) -> Option<usize> {
    for (i, c) in text.char_indices() {
        if !matches!(c, '.' | '!' | '?') {
            continue;
        }
        let next = i + c.len_utf8();
        if !char_at(text, next).is_some_and(char::is_whitespace) {
            continue;
        }
        if c == '.' && is_non_terminal_sentence_period(text, i) {
            continue;
        }
        return Some(next);
    }
    None
}

fn is_non_terminal_sentence_period(text: &str, period: usize) -> bool {
    let Some(before) = char_before(text, period) else {
        return false;
    };
    if before.is_numeric() {
        return true;
    }
    if is_letter(before) {
        let prior_is_letter = char_before(text, period - before.len_utf8()).is_some_and(is_letter);
        if !prior_is_letter {
            return true;
        }
        let word = text::trailing_letters(text, period).to_lowercase();
        if text::ABBREVIATIONS.contains(&word.as_str()) {
            return true;
        }
    }
    false
}

fn is_suggestion_word_char(c: char) -> bool {
    is_word_char(c) || c == '\'' || c == '\u{2019}'
}

fn limit_words(text: &str, max_words: usize) -> String {
    if max_words == 0 {
        return String::new();
    }
    let mut words = 0;
    let mut in_word = false;
    for (i, c) in text.char_indices() {
        let is_word = is_suggestion_word_char(c);
        if is_word && !in_word {
            words += 1;
            if words > max_words {
                return trim_trailing_limit_boundary(&text[..i]);
            }
            in_word = true;
        } else if !is_word {
            in_word = false;
        }
    }
    text.trim_end().to_string()
}

fn trim_trailing_limit_boundary(text: &str) -> String {
    let mut result = text.trim_end();
    while let Some(stripped) = result.strip_suffix('.') {
        result = stripped.trim_end();
    }
    result.to_string()
}

fn is_plausible_mid_word_continuation(text: &str, after: &str) -> bool {
    let trailing = window::leading_word_run(after);
    if trailing.is_empty() {
        return true;
    }
    let candidate = window::leading_word_run(text);
    if candidate.is_empty() {
        return false;
    }
    let candidate = candidate.to_lowercase();
    let trailing = trailing.to_lowercase();
    trailing.starts_with(&candidate) || candidate.starts_with(&trailing)
}

fn strip_stylistic_ellipses(text: &str) -> String {
    let leading = strip_leading_stylistic_ellipsis(text);
    strip_trailing_stylistic_ellipsis(&leading)
}

/// The end of an ellipsis ("…" or three or more dots) starting at `index`.
fn stylistic_ellipsis_end(text: &str, index: usize) -> Option<usize> {
    let c = char_at(text, index)?;
    if c == '…' {
        return Some(index + c.len_utf8());
    }
    if c != '.' {
        return None;
    }
    let dots = text[index..].chars().take_while(|c| *c == '.').count();
    (dots >= 3).then_some(index + dots)
}

fn strip_leading_stylistic_ellipsis(text: &str) -> String {
    let cursor = text.len() - text.trim_start_matches([' ', '\t']).len();
    let Some(end) = stylistic_ellipsis_end(text, cursor) else {
        return text.to_string();
    };
    if !(end == text.len() || char_at(text, end).is_some_and(char::is_whitespace)) {
        return text.to_string();
    }
    let rest_start = if cursor > 0 {
        end + (text[end..].len() - text[end..].trim_start().len())
    } else {
        end
    };
    format!("{}{}", &text[..cursor], &text[rest_start..])
}

fn strip_trailing_stylistic_ellipsis(text: &str) -> String {
    let end = text.trim_end().len();
    if end == 0 {
        return text.to_string();
    }
    let body = &text[..end];
    let start = if body.ends_with('…') {
        end - '…'.len_utf8()
    } else {
        let dots = body.chars().rev().take_while(|c| *c == '.').count();
        if dots < 3 {
            return text.to_string();
        }
        end - dots
    };
    text[..start].trim_end().to_string()
}

fn insert_missing_sentence_boundary_spaces(text: &str) -> String {
    if !text.contains(['.', '!', '?']) {
        return text.to_string();
    }
    let mut repaired = String::with_capacity(text.len() + 4);
    for (i, c) in text.char_indices() {
        repaired.push(c);
        let next = i + c.len_utf8();
        if next < text.len() && should_insert_sentence_space(text, c, i, next) {
            repaired.push(' ');
        }
    }
    repaired
}

fn should_insert_sentence_space(text: &str, c: char, index: usize, next: usize) -> bool {
    let Some(next_char) = char_at(text, next) else {
        return false;
    };
    if next_char.is_whitespace() || !is_word_char(next_char) {
        return false;
    }
    if c == '!' || c == '?' {
        return true;
    }
    if c != '.' {
        return false;
    }
    let Some(previous) = char_before(text, index) else {
        return true;
    };
    if previous.is_numeric() && next_char.is_numeric() {
        return false;
    }
    if previous == '.' || next_char == '.' {
        return false;
    }
    if is_continuing_dotted_initialism(text, index, next) {
        return false;
    }
    !is_url_domain_or_file(token_around(text, index))
}

fn is_continuing_dotted_initialism(text: &str, period: usize, next: usize) -> bool {
    let (Some(before), Some(next_char)) = (char_before(text, period), char_at(text, next)) else {
        return false;
    };
    if !is_letter(before) || !is_letter(next_char) {
        return false;
    }
    let segment = text::trailing_letters(text, period);
    if segment.chars().count() != 1 {
        return false;
    }
    let after_next = next + next_char.len_utf8();
    if char_at(text, after_next) == Some('.') {
        return true;
    }
    next_char.is_uppercase() && dotted_letter_run_precedes(text, period - segment.len())
}

fn dotted_letter_run_precedes(text: &str, index: usize) -> bool {
    let mut saw_dot = false;
    for c in text[..index].chars().rev() {
        if c.is_whitespace() {
            break;
        }
        if c == '.' {
            saw_dot = true;
        } else if !is_letter(c) {
            break;
        }
    }
    saw_dot
}

/// The URL-like token around byte `index` (a period).
fn token_around(text: &str, index: usize) -> &str {
    let start = text[..index]
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_url_like(*c))
        .last()
        .map_or(index, |(i, _)| i);
    let after = index + 1;
    let end = text[after..]
        .char_indices()
        .find(|(_, c)| !is_url_like(*c))
        .map_or(text.len(), |(i, _)| after + i);
    &text[start..end]
}

fn contains_placeholder_text(text: &str) -> bool {
    let trimmed = text.trim();
    !trimmed.is_empty()
        && (contains_delimited_placeholder(trimmed, '[', ']')
            || contains_delimited_placeholder(trimmed, '<', '>'))
}

fn contains_delimited_placeholder(text: &str, open: char, close: char) -> bool {
    let mut rest = text;
    while let Some(open_at) = rest.find(open) {
        let inner = &rest[open_at + open.len_utf8()..];
        let Some(close_at) = inner.find(close) else {
            return false;
        };
        let content = &inner[..close_at];
        if content.chars().count() <= 60 && content.chars().any(is_letter) {
            return true;
        }
        rest = &inner[close_at + close.len_utf8()..];
    }
    false
}

fn strip_benign_inline_markup(text: &str) -> String {
    static MARKUP: OnceLock<regex::Regex> = OnceLock::new();
    let markup = MARKUP.get_or_init(|| {
        regex::Regex::new(r"</?(?:b|br|code|em|i|kbd|samp|span|strong|u|var)(?:\s+[^>]*)?>")
            .expect("markup pattern compiles")
    });
    markup.replace_all(text, "").into_owned()
}

fn begins_new_question(text: &str, prefix: &str) -> bool {
    if prefix.trim().ends_with('?') {
        return false;
    }
    let lowered = text
        .trim()
        .trim_matches(['"', '\'', '“', '”', '‘', '’'])
        .to_lowercase();
    if lowered.is_empty() {
        return false;
    }
    const QUESTION_PREFIXES: [&str; 12] = [
        "what ",
        "why ",
        "how ",
        "when ",
        "where ",
        "who ",
        "would you ",
        "could you ",
        "can you ",
        "do you ",
        "are you ",
        "is there ",
    ];
    QUESTION_PREFIXES.iter().any(|p| lowered.starts_with(p)) && lowered.contains('?')
}

fn strip_think_blocks(text: &str) -> String {
    if !text.contains("<think>") {
        return text.to_string();
    }
    let mut result = text.to_string();
    if let Some(open) = result.find("<think>")
        && let Some(close) = result[open..].find("</think>")
    {
        result.replace_range(open..open + close + "</think>".len(), "");
    }
    if let Some(open) = result.find("<think>") {
        result.truncate(open);
    }
    result
}

/// Leading words that repeat the tail of the text before the caret. Every
/// overlap up to 15 words is tried; the longest wins.
fn strip_echo_prefix(suggestion: &str, preceding: &str) -> String {
    let suggestion_words = word_spans(suggestion);
    if suggestion_words.is_empty() {
        return suggestion.to_string();
    }
    let preceding_words = word_spans(preceding);
    if preceding_words.is_empty() {
        return suggestion.to_string();
    }
    let depth = preceding_words.len().min(15);
    let mut best = 0;
    for overlap in 1..=depth {
        if overlap > suggestion_words.len() {
            continue;
        }
        let tail = &preceding_words[preceding_words.len() - overlap..];
        let head = &suggestion_words[..overlap];
        let matches = tail.iter().zip(head).all(|((ts, te), (hs, he))| {
            preceding[*ts..*te].to_lowercase() == suggestion[*hs..*he].to_lowercase()
        });
        if matches {
            best = overlap;
        }
    }
    if best == 0 {
        return suggestion.to_string();
    }
    if best >= suggestion_words.len() {
        return String::new();
    }
    suggestion[suggestion_words[best - 1].1..].to_string()
}

/// Byte ranges of whitespace-separated words.
fn word_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = None;
    for (i, c) in text.char_indices() {
        if c.is_whitespace() {
            if let Some(s) = start.take() {
                spans.push((s, i));
            }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start {
        spans.push((s, text.len()));
    }
    spans
}

/// Section labels small instruct models parrot.
const SCAFFOLDING_LABELS: [&str; 14] = [
    "Text before the caret:",
    "Text before caret:",
    "Text after the caret:",
    "Text after caret:",
    "User Profile Context:",
    "Your style preferences:",
    "Final instruction:",
    "Screen context:",
    "Screen content:",
    "User's clipboard:",
    "Continuation:",
    "Application:",
    "Task:",
    "App:",
];

fn strip_leading_scaffolding_labels(text: &str) -> String {
    let mut labels = SCAFFOLDING_LABELS;
    labels.sort_by_key(|l| std::cmp::Reverse(l.chars().count()));
    let mut working = text.to_string();
    loop {
        let leading = working.trim_start();
        match labels
            .iter()
            .find_map(|label| strip_prefix_ignoring_case(leading, label))
        {
            Some(rest) => working = rest.to_string(),
            None => return working,
        }
    }
}

// ---------------------------------------------------------------- prompt leaks

/// Renderer labels; a leak is caught only when that kind of line was really
/// in this request's preface.
const RENDERER_MARKER_STEMS: [&str; 14] = [
    "an email being written in",
    "a chat message being typed in",
    "text being typed in",
    "the window is titled",
    "the text field is labeled",
    "written by",
    "writing style",
    "the text is usually written in",
    "notes the writer keeps in mind",
    "relevant saved facts",
    "current visible text above the field",
    "visible in this window",
    "previously accepted completion",
    "on the clipboard",
];

/// Older prompt layouts a learned example or model prior can bring back.
const LEGACY_MARKER_STEMS: [&str; 10] = [
    "text before the caret",
    "text before caret",
    "text after the caret",
    "text after caret",
    "user profile context",
    "your style preferences",
    "final instruction",
    "screen context",
    "screen content",
    "user's clipboard",
];

const SYSTEM_MARKER_STEMS: [&str; 4] = [
    "system prompt",
    "system message",
    "system instruction",
    "hidden prompt",
];

/// `CotypingPromptLeakGuard.detectsLeak`: punctuation-, case- and
/// diacritic-insensitive matching against the exact preface the model saw.
pub fn detects_prompt_leak(candidate: &str, conditioning_preface: Option<&str>) -> bool {
    let candidate = canonicalize(candidate);
    let Some(preface) = conditioning_preface.filter(|p| !p.trim().is_empty()) else {
        return false;
    };
    if candidate.is_empty() {
        return false;
    }
    if matches_protected_text(&candidate, &canonicalize(preface)) {
        return true;
    }
    let lines = protected_preface_lines(preface);
    if lines
        .iter()
        .any(|line| matches_protected_text(&candidate, line))
    {
        return true;
    }
    // A renderer label whose value the model changed or left out, when that
    // label is active in this preface.
    let active = RENDERER_MARKER_STEMS
        .iter()
        .map(|s| canonicalize(s))
        .filter(|marker| {
            lines
                .iter()
                .any(|line| line == marker || line.starts_with(&format!("{marker} ")))
        });
    for marker in active {
        if contains_phrase(&candidate, &marker) || marker.starts_with(&candidate) {
            return true;
        }
    }
    LEGACY_MARKER_STEMS
        .iter()
        .chain(SYSTEM_MARKER_STEMS.iter())
        .any(|stem| contains_phrase(&candidate, &canonicalize(stem)))
}

/// `CotypingPromptLeakGuard.looksLikePromptScaffolding`: the context-free
/// check for learned examples.
pub fn looks_like_prompt_scaffolding(text: &str) -> bool {
    let candidate = canonicalize(text);
    if candidate.is_empty() {
        return false;
    }
    RENDERER_MARKER_STEMS
        .iter()
        .chain(LEGACY_MARKER_STEMS.iter())
        .chain(SYSTEM_MARKER_STEMS.iter())
        .any(|stem| {
            let marker = canonicalize(stem);
            contains_phrase(&candidate, &marker)
                || (candidate.chars().count() >= 8 && marker.starts_with(&candidate))
        })
}

/// Preface lines a suggestion must not repeat. The focused window's own
/// lines are left out: continuing with a name or phrase on screen is what
/// that context is for. Its label stays protected; the block ends at the
/// blank line the renderer puts after it.
fn protected_preface_lines(preface: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut in_window = false;
    for line in preface.split(is_newline) {
        if line == WINDOW_LABEL {
            in_window = true;
        } else if in_window {
            if line.trim().is_empty() {
                in_window = false;
            }
            continue;
        }
        let canonical = canonicalize(line);
        if !canonical.is_empty() {
            lines.push(canonical);
        }
    }
    lines
}

fn matches_protected_text(candidate: &str, protected: &str) -> bool {
    !protected.is_empty()
        && (contains_phrase(candidate, protected) || protected.starts_with(candidate))
}

fn contains_phrase(text: &str, phrase: &str) -> bool {
    !phrase.is_empty()
        && (text == phrase
            || text.starts_with(&format!("{phrase} "))
            || text.ends_with(&format!(" {phrase}"))
            || text.contains(&format!(" {phrase} ")))
}

fn canonicalize(text: &str) -> String {
    text::fold(text)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

// -------------------------------------------------------------- control tokens

/// `CotypingControlTokens.openingMarkers`.
const OPENING_MARKERS: [&str; 9] = [
    "<|im_start|>",
    "<start_of_turn>",
    "<|user|>",
    "<|assistant|>",
    "<|system|>",
    "<|start_header_id|>",
    "<|end_header_id|>",
    "[INST]",
    "[/INST]",
];

/// End-of-turn markers; `</s>` is left out because it also closes HTML `<s>`.
pub const STOP_MARKERS: [&str; 5] = [
    "<|im_end|>",
    "<|endoftext|>",
    "<|end|>",
    "<end_of_turn>",
    "<|eot_id|>",
];

/// Removes chat control tokens a model leaks as text, and everything after
/// an end-of-turn marker.
pub fn sanitize_control_tokens(text: &str) -> String {
    static HEADER: OnceLock<regex::Regex> = OnceLock::new();
    let header = HEADER.get_or_init(|| {
        regex::Regex::new(r"<\|start_header_id\|>.*?<\|end_header_id\|>")
            .expect("header pattern compiles")
    });
    let mut result = header.replace_all(text, "").into_owned();
    for marker in OPENING_MARKERS {
        result = result.replace(marker, "");
    }
    if let Some(cut) = STOP_MARKERS.iter().filter_map(|m| result.find(m)).min() {
        result.truncate(cut);
    }
    result
}

/// `CotypingTrailingDuplicationFilter`: the completion would mostly re-type
/// the text after the caret.
pub fn duplicates_trailing_text(completion: &str, after: &str) -> bool {
    const MINIMUM: usize = 3;
    let fold = |text: &str| -> Vec<char> {
        text.to_lowercase()
            .chars()
            .filter(|c| c.is_alphanumeric() || unicode_normalization::char::is_combining_mark(*c))
            .collect()
    };
    let completion = fold(completion);
    if completion.len() < MINIMUM {
        return false;
    }
    let trailing = fold(after);
    if trailing.is_empty() {
        return false;
    }
    if trailing.starts_with(&completion) {
        return true;
    }
    if completion.starts_with(&trailing) && trailing.len() >= MINIMUM {
        return true;
    }
    let overlap = completion
        .iter()
        .zip(&trailing)
        .take_while(|(a, b)| a == b)
        .count();
    overlap >= MINIMUM.max(completion.len() / 2)
}

/// `CotypingInsertionSafety`: no control characters, no replacement glyph,
/// not only whitespace.
pub fn is_safe_to_insert(completion: &str) -> bool {
    if completion.is_empty() {
        return false;
    }
    let mut saw_visible = false;
    for c in completion.chars() {
        if c == '\u{FFFD}' {
            return false;
        }
        if c != '\n' && ((c as u32) < 0x20 || c == '\u{7F}') {
            return false;
        }
        if !c.is_whitespace() {
            saw_visible = true;
        }
    }
    saw_visible
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::autocomplete::prompt::{self, Context, Sampling};

    fn request(prefix: &str) -> Request {
        request_with(prefix, "", false, 6)
    }

    fn request_with(prefix: &str, after: &str, multi_line: bool, max_words: usize) -> Request {
        Request {
            prompt: prefix.to_string(),
            prefix: prefix.to_string(),
            after: after.to_string(),
            multi_line,
            max_tokens: 24,
            max_words,
            sampling: Sampling::default(),
            force_word_continuation: false,
            word_prefix: String::new(),
            word_prefix_is_valid_word: true,
            conditioning_preface: None,
        }
    }

    fn word_request(prefix: &str, after: &str, word: &str, valid: bool, force: bool) -> Request {
        Request {
            force_word_continuation: force,
            word_prefix: word.to_string(),
            word_prefix_is_valid_word: valid,
            ..request_with(prefix, after, false, 6)
        }
    }

    fn contextual_request() -> Request {
        let lines = vec![
            "An email being written in Mail.".to_string(),
            "The window is titled \"Q3 planning\".".to_string(),
            "The text field is labeled \"Reply\".".to_string(),
        ];
        let examples = vec!["following up with the final numbers".to_string()];
        let rendered = prompt::render(&Context {
            prefix: "Thanks for ",
            surface_lines: &lines,
            user_name: Some("Sam"),
            style_note: Some("concise"),
            language_hint: Some("The text is usually written in German."),
            extended_context: Some("Acme = our product"),
            clipboard: Some("secret release plan"),
            learned_examples: &examples,
            ..Context::default()
        });
        Request {
            prompt: rendered.prompt,
            conditioning_preface: rendered.conditioning_preface,
            max_words: 20,
            ..request("Thanks for ")
        }
    }

    fn detailed(raw: &str, request: &Request) -> Normalized {
        normalize_detailed(raw, request)
    }

    #[test]
    fn a_completion_that_began_on_a_new_line_keeps_one_separating_space() {
        assert_eq!(
            normalize("\n\nI'm working on it", &request("Hi team,")),
            " I'm working on it"
        );
        assert_eq!(
            normalize("\ndelicious", &request("The food was")),
            " delicious"
        );
        assert_eq!(
            normalize("\nI'm working on it", &request("Hi team, ")),
            "I'm working on it"
        );
        assert_eq!(
            normalize(" up on that", &request("I wanted to follow")),
            " up on that"
        );
        assert_eq!(normalize("ing along", &request("We are sing")), "ing along");
    }

    #[test]
    fn collapses_lines_strips_echoes_and_control_tokens() {
        assert_eq!(
            normalize("brown fox\nand more", &request("The quick ")),
            "brown fox"
        );
        assert_eq!(
            normalize("The quick brown fox", &request("The quick ")),
            "brown fox"
        );
        assert_eq!(
            normalize("brown<|im_end|> trailing junk", &request("The quick ")),
            "brown"
        );
        assert_eq!(
            normalize(
                "<think>reasoning here</think>delicious",
                &request("It tastes ")
            ),
            "delicious"
        );
        assert_eq!(normalize("like to eat", &request("i like ")), "to eat");
        assert_eq!(
            normalize("Continuation: hello there", &request("x ")),
            "hello there"
        );
    }

    #[test]
    fn ellipses_are_stylistic_only_at_the_edges() {
        let ascii = detailed("...", &request("I think"));
        assert_eq!(
            ascii,
            Normalized::suppressed(Suppression::NormalizedToEmpty)
        );
        let unicode = detailed("…", &request("I think"));
        assert_eq!(
            unicode,
            Normalized::suppressed(Suppression::NormalizedToEmpty)
        );
        assert_eq!(
            normalize("… probably fine", &request("This is ")),
            "probably fine"
        );
        assert_eq!(
            normalize(" probably fine...", &request("This is")),
            " probably fine"
        );
        assert_eq!(
            normalize("probably fine…", &request("This is ")),
            "probably fine"
        );
        assert_eq!(
            normalize(
                "version 1...5 stays compact",
                &request_with("Use ", "", false, 8)
            ),
            "version 1...5 stays compact"
        );
    }

    #[test]
    fn suppresses_trailing_duplication() {
        let result = detailed(
            "tomorrow",
            &request_with("See you ", "tomorrow at noon", false, 6),
        );
        assert_eq!(
            result,
            Normalized::suppressed(Suppression::DuplicatesTrailingText)
        );
        assert!(duplicates_trailing_text("tomor", "tomorrow"));
        assert!(!duplicates_trailing_text("a", "apple"));
        assert!(duplicates_trailing_text("- world", "world peace"));
        assert!(!duplicates_trailing_text("brand new idea", "old plan"));
    }

    #[test]
    fn suppresses_every_rendered_prompt_context_line() {
        let request = contextual_request();
        for leaked in [
            "An email being written in Mail.",
            "The window is titled \"Q3 planning\".",
            "The text field is labeled \"Reply\".",
            "Written by Sam.",
            "Writing style: concise.",
            "The text is usually written in German.",
            "Notes the writer keeps in mind: Acme = our product",
            "Previously accepted completion: following up with the final numbers",
            "On the clipboard: secret release plan",
            "ON THE CLIPBOARD — secret release plan",
            "An",
            "The window",
            "Previously accepted",
            "On the clip",
            "Continuation: On the clip",
        ] {
            assert_eq!(
                detailed(leaked, &request),
                Normalized::suppressed(Suppression::PromptContextLeak),
                "{leaked}"
            );
        }
    }

    #[test]
    fn allows_context_informed_continuations_and_strips_a_whole_prompt_echo() {
        let request = contextual_request();
        assert_eq!(
            detailed("the release plan tomorrow", &request),
            Normalized::shown("the release plan tomorrow")
        );
        let echoed = format!("{} the release plan tomorrow", request.prompt);
        assert_eq!(
            detailed(&echoed, &request),
            Normalized::shown("the release plan tomorrow")
        );
    }

    #[test]
    fn strips_benign_inline_markup() {
        assert_eq!(
            normalize(
                "that you can't use the same <code>.env</code> file for both development and production",
                &request("The main tradeoff is ")
            ),
            "that you can't use the same"
        );
    }

    #[test]
    fn whitespace_only_is_an_empty_generation() {
        assert_eq!(
            detailed("   \n  ", &request("Hello ")),
            Normalized::suppressed(Suppression::EmptyGeneration)
        );
    }

    #[test]
    fn multi_line_keeps_lines_until_a_blank_one() {
        assert_eq!(
            normalize(" world", &request_with("Hello", "", true, 6)),
            " world"
        );
        assert_eq!(
            normalize(" world\nnext line ", &request_with("hello", "", true, 6)),
            " world\nnext line"
        );
        assert_eq!(
            normalize(" world", &request_with("Hello ", "", true, 6)),
            "world"
        );
        assert_eq!(
            normalize(
                "line one\nline two\n\nignored",
                &request_with("Start ", "", true, 6)
            ),
            "line one\nline two"
        );
    }

    #[test]
    fn suppresses_placeholders_and_new_questions() {
        assert_eq!(
            detailed(
                "up on [the project/your email]",
                &request("I wanted to follow ")
            ),
            Normalized::suppressed(Suppression::PlaceholderText)
        );
        assert_eq!(
            detailed("up on [пројекат]", &request("I wanted to follow ")),
            Normalized::suppressed(Suppression::PlaceholderText)
        );
        assert_eq!(
            detailed(
                "What would you like me to do next?",
                &request("I can take ")
            ),
            Normalized::suppressed(Suppression::QuestionContinuation)
        );
        assert_eq!(
            normalize("how to fix it", &request("I'll show you ")),
            "how to fix it"
        );
    }

    #[test]
    fn single_line_stops_at_the_sentence_and_the_word_limit() {
        assert_eq!(
            normalize(
                "care of that. What would you like me to do next?",
                &request("I can take ")
            ),
            "care of that."
        );
        assert_eq!(
            normalize(
                "care of that.Next step is review",
                &request_with("I can take ", "", false, 8)
            ),
            "care of that."
        );
        assert_eq!(
            normalize("done.Next", &request_with("Status: ", "", false, 8)),
            "done."
        );
        assert_eq!(
            normalize("version 1.2 ships", &request_with("Use ", "", false, 8)),
            "version 1.2 ships"
        );
        assert_eq!(
            normalize("example.com works", &request_with("Open ", "", false, 8)),
            "example.com works"
        );
        assert_eq!(
            normalize("e.g.this case", &request_with("For example ", "", false, 8)),
            "e.g. this case"
        );
        assert_eq!(
            normalize(
                "one two three four five six seven eight",
                &request("Let's ")
            ),
            "one two three four five six"
        );
        assert_eq!(
            normalize(
                "one two three four five six seven eight",
                &request_with("Let's ", "", false, 8)
            ),
            "one two three four five six seven eight"
        );
    }

    #[test]
    fn word_fragments_must_be_extended() {
        let follo = word_request("I wanted to follo", "", "follo", false, false);
        assert_eq!(
            detailed(" up on that", &follo),
            Normalized::suppressed(Suppression::WordCompletionMismatch)
        );
        assert_eq!(
            detailed("w up on that", &follo),
            Normalized::shown("w up on that")
        );
        let the = word_request("I will attend the", "", "the", true, false);
        assert_eq!(detailed(" meeting", &the), Normalized::shown(" meeting"));
        let boundary = word_request("I wanted to ", "", "", false, false);
        assert_eq!(
            detailed(" up on that", &boundary),
            Normalized::shown("up on that")
        );
        let forced = word_request("rec", "ord", "rec", false, true);
        assert_eq!(detailed(" ord", &forced), Normalized::shown("ord"));
    }

    #[test]
    fn mid_word_rules() {
        let rec = request("I want to rec");
        assert_eq!(normalize("receive the package", &rec), "eive the package");
        assert_eq!(normalize("eive the package", &rec), "eive the package");
        let forced = Request {
            force_word_continuation: true,
            ..request_with("Please rec", "eive the files when ready.", false, 6)
        };
        assert_eq!(
            detailed("ode the following code in C++:", &forced),
            Normalized::suppressed(Suppression::UnsafeToInsert)
        );
        assert_eq!(normalize(" document", &request("rec")), " document");
        assert_eq!(normalize("am late", &request("I a")), "am late");
    }

    #[test]
    fn healed_output_must_retype_the_cut_text() {
        let request = request("Let's celebrate ");
        assert_eq!(
            normalize_healed(" this weekend", " ", &request),
            Normalized::shown("this weekend")
        );
        assert_eq!(
            normalize_healed("d it", " ", &request),
            Normalized::suppressed(Suppression::WordCompletionMismatch)
        );
        assert_eq!(
            normalize_healed("", " ", &request),
            Normalized::suppressed(Suppression::EmptyGeneration)
        );
        let follo = word_request("I wanted to follo", "", "follo", true, false);
        assert!(
            normalize_healed(" following up", " follo", &follo)
                .text
                .starts_with("wing")
        );
    }

    #[test]
    fn scaffolding_check_for_learned_examples() {
        assert!(looks_like_prompt_scaffolding(
            "Previously accepted completion: x"
        ));
        assert!(looks_like_prompt_scaffolding("system prompt"));
        assert!(!looks_like_prompt_scaffolding("the"));
        assert!(!looks_like_prompt_scaffolding(
            "following up with the numbers"
        ));
    }

    #[test]
    fn insertion_safety() {
        assert!(is_safe_to_insert(" ok"));
        assert!(is_safe_to_insert("line\nnext"));
        assert!(!is_safe_to_insert(""));
        assert!(!is_safe_to_insert("   "));
        assert!(!is_safe_to_insert("bad\u{7}"));
        assert!(!is_safe_to_insert("\u{FFFD}"));
    }
}
