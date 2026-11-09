//! Text from documents (`DocExtractor`, `OfficeText`, `RTF`, as DigUp's Linux and
//! Windows builds read them): plain text directly, HTML by stripping tags, docx
//! and odt from the XML inside their zip, rtf stripped of its control words, and
//! spreadsheets and presentations from their XML. Legacy .doc isn't read here.

use std::collections::HashMap;
use std::io::Read as _;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

/// Why a file has no text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadError {
    Unreadable(String),
    Locked,
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReadError::Unreadable(why) => write!(f, "unreadable: {why}"),
            ReadError::Locked => f.write_str("password-protected"),
        }
    }
}

/// Larger zip entries aren't inflated: a zip bomb, or XML far past what the index
/// keeps of a document.
const MAX_ENTRY_BYTES: u64 = 64 << 20;
/// Reading stops past what the index keeps of a document.
const MAX_OFFICE_CHARACTERS: usize = 10_000_000;

pub fn text_of(path: &Path) -> Result<String, ReadError> {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "docx" => {
            let xml = entry_text(path, "word/document.xml")?;
            Ok(plain_text_from_html(&as_html(
                &xml,
                &["w:p"],
                &["w:br", "w:cr"],
                &["w:tab"],
            )))
        }
        "odt" => {
            let xml = entry_text(path, "content.xml")?;
            Ok(plain_text_from_html(&as_html(
                &xml,
                &["text:p", "text:h"],
                &["text:line-break"],
                &["text:tab", "text:s"],
            )))
        }
        "rtf" => Ok(rtf_text(&read_text(path)?)),
        "doc" => Err(ReadError::Unreadable(
            "legacy Word (.doc) files aren't read on this system".into(),
        )),
        "xlsx" | "pptx" | "ods" | "odp" => office_text(path, &ext),
        "html" | "htm" => Ok(plain_text_from_html(&read_text(path)?)),
        _ => read_text(path),
    }
}

/// UTF-8 (with or without a BOM), UTF-16 with a BOM, else Latin-1, as
/// `String(contentsOf:usedEncoding:)` falls back.
pub fn read_text(path: &Path) -> Result<String, ReadError> {
    let bytes = std::fs::read(path).map_err(|err| ReadError::Unreadable(err.to_string()))?;
    Ok(decode_text(&bytes))
}

fn decode_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    let utf16 = |rest: &[u8], read: fn([u8; 2]) -> u16| {
        let units: Vec<u16> = rest.as_chunks::<2>().0.iter().map(|b| read(*b)).collect();
        String::from_utf16_lossy(&units)
    };
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(rest, u16::from_le_bytes);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(rest, u16::from_be_bytes);
    }
    match std::str::from_utf8(bytes) {
        Ok(text) => text.to_string(),
        Err(_) => bytes.iter().map(|b| *b as char).collect(),
    }
}

macro_rules! pattern {
    ($name:ident, $source:expr) => {
        static $name: LazyLock<Regex> =
            LazyLock::new(|| Regex::new($source).expect("a valid pattern"));
    };
}

pattern!(HTML_SCRIPT, r"(?is)<script\b.*?</script\s*>");
pattern!(HTML_STYLE, r"(?is)<style\b.*?</style\s*>");
pattern!(HTML_COMMENT, r"(?s)<!--.*?-->");
pattern!(HTML_HEAD, r"(?is)<head\b.*?</head\s*>");
pattern!(
    HTML_BLOCK_END,
    r"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"
);
pattern!(HTML_TAG, r"<[^>]+>");
pattern!(HTML_NUMERIC, r"&#(x[0-9a-fA-F]+|[0-9]+);");
pattern!(HTML_SPACES, r"[ \t]+");
pattern!(HTML_LINES, r"\s*\n\s*");

/// Good enough for search: drops scripts, styles and comments, turns block ends
/// into line breaks, strips the remaining tags and decodes common entities.
pub fn plain_text_from_html(html: &str) -> String {
    let mut text = html.to_string();
    for pattern in [&HTML_SCRIPT, &HTML_STYLE, &HTML_COMMENT, &HTML_HEAD] {
        text = pattern.replace_all(&text, " ").into_owned();
    }
    text = HTML_BLOCK_END.replace_all(&text, "\n").into_owned();
    text = HTML_TAG.replace_all(&text, " ").into_owned();
    for (entity, character) in [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
    ] {
        text = text.replace(entity, character);
    }
    let text = HTML_NUMERIC.replace_all(&text, |captures: &regex::Captures| {
        let code = &captures[1];
        let value = match code.strip_prefix('x') {
            Some(hex) => u32::from_str_radix(hex, 16).ok(),
            None => code.parse().ok(),
        };
        value
            .and_then(char::from_u32)
            .map_or(" ".to_string(), String::from)
    });
    let text = HTML_SPACES.replace_all(&text, " ");
    let text = HTML_LINES.replace_all(&text, "\n");
    text.trim().to_string()
}

/// Word-processing XML as the little HTML `plain_text_from_html` reads:
/// paragraph ends become `</p>`, breaks `<br>`, tabs and spaces a space.
fn as_html(xml: &str, paragraphs: &[&str], breaks: &[&str], spaces: &[&str]) -> String {
    let mut text = xml.to_string();
    for tag in paragraphs {
        text = text.replace(&format!("</{tag}>"), "</p>");
    }
    let replace_tag = |text: String, tag: &str, with: &str| -> String {
        let pattern =
            Regex::new(&format!(r"<{}\b[^>]*/?>", regex::escape(tag))).expect("a valid pattern");
        pattern.replace_all(&text, with).into_owned()
    };
    for tag in breaks {
        text = replace_tag(text, tag, "<br>");
    }
    for tag in spaces {
        text = replace_tag(text, tag, " ");
    }
    text
}

// ---------------------------------------------------------------------- zip

struct Zip {
    archive: zip::ZipArchive<std::fs::File>,
}

impl Zip {
    fn open(path: &Path) -> Result<Self, ReadError> {
        let file =
            std::fs::File::open(path).map_err(|err| ReadError::Unreadable(err.to_string()))?;
        let archive = zip::ZipArchive::new(file)
            .map_err(|_| ReadError::Unreadable("not a zip file".into()))?;
        Ok(Self { archive })
    }

    /// The entry's bytes, or `None` when there's no such entry. The declared size
    /// is checked before anything is allocated.
    fn data(&mut self, name: &str) -> Result<Option<Vec<u8>>, ReadError> {
        let mut entry = match self.archive.by_name(name) {
            Ok(entry) => entry,
            Err(zip::result::ZipError::FileNotFound) => return Ok(None),
            Err(_) => return Err(ReadError::Unreadable(format!("can't read {name}"))),
        };
        if entry.size() > MAX_ENTRY_BYTES {
            return Err(ReadError::Unreadable(format!(
                "{name} is {} MB, more than is read",
                entry.size() >> 20
            )));
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        // Never more than was declared, whatever the stream says.
        (&mut entry)
            .take(MAX_ENTRY_BYTES)
            .read_to_end(&mut bytes)
            .map_err(|_| ReadError::Unreadable(format!("can't read {name}")))?;
        Ok(Some(bytes))
    }

    fn required(&mut self, name: &str) -> Result<Vec<u8>, ReadError> {
        self.data(name)?
            .ok_or_else(|| ReadError::Unreadable(format!("no {name} inside")))
    }
}

fn entry_text(path: &Path, name: &str) -> Result<String, ReadError> {
    let bytes = Zip::open(path)?.required(name)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

// ------------------------------------------------------------------- office

fn office_text(path: &Path, ext: &str) -> Result<String, ReadError> {
    // An Office file with a password is an OLE compound file holding the zip.
    if is_compound_file(path) {
        return Err(ReadError::Locked);
    }
    let mut zip = Zip::open(path)?;
    let mut out = Output::default();
    match ext {
        "xlsx" => workbook(&mut zip, &mut out)?,
        "pptx" => presentation(&mut zip, &mut out)?,
        "ods" => spreadsheet(&zip.required("content.xml")?, &mut out),
        _ => slides(&zip.required("content.xml")?, &mut out),
    }
    Ok(out.text.trim().to_string())
}

fn is_compound_file(path: &Path) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let mut head = Vec::with_capacity(8);
    file.take(8).read_to_end(&mut head).is_ok()
        && head == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
}

#[derive(Default)]
struct Output {
    text: String,
}

impl Output {
    fn full(&self) -> bool {
        self.text.len() >= MAX_OFFICE_CHARACTERS
    }

    fn line(&mut self, line: &str) {
        if !self.full() {
            self.text.push_str(line);
            self.text.push('\n');
        }
    }

    /// A blank line between sheets or slides.
    fn paragraph(&mut self) {
        if !self.text.is_empty() && !self.text.ends_with("\n\n") {
            self.text.push('\n');
        }
    }
}

/// A tag's name without its namespace prefix: writers don't all use the same ones.
fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

type Links = HashMap<String, (String, String)>;

/// Sheets in the workbook's order, cells with their shared strings or their last
/// computed value.
fn workbook(zip: &mut Zip, out: &mut Output) -> Result<(), ReadError> {
    let book = main_part(zip, "xl/workbook.xml")?;
    let links = relationships(&book, zip)?;
    let shared = match links
        .values()
        .find(|(kind, _)| kind.ends_with("/sharedStrings"))
    {
        Some((_, part)) => zip
            .data(part)?
            .map(|xml| shared_strings(&xml))
            .unwrap_or_default(),
        None => Vec::new(),
    };
    let xml = zip.required(&book)?;
    let mut scan = XmlScanner::new(&xml);
    let mut sheets: Vec<(String, String)> = Vec::new();
    while let Some(event) = scan.next_event() {
        if let Event::Open {
            name, attributes, ..
        } = event
            && local(&name) == "sheet"
            && let Some(id) = scan.attribute(":id", attributes.clone())
            && let Some((kind, target)) = links.get(&id)
            && kind.ends_with("/worksheet")
        {
            let title = scan.attribute("name", attributes).unwrap_or_default();
            sheets.push((title, target.clone()));
        }
    }
    for (title, part) in sheets {
        if out.full() {
            break;
        }
        let Some(xml) = zip.data(&part)? else {
            continue;
        };
        out.paragraph();
        out.line(&title);
        worksheet(&xml, &shared, out);
    }
    Ok(())
}

/// The table of strings cells point to: each `<si>`'s runs joined, phonetic
/// readings left out.
fn shared_strings(xml: &[u8]) -> Vec<String> {
    let mut scan = XmlScanner::new(xml);
    let mut strings = Vec::new();
    let (mut current, mut in_text, mut phonetic) = (String::new(), false, 0i32);
    while let Some(event) = scan.next_event() {
        match event {
            Event::Open { name, empty, .. } => {
                match local(&name) {
                    "si" => current.clear(),
                    "t" => in_text = !empty,
                    "rPh" if !empty => phonetic += 1,
                    _ => {}
                }
                if empty && local(&name) == "si" {
                    strings.push(String::new());
                }
            }
            Event::Close(name) => match local(&name) {
                "si" => strings.push(current.clone()),
                "t" => in_text = false,
                "rPh" => phonetic -= 1,
                _ => {}
            },
            Event::Text(range, raw) => {
                if in_text && phonetic == 0 {
                    current.push_str(&scan.string(range, raw));
                }
            }
        }
    }
    strings
}

fn worksheet(xml: &[u8], shared: &[String], out: &mut Output) {
    let mut scan = XmlScanner::new(xml);
    let mut row: Vec<String> = Vec::new();
    let (mut kind, mut value) = ("n".to_string(), String::new());
    let (mut in_value, mut inline, mut in_text, mut phonetic) = (false, false, false, 0i32);
    while !out.full() {
        let Some(event) = scan.next_event() else {
            break;
        };
        match event {
            Event::Open {
                name,
                attributes,
                empty,
            } => match local(&name) {
                "row" => row.clear(),
                "c" => {
                    kind = scan
                        .attribute("t", attributes)
                        .unwrap_or_else(|| "n".into());
                    value.clear();
                }
                "v" => in_value = !empty,
                "is" => inline = !empty,
                "t" => in_text = !empty,
                "rPh" if !empty => phonetic += 1,
                _ => {}
            },
            Event::Close(name) => match local(&name) {
                "row" => {
                    if !row.is_empty() {
                        out.line(&row.join("\t"));
                    }
                }
                "c" => {
                    let shown = match kind.as_str() {
                        "s" => value
                            .trim()
                            .parse::<usize>()
                            .ok()
                            .and_then(|index| shared.get(index).cloned())
                            .unwrap_or_default(),
                        // TRUE/FALSE and #N/A say nothing to search for.
                        "b" | "e" => String::new(),
                        _ => value.clone(),
                    };
                    let cell = shown.trim();
                    if !cell.is_empty() {
                        row.push(cell.to_string());
                    }
                }
                "v" => in_value = false,
                "is" => inline = false,
                "t" => in_text = false,
                "rPh" => phonetic -= 1,
                _ => {}
            },
            Event::Text(range, raw) => {
                if in_value || (inline && in_text && phonetic == 0) {
                    value.push_str(&scan.string(range, raw));
                }
            }
        }
    }
}

/// Slides in the presentation's order, each followed by its notes.
fn presentation(zip: &mut Zip, out: &mut Output) -> Result<(), ReadError> {
    let deck = main_part(zip, "ppt/presentation.xml")?;
    let links = relationships(&deck, zip)?;
    let xml = zip.required(&deck)?;
    let mut scan = XmlScanner::new(&xml);
    let mut parts: Vec<String> = Vec::new();
    while let Some(event) = scan.next_event() {
        if let Event::Open {
            name, attributes, ..
        } = event
            && local(&name) == "sldId"
            && let Some(id) = scan.attribute(":id", attributes)
            && let Some((kind, target)) = links.get(&id)
            && kind.ends_with("/slide")
        {
            parts.push(target.clone());
        }
    }
    for slide in parts {
        if out.full() {
            break;
        }
        let Some(xml) = zip.data(&slide)? else {
            continue;
        };
        out.paragraph();
        drawing_text(&xml, out);
        let links = relationships(&slide, zip)?;
        if let Some((_, notes)) = links
            .values()
            .find(|(kind, _)| kind.ends_with("/notesSlide"))
            && let Some(xml) = zip.data(notes)?
        {
            drawing_text(&xml, out);
        }
    }
    Ok(())
}

/// A slide or notes page: `<a:t>` runs, a line per paragraph, fields left out.
fn drawing_text(xml: &[u8], out: &mut Output) {
    let mut scan = XmlScanner::new(xml);
    let (mut paragraph, mut in_text, mut field) = (String::new(), false, 0i32);
    while !out.full() {
        let Some(event) = scan.next_event() else {
            break;
        };
        match event {
            Event::Open { name, empty, .. } => match local(&name) {
                "t" => in_text = !empty,
                "br" => paragraph.push('\n'),
                "fld" if !empty => field += 1,
                _ => {}
            },
            Event::Close(name) => match local(&name) {
                "t" => in_text = false,
                "fld" => field -= 1,
                "p" => {
                    let line = paragraph.trim();
                    if !line.is_empty() {
                        out.line(line);
                    }
                    paragraph.clear();
                }
                _ => {}
            },
            Event::Text(range, raw) => {
                if in_text && field == 0 {
                    paragraph.push_str(&scan.string(range, raw));
                }
            }
        }
    }
}

fn main_part(zip: &mut Zip, default: &str) -> Result<String, ReadError> {
    Ok(relationships("", zip)?
        .values()
        .find(|(kind, _)| kind.ends_with("/officeDocument"))
        .map(|(_, target)| target.clone())
        .unwrap_or_else(|| default.to_string()))
}

/// A part's links by id, from the `_rels` file beside it, with their targets as
/// zip entry names.
fn relationships(part: &str, zip: &mut Zip) -> Result<Links, ReadError> {
    let (folder, file) = match part.rsplit_once('/') {
        Some((folder, file)) => (folder, file),
        None => ("", part),
    };
    let rels = if folder.is_empty() {
        format!("_rels/{file}.rels")
    } else {
        format!("{folder}/_rels/{file}.rels")
    };
    let Some(xml) = zip.data(&rels)? else {
        return Ok(HashMap::new());
    };
    let mut scan = XmlScanner::new(&xml);
    let mut links = HashMap::new();
    while let Some(event) = scan.next_event() {
        let Event::Open {
            name, attributes, ..
        } = event
        else {
            continue;
        };
        if local(&name) != "Relationship"
            || scan.attribute("TargetMode", attributes.clone()).as_deref() == Some("External")
        {
            continue;
        }
        if let (Some(id), Some(target)) = (
            scan.attribute("Id", attributes.clone()),
            scan.attribute("Target", attributes.clone()),
        ) {
            let kind = scan.attribute("Type", attributes).unwrap_or_default();
            links.insert(id, (kind, resolve_target(&target, folder)));
        }
    }
    Ok(links)
}

/// Absolute targets start at the package's root, others at the part's folder.
fn resolve_target(target: &str, folder: &str) -> String {
    let mut path: Vec<&str> = if target.starts_with('/') {
        Vec::new()
    } else {
        folder.split('/').filter(|p| !p.is_empty()).collect()
    };
    for piece in target.split('/').filter(|p| !p.is_empty()) {
        match piece {
            "." => {}
            ".." => {
                path.pop();
            }
            other => path.push(other),
        }
    }
    path.join("/")
}

/// Each sheet's name, then its rows. Comments' authors and dates are left out.
fn spreadsheet(xml: &[u8], out: &mut Output) {
    let mut scan = XmlScanner::new(xml);
    let (mut row, mut cell, mut paragraph) = (Vec::<String>::new(), String::new(), String::new());
    let (mut in_cell, mut boolean, mut in_paragraph, mut skipped) = (false, false, 0i32, 0i32);
    while !out.full() {
        let Some(event) = scan.next_event() else {
            break;
        };
        match event {
            Event::Open {
                name,
                attributes,
                empty,
            } => match local(&name) {
                "table" => {
                    out.paragraph();
                    let title = scan.attribute("table:name", attributes).unwrap_or_default();
                    out.line(&title);
                }
                "table-row" => row.clear(),
                "table-cell" | "covered-table-cell" => {
                    boolean = scan.attribute("office:value-type", attributes).as_deref()
                        == Some("boolean");
                    in_cell = !empty;
                    cell.clear();
                }
                "p" | "h" if !empty => {
                    in_paragraph += 1;
                    paragraph.clear();
                }
                "s" | "tab" | "line-break" if in_paragraph > 0 => paragraph.push(' '),
                "creator" | "date" if !empty => skipped += 1,
                _ => {}
            },
            Event::Close(name) => match local(&name) {
                "table-row" => {
                    if !row.is_empty() {
                        out.line(&row.join("\t"));
                    }
                }
                "table-cell" | "covered-table-cell" => {
                    let text = cell.trim();
                    if !text.is_empty() && !boolean {
                        row.push(text.to_string());
                    }
                    in_cell = false;
                }
                "p" | "h" => {
                    in_paragraph -= 1;
                    let text = paragraph.trim();
                    if !text.is_empty() {
                        if in_cell {
                            if !cell.is_empty() {
                                cell.push(' ');
                            }
                            cell.push_str(text);
                        } else {
                            out.line(text);
                        }
                    }
                }
                "creator" | "date" => skipped -= 1,
                _ => {}
            },
            Event::Text(range, raw) => {
                if in_paragraph > 0 && skipped == 0 {
                    paragraph.push_str(&scan.string(range, raw));
                }
            }
        }
    }
}

/// Each page's text, a line per paragraph. Page numbers and dates are left out.
fn slides(xml: &[u8], out: &mut Output) {
    let mut scan = XmlScanner::new(xml);
    let mut paragraph = String::new();
    let (mut in_paragraph, mut skipped) = (0i32, 0i32);
    while !out.full() {
        let Some(event) = scan.next_event() else {
            break;
        };
        match event {
            Event::Open { name, empty, .. } => match local(&name) {
                "page" => out.paragraph(),
                "p" | "h" if !empty => {
                    in_paragraph += 1;
                    paragraph.clear();
                }
                "s" | "tab" if in_paragraph > 0 => paragraph.push(' '),
                "line-break" if in_paragraph > 0 => paragraph.push('\n'),
                "page-number" | "date-time" | "creator" | "date" if !empty => skipped += 1,
                _ => {}
            },
            Event::Close(name) => match local(&name) {
                "p" | "h" => {
                    in_paragraph -= 1;
                    let text = paragraph.trim();
                    if !text.is_empty() {
                        out.line(text);
                    }
                    paragraph.clear();
                }
                "page-number" | "date-time" | "creator" | "date" => skipped -= 1,
                _ => {}
            },
            Event::Text(range, raw) => {
                if in_paragraph > 0 && skipped == 0 {
                    paragraph.push_str(&scan.string(range, raw));
                }
            }
        }
    }
}

// ------------------------------------------------------------------ scanner

enum Event {
    Open {
        name: String,
        attributes: std::ops::Range<usize>,
        empty: bool,
    },
    Close(String),
    /// Text between tags; `raw` for CDATA, whose `&` is a plain `&`.
    Text(std::ops::Range<usize>, bool),
}

/// A small XML reader for the parts of Office files (`XMLScanner`): no DTDs, and
/// namespace prefixes stay in the names.
struct XmlScanner<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> XmlScanner<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, position: 0 }
    }

    fn next_event(&mut self) -> Option<Event> {
        let bytes = self.bytes;
        while self.position < bytes.len() {
            let start = self.position;
            if bytes[start] != b'<' {
                while self.position < bytes.len() && bytes[self.position] != b'<' {
                    self.position += 1;
                }
                return Some(Event::Text(start..self.position, false));
            }
            if bytes[start..].starts_with(b"<![CDATA[") {
                let end = find(bytes, b"]]>", start + 9).unwrap_or(bytes.len());
                self.position = (end + 3).min(bytes.len());
                return Some(Event::Text(start + 9..end, true));
            }
            if bytes[start..].starts_with(b"<!--") {
                self.position =
                    (find(bytes, b"-->", start + 4).unwrap_or(bytes.len()) + 3).min(bytes.len());
                continue;
            }
            // The tag's end: the first `>` outside quotes.
            let (mut end, mut quote) = (start + 1, 0u8);
            while end < bytes.len() {
                let byte = bytes[end];
                if quote != 0 {
                    if byte == quote {
                        quote = 0;
                    }
                } else if byte == b'"' || byte == b'\'' {
                    quote = byte;
                } else if byte == b'>' {
                    break;
                }
                end += 1;
            }
            self.position = (end + 1).min(bytes.len());
            if start + 1 >= end || end > bytes.len() {
                continue;
            }
            let first = bytes[start + 1];
            if first == b'?' || first == b'!' {
                continue;
            }
            let closing = first == b'/';
            let name_start = start + if closing { 2 } else { 1 };
            let mut name_end = name_start;
            while name_end < end && !is_space(bytes[name_end]) && bytes[name_end] != b'/' {
                name_end += 1;
            }
            let name = String::from_utf8_lossy(&bytes[name_start..name_end]).into_owned();
            if closing {
                return Some(Event::Close(name));
            }
            let empty = bytes[end - 1] == b'/';
            return Some(Event::Open {
                name,
                attributes: name_end..if empty { end - 1 } else { end },
                empty,
            });
        }
        None
    }

    /// The value of attribute `name`. A name starting with ":" matches any
    /// prefix (":id" finds "r:id" but not "id").
    fn attribute(&self, name: &str, attributes: std::ops::Range<usize>) -> Option<String> {
        let bytes = self.bytes;
        let wanted = name.as_bytes();
        let any_prefix = name.starts_with(':');
        let mut i = attributes.start;
        let end = attributes.end.min(bytes.len());
        while i < end {
            while i < end && is_space(bytes[i]) {
                i += 1;
            }
            let key_start = i;
            while i < end && bytes[i] != b'=' && !is_space(bytes[i]) {
                i += 1;
            }
            let key = &bytes[key_start..i];
            while i < end && (is_space(bytes[i]) || bytes[i] == b'=') {
                i += 1;
            }
            if i >= end {
                return None;
            }
            let quote = bytes[i];
            if quote != b'"' && quote != b'\'' {
                return None;
            }
            let value_start = i + 1;
            i = value_start;
            while i < end && bytes[i] != quote {
                i += 1;
            }
            let matches = if any_prefix {
                key.len() > wanted.len() && key.ends_with(wanted)
            } else {
                key == wanted
            };
            if matches {
                return Some(self.string(value_start..i.min(end), false));
            }
            i += 1;
        }
        None
    }

    /// Text or an attribute's value, with `&amp;`, `&#233;` and the like decoded.
    fn string(&self, range: std::ops::Range<usize>, raw: bool) -> String {
        let text = String::from_utf8_lossy(&self.bytes[range]);
        if raw || !text.contains('&') {
            return text.into_owned();
        }
        let mut out = String::with_capacity(text.len());
        let mut rest: &str = &text;
        while let Some(amp) = rest.find('&') {
            out.push_str(&rest[..amp]);
            let after = &rest[amp + 1..];
            let window: String = after.chars().take(11).collect();
            let decoded = window.find(';').and_then(|semicolon| {
                let entity = &window[..semicolon];
                let value = match entity {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    _ => match entity
                        .strip_prefix("#x")
                        .or_else(|| entity.strip_prefix("#X"))
                    {
                        Some(hex) => u32::from_str_radix(hex, 16).ok().and_then(char::from_u32),
                        None => entity
                            .strip_prefix('#')
                            .and_then(|n| n.parse().ok())
                            .and_then(char::from_u32),
                    },
                };
                value.map(|c| (c, semicolon))
            });
            match decoded {
                Some((c, semicolon)) => {
                    out.push(c);
                    rest = &after[semicolon + 1..];
                }
                None => {
                    out.push('&');
                    rest = after;
                }
            }
        }
        out.push_str(rest);
        out
    }
}

fn is_space(byte: u8) -> bool {
    matches!(byte, 0x20 | 0x09 | 0x0A | 0x0D)
}

fn find(bytes: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    bytes
        .get(from..)?
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|at| at + from)
}

// ---------------------------------------------------------------------- rtf

const RTF_SKIPPED_GROUPS: &[&str] = &[
    "fonttbl",
    "colortbl",
    "stylesheet",
    "info",
    "pict",
    "header",
    "footer",
    "headerl",
    "headerr",
    "footerl",
    "footerr",
    "listtable",
    "listoverridetable",
    "rsidtbl",
    "generator",
    "themedata",
    "colorschememapping",
    "datastore",
    "xmlnstbl",
    "latentstyles",
    "pgdsctbl",
    "filetbl",
    "revtbl",
    "mmathPr",
    "fldinst",
    "object",
];

/// Rich Text Format, read for its words: control words dropped (paragraphs and
/// lines kept as line breaks), escapes decoded, destination groups skipped.
pub fn rtf_text(rtf: &str) -> String {
    let chars: Vec<char> = rtf.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let mut skip_depth = 0i32;
    let mut unicode_skip = 1usize;
    let mut pending_skip = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if skip_depth > 0 {
            match c {
                '{' => skip_depth += 1,
                '}' => skip_depth -= 1,
                '\\' => i += 1,
                _ => {}
            }
            i += 1;
            continue;
        }
        match c {
            '{' => {
                let mut j = i + 1;
                if chars.get(j) == Some(&'\\') {
                    j += 1;
                    if chars.get(j) == Some(&'*') {
                        skip_depth = 1;
                        i = j + 1;
                        continue;
                    }
                    let mut word = String::new();
                    while j < chars.len() && chars[j].is_ascii_alphabetic() && word.len() < 32 {
                        word.push(chars[j]);
                        j += 1;
                    }
                    if RTF_SKIPPED_GROUPS.contains(&word.as_str()) {
                        skip_depth = 1;
                        i = j;
                        continue;
                    }
                }
                i += 1;
            }
            '}' => i += 1,
            '\\' => {
                i += 1;
                let Some(&next) = chars.get(i) else {
                    break;
                };
                if next == '\'' {
                    let hex: String = chars.iter().skip(i + 1).take(2).collect();
                    if hex.len() == 2 && u8::from_str_radix(&hex, 16).is_ok() {
                        let byte = u8::from_str_radix(&hex, 16).unwrap_or(0);
                        if pending_skip > 0 {
                            pending_skip -= 1;
                        } else {
                            out.push(windows_1252(byte));
                        }
                        i += 3;
                    } else {
                        i += 1;
                    }
                } else if next.is_ascii_alphabetic() {
                    let (mut word, mut number) = (String::new(), String::new());
                    let mut j = i;
                    while j < chars.len() && chars[j].is_ascii_alphabetic() {
                        word.push(chars[j]);
                        j += 1;
                    }
                    if chars.get(j) == Some(&'-') {
                        number.push('-');
                        j += 1;
                    }
                    while j < chars.len() && chars[j].is_ascii_digit() {
                        number.push(chars[j]);
                        j += 1;
                    }
                    if chars.get(j) == Some(&' ') {
                        j += 1;
                    }
                    match word.as_str() {
                        "par" | "line" | "sect" | "page" | "row" => out.push('\n'),
                        "tab" | "cell" => out.push('\t'),
                        "emdash" => out.push('—'),
                        "endash" => out.push('–'),
                        "lquote" => out.push('‘'),
                        "rquote" => out.push('’'),
                        "ldblquote" => out.push('“'),
                        "rdblquote" => out.push('”'),
                        "bullet" => out.push('•'),
                        "uc" => unicode_skip = number.parse().unwrap_or(1),
                        "u" => {
                            // A signed 16-bit value; negative ones wrap.
                            if let Ok(value) = number.parse::<i32>()
                                && (-65536..65536).contains(&value)
                            {
                                let code = if value < 0 { value + 65536 } else { value };
                                if let Some(scalar) = char::from_u32(code as u32) {
                                    out.push(scalar);
                                }
                            }
                            pending_skip = unicode_skip;
                        }
                        _ => {}
                    }
                    i = j;
                } else {
                    match next {
                        '\\' | '{' | '}' => out.push(next),
                        '~' => out.push(' '),
                        '\n' | '\r' => out.push('\n'),
                        _ => {}
                    }
                    i += 1;
                }
            }
            '\r' | '\n' => i += 1,
            _ => {
                if pending_skip > 0 {
                    pending_skip -= 1;
                } else {
                    out.push(c);
                }
                i += 1;
            }
        }
    }
    out
}

/// Windows-1252's upper half; the rest is Latin-1.
fn windows_1252(byte: u8) -> char {
    const SPECIALS: [(u8, u32); 27] = [
        (0x80, 0x20AC),
        (0x82, 0x201A),
        (0x83, 0x0192),
        (0x84, 0x201E),
        (0x85, 0x2026),
        (0x86, 0x2020),
        (0x87, 0x2021),
        (0x88, 0x02C6),
        (0x89, 0x2030),
        (0x8A, 0x0160),
        (0x8B, 0x2039),
        (0x8C, 0x0152),
        (0x8E, 0x017D),
        (0x91, 0x2018),
        (0x92, 0x2019),
        (0x93, 0x201C),
        (0x94, 0x201D),
        (0x95, 0x2022),
        (0x96, 0x2013),
        (0x97, 0x2014),
        (0x98, 0x02DC),
        (0x99, 0x2122),
        (0x9A, 0x0161),
        (0x9B, 0x203A),
        (0x9C, 0x0153),
        (0x9E, 0x017E),
        (0x9F, 0x0178),
    ];
    SPECIALS
        .iter()
        .find(|(b, _)| *b == byte)
        .and_then(|(_, code)| char::from_u32(*code))
        .unwrap_or(byte as char)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn zip_file(dir: &Path, name: &str, entries: &[(&str, &str)]) -> std::path::PathBuf {
        let path = dir.join(name);
        let file = std::fs::File::create(&path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        for (entry, body) in entries {
            writer
                .start_file(*entry, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(body.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
        path
    }

    #[test]
    fn html_keeps_the_words_and_their_breaks() {
        let html = "<html><head><title>x</title></head><body><script>var a=1;</script>\
                    <h1>Plan</h1><p>Fish &amp; chips&nbsp;&#233;&#xe9;</p><!-- no -->\
                    <style>p{}</style><div>Done</div></body></html>";
        assert_eq!(plain_text_from_html(html), "Plan\nFish & chips éé\nDone");
    }

    #[test]
    fn rtf_keeps_words_and_drops_control() {
        let rtf = r"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\*\generator Word;}\f0 Hello\par W\'f6rld \u269?a\tab b\emdash{}c}";
        assert_eq!(rtf_text(rtf), "Hello\nWörld ča\tb—c");
    }

    #[test]
    fn plain_text_decodes_what_it_can() {
        assert_eq!(decode_text(b"\xEF\xBB\xBFplain"), "plain");
        assert_eq!(decode_text(&[0xFF, 0xFE, b'h', 0, b'i', 0]), "hi");
        assert_eq!(decode_text(&[0xFE, 0xFF, 0, b'h', 0, b'i']), "hi");
        assert_eq!(decode_text(&[b'c', b'a', b'f', 0xE9]), "café");
    }

    #[test]
    fn docx_and_odt_come_from_their_xml() {
        let dir = tempfile::tempdir().unwrap();
        let docx = zip_file(
            dir.path(),
            "a.docx",
            &[(
                "word/document.xml",
                r#"<w:document><w:body><w:p><w:r><w:t>First</w:t><w:tab/><w:t>para</w:t></w:r></w:p><w:p><w:r><w:t>Second &amp; last</w:t></w:r></w:p></w:body></w:document>"#,
            )],
        );
        assert_eq!(text_of(&docx).unwrap(), "First para\nSecond & last");
        let odt = zip_file(
            dir.path(),
            "a.odt",
            &[(
                "content.xml",
                r#"<office:text><text:h>Title</text:h><text:p>One<text:s/>two</text:p></office:text>"#,
            )],
        );
        assert_eq!(text_of(&odt).unwrap(), "Title\nOne two");
        let doc = dir.path().join("a.doc");
        std::fs::write(&doc, b"x").unwrap();
        assert!(text_of(&doc).is_err());
        let not_zip = dir.path().join("b.docx");
        std::fs::write(&not_zip, b"not a zip").unwrap();
        assert_eq!(
            text_of(&not_zip),
            Err(ReadError::Unreadable("not a zip file".into()))
        );
    }

    #[test]
    fn a_workbook_comes_out_sheet_by_sheet() {
        let dir = tempfile::tempdir().unwrap();
        let path = zip_file(
            dir.path(),
            "a.xlsx",
            &[
                (
                    "_rels/.rels",
                    r#"<Relationships><Relationship Id="rId1" Type="http://x/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
                ),
                (
                    "xl/_rels/workbook.xml.rels",
                    r#"<Relationships><Relationship Id="rId1" Type="http://x/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://x/sharedStrings" Target="sharedStrings.xml"/></Relationships>"#,
                ),
                (
                    "xl/workbook.xml",
                    r#"<workbook><sheets><sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
                ),
                (
                    "xl/sharedStrings.xml",
                    r#"<sst><si><t>Rent</t></si><si><r><t>Fo</t></r><r><t>od</t></r><rPh><t>x</t></rPh></si></sst>"#,
                ),
                (
                    "xl/worksheets/sheet1.xml",
                    r#"<worksheet><sheetData><row><c t="s"><v>0</v></c><c><v>1200</v></c><c t="b"><v>1</v></c></row><row><c t="s"><v>1</v></c><c t="inlineStr"><is><t>note</t></is></c></row></sheetData></worksheet>"#,
                ),
            ],
        );
        assert_eq!(text_of(&path).unwrap(), "Budget\nRent\t1200\nFood\tnote");
    }

    #[test]
    fn a_presentation_keeps_slide_order_and_notes() {
        let dir = tempfile::tempdir().unwrap();
        let path = zip_file(
            dir.path(),
            "a.pptx",
            &[
                (
                    "ppt/_rels/presentation.xml.rels",
                    r#"<Relationships><Relationship Id="rId2" Type="x/slide" Target="slides/slide2.xml"/><Relationship Id="rId1" Type="x/slide" Target="slides/slide1.xml"/></Relationships>"#,
                ),
                (
                    "ppt/presentation.xml",
                    r#"<p:presentation><p:sldIdLst><p:sldId r:id="rId2"/><p:sldId r:id="rId1"/></p:sldIdLst></p:presentation>"#,
                ),
                (
                    "ppt/slides/slide1.xml",
                    r#"<p:sld><a:p><a:r><a:t>Later</a:t></a:r></a:p></p:sld>"#,
                ),
                (
                    "ppt/slides/slide2.xml",
                    r#"<p:sld><a:p><a:r><a:t>First</a:t></a:r><a:fld><a:t>9</a:t></a:fld></a:p></p:sld>"#,
                ),
                (
                    "ppt/slides/_rels/slide2.xml.rels",
                    r#"<Relationships><Relationship Id="rId1" Type="x/notesSlide" Target="../notesSlides/n.xml"/></Relationships>"#,
                ),
                (
                    "ppt/notesSlides/n.xml",
                    r#"<p:notes><a:p><a:r><a:t>Say this</a:t></a:r></a:p></p:notes>"#,
                ),
            ],
        );
        assert_eq!(text_of(&path).unwrap(), "First\nSay this\n\nLater");
    }

    #[test]
    fn opendocument_sheets_and_slides() {
        let dir = tempfile::tempdir().unwrap();
        let ods = zip_file(
            dir.path(),
            "a.ods",
            &[(
                "content.xml",
                r#"<table:table table:name="S"><table:table-row><table:table-cell office:value-type="string"><text:p>Cell</text:p></table:table-cell><table:table-cell office:value-type="boolean"><text:p>TRUE</text:p></table:table-cell></table:table-row></table:table>"#,
            )],
        );
        assert_eq!(text_of(&ods).unwrap(), "S\nCell");
        let odp = zip_file(
            dir.path(),
            "a.odp",
            &[(
                "content.xml",
                r#"<draw:page><text:p>Hello<text:s/>there</text:p><text:p><text:page-number>3</text:page-number></text:p></draw:page><draw:page><text:p>Next</text:p></draw:page>"#,
            )],
        );
        assert_eq!(text_of(&odp).unwrap(), "Hello there\n\nNext");
    }

    #[test]
    fn a_locked_office_file_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.xlsx");
        std::fs::write(&path, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0]).unwrap();
        assert_eq!(text_of(&path), Err(ReadError::Locked));
    }

    #[test]
    fn targets_resolve_against_their_folder() {
        assert_eq!(
            resolve_target("../notesSlides/n.xml", "ppt/slides"),
            "ppt/notesSlides/n.xml"
        );
        assert_eq!(resolve_target("/xl/a.xml", "ppt"), "xl/a.xml");
        assert_eq!(resolve_target("./b.xml", "xl"), "xl/b.xml");
    }
}
