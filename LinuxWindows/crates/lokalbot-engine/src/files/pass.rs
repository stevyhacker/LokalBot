//! Extracts and embeds whatever is pending (`Indexer`): pending files first,
//! screenshots first and newest first; long PDFs and documents get their first
//! step, and the rest after everything else. Per-file problems are recorded on the
//! file; a server that can't answer stops the pass, and files stay pending.

use std::collections::{BTreeMap, HashSet};
use std::path::Path;
use std::time::Instant;

use anyhow::Result;
use lokalbot_ai::media_embedder::{MediaEmbedder, MediaError};
use lokalbot_core::files::costs::MeasuredCosts;
use lokalbot_core::files::index::{FileIndex, FileRecord};
use lokalbot_core::files::text::{chunks, excerpt, has_prose};
use lokalbot_core::files::{FileKind, IndexOptions, Modality, SegmentKind, document_prompt};

use super::documents::{self, ReadError};
use super::image_sizing;
use super::media::{self, ImageFailure};
use super::pdf;

/// The model calls a pass makes. One at a time, and they wait.
pub trait Embed {
    fn source(&self) -> String;
    fn embed_texts(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, MediaError>;
    fn embed_image(&self, png: &[u8]) -> Result<Vec<f32>, MediaError>;
    fn embed_audio(&self, wav: &[u8]) -> Result<Vec<f32>, MediaError>;
}

impl Embed for MediaEmbedder {
    fn source(&self) -> String {
        lokalbot_ai::media_embedder::vector_source()
    }

    fn embed_texts(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, MediaError> {
        MediaEmbedder::embed_texts(self, texts)
    }

    fn embed_image(&self, png: &[u8]) -> Result<Vec<f32>, MediaError> {
        MediaEmbedder::embed_image(self, png)
    }

    fn embed_audio(&self, wav: &[u8]) -> Result<Vec<f32>, MediaError> {
        MediaEmbedder::embed_audio(self, wav)
    }
}

/// Screenshots' words, for keyword search. Without the model there are no words:
/// a screenshot then has its picture vector and its name.
pub trait ReadText {
    fn text_of(&mut self, rgb: &image_sizing::Rgb) -> String;
}

/// Reads no words.
pub struct NoText;

impl ReadText for NoText {
    fn text_of(&mut self, _rgb: &image_sizing::Rgb) -> String {
        String::new()
    }
}

/// What a pass was stopped by: the embedder went away. Files stay pending.
#[derive(Debug)]
pub struct WorkerGone(pub String);

impl std::fmt::Display for WorkerGone {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for WorkerGone {}

fn gone(err: MediaError) -> anyhow::Error {
    WorkerGone(err.to_string()).into()
}

/// How a call to the model ended, for one file.
enum Outcome<T> {
    Ok(T),
    /// This input fails alone.
    Rejected(String),
}

fn outcome<T>(result: Result<T, MediaError>) -> Result<Outcome<T>> {
    match result {
        Ok(value) => Ok(Outcome::Ok(value)),
        Err(MediaError::Rejected(why)) => Ok(Outcome::Rejected(why)),
        Err(err @ MediaError::Unavailable(_)) => Err(gone(err)),
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PassOutcome {
    pub files_read: usize,
    /// Seconds the model and the readers worked.
    pub seconds: f64,
    /// Files still waiting afterwards.
    pub left: usize,
}

/// Progress from a pass.
pub enum PassProgress {
    Files { done: usize, total: usize },
    LongFiles { left: usize },
}

/// One job's worth of reading, done ahead of the model.
enum Payload {
    Nothing,
    Images(Vec<ReadyImage>),
    Pdf {
        pages: Vec<pdf::Page>,
        read: std::ops::Range<usize>,
        total: usize,
        title: Option<String>,
    },
    Doc {
        chunks: Vec<String>,
        read: std::ops::Range<usize>,
        total: usize,
        characters: usize,
    },
    /// Decoded while the model embeds, a window at a time: long recordings never
    /// sit in memory whole.
    Audio,
    Video,
}

struct ReadyImage {
    slot: usize,
    png: Vec<u8>,
    width: usize,
    height: usize,
    taken: Option<String>,
    words: String,
}

struct Prepared {
    payload: Payload,
    /// Files already settled while reading: slot, state, detail.
    outcomes: Vec<(usize, &'static str, String)>,
}

struct Job {
    files: Vec<FileRecord>,
    /// A long file's later step (`Job.step`): the pages or chunks to read, from 0.
    step: Option<std::ops::Range<usize>>,
}

/// Images and screenshots go to the model 8 at a time; other files one by one.
fn batches(queue: Vec<FileRecord>) -> Vec<Vec<FileRecord>> {
    let mut out: Vec<Vec<FileRecord>> = Vec::new();
    for file in queue {
        match out.last_mut() {
            Some(batch)
                if matches!(file.kind, FileKind::Image | FileKind::Screenshot)
                    && batch.len() < 8
                    && batch[0].kind == file.kind =>
            {
                batch.push(file);
            }
            _ => out.push(vec![file]),
        }
    }
    out
}

/// A scan, or a page that's mostly a picture: its words come from OCR, for keyword
/// search only (an invoice number on a scan, as on a screenshot), and its meaning stays
/// the picture's vector. Not for a text layer that came out in glyph order, which OCR
/// can't read either.
fn read_scan(page: &mut pdf::Page, budget: u32, words: &mut dyn ReadText) {
    let Some(scan) = page.scan.take() else {
        return;
    };
    if page.garbled.is_none() {
        let read = words.text_of(&scan);
        let read = read.trim();
        if read.chars().count() > page.text.chars().count() {
            page.text = read.to_string();
        }
    }
    match image_sizing::png(&scan, budget) {
        Ok(png) => page.picture = Some(png),
        Err(err) => log::debug!("file search: page {} has no picture: {err}", page.number),
    }
}

/// A pass's source of decoded long documents, kept while their steps go by: the
/// PDF parser reads a whole file at a time.
#[derive(Default)]
struct PdfCache {
    path: String,
    document: Option<pdf::Document>,
}

impl PdfCache {
    fn get(&mut self, path: &str) -> Result<&pdf::Document, ReadError> {
        if self.path != path || self.document.is_none() {
            self.document = Some(pdf::read(Path::new(path))?);
            self.path = path.to_string();
        }
        Ok(self.document.as_ref().expect("read above"))
    }
}

fn prepare(
    job: &Job,
    options: &IndexOptions,
    words: &mut dyn ReadText,
    pdfs: &mut PdfCache,
) -> Prepared {
    let first = &job.files[0];
    let mut outcomes = Vec::new();
    let failed = |err: ReadError, outcomes: &mut Vec<_>| {
        outcomes.push((0, "failed", err.to_string()));
        Payload::Nothing
    };
    let payload = match first.kind {
        FileKind::Image | FileKind::Screenshot => {
            let screenshot = first.kind == FileKind::Screenshot;
            let budget = if screenshot {
                options.screenshot_budget
            } else {
                options.photo_budget
            };
            let mut ready = Vec::new();
            for (slot, file) in job.files.iter().enumerate() {
                match media::decode_image(Path::new(&file.path), options.min_image_side) {
                    Ok(decoded) => match image_sizing::png(&decoded.image, budget) {
                        Ok(png) => {
                            let text = if screenshot {
                                words.text_of(&decoded.image)
                            } else {
                                String::new()
                            };
                            ready.push(ReadyImage {
                                slot,
                                png,
                                width: decoded.width,
                                height: decoded.height,
                                taken: decoded.taken,
                                words: text,
                            });
                        }
                        Err(err) => outcomes.push((slot, "failed", format!("unreadable: {err}"))),
                    },
                    Err(err @ ImageFailure::TooSmall(..)) => {
                        outcomes.push((slot, "skipped", err.to_string()));
                    }
                    Err(err) => outcomes.push((slot, "failed", err.to_string())),
                }
            }
            Payload::Images(ready)
        }
        FileKind::Pdf => match pdfs.get(&first.path) {
            Ok(document) => {
                let total = document.pages.len();
                let wanted = job
                    .step
                    .clone()
                    .unwrap_or(if total > options.big_pdf_pages {
                        0..options.pdf_step
                    } else {
                        0..options.max_pages
                    });
                let end = total.min(options.max_pages);
                let read = wanted.start.min(end)..wanted.end.min(end);
                let mut pages = pdf::pages_in(
                    document,
                    read.clone(),
                    options.min_page_text,
                    options.min_image_side,
                );
                for page in &mut pages {
                    read_scan(page, options.page_budget, words);
                }
                Payload::Pdf {
                    pages,
                    read,
                    total,
                    title: document.title.clone(),
                }
            }
            Err(err) => failed(err, &mut outcomes),
        },
        FileKind::Doc => match documents::text_of(Path::new(&first.path)) {
            Ok(text) => {
                let all = chunks(&text, options.max_chunks + 1);
                let wanted = job.step.clone().unwrap_or(0..options.doc_step);
                let end = all.len().min(options.max_chunks);
                let read = wanted.start.min(end)..wanted.end.min(end);
                Payload::Doc {
                    chunks: all[read.clone()].to_vec(),
                    read,
                    total: all.len(),
                    characters: text.chars().count(),
                }
            }
            Err(err) => failed(err, &mut outcomes),
        },
        FileKind::Audio => Payload::Audio,
        FileKind::Video => Payload::Video,
        FileKind::Code => {
            outcomes.push((0, "skipped", "code isn't read here".to_string()));
            Payload::Nothing
        }
    };
    Prepared { payload, outcomes }
}

/// One pass over one index.
pub struct Pass<'a> {
    pub index: &'a FileIndex,
    pub options: &'a IndexOptions,
    pub embedder: &'a dyn Embed,
    pub words: &'a mut dyn ReadText,
    pub scratch: &'a Path,
    measured: MeasuredCosts,
    embedding_started: bool,
    pdfs: PdfCache,
}

impl<'a> Pass<'a> {
    pub fn new(
        index: &'a FileIndex,
        options: &'a IndexOptions,
        embedder: &'a dyn Embed,
        words: &'a mut dyn ReadText,
        scratch: &'a Path,
    ) -> Self {
        Self {
            index,
            options,
            embedder,
            words,
            scratch,
            measured: MeasuredCosts::default(),
            embedding_started: false,
            pdfs: PdfCache::default(),
        }
    }

    fn fingerprint(&self) -> String {
        format!(
            "{} | {}",
            self.embedder.source(),
            self.options.fingerprint()
        )
    }

    /// Compares the index with the current model and settings; a change empties
    /// it, since vectors from different settings can't be compared.
    pub fn check_model(&self) -> Result<()> {
        let now = self.fingerprint();
        if let Some(indexed) = self.index.meta("fingerprint")?
            && indexed != now
        {
            log::info!(
                "file search: vectors changed ({indexed} → {now}); reading every file again"
            );
            self.index.reset_all()?;
        }
        Ok(())
    }

    /// Set once the model has made something: the index now holds its vectors.
    fn note_embedding(&mut self) -> Result<()> {
        if !self.embedding_started {
            self.check_model()?;
            self.index
                .set_meta("fingerprint", Some(&self.fingerprint()))?;
            self.index
                .set_meta("vector_source", Some(&self.embedder.source()))?;
            self.embedding_started = true;
        }
        Ok(())
    }

    /// Processes pending files (`only`: just these). Returns how many were read.
    pub fn run(
        &mut self,
        only: Option<&HashSet<i64>>,
        should_stop: &mut dyn FnMut() -> bool,
        progress: &mut dyn FnMut(PassProgress),
    ) -> Result<(usize, f64)> {
        let queue = self.index.pending(only)?;
        let total = queue.len();
        let jobs: Vec<Job> = batches(queue)
            .into_iter()
            .map(|files| Job { files, step: None })
            .collect();
        let (mut done, mut read, mut seconds) = (0, 0, 0.0);
        for job in jobs {
            if should_stop() {
                break;
            }
            let started = Instant::now();
            let prepared = prepare(&job, self.options, &mut *self.words, &mut self.pdfs);
            let model_was_running = self.embedding_started;
            let settled = self.commit(&job, prepared)?;
            let spent = started.elapsed().as_secs_f64();
            seconds += spent;
            if model_was_running {
                self.measure(&job, &settled, spent);
            }
            done += job.files.len();
            read += settled.len();
            progress(PassProgress::Files { done, total });
        }
        self.save_costs();
        Ok((read, seconds))
    }

    /// The later pass: the rest of long PDFs and documents, a step at a time.
    /// Each step is saved as one transaction, so stopping loses nothing.
    pub fn finish_long_files(
        &mut self,
        should_stop: &mut dyn FnMut() -> bool,
        progress: &mut dyn FnMut(PassProgress),
    ) -> Result<f64> {
        let mut jobs = Vec::new();
        for file in self.index.unfinished()? {
            let info = self.index.info(file.id)?;
            let size = if file.kind == FileKind::Pdf {
                self.options.pdf_step
            } else {
                self.options.doc_step
            };
            let mut start = match info.get("read_to").and_then(|v| v.parse().ok()) {
                Some(place) => place,
                None => self.index.last_place(file.id)?.unwrap_or(0),
            };
            let end = info
                .get("read_end")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(0)
                .max(start + 1);
            while start < end {
                jobs.push(Job {
                    files: vec![file.clone()],
                    step: Some(start..(start + size).min(end)),
                });
                start += size;
            }
        }
        let mut files_left = jobs
            .iter()
            .map(|job| job.files[0].id)
            .collect::<HashSet<_>>()
            .len();
        let mut finished: HashSet<i64> = HashSet::new();
        let mut seconds = 0.0;
        for job in jobs {
            let file_id = job.files[0].id;
            if finished.contains(&file_id) {
                continue;
            }
            if should_stop() {
                break;
            }
            let started = Instant::now();
            let prepared = prepare(&job, self.options, &mut *self.words, &mut self.pdfs);
            let state = if let Some((_, _, why)) = prepared.outcomes.first().cloned() {
                self.stop_reading(&job, &why)?
            } else {
                self.commit(&job, prepared)?;
                self.index
                    .info(file_id)?
                    .get("read_to")
                    .map_or("done", |_| "partial")
            };
            seconds += started.elapsed().as_secs_f64();
            if state != "partial" && finished.insert(file_id) {
                files_left -= 1;
            }
            progress(PassProgress::LongFiles { left: files_left });
        }
        self.save_costs();
        Ok(seconds)
    }

    fn save_costs(&mut self) {
        if !self.measured.tallies.is_empty() {
            MeasuredCosts::merge(&self.measured, self.index.directory());
            self.measured = MeasuredCosts::default();
        }
    }

    /// A long file that can't be read any further keeps what was read of it.
    fn stop_reading(&self, job: &Job, why: &str) -> Result<&'static str> {
        let file = &job.files[0];
        let place = job.step.as_ref().map_or(0, |step| step.start);
        let mut info = self.index.info(file.id)?;
        info.remove("read_to");
        info.remove("read_end");
        let unit = if file.kind == FileKind::Pdf {
            "page"
        } else {
            "chunk"
        };
        self.index.finish(
            file.id,
            "done",
            Some(&format!("read to {unit} {place}, not after: {why}")),
            &info,
        )?;
        Ok("done")
    }

    /// Writes one job's results. Returns the slots read; a server that can't
    /// answer stops the pass.
    fn commit(&mut self, job: &Job, prepared: Prepared) -> Result<Vec<usize>> {
        let mut read: Vec<usize> = Vec::new();
        for (slot, state, detail) in &prepared.outcomes {
            self.index
                .finish(job.files[*slot].id, state, Some(detail), &BTreeMap::new())?;
        }
        match prepared.payload {
            Payload::Nothing => {}
            Payload::Images(ready) => {
                read = self.images(&job.files, ready)?;
            }
            Payload::Pdf {
                pages,
                read: range,
                total,
                title,
            } => {
                self.pdf(
                    &job.files[0],
                    &pages,
                    range,
                    total,
                    title,
                    job.step.is_some(),
                )?;
                read.push(0);
            }
            Payload::Doc {
                chunks,
                read: range,
                total,
                characters,
            } => {
                self.doc(&job.files[0], &chunks, range, total, characters)?;
                read.push(0);
            }
            Payload::Audio => {
                self.audio(&job.files[0])?;
                read.push(0);
            }
            Payload::Video => {
                self.video(&job.files[0])?;
                read.push(0);
            }
        }
        Ok(read)
    }

    fn measure(&mut self, job: &Job, read: &[usize], seconds: f64) {
        let first = &job.files[0];
        match first.kind {
            FileKind::Screenshot => self.measured.add("screenshot", read.len() as f64, seconds),
            FileKind::Image => self.measured.add("image", read.len() as f64, seconds),
            FileKind::Pdf => {
                if let Some(step) = &job.step {
                    self.measured.add("pdfPage", step.len() as f64, seconds);
                }
            }
            FileKind::Doc => {
                if let Some(step) = &job.step {
                    self.measured.add("docChunk", step.len() as f64, seconds);
                }
            }
            _ => {}
        }
    }

    fn images(&mut self, batch: &[FileRecord], ready: Vec<ReadyImage>) -> Result<Vec<usize>> {
        if ready.is_empty() {
            return Ok(Vec::new());
        }
        self.note_embedding()?;
        let mut read = Vec::new();
        let mut vectors = Vec::with_capacity(ready.len());
        for item in &ready {
            vectors.push(outcome(self.embedder.embed_image(&item.png))?);
        }
        self.index.transaction(|| {
            for (item, vector) in ready.iter().zip(&vectors) {
                let file = &batch[item.slot];
                let vector = match vector {
                    Outcome::Ok(vector) => vector,
                    Outcome::Rejected(why) => {
                        self.index
                            .finish(file.id, "failed", Some(why), &BTreeMap::new())?;
                        continue;
                    }
                };
                self.index.add_segment(
                    file.id,
                    SegmentKind::Image,
                    Modality::Image,
                    None,
                    None,
                    None,
                    None,
                    Some(vector),
                )?;
                // The words on screen are for keyword search: codes, names and
                // errors typed exactly. Meaning comes from the picture alone.
                if !item.words.is_empty() {
                    self.index.add_segment(
                        file.id,
                        SegmentKind::Ocr,
                        Modality::Text,
                        None,
                        None,
                        Some(&excerpt(&item.words, 240)),
                        Some(&item.words),
                        None,
                    )?;
                }
                let mut info = BTreeMap::from([
                    ("width".to_string(), item.width.to_string()),
                    ("height".to_string(), item.height.to_string()),
                ]);
                if let Some(taken) = &item.taken {
                    info.insert("taken".into(), taken.clone());
                }
                if file.kind == FileKind::Screenshot {
                    info.insert("ocr_chars".into(), item.words.chars().count().to_string());
                }
                self.index.finish(file.id, "done", None, &info)?;
                read.push(item.slot);
            }
            Ok(())
        })?;
        Ok(read)
    }

    /// Pages `read` of a PDF. A long one stays `partial` with `read_to` and
    /// `read_end` in its info until its last step.
    fn pdf(
        &mut self,
        file: &FileRecord,
        pages: &[pdf::Page],
        read: std::ops::Range<usize>,
        total: usize,
        title: Option<String>,
        later: bool,
    ) -> Result<()> {
        let end = total.min(self.options.max_pages);
        let unread = read.end < end;
        if pages.is_empty() && !later && !unread {
            return self
                .index
                .finish(file.id, "skipped", Some("no pages"), &BTreeMap::new());
        }
        let title = title.unwrap_or_else(|| stem(&file.path));
        let worded: Vec<&pdf::Page> = pages
            .iter()
            .filter(|page| {
                page.picture.is_none() && page.garbled.is_none() && has_prose(&page.text)
            })
            .collect();
        let pictured: Vec<&pdf::Page> =
            pages.iter().filter(|page| page.picture.is_some()).collect();
        let garbled: Vec<&pdf::Page> = pages.iter().filter(|page| page.garbled.is_some()).collect();
        let text_prompts: Vec<String> = worded
            .iter()
            .map(|page| document_prompt(Some(&title), &first_chars(&page.text, 4000)))
            .collect();
        let garbled_prompts: Vec<String> = garbled
            .iter()
            .map(|page| {
                document_prompt(
                    Some(&title),
                    &first_chars(page.garbled.as_deref().unwrap_or(""), 4000),
                )
            })
            .collect();
        let needs_model =
            !text_prompts.is_empty() || !garbled_prompts.is_empty() || !pictured.is_empty();
        if needs_model {
            self.note_embedding()?;
        }
        let text_vectors = if text_prompts.is_empty() {
            Vec::new()
        } else {
            self.embedder.embed_texts(&text_prompts).map_err(gone)?
        };
        let garbled_vectors = if garbled_prompts.is_empty() {
            Vec::new()
        } else {
            self.embedder.embed_texts(&garbled_prompts).map_err(gone)?
        };
        let mut picture_vectors = Vec::with_capacity(pictured.len());
        for page in &pictured {
            picture_vectors.push(outcome(
                self.embedder
                    .embed_image(page.picture.as_deref().unwrap_or_default()),
            )?);
        }
        let vector_of = |number: usize| {
            worded
                .iter()
                .position(|page| page.number == number)
                .and_then(|at| text_vectors.get(at))
        };
        self.index.transaction(|| {
            // Meaning only: the garbled words are never shown or matched.
            for (page, vector) in garbled.iter().zip(&garbled_vectors) {
                self.index.add_segment(
                    file.id,
                    SegmentKind::Page,
                    Modality::Text,
                    Some(page.number as f64),
                    None,
                    None,
                    None,
                    Some(vector),
                )?;
            }
            for page in pages
                .iter()
                .filter(|page| page.garbled.is_none() && page.picture.is_none())
            {
                if page.text.is_empty() {
                    continue;
                }
                self.index.add_segment(
                    file.id,
                    SegmentKind::Page,
                    Modality::Text,
                    Some(page.number as f64),
                    None,
                    Some(&excerpt(&page.text, 240)),
                    Some(&page.text),
                    vector_of(page.number).map(Vec::as_slice),
                )?;
            }
            let mut info = if later {
                self.index.info(file.id)?
            } else {
                BTreeMap::new()
            };
            for (page, vector) in pictured.iter().zip(&picture_vectors) {
                let vector = match vector {
                    Outcome::Ok(vector) => Some(vector.as_slice()),
                    // The picture fails alone; any words still count.
                    Outcome::Rejected(why) => {
                        log::debug!("file search: page {} rejected: {why}", page.number);
                        None
                    }
                };
                let words = (!page.text.is_empty()).then_some(page.text.as_str());
                if vector.is_none() && words.is_none() {
                    continue;
                }
                self.index.add_segment(
                    file.id,
                    SegmentKind::PageImage,
                    Modality::Image,
                    Some(page.number as f64),
                    None,
                    words.map(|words| excerpt(words, 240)).as_deref(),
                    words,
                    vector,
                )?;
            }
            info.insert("pages".into(), total.to_string());
            let scanned = info
                .get("scanned_pages")
                .and_then(|count| count.parse::<usize>().ok())
                .unwrap_or(0)
                + pictured.len();
            info.insert("scanned_pages".into(), scanned.to_string());
            if unread {
                info.insert("read_to".into(), read.end.to_string());
                info.insert("read_end".into(), end.to_string());
            } else {
                info.remove("read_to");
                info.remove("read_end");
            }
            let detail = if unread {
                Some(format!("read to page {} of {total}", read.end))
            } else if end < total {
                Some(format!("the first {end} of {total} pages"))
            } else {
                None
            };
            self.index.finish(
                file.id,
                if unread { "partial" } else { "done" },
                detail.as_deref(),
                &info,
            )
        })
    }

    /// Chunks `read` of a document, the way `pdf` reads pages.
    fn doc(
        &mut self,
        file: &FileRecord,
        pieces: &[String],
        read: std::ops::Range<usize>,
        total: usize,
        characters: usize,
    ) -> Result<()> {
        if total == 0 {
            return self
                .index
                .finish(file.id, "skipped", Some("no text"), &BTreeMap::new());
        }
        let title = stem(&file.path);
        // Text that's mostly digits gets keyword search only.
        let worded: Vec<usize> = (0..pieces.len())
            .filter(|at| has_prose(&pieces[*at]))
            .collect();
        let vectors = if worded.is_empty() {
            Vec::new()
        } else {
            self.note_embedding()?;
            let prompts: Vec<String> = worded
                .iter()
                .map(|at| document_prompt(Some(&title), &pieces[*at]))
                .collect();
            self.embedder.embed_texts(&prompts).map_err(gone)?
        };
        let end = total.min(self.options.max_chunks);
        let unread = read.end < end;
        self.index.transaction(|| {
            for (offset, chunk) in pieces.iter().enumerate() {
                let vector = worded
                    .iter()
                    .position(|at| *at == offset)
                    .and_then(|at| vectors.get(at));
                self.index.add_segment(
                    file.id,
                    SegmentKind::Chunk,
                    Modality::Text,
                    Some((read.start + offset + 1) as f64),
                    None,
                    Some(&excerpt(chunk, 240)),
                    Some(chunk),
                    vector.map(Vec::as_slice),
                )?;
            }
            let mut info = BTreeMap::from([
                ("chunks".to_string(), end.to_string()),
                ("chars".to_string(), characters.to_string()),
            ]);
            if unread {
                info.insert("read_to".into(), read.end.to_string());
                info.insert("read_end".into(), end.to_string());
            }
            let detail = if unread {
                Some(format!("read to chunk {} of {end}", read.end))
            } else if end < total {
                Some(format!("the first {end} chunks"))
            } else {
                None
            };
            self.index.finish(
                file.id,
                if unread { "partial" } else { "done" },
                detail.as_deref(),
                &info,
            )
        })
    }

    /// A recording's windows, embedded as they are decoded.
    fn embed_sound(&mut self, file: &FileRecord) -> Result<(Vec<Placed>, f64), Failed> {
        let (window, hop) = (self.options.audio_window, self.options.audio_hop);
        let embedder = self.embedder;
        let mut made = Vec::new();
        let mut stopped: Option<anyhow::Error> = None;
        let result =
            media::sound_windows(
                Path::new(&file.path),
                window,
                hop,
                &mut |piece| match outcome(embedder.embed_audio(&piece.bytes)) {
                    Ok(Outcome::Ok(vector)) => {
                        made.push((piece.start, piece.end, vector));
                        true
                    }
                    Ok(Outcome::Rejected(why)) => {
                        log::debug!("file search: a window was refused: {why}");
                        true
                    }
                    Err(err) => {
                        stopped = Some(err);
                        false
                    }
                },
            );
        if let Some(err) = stopped {
            return Err(Failed::Gone(err));
        }
        match result {
            Ok(duration) => Ok((made, duration)),
            Err(err) => Err(Failed::File(err.to_string())),
        }
    }

    fn audio(&mut self, file: &FileRecord) -> Result<()> {
        self.note_embedding()?;
        let started = Instant::now();
        let (windows, duration) = match self.embed_sound(file) {
            Ok(result) => result,
            Err(Failed::File(why)) => {
                return self
                    .index
                    .finish(file.id, "failed", Some(&why), &BTreeMap::new());
            }
            Err(Failed::Gone(err)) => return Err(err),
        };
        self.measured
            .add("audioSecond", duration, started.elapsed().as_secs_f64());
        if windows.is_empty() {
            return self.index.finish(
                file.id,
                "skipped",
                Some("silent or shorter than 2 s"),
                &BTreeMap::new(),
            );
        }
        self.index.transaction(|| {
            for (start, end, vector) in &windows {
                self.index.add_segment(
                    file.id,
                    SegmentKind::Audio,
                    Modality::Audio,
                    Some(*start),
                    Some(*end),
                    None,
                    None,
                    Some(vector),
                )?;
            }
            let info = BTreeMap::from([("duration".to_string(), format!("{duration:.1}"))]);
            self.index.finish(file.id, "done", None, &info)
        })
    }

    /// A frame per shot, when ffmpeg can draw them, and the soundtrack.
    fn video(&mut self, file: &FileRecord) -> Result<()> {
        self.note_embedding()?;
        let started = Instant::now();
        let path = Path::new(&file.path);
        let playing = media::duration(path);
        let scratch = self.scratch.join(format!("frames-{}", file.id));
        let mut frames: Vec<(f64, f64, Vec<f32>)> = Vec::new();
        let mut stopped = None;
        let (embedder, budget) = (self.embedder, self.options.frame_budget);
        media::keyframes(
            path,
            self.options.frame_interval,
            playing,
            &scratch,
            &mut |start, frame| {
                let Ok(png) = image_sizing::png(frame, budget) else {
                    return true;
                };
                match embedder.embed_image(&png) {
                    Ok(vector) => frames.push((start, playing, vector)),
                    Err(MediaError::Rejected(why)) => {
                        log::debug!("file search: a frame was refused: {why}");
                    }
                    Err(err) => {
                        stopped = Some(gone(err));
                        return false;
                    }
                }
                true
            },
        );
        if let Some(err) = stopped {
            return Err(err);
        }
        // Each kept frame stands for the stretch until the next kept frame.
        for at in 1..frames.len() {
            frames[at - 1].1 = frames[at].0;
        }
        let (windows, sound_seconds) = match self.embed_sound(file) {
            Ok(result) => result,
            // A video with no sound we can read may still have its frames.
            Err(Failed::File(why)) => {
                log::debug!("file search: no sound from a video: {why}");
                (Vec::new(), 0.0)
            }
            Err(Failed::Gone(err)) => return Err(err),
        };
        let duration = if playing > 0.0 {
            playing
        } else {
            sound_seconds
        };
        self.measured
            .add("videoSecond", duration, started.elapsed().as_secs_f64());
        if frames.is_empty() && windows.is_empty() {
            return self.index.finish(
                file.id,
                "skipped",
                Some("no frames or sound"),
                &BTreeMap::new(),
            );
        }
        self.index.transaction(|| {
            for (start, end, vector) in &frames {
                self.index.add_segment(
                    file.id,
                    SegmentKind::Frame,
                    Modality::Image,
                    Some(*start),
                    Some(*end),
                    None,
                    None,
                    Some(vector),
                )?;
            }
            for (start, end, vector) in &windows {
                self.index.add_segment(
                    file.id,
                    SegmentKind::Audio,
                    Modality::Audio,
                    Some(*start),
                    Some(*end),
                    None,
                    None,
                    Some(vector),
                )?;
            }
            let info = BTreeMap::from([
                ("duration".to_string(), format!("{duration:.1}")),
                ("frames".to_string(), frames.len().to_string()),
                ("sound_windows".to_string(), windows.len().to_string()),
            ]);
            self.index.finish(file.id, "done", None, &info)
        })
    }
}

/// A vector and the stretch of a recording or video it stands for.
type Placed = (f64, f64, Vec<f32>);

enum Failed {
    File(String),
    Gone(anyhow::Error),
}

fn stem(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn first_chars(text: &str, count: usize) -> String {
    text.chars().take(count).collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use lokalbot_core::files::Candidate;
    use parking_lot::Mutex;
    use std::sync::Arc;

    /// A model with one dimension per keyword, in the index's 768.
    #[derive(Default, Clone)]
    pub(crate) struct StubEmbedder {
        pub calls: Arc<Mutex<Vec<String>>>,
        pub fail_after: Arc<Mutex<Option<usize>>>,
    }

    fn vector_for(text: &str) -> Vec<f32> {
        let mut vector = vec![0.0f32; 768];
        for (axis, word) in ["budget", "zebra", "hiring"].iter().enumerate() {
            if text.to_lowercase().contains(word) {
                vector[axis] = 1.0;
            }
        }
        vector[767] = 0.1;
        let norm = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
        vector.iter().map(|v| v / norm).collect()
    }

    impl StubEmbedder {
        fn note(&self, what: &str) -> Result<(), MediaError> {
            let mut calls = self.calls.lock();
            calls.push(what.chars().take(60).collect());
            if let Some(limit) = *self.fail_after.lock()
                && calls.len() > limit
            {
                return Err(MediaError::Unavailable("server gone".into()));
            }
            Ok(())
        }
    }

    impl Embed for StubEmbedder {
        fn source(&self) -> String {
            "stub@1".into()
        }

        fn embed_texts(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, MediaError> {
            self.note("texts")?;
            Ok(texts.iter().map(|t| vector_for(t)).collect())
        }

        fn embed_image(&self, png: &[u8]) -> Result<Vec<f32>, MediaError> {
            self.note("image")?;
            if png.is_empty() {
                return Err(MediaError::Rejected("empty".into()));
            }
            Ok(vector_for("zebra"))
        }

        fn embed_audio(&self, _wav: &[u8]) -> Result<Vec<f32>, MediaError> {
            self.note("audio")?;
            Ok(vector_for("hiring"))
        }
    }

    fn add(index: &FileIndex, path: &Path, kind: FileKind) -> i64 {
        let meta = std::fs::metadata(path).unwrap();
        index
            .insert(&Candidate {
                path: path.to_string_lossy().into_owned(),
                kind,
                size: meta.len() as i64,
                mtime: 1.0,
                inode: 0,
                device: 0,
            })
            .unwrap()
    }

    fn state(index: &FileIndex, id: i64) -> (String, Option<String>) {
        let file = index
            .files_under(&[index
                .directory()
                .parent()
                .unwrap()
                .to_string_lossy()
                .into_owned()])
            .unwrap();
        file.into_iter()
            .find(|f| f.id == id)
            .map(|f| (f.state, f.detail))
            .unwrap()
    }

    fn run_all(pass: &mut Pass) -> usize {
        let (read, _) = pass.run(None, &mut || false, &mut |_| {}).unwrap();
        pass.finish_long_files(&mut || false, &mut |_| {}).unwrap();
        read
    }

    #[test]
    fn documents_become_chunks_and_words() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let note = dir.path().join("plan.md");
        std::fs::write(&note, "The budget for next year is on track and final.").unwrap();
        let numbers = dir.path().join("dump.txt");
        std::fs::write(&numbers, "123 456 789 ".repeat(50)).unwrap();
        let empty = dir.path().join("empty.txt");
        std::fs::write(&empty, "  ").unwrap();
        let note_id = add(&index, &note, FileKind::Doc);
        let numbers_id = add(&index, &numbers, FileKind::Doc);
        let empty_id = add(&index, &empty, FileKind::Doc);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(state(&index, note_id).0, "done");
        assert_eq!(state(&index, numbers_id).0, "done");
        assert_eq!(
            state(&index, empty_id),
            ("skipped".to_string(), Some("no text".to_string()))
        );
        assert_eq!(
            embedder.calls.lock().len(),
            1,
            "only the prose went to the model"
        );
        let counts = index.counts().unwrap();
        assert_eq!(counts.vectors, 1, "digits get keyword search only");
        assert_eq!(counts.segments, 2);
        assert_eq!(
            index.meta("fingerprint").unwrap().unwrap(),
            "stub@1 | photo140 shot280 page280 frame70/3.0s audio30.0/25.0s"
        );
    }

    #[test]
    fn long_documents_are_read_in_steps_and_can_stop() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let long = dir.path().join("book.txt");
        std::fs::write(&long, "budget words for the plan ".repeat(5000)).unwrap();
        let id = add(&index, &long, FileKind::Doc);
        let embedder = StubEmbedder::default();
        let options = IndexOptions {
            doc_step: 10,
            ..IndexOptions::default()
        };
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        pass.run(None, &mut || false, &mut |_| {}).unwrap();
        assert_eq!(state(&index, id).0, "partial");
        let info = index.info(id).unwrap();
        assert_eq!(info["read_to"], "10");
        let total: usize = info["read_end"].parse().unwrap();
        assert!(total > 10);
        // Stopped before anything else is read: nothing is lost.
        pass.finish_long_files(&mut || true, &mut |_| {}).unwrap();
        assert_eq!(state(&index, id).0, "partial");
        let mut lefts = Vec::new();
        pass.finish_long_files(&mut || false, &mut |progress| {
            if let PassProgress::LongFiles { left } = progress {
                lefts.push(left);
            }
        })
        .unwrap();
        assert_eq!(state(&index, id).0, "done");
        assert_eq!(*lefts.last().unwrap(), 0);
        assert_eq!(index.counts().unwrap().segments, total);
        assert!(!index.info(id).unwrap().contains_key("read_to"));
    }

    #[test]
    fn pictures_are_sized_and_small_ones_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let big = dir.path().join("big.png");
        image::RgbImage::from_pixel(600, 400, image::Rgb([9, 9, 9]))
            .save(&big)
            .unwrap();
        let small = dir.path().join("small.png");
        image::RgbImage::new(20, 20).save(&small).unwrap();
        let broken = dir.path().join("broken.png");
        std::fs::write(&broken, b"not a picture").unwrap();
        let big_id = add(&index, &big, FileKind::Image);
        let small_id = add(&index, &small, FileKind::Image);
        let broken_id = add(&index, &broken, FileKind::Image);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        assert_eq!(run_all(&mut pass), 1);
        assert_eq!(state(&index, big_id).0, "done");
        assert_eq!(state(&index, small_id).0, "skipped");
        assert_eq!(state(&index, broken_id).0, "failed");
        let info = index.info(big_id).unwrap();
        assert_eq!(
            (info["width"].as_str(), info["height"].as_str()),
            ("600", "400")
        );
        assert_eq!(index.counts().unwrap().vectors, 1);
    }

    struct FixedWords;
    impl ReadText for FixedWords {
        fn text_of(&mut self, _rgb: &image_sizing::Rgb) -> String {
            "error code K7Q2LM".into()
        }
    }

    #[test]
    fn a_scanned_page_is_read_as_a_picture_with_its_words_for_keywords() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let scan = dir.path().join("invoice.pdf");
        std::fs::write(
            &scan,
            pdf::tests_support::scanned_pdf(pdf::tests_support::ScanPicture::Jpeg(800, 1000)),
        )
        .unwrap();
        let id = add(&index, &scan, FileKind::Pdf);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = FixedWords;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(state(&index, id).0, "done");
        let info = index.info(id).unwrap();
        assert_eq!(info["pages"], "1");
        assert_eq!(info["scanned_pages"], "1");
        let counts = index.counts().unwrap();
        assert_eq!(counts.vectors, 1, "meaning comes from the picture");
        assert_eq!(counts.segments, 1, "the page, with its words");
        // The words on the scan find its page.
        let directory = dir.path().join("index");
        let mut searcher = lokalbot_core::files::search::Searcher::new(
            FileIndex::open_read_only(&directory).unwrap(),
        )
        .unwrap();
        let hits = searcher.search("K7Q2LM", None, None, 5).unwrap();
        assert_eq!(hits.len(), 1);
        let hit = hits.into_iter().next().unwrap().into_file_hit();
        assert_eq!(hit.page, Some(1));
        assert!(hit.excerpt.unwrap().contains("K7Q2LM"));
    }

    #[test]
    fn a_scan_with_no_ocr_still_has_its_picture() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let scan = dir.path().join("scan.pdf");
        std::fs::write(
            &scan,
            pdf::tests_support::scanned_pdf(pdf::tests_support::ScanPicture::Jpeg(800, 1000)),
        )
        .unwrap();
        let id = add(&index, &scan, FileKind::Pdf);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(index.info(id).unwrap()["scanned_pages"], "1");
        assert_eq!(index.counts().unwrap().vectors, 1);
    }

    #[test]
    fn screenshots_keep_their_words_for_keywords_only() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let shot = dir.path().join("Screenshot 1.png");
        image::RgbImage::new(600, 400).save(&shot).unwrap();
        let id = add(&index, &shot, FileKind::Screenshot);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = FixedWords;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(index.info(id).unwrap()["ocr_chars"], "17");
        assert_eq!(
            index.counts().unwrap().vectors,
            1,
            "meaning comes from the picture"
        );
        assert_eq!(index.counts().unwrap().segments, 2);
    }

    #[test]
    fn a_gone_server_leaves_files_pending() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let note = dir.path().join("plan.md");
        std::fs::write(&note, "The budget for next year is on track and final.").unwrap();
        let id = add(&index, &note, FileKind::Doc);
        let embedder = StubEmbedder::default();
        *embedder.fail_after.lock() = Some(0);
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        let result = pass.run(None, &mut || false, &mut |_| {});
        assert!(result.is_err());
        assert_eq!(state(&index, id).0, "pending");
    }

    #[test]
    fn a_new_model_reads_everything_again() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let note = dir.path().join("plan.md");
        std::fs::write(&note, "The budget for next year is on track and final.").unwrap();
        let id = add(&index, &note, FileKind::Doc);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        {
            let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
            run_all(&mut pass);
        }
        assert_eq!(state(&index, id).0, "done");
        index
            .set_meta("fingerprint", Some("another model | photo140"))
            .unwrap();
        let pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        pass.check_model().unwrap();
        assert_eq!(state(&index, id).0, "pending");
        assert_eq!(index.meta("fingerprint").unwrap(), None);
    }

    #[test]
    fn audio_becomes_windows() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let path = dir.path().join("talk.wav");
        let samples: Vec<f32> = (0..16_000 * 40)
            .map(|i| (i as f32 * 0.05).sin() * 0.4)
            .collect();
        std::fs::write(&path, lokalbot_audio::wav_bytes(&samples, 16_000)).unwrap();
        let id = add(&index, &path, FileKind::Audio);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(state(&index, id).0, "done");
        assert_eq!(index.info(id).unwrap()["duration"], "40.0");
        assert_eq!(index.counts().unwrap().vectors, 2);
    }

    /// Runs only where ffmpeg is installed, which is what frames need.
    #[test]
    fn video_becomes_frames_and_sound() {
        let Some(tool) = media::ffmpeg() else {
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("clip.mp4");
        let made = std::process::Command::new(tool)
            .args([
                "-v",
                "error",
                "-nostdin",
                "-f",
                "lavfi",
                "-i",
                "testsrc=duration=9:size=320x240:rate=5",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=9",
                "-shortest",
            ])
            .arg(&path)
            .status()
            .unwrap();
        if !made.success() {
            return;
        }
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let id = add(&index, &path, FileKind::Video);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let scratch = dir.path().join("scratch");
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, &scratch);
        run_all(&mut pass);
        assert_eq!(state(&index, id).0, "done");
        let info = index.info(id).unwrap();
        assert!(info["frames"].parse::<usize>().unwrap() >= 1, "{info:?}");
        assert_eq!(info["sound_windows"], "1", "{info:?}");
        assert!(!scratch.join(format!("frames-{id}")).exists(), "cleaned up");
    }

    #[test]
    fn pdfs_are_read_page_by_page() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let path = dir.path().join("report.pdf");
        std::fs::write(
            &path,
            crate::files::pdf::tests_support::sample_pdf(&[
                "The budget for the year is on track",
                "Hiring is planned for the second half",
            ]),
        )
        .unwrap();
        let id = add(&index, &path, FileKind::Pdf);
        let embedder = StubEmbedder::default();
        let options = IndexOptions::default();
        let mut words = NoText;
        let mut pass = Pass::new(&index, &options, &embedder, &mut words, dir.path());
        run_all(&mut pass);
        assert_eq!(state(&index, id).0, "done");
        assert_eq!(index.info(id).unwrap()["pages"], "2");
        assert_eq!(index.counts().unwrap().vectors, 2);
    }

    #[test]
    fn batches_hold_up_to_eight_pictures_of_a_kind() {
        let record = |id: i64, kind| FileRecord {
            id,
            path: String::new(),
            kind,
            size: 0,
            mtime: 0.0,
            inode: 0,
            device: 0,
            state: "pending".into(),
            detail: None,
        };
        let mut queue: Vec<FileRecord> = (0..9).map(|i| record(i, FileKind::Screenshot)).collect();
        queue.push(record(9, FileKind::Image));
        queue.push(record(10, FileKind::Doc));
        queue.push(record(11, FileKind::Doc));
        let sizes: Vec<usize> = batches(queue).iter().map(Vec::len).collect();
        assert_eq!(sizes, [8, 1, 1, 1, 1]);
    }
}
