pub fn contains_cjk(text: &str) -> bool {
    text.chars().any(is_cjk)
}

fn is_cjk(c: char) -> bool {
    matches!(
        u32::from(c),
        0x1100..=0x11FF
            | 0x3040..=0x309F
            | 0x30A0..=0x30FF
            | 0x3100..=0x312F
            | 0x3130..=0x318F
            | 0x31A0..=0x31BF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0xFF66..=0xFF9F
            | 0x20000..=0x3134F
    )
}

const SEPARATORS: &str =
    ",;:!?()[]{}<>\"“”‘’「」『』（）《》〈〉【】〔〕［］｛｝，。、；：！？…—～·";

pub fn terms(query: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    query
        .split(|c: char| c.is_whitespace() || SEPARATORS.contains(c))
        .filter(|term| !term.is_empty() && seen.insert(term.to_lowercase()))
        .map(str::to_string)
        .collect()
}

pub fn like_pattern(term: &str) -> String {
    let mut pattern = String::with_capacity(term.len() + 2);
    pattern.push('%');
    for c in term.chars() {
        if matches!(c, '\\' | '%' | '_') {
            pattern.push('\\');
        }
        pattern.push(c);
    }
    pattern.push('%');
    pattern
}

fn folded(text: &str) -> Vec<char> {
    text.chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect()
}

fn match_ranges(text: &[char], terms: &[String]) -> Vec<(usize, usize)> {
    let mut found: Vec<(usize, usize)> = Vec::new();
    for term in terms {
        let needle = folded(term);
        if needle.is_empty() || needle.len() > text.len() {
            continue;
        }
        let mut start = 0;
        while start + needle.len() <= text.len() {
            if text[start..start + needle.len()] == needle[..] {
                found.push((start, start + needle.len()));
                start += needle.len();
            } else {
                start += 1;
            }
        }
    }
    found.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (from, to) in found {
        match merged.last_mut() {
            Some(last) if from <= last.1 => last.1 = last.1.max(to),
            _ => merged.push((from, to)),
        }
    }
    merged
}

pub fn snippet(text: &str, terms: &[String]) -> Option<String> {
    const BEFORE: usize = 18;
    const AFTER: usize = 54;
    let characters: Vec<char> = text.chars().collect();
    let ranges = match_ranges(&folded(text), terms);
    let first = *ranges.first()?;
    let start = first.0.saturating_sub(BEFORE);
    let end = (first.1 + AFTER).min(characters.len());
    let mut excerpt = String::new();
    if start > 0 {
        excerpt.push('…');
    }
    let mut cursor = start;
    for (from, to) in ranges {
        if from < cursor || to > end {
            continue;
        }
        excerpt.extend(&characters[cursor..from]);
        excerpt.push('«');
        excerpt.extend(&characters[from..to]);
        excerpt.push('»');
        cursor = to;
    }
    excerpt.extend(&characters[cursor..end]);
    if end < characters.len() {
        excerpt.push('…');
    }
    Some(excerpt)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_cjk_text_and_splits_terms() {
        assert!(contains_cjk("发布流程"));
        assert!(contains_cjk("logoを大きく"));
        assert!(!contains_cjk("release notes"));
        assert_eq!(terms("单元测试，  打标签 单元测试"), ["单元测试", "打标签"]);
        assert_eq!(like_pattern("50%_a\\"), "%50\\%\\_a\\\\%");
    }

    #[test]
    fn snippets_mark_matches_and_cut_with_ellipses() {
        let text = "发布前先运行全部单元测试，然后打标签。";
        assert_eq!(
            snippet(text, &["单元测试".into()]).as_deref(),
            Some("发布前先运行全部«单元测试»，然后打标签。")
        );
        let long = format!("{}Logo再大一点{}", "前".repeat(30), "后".repeat(80));
        let cut = snippet(&long, &["logo".into()]).unwrap();
        assert!(cut.starts_with('…') && cut.ends_with('…'));
        assert!(cut.contains("«Logo»"));
        assert_eq!(snippet(text, &["没有".into()]), None);
    }
}
