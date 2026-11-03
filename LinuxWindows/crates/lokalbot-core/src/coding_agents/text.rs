//! The parts of `CodingAgentText.swift` that judge a title: is it a name for
//! work, or something said to an agent?

use std::sync::LazyLock;

use regex::Regex;

static CONVERSATIONAL_OPENING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(concat!(
        r"(?i)^((can|could|would|will) (you|we)|(should|shall) we|we (should|need|must|have to)|",
        r"i('d| would)? (want|need|like)|let['’]?s|let us|help me|please|pls|hey|hi|hello|",
        r"yes|no|ok|okay|thanks|try again|go ahead|how|why|what|which|where|when|who|",
        r"(is|are|do|does|did) (there|it|we|you|this|that))\b",
    ))
    .expect("valid regex")
});

static POLITE_OPENING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(concat!(
        r"(?i)^((can|could|would|will) you|please|pls|let['’]?s|let us|we should|we need to|",
        r"i('d like| want| need) you to|go ahead and|ok(ay)?|so|now|and)\b[,:]?\s*",
    ))
    .expect("valid regex")
});

/// Text said to an agent rather than a name for work: a question, a truncated
/// or harness-tagged request, a link, or a conversational opening such as
/// "can you" or "we should".
pub fn reads_as_request(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.is_empty()
        || trimmed.starts_with('<')
        || trimmed.ends_with('?')
        || trimmed.ends_with('…')
        || trimmed.contains("://")
        || CONVERSATIONAL_OPENING.is_match(trimmed)
}

/// A request that is a short instruction, as a work title: "Review all open
/// PRs" as is, "let's commit the benchmark." as "Commit the benchmark". `None`
/// for anything else, such as a question, a long or truncated request, a
/// terminal command, or pasted text.
pub fn instruction(request: &str) -> Option<String> {
    let mut clean = request.trim().to_string();
    if clean.starts_with('/')
        || clean.starts_with("Ran in terminal:")
        || clean.contains("[pasted text]")
    {
        return None;
    }
    while let Some(opening) = POLITE_OPENING.find(&clean) {
        clean.replace_range(opening.range(), "");
    }
    while clean.ends_with(['.', '!']) {
        clean.pop();
    }
    let words = clean.split_whitespace().count();
    if !(2..=10).contains(&words) || reads_as_request(&clean) {
        return None;
    }
    let mut chars = clean.chars();
    let first = chars.next()?;
    // "iOS …" keeps its case.
    let second_is_upper = chars.clone().next().is_some_and(char::is_uppercase);
    Some(if first.is_lowercase() && !second_is_upper {
        first.to_uppercase().chain(chars).collect()
    } else {
        clean
    })
}
