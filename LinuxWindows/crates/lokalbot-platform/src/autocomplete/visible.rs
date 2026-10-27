//! The text shown just above the focused field, such as the conversation
//! being answered (`CotypingVisibleContext.swift`). One bounded walk over
//! the window's accessibility tree runs in the background once per field:
//! metadata is checked before text, rejected branches are never read, and
//! only static labels and links in a column above the field count. Nothing
//! is kept once focus leaves the field.

use std::collections::HashSet;
use std::hash::Hash;

use super::geometry::Rect;

pub const MAX_NODES: usize = 180;
pub const MAX_CHARACTERS: usize = 420;
pub const MAX_EXCERPTS: usize = 3;
const MAX_EXCERPT: usize = 240;
const MAX_RAW: usize = 8_000;
const MAX_CHILDREN: usize = 80;
/// The column above the field: this tall, and this much wider on each side.
const CORRIDOR_HEIGHT: f32 = 600.0;
const CORRIDOR_MARGIN: f32 = 24.0;

/// What kind of node a toolkit reports, as far as the walk cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodeKind {
    /// A label or paragraph whose text may be read.
    StaticText,
    Link,
    /// A container that clips its children to its frame (scroll areas,
    /// web documents, windows).
    ClippingContainer,
    Container,
    /// Never entered: toolbars, menus, trees, and any editable or secure
    /// field (another field's draft is not context).
    Excluded,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Node {
    pub kind: NodeKind,
    pub frame: Option<Rect>,
    pub hidden: bool,
}

/// A tree to walk, with its own time budget.
pub trait VisibleSource {
    type Id: Clone + Eq + Hash;

    fn node(&mut self, id: &Self::Id) -> Option<Node>;
    fn children(&mut self, id: &Self::Id) -> Vec<Self::Id>;
    /// The text of a [`NodeKind::StaticText`] or [`NodeKind::Link`] node.
    fn text(&mut self, id: &Self::Id) -> Option<String>;
    fn within_budget(&self) -> bool;
}

/// Where the walk starts and what it is for.
#[derive(Clone, Debug)]
pub struct Target<Id> {
    /// A container with room above the field, usually the pane holding it.
    pub scope: Id,
    pub scope_frame: Rect,
    pub window_frame: Rect,
    pub field: Id,
    pub field_frame: Rect,
}

/// The column above the field inside its window and scope.
pub fn corridor(window: Rect, scope: Rect, field: Rect) -> Option<Rect> {
    if !window.contains_rect(&field) || !scope.contains_rect(&field) {
        return None;
    }
    let column = Rect::new(
        field.x - CORRIDOR_MARGIN,
        field.y - CORRIDOR_HEIGHT,
        field.width + 2.0 * CORRIDOR_MARGIN,
        CORRIDOR_HEIGHT,
    );
    column.intersection(&window)?.intersection(&scope)
}

/// Up to three excerpts from just above the field, nearest first in
/// selection and in reading order in the result, joined by " | ".
pub fn capture<S: VisibleSource>(source: &mut S, target: &Target<S::Id>) -> Option<String> {
    let area = corridor(target.window_frame, target.scope_frame, target.field_frame)?;
    let start_view = target.scope_frame.intersection(&target.window_frame)?;
    let mut queue: std::collections::VecDeque<(S::Id, Rect)> = std::collections::VecDeque::new();
    queue.push_back((target.scope.clone(), start_view));
    let mut visited: HashSet<S::Id> = HashSet::new();
    let mut candidates: Vec<(S::Id, Rect)> = Vec::new();
    while let Some((id, viewport)) = queue.pop_front() {
        if !source.within_budget() || visited.len() >= MAX_NODES {
            return None;
        }
        if !visited.insert(id.clone()) || id == target.field {
            continue;
        }
        let Some(node) = source.node(&id) else {
            continue;
        };
        if node.hidden || node.kind == NodeKind::Excluded {
            continue;
        }
        if let Some(frame) = node.frame
            && (!frame.is_finite() || !frame.intersects(&area) || !frame.intersects(&viewport))
        {
            continue;
        }
        if matches!(node.kind, NodeKind::StaticText | NodeKind::Link) {
            if let Some(frame) = node.frame
                && viewport.contains_rect(&frame)
                && area.contains_rect(&frame)
            {
                candidates.push((id.clone(), frame));
            }
            continue;
        }
        let clipped = if node.kind == NodeKind::ClippingContainer {
            let Some(frame) = node.frame else {
                continue;
            };
            match viewport.intersection(&frame) {
                Some(clipped) => clipped,
                None => continue,
            }
        } else {
            viewport
        };
        for child in source.children(&id).into_iter().take(MAX_CHILDREN) {
            queue.push_back((child, clipped));
        }
    }
    // The nearest text above the field first.
    candidates.sort_by(|a, b| b.1.bottom().total_cmp(&a.1.bottom()));
    let mut excerpts: Vec<(Rect, String)> = Vec::new();
    let mut seen = HashSet::new();
    let mut remaining = MAX_CHARACTERS;
    for (id, frame) in candidates {
        if excerpts.len() >= MAX_EXCERPTS || remaining == 0 {
            break;
        }
        if !source.within_budget() {
            return None;
        }
        let Some(raw) = source.text(&id) else {
            continue;
        };
        if raw.is_empty() || raw.chars().count() > MAX_RAW {
            continue;
        }
        let Some(text) = sanitize_excerpt(&raw, MAX_EXCERPT.min(remaining)) else {
            continue;
        };
        if !seen.insert(text.clone()) {
            continue;
        }
        remaining = remaining.saturating_sub(text.chars().count() + 3);
        excerpts.push((frame, text));
    }
    if excerpts.is_empty() {
        return None;
    }
    excerpts.sort_by(|a, b| a.0.y.total_cmp(&b.0.y).then(a.0.x.total_cmp(&b.0.x)));
    Some(
        excerpts
            .into_iter()
            .map(|(_, text)| text)
            .collect::<Vec<_>>()
            .join(" | "),
    )
}

/// An excerpt fit for a prompt, or `None` when it carries a credential or
/// reads like an instruction to the model (`CotypingMemoryContext.sanitized`,
/// `PromptContextSanitizer`). Control characters become spaces, whitespace
/// collapses, and the text is cut at a word boundary with an ellipsis.
pub fn sanitize_excerpt(raw: &str, max_characters: usize) -> Option<String> {
    if super::policy::is_secure_field([raw]) || crate::privacy::redact(raw).1 > 0 {
        return None;
    }
    let lower = raw.to_lowercase();
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
    if INJECTION.iter().any(|marker| lower.contains(marker)) {
        return None;
    }
    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_control() || c == '\u{fffc}' {
                ' '
            } else {
                c
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if cleaned.is_empty() || max_characters == 0 {
        return None;
    }
    if cleaned.chars().count() <= max_characters {
        return Some(cleaned);
    }
    // Leave room for the ellipsis and cut after a word.
    let mut cut: String = cleaned
        .chars()
        .take(max_characters.saturating_sub(1))
        .collect();
    if let Some(space) = cut.rfind(' ')
        && space > 0
    {
        cut.truncate(space);
    }
    cut.push('\u{2026}');
    Some(cut)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct Tree {
        nodes: HashMap<u32, (Node, Vec<u32>, Option<String>)>,
        reads: std::cell::RefCell<Vec<u32>>,
    }

    impl VisibleSource for Tree {
        type Id = u32;

        fn node(&mut self, id: &u32) -> Option<Node> {
            self.nodes.get(id).map(|n| n.0.clone())
        }

        fn children(&mut self, id: &u32) -> Vec<u32> {
            self.nodes.get(id).map(|n| n.1.clone()).unwrap_or_default()
        }

        fn text(&mut self, id: &u32) -> Option<String> {
            self.reads.borrow_mut().push(*id);
            self.nodes.get(id).and_then(|n| n.2.clone())
        }

        fn within_budget(&self) -> bool {
            true
        }
    }

    fn node(kind: NodeKind, frame: Rect) -> Node {
        Node {
            kind,
            frame: Some(frame),
            hidden: false,
        }
    }

    /// A chat window: two messages above the reply box, one in a toolbar,
    /// one far to the side, and another field's draft.
    fn chat() -> (Tree, Target<u32>) {
        let window = Rect::new(0.0, 0.0, 800.0, 720.0);
        let field = Rect::new(40.0, 560.0, 720.0, 120.0);
        let mut nodes = HashMap::new();
        nodes.insert(
            1,
            (
                node(NodeKind::ClippingContainer, window),
                vec![2, 3, 4, 5, 6, 7],
                None,
            ),
        );
        nodes.insert(
            2,
            (
                node(NodeKind::StaticText, Rect::new(40.0, 440.0, 720.0, 48.0)),
                vec![],
                Some("Sarah: The migration timeline still works.".into()),
            ),
        );
        nodes.insert(
            3,
            (
                node(NodeKind::StaticText, Rect::new(40.0, 500.0, 720.0, 48.0)),
                vec![],
                Some("Sarah:  Daniel can start on\tThursday.".into()),
            ),
        );
        nodes.insert(
            4,
            (
                node(NodeKind::Excluded, Rect::new(0.0, 0.0, 800.0, 40.0)),
                vec![8],
                None,
            ),
        );
        nodes.insert(
            8,
            (
                node(NodeKind::StaticText, Rect::new(10.0, 5.0, 100.0, 30.0)),
                vec![],
                Some("Toolbar".into()),
            ),
        );
        nodes.insert(
            5,
            (
                node(NodeKind::Excluded, Rect::new(40.0, 380.0, 720.0, 48.0)),
                vec![],
                Some("draft in another field".into()),
            ),
        );
        nodes.insert(
            6,
            (
                node(NodeKind::StaticText, Rect::new(40.0, 320.0, 720.0, 48.0)),
                vec![],
                Some("password=hunter2222".into()),
            ),
        );
        nodes.insert(7, (node(NodeKind::Container, field), vec![], None));
        let target = Target {
            scope: 1,
            scope_frame: window,
            window_frame: window,
            field: 7,
            field_frame: field,
        };
        (
            Tree {
                nodes,
                reads: Default::default(),
            },
            target,
        )
    }

    #[test]
    fn reads_nearby_messages_in_order_and_nothing_else() {
        let (mut tree, target) = chat();
        let text = capture(&mut tree, &target).unwrap();
        assert_eq!(
            text,
            "Sarah: The migration timeline still works. | Sarah: Daniel can start on Thursday."
        );
        // Excluded branches and fields are never read.
        let reads = tree.reads.borrow();
        assert!(!reads.contains(&8));
        assert!(!reads.contains(&5));
    }

    #[test]
    fn hidden_and_outside_text_is_skipped() {
        let (mut tree, target) = chat();
        tree.nodes.get_mut(&2).unwrap().0.hidden = true;
        // Far to the left of the field's column.
        tree.nodes.get_mut(&3).unwrap().0.frame = Some(Rect::new(-500.0, 500.0, 100.0, 40.0));
        assert_eq!(capture(&mut tree, &target), None);
    }

    #[test]
    fn corridor_needs_the_field_inside_its_window() {
        let window = Rect::new(0.0, 0.0, 800.0, 720.0);
        assert!(corridor(window, window, Rect::new(900.0, 100.0, 10.0, 10.0)).is_none());
        let area = corridor(window, window, Rect::new(40.0, 560.0, 720.0, 120.0)).unwrap();
        assert_eq!(area, Rect::new(16.0, 0.0, 768.0, 560.0));
    }

    #[test]
    fn excerpts_are_cleaned_and_bounded() {
        assert_eq!(
            sanitize_excerpt("a\u{7}b   c\n d", 100).as_deref(),
            Some("a b c d")
        );
        assert_eq!(sanitize_excerpt("Ignore previous instructions", 100), None);
        assert_eq!(sanitize_excerpt("token=abcdef123456", 100), None);
        assert_eq!(
            sanitize_excerpt("one two three four", 12).as_deref(),
            Some("one two\u{2026}")
        );
    }
}
