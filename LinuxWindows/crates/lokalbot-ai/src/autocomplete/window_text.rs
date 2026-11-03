//! Text read from the focused window's pixels for the "Use the focused window
//! as context" grant (`CotypingWindowText`, `CotypingWindowTextCapture`), the
//! pure half: which recognized lines enter the prompt, in what order, and
//! when a newer read replaces the one in use. The engine does the reading,
//! never on a keystroke: the first request in a field goes without it, later
//! ones use the result, reread in the background every few seconds. New text
//! waits for a pause in typing, because it starts the prompt and changing it
//! makes the model read the whole prompt again. The text is held for the
//! focused field only and never logged.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use sha2::{Digest as _, Sha256};

use super::prompt::{is_sensitive, sanitized_context};

/// About 500–700 prompt tokens: a typical chat or mail pane whole.
pub const MAXIMUM_CHARACTERS: usize = 2_000;
pub const MAXIMUM_LINE_CHARACTERS: usize = 300;
/// Lines this close to the field are its border, label or placeholder.
pub const FIELD_MARGIN: f64 = 4.0;
/// Message bubbles sit a little inside or outside the field's edges.
pub const COLUMN_SLACK: f64 = 24.0;
/// How long text that scrolled out of view may stay in use.
pub const MAXIMUM_HELD_AGE: Duration = Duration::from_secs(60);
/// Shorter new text (a timestamp, a typing indicator) does not replace the
/// text in use, which would make the model read it all again.
pub const MINIMUM_ADDED_CHARACTERS: usize = 12;
pub const REFRESH_INTERVAL: Duration = Duration::from_secs(4);
/// New text from a reread is used once typing has stopped this long.
pub const TYPING_PAUSE: Duration = Duration::from_secs(1);
/// Width of the image a fingerprint hashes.
const FINGERPRINT_WIDTH: usize = 512;

/// A rectangle in screen pixels, top-left origin.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    fn max_x(&self) -> f64 {
        self.x + self.width
    }

    fn max_y(&self) -> f64 {
        self.y + self.height
    }

    fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }

    fn inset(&self, by: f64) -> Self {
        Self::new(
            self.x + by,
            self.y + by,
            self.width - 2.0 * by,
            self.height - 2.0 * by,
        )
    }

    pub fn intersects(&self, other: &Frame) -> bool {
        self.x < other.max_x()
            && other.x < self.max_x()
            && self.y < other.max_y()
            && other.y < self.max_y()
    }

    fn is_valid(&self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
            && self.width > 0.0
            && self.height > 0.0
    }
}

/// One recognized line.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub text: String,
    pub frame: Frame,
}

/// A line that may enter the prompt.
#[derive(Clone, Debug, PartialEq)]
pub struct Excerpt {
    pub frame: Frame,
    pub text: String,
}

/// Drops credential-bearing lines rather than teaching the model to complete
/// a redaction marker, and lines with no letters or digits.
pub fn cleaned(raw: &str) -> Option<String> {
    if is_sensitive(raw) {
        return None;
    }
    let text = sanitized_context(raw)?;
    text.chars()
        .any(char::is_alphanumeric)
        .then(|| text.chars().take(MAXIMUM_LINE_CHARACTERS).collect())
}

/// The draft is never prompt context, so its lines are not kept for reuse.
pub fn outside_field(lines: Vec<Line>, field: Frame) -> Vec<Line> {
    let around_field = field.inset(-FIELD_MARGIN);
    lines
        .into_iter()
        .filter(|line| !line.frame.intersects(&around_field))
        .collect()
}

/// The lines a prompt gets, in reading order. The draft never enters: it is
/// already the text before the caret. Lines in the field's column above it
/// come first, nearest first, so a long conversation keeps its newest
/// messages; the rest of the window fills what is left and is placed before
/// them, so the conversation ends right where the draft begins.
pub fn excerpts(lines: &[Line], field: Frame, window: Frame, maximum: usize) -> Vec<Excerpt> {
    let around_field = field.inset(-FIELD_MARGIN);
    let column = (field.x - COLUMN_SLACK)..=(field.max_x() + COLUMN_SLACK);
    let mut above = Vec::new();
    let mut rest = Vec::new();
    for line in lines {
        if !line.frame.is_valid()
            || !line.frame.intersects(&window)
            || line.frame.intersects(&around_field)
        {
            continue;
        }
        let Some(text) = cleaned(&line.text) else {
            continue;
        };
        let excerpt = Excerpt {
            frame: line.frame,
            text,
        };
        if column.contains(&line.frame.mid_x()) && line.frame.mid_y() < field.y {
            above.push(excerpt);
        } else {
            rest.push(excerpt);
        }
    }
    let nearest_first = |a: &Excerpt, b: &Excerpt| {
        b.frame
            .max_y()
            .total_cmp(&a.frame.max_y())
            .then(a.frame.x.total_cmp(&b.frame.x))
    };
    let reading_order = |a: &Excerpt, b: &Excerpt| {
        a.frame
            .y
            .total_cmp(&b.frame.y)
            .then(a.frame.x.total_cmp(&b.frame.x))
    };
    above.sort_by(nearest_first);
    rest.sort_by(reading_order);
    let mut remaining = maximum;
    // Stops at the first line that does not fit, so the kept part has no holes.
    let mut take = |ordered: Vec<Excerpt>| {
        let mut kept = Vec::new();
        for excerpt in ordered {
            let cost = excerpt.text.chars().count() + 1;
            if cost > remaining {
                break;
            }
            remaining -= cost;
            kept.push(excerpt);
        }
        kept
    };
    let mut conversation = take(above);
    let mut surroundings = take(rest);
    conversation.sort_by(reading_order);
    surroundings.append(&mut conversation);
    surroundings
}

/// Text in use, for one window.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub title: String,
    pub url: Option<String>,
    pub excerpts: Vec<Excerpt>,
}

impl Snapshot {
    /// Window text keeps its line breaks: a conversation reads line by line.
    pub fn text(&self) -> Option<String> {
        (!self.excerpts.is_empty()).then(|| {
            self.excerpts
                .iter()
                .map(|excerpt| excerpt.text.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
    }
}

fn comparable(text: &str) -> String {
    text.to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether a newer read replaces the text in use. Rereading an unchanged
/// window changes nothing, and lines that only scrolled away stay for a
/// while; new text replaces it at once.
pub fn should_replace(current: Option<&Snapshot>, new: &Snapshot, held_for: Duration) -> bool {
    let Some(current) = current else {
        return true;
    };
    if current.excerpts.is_empty()
        || held_for >= MAXIMUM_HELD_AGE
        || current.title != new.title
        || current.url != new.url
    {
        return true;
    }
    let known: HashSet<String> = current
        .excerpts
        .iter()
        .map(|excerpt| comparable(&excerpt.text))
        .collect();
    let added: usize = new
        .excerpts
        .iter()
        .filter(|excerpt| !known.contains(&comparable(&excerpt.text)))
        .map(|excerpt| excerpt.text.chars().count())
        .sum();
    added >= MINIMUM_ADDED_CHARACTERS
}

/// Identifies one field's window between reads. Field height and position are
/// left out because a reply box grows as you type; another title is another
/// document, tab or conversation, whose text is not reused.
pub fn key(pid: u32, role: &str, title: &str, field: Frame) -> String {
    [
        pid.to_string(),
        role.to_string(),
        title.to_string(),
        (field.x.round() as i64).to_string(),
        (field.width.round() as i64).to_string(),
    ]
    .join("\u{1f}")
}

/// What recognition would read from a window image apart from the field being
/// typed in, whose draft and blinking caret a prompt never uses. Equal
/// fingerprints reuse the last lines instead of recognizing the window again.
/// `rgba` is `image_width` × `image_height` pixels showing `window`.
pub fn fingerprint(
    rgba: &[u8],
    image_width: usize,
    image_height: usize,
    window: Frame,
    field: Frame,
) -> Option<[u8; 32]> {
    if image_width == 0
        || image_height == 0
        || rgba.len() != image_width * image_height * 4
        || window.width <= 0.0
        || window.height <= 0.0
    {
        return None;
    }
    let width = FINGERPRINT_WIDTH;
    let height = (image_height as f64 * width as f64 / image_width as f64)
        .round()
        .max(1.0) as usize;
    // Area-averaged, a changed word still changes pixels.
    let mut pixels = vec![0u8; width * height];
    for y in 0..height {
        let y0 = y * image_height / height;
        let y1 = ((y + 1) * image_height / height).clamp(y0 + 1, image_height);
        for x in 0..width {
            let x0 = x * image_width / width;
            let x1 = ((x + 1) * image_width / width).clamp(x0 + 1, image_width);
            let mut sum = 0u64;
            let mut count = 0u64;
            for sy in y0..y1 {
                let start = (sy * image_width + x0) * 4;
                for pixel in rgba[start..start + (x1 - x0) * 4].as_chunks::<4>().0 {
                    sum += 299 * u64::from(pixel[0])
                        + 587 * u64::from(pixel[1])
                        + 114 * u64::from(pixel[2]);
                    count += 1;
                }
            }
            pixels[y * width + x] = (sum / (count.max(1) * 1000)) as u8;
        }
    }
    let area = field.inset(-FIELD_MARGIN);
    let scale_x = width as f64 / window.width;
    let scale_y = height as f64 / window.height;
    let pixel = |value: f64, limit: usize| value.clamp(0.0, limit as f64) as usize;
    let min_x = pixel(((area.x - window.x) * scale_x).floor() - 1.0, width);
    let max_x = pixel(((area.max_x() - window.x) * scale_x).ceil() + 1.0, width);
    let min_y = pixel(((area.y - window.y) * scale_y).floor() - 1.0, height);
    let max_y = pixel(((area.max_y() - window.y) * scale_y).ceil() + 1.0, height);
    if min_x < max_x {
        for row in min_y..max_y {
            pixels[row * width + min_x..row * width + max_x].fill(0);
        }
    }
    let mut hasher = Sha256::new();
    for value in [
        window.x,
        window.y,
        window.width,
        window.height,
        field.x,
        field.y,
        field.width,
        field.height,
    ] {
        hasher.update(value.to_le_bytes());
    }
    hasher.update(&pixels);
    Some(hasher.finalize().into())
}

#[derive(Clone, Debug)]
struct Entry {
    key: String,
    snapshot: Option<Snapshot>,
    /// A newer read with new text, held until typing pauses.
    pending: Option<Snapshot>,
    started_at: Instant,
    adopted_at: Instant,
}

/// What a finished read changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Finished {
    /// The text in use changed: the prompt's start must be read again.
    Changed,
    /// New text waits for a pause in typing.
    Held,
    Unchanged,
}

/// The state of `CotypingWindowTextCapture`, without its thread or clock.
#[derive(Clone, Debug, Default)]
pub struct Capture {
    entry: Option<Entry>,
    reading: bool,
    last_typing: Option<Instant>,
    generation: u64,
}

/// A read to start. `finish` must get its `generation` back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub generation: u64,
}

impl Capture {
    /// The text for `key`, or `None` until the first read finishes, and a
    /// ticket when a read should start: none is running and the last one is
    /// old. Counted from the start, so a read that fails is not retried on
    /// every keystroke.
    pub fn snapshot(&mut self, key: &str, now: Instant) -> (Option<&Snapshot>, Option<Ticket>) {
        if self.entry.as_ref().is_some_and(|entry| entry.key != key) {
            // Another field, window or document: forget the old text.
            self.entry = None;
            self.generation += 1;
        }
        let due = self.entry.as_ref().is_none_or(|entry| {
            now.saturating_duration_since(entry.started_at) >= REFRESH_INTERVAL
        });
        let ticket = (due && !self.reading).then(|| {
            self.reading = true;
            match &mut self.entry {
                Some(entry) => entry.started_at = now,
                None => {
                    self.entry = Some(Entry {
                        key: key.to_string(),
                        snapshot: None,
                        pending: None,
                        started_at: now,
                        adopted_at: now,
                    })
                }
            }
            Ticket {
                generation: self.generation,
            }
        });
        (
            self.entry
                .as_ref()
                .and_then(|entry| entry.snapshot.as_ref()),
            ticket,
        )
    }

    /// A key that changes the text was pressed.
    pub fn note_typing(&mut self, now: Instant) {
        self.last_typing = Some(now);
    }

    fn typing_recently(&self, now: Instant) -> bool {
        self.last_typing
            .is_some_and(|at| now.saturating_duration_since(at) < TYPING_PAUSE)
    }

    /// A read came back. `snapshot` is `None` when it failed or was refused.
    /// A read older than the text's last forgetting cannot put it back.
    pub fn finish(
        &mut self,
        ticket: Ticket,
        key: &str,
        snapshot: Option<Snapshot>,
        now: Instant,
    ) -> Finished {
        self.reading = false;
        let typing = self.typing_recently(now);
        if ticket.generation != self.generation {
            return Finished::Unchanged;
        }
        let (Some(entry), Some(snapshot)) = (self.entry.as_mut(), snapshot) else {
            return Finished::Unchanged;
        };
        if entry.key != key {
            return Finished::Unchanged;
        }
        let held_for = now.saturating_duration_since(entry.adopted_at);
        if !should_replace(entry.snapshot.as_ref(), &snapshot, held_for) {
            // The text in use is still right, so anything held is out of date.
            entry.pending = None;
            return Finished::Unchanged;
        }
        if entry.snapshot.is_some() && typing {
            entry.pending = Some(snapshot);
            return Finished::Held;
        }
        adopt(entry, snapshot, now)
    }

    /// When held text can be used, if nothing is typed meanwhile.
    pub fn adoption_due(&self) -> Option<Instant> {
        self.entry.as_ref()?.pending.as_ref()?;
        Some(
            self.last_typing
                .map_or_else(Instant::now, |at| at + TYPING_PAUSE),
        )
    }

    /// Uses the held text if typing has paused long enough.
    pub fn adopt_pending_if_quiet(&mut self, now: Instant) -> Finished {
        if self.typing_recently(now) {
            return Finished::Unchanged;
        }
        let Some(entry) = self.entry.as_mut() else {
            return Finished::Unchanged;
        };
        let Some(pending) = entry.pending.take() else {
            return Finished::Unchanged;
        };
        adopt(entry, pending, now)
    }

    /// Forgets the text in use. A read already running cannot put it back.
    pub fn remove_all(&mut self) {
        self.entry = None;
        self.generation += 1;
    }
}

fn adopt(entry: &mut Entry, snapshot: Snapshot, now: Instant) -> Finished {
    let changed = entry.snapshot.as_ref().and_then(Snapshot::text) != snapshot.text();
    entry.snapshot = (!snapshot.excerpts.is_empty()).then_some(snapshot);
    entry.pending = None;
    entry.adopted_at = now;
    if changed {
        Finished::Changed
    } else {
        Finished::Unchanged
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WINDOW: Frame = Frame {
        x: 0.0,
        y: 0.0,
        width: 800.0,
        height: 600.0,
    };
    const FIELD: Frame = Frame {
        x: 100.0,
        y: 500.0,
        width: 400.0,
        height: 40.0,
    };

    fn line(text: &str, x: f64, y: f64) -> Line {
        Line {
            text: text.to_string(),
            frame: Frame::new(x, y, 200.0, 20.0),
        }
    }

    #[test]
    fn surroundings_come_first_and_the_conversation_ends_at_the_draft() {
        let lines = [
            line("Newest message", 100.0, 460.0),
            line("Older message", 100.0, 400.0),
            line("Sidebar item", 600.0, 100.0),
            line("Inbox title", 100.0, 10.0),
            line("Below the field", 100.0, 560.0),
            line("My draft", 110.0, 505.0),
            line("password: hunter2", 100.0, 300.0),
            line("---", 100.0, 200.0),
        ];
        let kept: Vec<String> = excerpts(&lines, FIELD, WINDOW, MAXIMUM_CHARACTERS)
            .into_iter()
            .map(|e| e.text)
            .collect();
        assert_eq!(
            kept,
            [
                "Sidebar item",
                "Below the field",
                "Inbox title",
                "Older message",
                "Newest message"
            ]
        );
    }

    #[test]
    fn the_nearest_lines_win_when_there_is_too_much() {
        let lines = [
            line("aaaaaaaaaa", 100.0, 300.0),
            line("bbbbbbbbbb", 100.0, 400.0),
            line("cccccccccc", 100.0, 460.0),
        ];
        let kept: Vec<String> = excerpts(&lines, FIELD, WINDOW, 22)
            .into_iter()
            .map(|e| e.text)
            .collect();
        assert_eq!(kept, ["bbbbbbbbbb", "cccccccccc"]);
    }

    fn snapshot(lines: &[&str]) -> Snapshot {
        Snapshot {
            title: "Inbox".into(),
            url: None,
            excerpts: lines
                .iter()
                .map(|text| Excerpt {
                    frame: Frame::default(),
                    text: text.to_string(),
                })
                .collect(),
        }
    }

    #[test]
    fn only_real_new_text_replaces_the_text_in_use() {
        let held = snapshot(&["Hello there"]);
        let age = Duration::from_secs(1);
        assert!(should_replace(None, &held, age));
        assert!(!should_replace(Some(&held), &held, age));
        // A timestamp is too little; scrolling out of view keeps the text.
        assert!(!should_replace(
            Some(&held),
            &snapshot(&["hello  THERE", "10:45"]),
            age
        ));
        assert!(!should_replace(Some(&held), &snapshot(&[]), age));
        assert!(should_replace(
            Some(&held),
            &snapshot(&["Hello there", "A reply has arrived"]),
            age
        ));
        assert!(should_replace(Some(&held), &held, MAXIMUM_HELD_AGE));
        let mut other = held.clone();
        other.title = "Other".into();
        assert!(should_replace(Some(&held), &other, age));
    }

    #[test]
    fn the_key_ignores_what_grows_while_typing() {
        let a = key(1, "text", "Inbox", Frame::new(10.0, 20.0, 100.0, 30.0));
        let taller = key(1, "text", "Inbox", Frame::new(10.0, 5.0, 100.0, 60.0));
        assert_eq!(a, taller);
        assert_ne!(
            a,
            key(1, "text", "Other", Frame::new(10.0, 20.0, 100.0, 30.0))
        );
        assert_ne!(
            a,
            key(2, "text", "Inbox", Frame::new(10.0, 20.0, 100.0, 30.0))
        );
    }

    #[test]
    fn the_fingerprint_ignores_the_field_being_typed_in() {
        let (w, h) = (800, 600);
        let mut image = vec![255u8; w * h * 4];
        let print = |image: &[u8]| fingerprint(image, w, h, WINDOW, FIELD).unwrap();
        let clean = print(&image);
        // Typing in the field changes nothing.
        for x in 120..200 {
            let at = (510 * w + x) * 4;
            image[at..at + 3].fill(0);
        }
        assert_eq!(print(&image), clean);
        // A new word above it does.
        for x in 120..200 {
            let at = (300 * w + x) * 4;
            image[at..at + 3].fill(0);
        }
        assert_ne!(print(&image), clean);
        assert!(fingerprint(&[], 0, 0, WINDOW, FIELD).is_none());
    }

    #[test]
    fn reads_are_spaced_and_held_while_typing() {
        let start = Instant::now();
        let mut capture = Capture::default();
        // The first request starts a read and goes without text.
        let (text, ticket) = capture.snapshot("k", start);
        assert!(text.is_none());
        let ticket = ticket.unwrap();
        // One read at a time, and no retry on every keystroke.
        assert!(capture.snapshot("k", start).1.is_none());
        assert_eq!(
            capture.finish(ticket, "k", Some(snapshot(&["First conversation"])), start),
            Finished::Changed
        );
        let later = start + Duration::from_secs(1);
        let (text, ticket) = capture.snapshot("k", later);
        assert!(text.is_some());
        assert!(ticket.is_none());
        let due = start + REFRESH_INTERVAL;
        let ticket = capture.snapshot("k", due).1.unwrap();
        // New text waits while typing, and comes once typing pauses.
        capture.note_typing(due);
        let reply = snapshot(&["First conversation", "A reply has arrived"]);
        assert_eq!(
            capture.finish(ticket, "k", Some(reply), due),
            Finished::Held
        );
        assert_eq!(capture.adoption_due(), Some(due + TYPING_PAUSE));
        assert_eq!(capture.adopt_pending_if_quiet(due), Finished::Unchanged);
        assert_eq!(
            capture.adopt_pending_if_quiet(due + TYPING_PAUSE),
            Finished::Changed
        );
        assert_eq!(capture.adoption_due(), None);
    }

    #[test]
    fn another_field_forgets_and_a_late_read_cannot_put_it_back() {
        let now = Instant::now();
        let mut capture = Capture::default();
        let ticket = capture.snapshot("a", now).1.unwrap();
        // Focus moved while the read ran.
        assert!(capture.snapshot("b", now).0.is_none());
        assert_eq!(
            capture.finish(ticket, "a", Some(snapshot(&["Old window text"])), now),
            Finished::Unchanged
        );
        let ticket = capture.snapshot("b", now).1.unwrap();
        capture.finish(ticket, "b", Some(snapshot(&["New window text"])), now);
        assert!(capture.snapshot("b", now).0.is_some());
        capture.remove_all();
        let (forgotten, ticket) = capture.snapshot("b", now);
        assert!(forgotten.is_none());
        capture.finish(ticket.unwrap(), "b", None, now);
        // A failed read keeps nothing and is not retried at once.
        let failing = capture.snapshot("c", now).1.unwrap();
        assert_eq!(capture.finish(failing, "c", None, now), Finished::Unchanged);
        assert!(capture.snapshot("c", now).1.is_none());
    }
}
