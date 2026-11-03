//! PDFs read for their words, page by page. The Mac (PDFKit) and DigUp's other
//! builds (PDFium) draw pages with little text and embed the picture. No PDF renderer
//! ships here, so a page with little text is read from the largest picture stored in
//! it, when that's a JPEG or a plain raster. Other scans (JBIG2, CCITT, JPEG 2000)
//! and pages drawn from vectors stay unread, and Settings says so.

use std::path::Path;

use super::documents::ReadError;
use super::image_sizing::Rgb;

/// Larger files aren't loaded whole.
const MAX_BYTES: u64 = 1 << 30;
/// A scanned page is read at this size, like the Mac's rendered page (`renderPixels`).
const SCAN_PIXELS: u32 = 1400;
/// A stored picture with more pixels than this isn't decoded.
const MAX_SCAN_PIXELS: i64 = 200_000_000;

/// One page's text, or why it can't be shown.
#[derive(Clone, Debug, PartialEq)]
pub struct Page {
    /// From 1.
    pub number: usize,
    pub text: String,
    /// Text read in glyph order: too garbled to show or match words against, but
    /// enough of its words survive for a meaning vector.
    pub garbled: Option<String>,
    /// The picture of a page with too little text, for OCR and the image model.
    pub scan: Option<Rgb>,
    /// That picture, sized and encoded for the image model.
    pub picture: Option<Vec<u8>>,
}

#[derive(Debug)]
pub struct Document {
    pub title: Option<String>,
    /// Text of every page, in order.
    pub pages: Vec<String>,
    /// For reading pictures. `None` for an encrypted file.
    parsed: Option<lopdf::Document>,
}

/// Every page's text. A malformed file can make the parser panic: that fails
/// this file only.
pub fn read(path: &Path) -> Result<Document, ReadError> {
    let size = std::fs::metadata(path)
        .map_err(|err| ReadError::Unreadable(err.to_string()))?
        .len();
    if size > MAX_BYTES {
        return Err(ReadError::Unreadable("too big".into()));
    }
    let bytes = std::fs::read(path).map_err(|err| ReadError::Unreadable(err.to_string()))?;
    let parsed = std::panic::catch_unwind(|| parse(&bytes));
    parsed.unwrap_or_else(|_| Err(ReadError::Unreadable("can't open PDF".into())))
}

fn parse(bytes: &[u8]) -> Result<Document, ReadError> {
    let document = lopdf::Document::load_mem(bytes)
        .map_err(|_| ReadError::Unreadable("can't open PDF".into()))?;
    if document.is_encrypted() && !opens_without_password(bytes) {
        return Err(ReadError::Locked);
    }
    let title = document_title(&document);
    let pages = pdf_extract::extract_text_from_mem_by_pages(bytes)
        .map_err(|_| ReadError::Unreadable("can't read this PDF's text".into()))?;
    let parsed = (!document.is_encrypted()).then_some(document);
    Ok(Document {
        title,
        pages,
        parsed,
    })
}

/// The largest picture stored in page `number` (from 1), at least `min_side` pixels
/// each way. A malformed one can make a decoder panic: that loses this picture only.
fn scan_of(document: &lopdf::Document, number: usize, min_side: u32) -> Option<Rgb> {
    let read = std::panic::AssertUnwindSafe(|| {
        let id = *document.get_pages().get(&(number as u32))?;
        let images = document.get_page_images(id).ok()?;
        let largest = images
            .iter()
            .max_by_key(|image| image.width * image.height)?;
        if largest.width.min(largest.height) < i64::from(min_side)
            || largest.width.saturating_mul(largest.height) > MAX_SCAN_PIXELS
        {
            return None;
        }
        decode_picture(document, largest)
    });
    let picture = std::panic::catch_unwind(read).ok().flatten()?;
    let (width, height) = picture.dimensions();
    let longest = width.max(height);
    let picture = if longest > SCAN_PIXELS {
        let scale = f64::from(SCAN_PIXELS) / f64::from(longest);
        image::imageops::thumbnail(
            &picture,
            ((f64::from(width) * scale) as u32).max(1),
            ((f64::from(height) * scale) as u32).max(1),
        )
    } else {
        picture
    };
    let (width, height) = picture.dimensions();
    Some(Rgb {
        width: width as usize,
        height: height as usize,
        pixels: picture.into_raw(),
    })
}

fn decode_picture(
    document: &lopdf::Document,
    image: &lopdf::xobject::PdfImage<'_>,
) -> Option<image::RgbImage> {
    let filters = image.filters.clone().unwrap_or_default();
    let names: Vec<&str> = filters.iter().map(String::as_str).collect();
    match names.as_slice() {
        ["DCTDecode"] | ["DCT"] => {
            image::load_from_memory_with_format(image.content, image::ImageFormat::Jpeg)
                .ok()
                .map(|decoded| decoded.to_rgb8())
        }
        [] => raster(image, image.content),
        ["FlateDecode"] | ["Fl"] => {
            let stream = document.get_object(image.id).ok()?.as_stream().ok()?;
            raster(image, &stream.decompressed_content().ok()?)
        }
        // JBIG2, CCITT and JPEG 2000 have no decoder here.
        _ => None,
    }
}

/// Plain samples: 8-bit colour or gray, or 1-bit gray as office scanners write it.
fn raster(image: &lopdf::xobject::PdfImage<'_>, samples: &[u8]) -> Option<image::RgbImage> {
    let width = usize::try_from(image.width).ok()?;
    let height = usize::try_from(image.height).ok()?;
    let area = width.checked_mul(height)?;
    let space = image.color_space.as_deref().unwrap_or("");
    let rgb: Vec<u8> = match (space, image.bits_per_component) {
        ("DeviceRGB" | "CalRGB", Some(8)) | ("ICCBased", Some(8))
            if samples.len() >= area.checked_mul(3)? =>
        {
            samples[..area * 3].to_vec()
        }
        ("DeviceGray" | "CalGray" | "ICCBased", Some(8)) if samples.len() >= area => samples
            [..area]
            .iter()
            .flat_map(|gray| [*gray, *gray, *gray])
            .collect(),
        ("DeviceGray" | "CalGray", Some(1)) => {
            let row = width.div_ceil(8);
            if samples.len() < row.checked_mul(height)? {
                return None;
            }
            // `/Decode [1 0]` swaps which bit is white.
            let inverted = image
                .origin_dict
                .get(b"Decode")
                .and_then(|decode| decode.as_array())
                .ok()
                .and_then(|decode| decode.first())
                .and_then(|first| first.as_i64().ok())
                == Some(1);
            let mut out = Vec::with_capacity(area * 3);
            for y in 0..height {
                for x in 0..width {
                    let bit = samples[y * row + x / 8] >> (7 - x % 8) & 1 == 1;
                    let value = if bit != inverted { 255 } else { 0 };
                    out.extend([value, value, value]);
                }
            }
            out
        }
        _ => return None,
    };
    image::RgbImage::from_raw(image.width as u32, image.height as u32, rgb)
}

/// An owner password alone still lets anyone read: an empty password opens it.
fn opens_without_password(bytes: &[u8]) -> bool {
    lopdf::Document::load_mem(bytes)
        .map(|mut document| document.decrypt("").is_ok())
        .unwrap_or(false)
}

fn document_title(document: &lopdf::Document) -> Option<String> {
    let info = document.trailer.get(b"Info").ok()?;
    let info = match info {
        lopdf::Object::Reference(id) => document.get_dictionary(*id).ok()?,
        lopdf::Object::Dictionary(dictionary) => dictionary,
        _ => return None,
    };
    let title = info.get(b"Title").ok()?;
    let bytes = title.as_str().ok()?;
    let text = if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| u16::from_be_bytes(*b))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        bytes.iter().map(|b| *b as char).collect()
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// How many pages a PDF has, from its page tree alone. One when it can't say,
/// as `Estimator.pages` guesses.
pub fn page_count(path: &Path) -> usize {
    let count = std::panic::catch_unwind(|| {
        lopdf::Document::load_metadata(path)
            .ok()
            .map(|meta| meta.page_count as usize)
    });
    count.ok().flatten().filter(|n| *n > 0).unwrap_or(1)
}

/// Pages `range` (from 0) of `document`. A page with fewer than `min_text` characters
/// also brings its picture, when it has one of at least `min_side` pixels.
pub fn pages_in(
    document: &Document,
    range: std::ops::Range<usize>,
    min_text: usize,
    min_side: u32,
) -> Vec<Page> {
    range
        .filter_map(|index| {
            let text = document.pages.get(index)?.trim();
            let garbled = glyph_order_problem(text);
            let shown = if garbled { "" } else { text };
            let scan = (shown.chars().count() < min_text)
                .then(|| {
                    document
                        .parsed
                        .as_ref()
                        .and_then(|parsed| scan_of(parsed, index + 1, min_side))
                })
                .flatten();
            Some(Page {
                number: index + 1,
                text: shown.to_string(),
                garbled: garbled.then(|| text.to_string()),
                scan,
                picture: None,
            })
        })
        .collect()
}

/// Dependent vowel signs of Bengali and Devanagari: in a real word, each follows
/// a consonant or its nukta (`PageTextProblem.glyphOrder`).
fn glyph_order_problem(text: &str) -> bool {
    fn is_vowel_sign(value: u32) -> bool {
        matches!(value,
            0x09BE..=0x09C4 | 0x09C7 | 0x09C8 | 0x09CB | 0x09CC | 0x09D7 | 0x09E2 | 0x09E3
            | 0x093A | 0x093B | 0x093E..=0x094C | 0x094E | 0x094F | 0x0955..=0x0957 | 0x0962 | 0x0963)
    }
    fn is_consonant_or_nukta(value: u32) -> bool {
        matches!(value,
            0x0995..=0x09B9 | 0x09BC | 0x09CE | 0x09DC | 0x09DD | 0x09DF | 0x09F0 | 0x09F1
            | 0x0915..=0x0939 | 0x093C | 0x0958..=0x095F | 0x0979..=0x097F)
    }
    use unicode_normalization::UnicodeNormalization as _;
    let (mut signs, mut misplaced) = (0usize, 0usize);
    let mut previous = ' ';
    for scalar in text.nfc() {
        if is_vowel_sign(scalar as u32) {
            signs += 1;
            if !is_consonant_or_nukta(previous as u32) {
                misplaced += 1;
            }
        }
        previous = scalar;
    }
    signs >= 10 && misplaced * 20 >= signs
}

#[cfg(test)]
pub(crate) mod tests_support {
    /// What a scanned page stores.
    pub(crate) enum ScanPicture {
        Jpeg(u32, u32),
        /// Colour space, bits per component, samples; 300 × 400, Flate compressed.
        Flate(&'static [u8], i64, Vec<u8>),
        /// 1-bit gray, uncompressed.
        Bitmap(i64, i64, Vec<u8>),
        /// A filter with no decoder here.
        Named(&'static [u8]),
    }

    /// A one-page PDF with no text and one picture.
    pub(crate) fn scanned_pdf(picture: ScanPicture) -> Vec<u8> {
        use lopdf::{Dictionary, Object, Stream, dictionary};
        let image = |width: i64, height: i64, space: &[u8], bits: i64| -> Dictionary {
            dictionary! {
                "Type" => "XObject",
                "Subtype" => "Image",
                "Width" => width,
                "Height" => height,
                "ColorSpace" => Object::Name(space.to_vec()),
                "BitsPerComponent" => bits,
            }
        };
        let stream = match picture {
            ScanPicture::Jpeg(width, height) => {
                let pixels = image::RgbImage::from_pixel(width, height, image::Rgb([90, 90, 90]));
                let mut jpeg = std::io::Cursor::new(Vec::new());
                pixels
                    .write_to(&mut jpeg, image::ImageFormat::Jpeg)
                    .unwrap();
                let mut dict = image(i64::from(width), i64::from(height), b"DeviceRGB", 8);
                dict.set("Filter", Object::Name(b"DCTDecode".to_vec()));
                Stream::new(dict, jpeg.into_inner())
            }
            ScanPicture::Flate(space, bits, samples) => {
                let mut stream = Stream::new(image(300, 400, space, bits), samples);
                stream.compress().unwrap();
                stream
            }
            ScanPicture::Bitmap(width, height, samples) => {
                Stream::new(image(width, height, b"DeviceGray", 1), samples)
            }
            ScanPicture::Named(filter) => {
                let mut dict = image(800, 1000, b"DeviceGray", 1);
                dict.set("Filter", Object::Name(filter.to_vec()));
                Stream::new(dict, vec![0; 16])
            }
        };
        let mut document = lopdf::Document::with_version("1.5");
        let picture = document.add_object(stream);
        let pages = document.new_object_id();
        let content = document.add_object(Stream::new(
            Dictionary::new(),
            b"q 612 0 0 792 0 0 cm /Im0 Do Q".to_vec(),
        ));
        let page = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Resources" => dictionary! { "XObject" => dictionary! { "Im0" => picture } },
            "Contents" => content,
        });
        document.objects.insert(
            pages,
            Object::Dictionary(dictionary! {
                "Type" => "Pages",
                "Kids" => vec![Object::Reference(page)],
                "Count" => 1,
            }),
        );
        let catalog = document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages });
        document.trailer.set("Root", catalog);
        let mut out = Vec::new();
        document.save_to(&mut out).unwrap();
        out
    }

    /// A small PDF with one line of text per page, built by hand.
    pub(crate) fn sample_pdf(pages: &[&str]) -> Vec<u8> {
        let mut objects: Vec<String> = Vec::new();
        let kids: Vec<String> = (0..pages.len())
            .map(|i| format!("{} 0 R", 4 + i * 2))
            .collect();
        objects.push("<< /Type /Catalog /Pages 2 0 R >>".into());
        objects.push(format!(
            "<< /Type /Pages /Kids [{}] /Count {} >>",
            kids.join(" "),
            pages.len()
        ));
        objects.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".into());
        for (index, text) in pages.iter().enumerate() {
            objects.push(format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
                5 + index * 2
            ));
            let content = format!("BT /F1 12 Tf 72 720 Td ({text}) Tj ET");
            objects.push(format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            ));
        }
        let mut out = b"%PDF-1.4\n".to_vec();
        let mut offsets = Vec::new();
        for (index, object) in objects.iter().enumerate() {
            offsets.push(out.len());
            out.extend(format!("{} 0 obj\n{object}\nendobj\n", index + 1).bytes());
        }
        let xref = out.len();
        out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).bytes());
        for offset in offsets {
            out.extend(format!("{offset:010} 00000 n \n").bytes());
        }
        out.extend(
            format!(
                "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
                objects.len() + 1
            )
            .bytes(),
        );
        out
    }
}

#[cfg(test)]
mod tests {
    use super::tests_support::sample_pdf;
    use super::*;

    #[test]
    fn reads_pages_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.pdf");
        std::fs::write(&path, sample_pdf(&["Quarterly budget", "Hiring plan"])).unwrap();
        let document = read(&path).unwrap();
        assert_eq!(document.pages.len(), 2);
        assert!(
            document.pages[0].contains("Quarterly budget"),
            "{document:?}"
        );
        assert!(document.pages[1].contains("Hiring plan"));
        assert_eq!(page_count(&path), 2);
        let pages = pages_in(&document, 1..5, 200, 256);
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].number, 2);
        assert!(pages[0].garbled.is_none());
        // Little text, but no picture to read instead.
        assert!(pages[0].scan.is_none());
    }

    fn write_scan(dir: &tempfile::TempDir, picture: tests_support::ScanPicture) -> Document {
        let path = dir.path().join("scan.pdf");
        std::fs::write(&path, tests_support::scanned_pdf(picture)).unwrap();
        read(&path).unwrap()
    }

    #[test]
    fn a_scanned_jpeg_page_brings_its_picture() {
        let dir = tempfile::tempdir().unwrap();
        let document = write_scan(&dir, tests_support::ScanPicture::Jpeg(800, 1000));
        let pages = pages_in(&document, 0..1, 200, 256);
        assert_eq!(pages[0].text, "");
        let scan = pages[0].scan.as_ref().unwrap();
        assert_eq!((scan.width, scan.height), (800, 1000));
        assert_eq!(scan.pixels.len(), 800 * 1000 * 3);
    }

    #[test]
    fn a_big_scan_is_read_at_the_size_the_mac_renders() {
        let dir = tempfile::tempdir().unwrap();
        let document = write_scan(&dir, tests_support::ScanPicture::Jpeg(2800, 2000));
        let pages = pages_in(&document, 0..1, 200, 256);
        let scan = pages[0].scan.as_ref().unwrap();
        assert_eq!((scan.width, scan.height), (1400, 1000));
    }

    #[test]
    fn plain_rasters_are_read_in_colour_gray_and_one_bit() {
        let dir = tempfile::tempdir().unwrap();
        for picture in [
            tests_support::ScanPicture::Flate(b"DeviceRGB", 8, vec![200; 300 * 400 * 3]),
            tests_support::ScanPicture::Flate(b"DeviceGray", 8, vec![200; 300 * 400]),
        ] {
            let document = write_scan(&dir, picture);
            let pages = pages_in(&document, 0..1, 200, 256);
            let scan = pages[0].scan.as_ref().unwrap();
            assert_eq!((scan.width, scan.height), (300, 400));
            assert!(scan.pixels.iter().all(|value| *value == 200));
        }
        // 1-bit: a set bit is white. 304 wide so each row is 38 whole bytes.
        let document = write_scan(
            &dir,
            tests_support::ScanPicture::Bitmap(304, 400, vec![0xFF; 38 * 400]),
        );
        let pages = pages_in(&document, 0..1, 200, 256);
        let scan = pages[0].scan.as_ref().unwrap();
        assert!(scan.pixels.iter().all(|value| *value == 255));
    }

    #[test]
    fn a_small_logo_or_an_undecodable_scan_stays_unread() {
        let dir = tempfile::tempdir().unwrap();
        let document = write_scan(&dir, tests_support::ScanPicture::Jpeg(120, 80));
        assert!(pages_in(&document, 0..1, 200, 256)[0].scan.is_none());
        let document = write_scan(&dir, tests_support::ScanPicture::Named(b"JBIG2Decode"));
        assert!(pages_in(&document, 0..1, 200, 256)[0].scan.is_none());
    }

    #[test]
    fn a_page_with_enough_text_is_not_read_as_a_picture() {
        let dir = tempfile::tempdir().unwrap();
        let document = write_scan(&dir, tests_support::ScanPicture::Jpeg(800, 1000));
        assert!(pages_in(&document, 0..1, 0, 256)[0].scan.is_none());
    }

    #[test]
    fn broken_files_fail_alone() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.pdf");
        std::fs::write(&path, b"%PDF-1.4 not really").unwrap();
        assert!(read(&path).is_err());
        assert_eq!(page_count(&path), 1, "as the estimate guesses");
    }

    #[test]
    fn glyph_order_is_told_from_real_text() {
        // Vowel signs ahead of their consonants.
        assert!(glyph_order_problem(&"িক".repeat(12)));
        assert!(!glyph_order_problem(&"কি".repeat(12)));
        assert!(!glyph_order_problem("plain English text"));
    }
}
