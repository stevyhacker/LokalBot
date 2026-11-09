//! Tesseract as a separate program, for the scripts ocrs can't read.
//!
//! Pixels reach it over a pipe as a grayscale PGM and text comes back over
//! another: `tesseract stdin stdout`. No image file exists at any point, and
//! nothing it prints is logged. It runs on one thread at low priority and is
//! killed at a deadline, so a slow read can't take the computer from the person.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use parking_lot::Mutex;

use super::OcrLine;

/// How long one read may take. The densest screen measured took 9.4 s.
const DEADLINE: Duration = Duration::from_secs(20);
/// A read that ran out of time leaves Tesseract alone for this long.
const HOLD_OFF: Duration = Duration::from_secs(300);
/// How long what the program offers is trusted before asking again.
const PROBE_LIFETIME: Duration = Duration::from_secs(30);
const PROBE_DEADLINE: Duration = Duration::from_secs(3);
/// Images up to this size are enlarged for the languages that need it.
const ENLARGE_UP_TO: u32 = 1_600;

/// Chinese, Japanese and Korean at 11–14 px read far better twice the size
/// (Japanese 35% to 96% on a downscaled window) for 20–40% more time. Other
/// scripts gain little and take about 80% more, so they stay as they are.
const ENLARGED_LANGUAGES: [&str; 4] = ["chi_sim", "chi_tra", "jpn", "kor"];
/// A window with at least this share of one gray is an interface or a page, not
/// a picture. Enlarging a photo took 6–20 s to find only noise (1–2 s at its size).
const FLAT_SHARE: f32 = 0.2;
/// In a picture, words less sure than this are noise: of 364 characters found in
/// pure noise 9 stay. Real text would lose too many this way (99% to 93% on
/// English), so interfaces and pages keep every word.
const PICTURE_CONFIDENCE: f32 = 50.0;

/// Whether Tesseract ran out of time recently.
struct HoldOff(Mutex<Option<Instant>>);

impl HoldOff {
    const fn new() -> Self {
        Self(Mutex::new(None))
    }

    fn active(&self, now: Instant) -> bool {
        self.0.lock().is_some_and(|until| now < until)
    }

    fn begin(&self, now: Instant) {
        *self.0.lock() = Some(now + HOLD_OFF);
    }
}

static HELD_OFF: HoldOff = HoldOff::new();

/// The program and the languages in its own data folder.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Probe {
    pub program: Option<PathBuf>,
    pub languages: Vec<String>,
}

/// What is installed now, asked at most every [`PROBE_LIFETIME`].
pub fn probe() -> Probe {
    static CACHE: OnceLock<Mutex<Option<(Instant, Probe)>>> = OnceLock::new();
    let mut cache = CACHE.get_or_init(|| Mutex::new(None)).lock();
    if let Some((at, probe)) = cache.as_ref()
        && at.elapsed() < PROBE_LIFETIME
    {
        return probe.clone();
    }
    let probe = ask_program();
    *cache = Some((Instant::now(), probe.clone()));
    probe
}

fn ask_program() -> Probe {
    let Some(program) = find_program("tesseract") else {
        return Probe::default();
    };
    let mut command = Command::new(&program);
    command.arg("--list-langs");
    let languages = run(&mut command, &[], PROBE_DEADLINE)
        .map(|output| parse_language_list(&String::from_utf8_lossy(&output)))
        .unwrap_or_else(|err| {
            log::debug!("tesseract did not list its languages: {err:#}");
            Vec::new()
        });
    Probe {
        program: Some(program),
        languages,
    }
}

fn find_program(name: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt as _;
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| {
            candidate
                .metadata()
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
}

/// The names after the header of `tesseract --list-langs`.
fn parse_language_list(output: &str) -> Vec<String> {
    output
        .lines()
        .skip_while(|line| !line.starts_with("List of available languages"))
        .skip(1)
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

/// One way of running the program, cheap to keep.
#[derive(Debug)]
pub(super) struct Tesseract {
    program: PathBuf,
    /// The folder of the language data, when it isn't the program's own.
    tessdata: Option<PathBuf>,
    languages: String,
    enlarge: bool,
}

impl Tesseract {
    pub(super) fn new(program: PathBuf, tessdata: Option<PathBuf>, languages: &[&str]) -> Self {
        Self {
            program,
            tessdata,
            languages: languages.join("+"),
            enlarge: languages
                .iter()
                .any(|language| ENLARGED_LANGUAGES.contains(language)),
        }
    }

    /// The lines in an RGBA image, in the image's pixels.
    pub(super) fn read(&self, rgba: &[u8], width: u32, height: u32) -> Result<Vec<OcrLine>> {
        if HELD_OFF.active(Instant::now()) {
            bail!("tesseract ran out of time recently");
        }
        let gray = grayscale(rgba);
        let flat = mostly_flat(&gray);
        let scale = if self.enlarge && flat && width.max(height) <= ENLARGE_UP_TO {
            2
        } else {
            1
        };
        let confidence = if flat { 0.0 } else { PICTURE_CONFIDENCE };
        let image = pgm(gray, width, height, scale);
        let mut command = self.command();
        match run(&mut command, &image, DEADLINE) {
            Ok(output) => Ok(parse_tsv(
                &String::from_utf8_lossy(&output),
                scale as i32,
                confidence,
            )),
            Err(err) => {
                if err.downcast_ref::<TimedOut>().is_some() {
                    HELD_OFF.begin(Instant::now());
                }
                Err(err)
            }
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.program);
        command.args(["stdin", "stdout"]);
        if let Some(tessdata) = &self.tessdata {
            command.arg("--tessdata-dir").arg(tessdata);
        }
        command
            .args(["-l", &self.languages])
            // Sparse text suits windows: labels on buttons and in sidebars stay
            // apart, and colourful screens read better (English 77% to 83%).
            .args(["--psm", "11", "--dpi", "96"])
            .args(["-c", "tessedit_create_tsv=1"])
            // More threads cost 2.7 times the CPU for a fifth off the time.
            .env("OMP_THREAD_LIMIT", "1")
            // It looks for `stdin.uzn` here, so nowhere anyone could put one.
            .current_dir(Path::new("/"));
        command
    }
}

#[derive(Debug, thiserror::Error)]
#[error("tesseract did not finish in time")]
struct TimedOut;

/// Runs `command`, feeding it `input`, and returns what it prints. Its standard
/// error goes nowhere. Killed at `deadline`, and held to low priority.
fn run(command: &mut Command, input: &[u8], deadline: Duration) -> Result<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("starting tesseract")?;
    // SAFETY: a plain system call with no pointers, on the process just started.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, child.id(), 10);
    }
    let mut stdin = child.stdin.take().context("no pipe to tesseract")?;
    let mut stdout = child.stdout.take().context("no pipe from tesseract")?;
    std::thread::scope(|scope| {
        // A program that stops reading ends the write with a broken pipe.
        scope.spawn(move || {
            let _ = stdin.write_all(input);
        });
        let reader = scope.spawn(move || {
            let mut output = Vec::new();
            let _ = stdout.read_to_end(&mut output);
            output
        });
        let started = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().context("waiting for tesseract")? {
                break status;
            }
            if started.elapsed() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(TimedOut.into());
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        anyhow::ensure!(status.success(), "tesseract failed: {status}");
        Ok(reader.join().unwrap_or_default())
    })
}

fn grayscale(rgba: &[u8]) -> Vec<u8> {
    rgba.as_chunks::<4>()
        .0
        .iter()
        .map(|p| ((299 * p[0] as u32 + 587 * p[1] as u32 + 114 * p[2] as u32) / 1000) as u8)
        .collect()
}

/// One shade covers much of the image, as an interface's background does.
fn mostly_flat(gray: &[u8]) -> bool {
    let mut counts = [0u32; 256];
    for value in gray {
        counts[*value as usize] += 1;
    }
    counts
        .iter()
        .max()
        .is_some_and(|most| *most as f32 >= gray.len() as f32 * FLAT_SHARE)
}

/// The image as a binary grayscale PGM, the form Tesseract reads from a pipe
/// with the least to send.
fn pgm(gray: Vec<u8>, width: u32, height: u32, scale: u32) -> Vec<u8> {
    let (w, h) = (width as usize, height as usize);
    let (pixels, w, h) = if scale == 2 {
        (enlarged(&gray, w, h), w * 2, h * 2)
    } else {
        (gray, w, h)
    };
    let mut out = format!("P5 {w} {h} 255\n").into_bytes();
    out.extend_from_slice(&pixels);
    out
}

/// Twice the size. Existing pixels stay; new ones are Catmull-Rom between them.
fn enlarged(gray: &[u8], w: usize, h: usize) -> Vec<u8> {
    let between = |a: u8, b: u8, c: u8, d: u8| {
        let value = (9 * (b as i32 + c as i32) - a as i32 - d as i32 + 8) >> 4;
        value.clamp(0, 255) as u8
    };
    let (w2, h2) = (w * 2, h * 2);
    let mut out = vec![0u8; w2 * h2];
    for y in 0..h {
        let row = &gray[y * w..(y + 1) * w];
        let at = |x: isize| row[x.clamp(0, w as isize - 1) as usize];
        let target = &mut out[2 * y * w2..(2 * y + 1) * w2];
        for x in 0..w {
            let i = x as isize;
            target[2 * x] = row[x];
            target[2 * x + 1] = between(at(i - 1), row[x], at(i + 1), at(i + 2));
        }
    }
    let line = |y: isize| 2 * y.clamp(0, h as isize - 1) as usize * w2;
    for y in 0..h {
        let i = y as isize;
        let (a, b, c, d) = (line(i - 1), line(i), line(i + 1), line(i + 2));
        for x in 0..w2 {
            out[(2 * y + 1) * w2 + x] = between(out[a + x], out[b + x], out[c + x], out[d + x]);
        }
    }
    out
}

/// The lines in Tesseract's TSV, whose word rows (level 5) carry a box and text.
/// `scale` is how much the image was enlarged; words below `confidence` are left out.
fn parse_tsv(tsv: &str, scale: i32, confidence: f32) -> Vec<OcrLine> {
    struct Line<'a> {
        key: (&'a str, &'a str, &'a str),
        words: Vec<&'a str>,
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    }
    let mut lines: Vec<Line<'_>> = Vec::new();
    for row in tsv.lines() {
        let cells: Vec<&str> = row.split('\t').collect();
        let [
            "5",
            _page,
            block,
            paragraph,
            line,
            _word,
            left,
            top,
            width,
            height,
            sure,
            text,
        ] = cells[..]
        else {
            continue;
        };
        let text = text.trim();
        if text.is_empty() || sure.parse::<f32>().is_ok_and(|sure| sure < confidence) {
            continue;
        }
        let number = |cell: &str| cell.parse::<i32>().unwrap_or(0);
        let (left, top) = (number(left), number(top));
        let (right, bottom) = (left + number(width), top + number(height));
        let key = (block, paragraph, line);
        match lines.last_mut().filter(|last| last.key == key) {
            Some(last) => {
                last.words.push(text);
                last.left = last.left.min(left);
                last.top = last.top.min(top);
                last.right = last.right.max(right);
                last.bottom = last.bottom.max(bottom);
            }
            None => lines.push(Line {
                key,
                words: vec![text],
                left,
                top,
                right,
                bottom,
            }),
        }
    }
    lines
        .into_iter()
        .filter_map(|line| {
            // Right-to-left runs come marked; the text is already in reading order.
            let text = super::collapse_cjk_spaces(&line.words.join(" "))
                .replace(['\u{200e}', '\u{200f}'], "");
            let text = text.trim();
            (!text.is_empty()).then(|| OcrLine {
                text: text.to_string(),
                x: line.left / scale,
                y: line.top / scale,
                width: (line.right - line.left) / scale,
                height: (line.bottom - line.top) / scale,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n";

    #[test]
    fn language_list_skips_its_header() {
        let output =
            "List of available languages in \"/usr/share/tessdata/\" (3):\neng\nosd\nsrp_latn\n";
        assert_eq!(parse_language_list(output), ["eng", "osd", "srp_latn"]);
        assert!(parse_language_list("").is_empty());
        assert!(parse_language_list("Error opening data file\n").is_empty());
    }

    #[test]
    fn words_become_lines_with_a_box_around_them() {
        let tsv = format!(
            "{HEADER}\
            1\t1\t0\t0\t0\t0\t0\t0\t800\t600\t-1\t\n\
            4\t1\t1\t1\t1\t0\t10\t20\t100\t12\t-1\t\n\
            5\t1\t1\t1\t1\t1\t10\t20\t40\t12\t96.1\tHello\n\
            5\t1\t1\t1\t1\t2\t60\t18\t50\t16\t95.2\tworld\n\
            5\t1\t2\t1\t1\t1\t10\t50\t30\t12\t91.0\tSave\n\
            5\t1\t2\t1\t2\t1\t10\t70\t30\t12\t91.0\t \n"
        );
        let lines = parse_tsv(&tsv, 1, 0.0);
        assert_eq!(lines.len(), 2);
        assert_eq!(
            lines[0],
            OcrLine {
                text: "Hello world".into(),
                x: 10,
                y: 18,
                width: 100,
                height: 16
            }
        );
        assert_eq!(lines[1].text, "Save");
        assert_eq!(parse_tsv("", 1, 0.0), Vec::new());
        // In a picture, unsure words are left out.
        let picture = parse_tsv(&tsv, 1, 95.5);
        assert_eq!(picture[0].text, "Hello");
        assert_eq!(picture.len(), 1);
    }

    #[test]
    fn enlarged_images_report_boxes_in_the_original_pixels() {
        let tsv = format!("{HEADER}5\t1\t1\t1\t1\t1\t20\t40\t60\t24\t90\tBox\n");
        let line = &parse_tsv(&tsv, 2, 0.0)[0];
        assert_eq!((line.x, line.y, line.width, line.height), (10, 20, 30, 12));
    }

    #[test]
    fn han_words_join_without_spaces_and_latin_keeps_them() {
        let tsv = format!(
            "{HEADER}\
            5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t90\t项\n\
            5\t1\t1\t1\t1\t2\t10\t0\t10\t10\t90\t目\n\
            5\t1\t1\t1\t1\t3\t20\t0\t10\t10\t90\tRust\n\
            5\t1\t1\t1\t1\t4\t30\t0\t10\t10\t90\tcode\n\
            5\t1\t2\t1\t1\t1\t0\t20\t10\t10\t90\t한국어\n\
            5\t1\t2\t1\t1\t2\t10\t20\t10\t10\t90\t문서\n\
            5\t1\t3\t1\t1\t1\t0\t40\t10\t10\t90\t\u{200f}مرحبا\u{200f}\n"
        );
        let lines: Vec<String> = parse_tsv(&tsv, 1, 0.0)
            .into_iter()
            .map(|l| l.text)
            .collect();
        assert_eq!(lines, ["项目 Rust code", "한국어 문서", "مرحبا"]);
    }

    #[test]
    fn pixels_become_a_grayscale_pgm() {
        // White, black, then pure green, which weighs 587/1000.
        let rgba = [255, 255, 255, 255, 0, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0];
        let image = pgm(grayscale(&rgba), 2, 2, 1);
        assert_eq!(&image[..12], b"P5 2 2 255\n\xff");
        assert_eq!(&image[11..], [255, 0, 149, 0]);
    }

    #[test]
    fn enlarging_keeps_every_original_pixel_and_flat_areas() {
        let flat = vec![200u8; 12];
        assert!(enlarged(&flat, 4, 3).iter().all(|value| *value == 200));
        let gradient: Vec<u8> = (0..16).map(|i| i * 10).collect();
        let big = enlarged(&gradient, 4, 4);
        assert_eq!(big.len(), 64);
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(big[2 * y * 8 + 2 * x], gradient[y * 4 + x]);
            }
        }
        // Halfway between two pixels on a straight ramp.
        assert_eq!(big[3], 15);
        let image = pgm(vec![9], 1, 1, 2);
        assert_eq!(image, b"P5 2 2 255\n\x09\x09\x09\x09");
    }

    #[test]
    fn only_flat_images_count_as_interfaces() {
        let mut interface = vec![250u8; 1000];
        interface[..300].fill(30);
        assert!(mostly_flat(&interface));
        let picture: Vec<u8> = (0..1000u32).map(|i| (i * 37 % 256) as u8).collect();
        assert!(!mostly_flat(&picture));
    }

    /// A stand-in program, written to a folder and run. Forking elsewhere in the
    /// test process can keep it open for a moment, so this waits until it runs.
    fn stand_in(dir: &Path, script: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt as _;
        let path = dir.join("tesseract");
        std::fs::write(
            &path,
            format!("#!/bin/sh\n[ \"$1\" = --wait ] && exit 0\n{script}\n"),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        for _ in 0..100 {
            match Command::new(&path)
                .arg("--wait")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .status()
            {
                Err(err) if err.raw_os_error() == Some(libc::ETXTBSY) => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                _ => break,
            }
        }
        path
    }

    #[test]
    fn pixels_only_ever_travel_over_the_pipe() {
        let dir = tempfile::tempdir().unwrap();
        let seen = dir.path().join("args");
        // Records its arguments, and passes on the image it was sent on stdin.
        let script = format!(
            "echo \"$@\" > '{}'\n\
             size=$(wc -c)\n\
             printf '5\\t1\\t1\\t1\\t1\\t1\\t1\\t2\\t3\\t4\\t90\\t%s\\n' \"$size\"\n",
            seen.display()
        );
        let program = stand_in(dir.path(), &script);
        let engine = Tesseract::new(program, Some(dir.path().to_path_buf()), &["eng"]);
        let lines = engine.read(&[0u8; 400 * 300 * 4], 400, 300).unwrap();
        // A header and 120,000 gray pixels reached standard input.
        let header = "P5 400 300 255\n".len();
        assert_eq!(lines[0].text, format!("{}", header + 400 * 300));
        let args = std::fs::read_to_string(&seen).unwrap();
        assert!(args.starts_with("stdin stdout "), "{args}");
        assert!(args.contains("-l eng"), "{args}");
        // No path to any image; the one path is the language data's folder.
        let paths = args
            .split_whitespace()
            .filter(|arg| arg.contains('/'))
            .count();
        assert_eq!(paths, 1, "{args}");
    }

    #[test]
    fn a_program_that_stops_reading_is_not_waited_on() {
        let dir = tempfile::tempdir().unwrap();
        let program = stand_in(dir.path(), "exit 0");
        let engine = Tesseract::new(program, None, &["eng"]);
        let lines = engine.read(&[0u8; 2000 * 2000 * 4], 2000, 2000).unwrap();
        assert!(lines.is_empty());
    }

    #[test]
    fn failure_is_an_error_without_what_it_printed() {
        let dir = tempfile::tempdir().unwrap();
        let program = stand_in(dir.path(), "echo secret >&2; echo secret; exit 3");
        let engine = Tesseract::new(program, None, &["eng"]);
        let err = engine.read(&[0u8; 4], 1, 1).unwrap_err();
        assert!(!format!("{err:#}").contains("secret"), "{err:#}");
    }

    #[test]
    fn a_slow_program_is_killed_at_the_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let program = stand_in(dir.path(), "exec sleep 30");
        let mut command = Tesseract::new(program, None, &["eng"]).command();
        let started = Instant::now();
        let err = run(&mut command, &[], Duration::from_millis(100)).unwrap_err();
        assert!(err.downcast_ref::<TimedOut>().is_some(), "{err:#}");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn running_out_of_time_holds_off_for_a_while() {
        let hold_off = HoldOff::new();
        let now = Instant::now();
        assert!(!hold_off.active(now));
        hold_off.begin(now);
        assert!(hold_off.active(now + HOLD_OFF - Duration::from_secs(1)));
        assert!(!hold_off.active(now + HOLD_OFF));
    }

    /// Reads with the real program when this computer has it and English data.
    #[test]
    fn the_real_program_reads_a_rendered_banner_when_it_is_installed() {
        let found = ask_program();
        let Some(program) = found.program else {
            eprintln!("no tesseract here; nothing to check");
            return;
        };
        if !found.languages.iter().any(|language| language == "eng") {
            eprintln!("tesseract has no English data here; nothing to check");
            return;
        }
        let (width, height, rgba) = crate::ocr::tests::banner();
        let engine = Tesseract::new(program, None, &["eng"]);
        let lines = engine.read(&rgba, width, height).unwrap();
        let text: String = lines.iter().map(|line| line.text.as_str()).collect();
        // The blocky test font's letters can be misread one at a time.
        assert!(text.to_uppercase().contains("BOT"), "{text}");
        assert!(lines[0].width > 100 && lines[0].height > 20, "{lines:?}");
    }
}
