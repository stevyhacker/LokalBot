use std::collections::HashSet;
use std::time::{Duration, Instant};

use sha2::{Digest as _, Sha256};

use super::prompt::{is_sensitive, sanitized_context};

pub const MAXIMUM_CHARACTERS: usize = 2_000;
pub const MAXIMUM_LINE_CHARACTERS: usize = 300;
pub const FIELD_MARGIN: f64 = 4.0;
pub const COLUMN_SLACK: f64 = 24.0;
pub const COMPOSER_CHROME_HEIGHT: f64 = 56.0;
pub const MAXIMUM_HELD_AGE: Duration = Duration::from_secs(60);
pub const MINIMUM_ADDED_CHARACTERS: usize = 12;
pub const REFRESH_INTERVAL: Duration = Duration::from_secs(4);
pub const TYPING_PAUSE: Duration = Duration::from_secs(1);
const FINGERPRINT_WIDTH: usize = 512;

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

#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub text: String,
    pub frame: Frame,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Excerpt {
    pub frame: Frame,
    pub text: String,
}

pub fn cleaned(raw: &str) -> Option<String> {
    if is_sensitive(raw) {
        return None;
    }
    let text = sanitized_context(raw)?;
    text.chars()
        .any(char::is_alphanumeric)
        .then(|| text.chars().take(MAXIMUM_LINE_CHARACTERS).collect())
}

pub fn outside_field(lines: Vec<Line>, field: Frame) -> Vec<Line> {
    let around_field = field.inset(-FIELD_MARGIN);
    lines
        .into_iter()
        .filter(|line| !line.frame.intersects(&around_field))
        .collect()
}

pub fn excerpts(lines: &[Line], field: Frame, window: Frame, maximum: usize) -> Vec<Excerpt> {
    let around_field = field.inset(-FIELD_MARGIN);
    let column = (field.x - COLUMN_SLACK)..=(field.max_x() + COLUMN_SLACK);
    let mut above = Vec::new();
    let mut rest = Vec::new();
    for line in lines {
        if !line.frame.is_valid()
            || !line.frame.intersects(&window)
            || line.frame.intersects(&around_field)
            || is_composer_chrome(&line.frame, &field, &column)
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

fn is_composer_chrome(
    frame: &Frame,
    field: &Frame,
    column: &std::ops::RangeInclusive<f64>,
) -> bool {
    column.contains(&frame.mid_x())
        && frame.y >= field.max_y() - FIELD_MARGIN
        && frame.max_y() <= field.max_y() + COMPOSER_CHROME_HEIGHT
}

#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub title: String,
    pub url: Option<String>,
    pub excerpts: Vec<Excerpt>,
}

impl Snapshot {
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
    pending: Option<Snapshot>,
    started_at: Instant,
    adopted_at: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Finished {
    Changed,
    Held,
    Unchanged,
}

#[derive(Clone, Debug, Default)]
pub struct Capture {
    entry: Option<Entry>,
    reading: bool,
    last_typing: Option<Instant>,
    generation: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub generation: u64,
}

impl Capture {
    pub fn snapshot(&mut self, key: &str, now: Instant) -> (Option<&Snapshot>, Option<Ticket>) {
        if self.entry.as_ref().is_some_and(|entry| entry.key != key) {
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

    pub fn note_typing(&mut self, now: Instant) {
        self.last_typing = Some(now);
    }

    fn typing_recently(&self, now: Instant) -> bool {
        self.last_typing
            .is_some_and(|at| now.saturating_duration_since(at) < TYPING_PAUSE)
    }

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
            entry.pending = None;
            return Finished::Unchanged;
        }
        if entry.snapshot.is_some() && typing {
            entry.pending = Some(snapshot);
            return Finished::Held;
        }
        adopt(entry, snapshot, now)
    }

    pub fn adoption_due(&self) -> Option<Instant> {
        self.entry.as_ref()?.pending.as_ref()?;
        Some(
            self.last_typing
                .map_or_else(Instant::now, |at| at + TYPING_PAUSE),
        )
    }

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
            line("Press Enter to send", 100.0, 560.0),
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
                "Inbox title",
                "Older message",
                "Newest message"
            ]
        );
    }

    #[test]
    fn drops_composer_chrome_under_field_while_keeping_thread_below_top_reply_box() {
        let top_field = Frame::new(100.0, 80.0, 400.0, 40.0);
        let lines = [
            line("Send", 120.0, 128.0),
            line("Quoted thread message", 100.0, 220.0),
        ];
        let kept: Vec<String> = excerpts(&lines, top_field, WINDOW, MAXIMUM_CHARACTERS)
            .into_iter()
            .map(|e| e.text)
            .collect();
        assert_eq!(kept, ["Quoted thread message"]);
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
        for x in 120..200 {
            let at = (510 * w + x) * 4;
            image[at..at + 3].fill(0);
        }
        assert_eq!(print(&image), clean);
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
        let (text, ticket) = capture.snapshot("k", start);
        assert!(text.is_none());
        let ticket = ticket.unwrap();
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
        let failing = capture.snapshot("c", now).1.unwrap();
        assert_eq!(capture.finish(failing, "c", None, now), Finished::Unchanged);
        assert!(capture.snapshot("c", now).1.is_none());
    }
}
