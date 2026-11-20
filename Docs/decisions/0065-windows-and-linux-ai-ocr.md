# 0065. Windows and Linux: ai — ocr

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/ocr.rs`, `LinuxWindows/crates/lokalbot-ai/src/ocr/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/ocr.rs`

#### Three OCR engines chosen by plan; downloads only when asked
On-device text recognition for screen context, the counterpart of the
Vision `VNRecognizeTextRequest` the Mac app runs on screenshots
(`ScreenshotImageProcessing.recognizeText`).

Three engines, chosen by [`plan`] from what this computer has:

- [ocrs](https://github.com/robertknight/ocrs), a pure-Rust engine that reads
  unaccented Latin letters. Its two models are pinned by size and SHA-256 and
  download only when the person asks, into `<library>/models/ocrs/`.
- Tesseract on Linux, a separate program that reads every other script. It
  uses the language data it already has, or pinned `tessdata_fast` files
  that download only when the person asks, into `<library>/models/tesseract/`.
  Pixels reach it over a pipe; see [`tesseract`].
- `Windows.Media.Ocr` on Windows, built in, with the languages installed there.

#### Same id used by engine and Models page
`OCR_MODEL_ID`: Id the engine and the Models page use for the pair of files.

#### Models are CC BY-SA 4.0 while the engine is MIT or Apache
`OCR_MODEL_LICENSE`: The models' license (the engine is MIT or Apache 2.0).

#### Detection then recognition; the files ocrs-cli 0.13 loads by default
`OCR_FILES`: Detection first, then recognition. These are the files `ocrs-cli` 0.13
loads by default.

#### Installed means pinned size and matching sidecar digest from verified download
`is_installed`: Both files are present with their pinned size and a matching sidecar
digest (written by the verified download).

#### Progress callback covers both files together
`download`: Downloads whatever is missing. `progress(done, total)` covers both files.

#### Same id used by engine and Models page for Tesseract data
`OCR_LANGUAGES_ID`: Id the engine and the Models page use for Tesseract's language data.

#### tessdata_fast files are Apache-2.0
`OCR_LANGUAGES_LICENSE`: The `tessdata_fast` files' license.

#### Language counts only with pinned size and matching digest
`has_language`: This language's file is present with its pinned size and a matching digest.

#### Size includes data that may already be downloaded
`languages_size`: What the languages wanted here take. Some of it may already be downloaded.

#### System-only languages count as lacking since one run reads one folder
`languages_to_download`: The languages wanted here that the library lacks. One Tesseract run reads
from one folder, so this counts what the system has as lacking too.

#### Progress callback covers all wanted language data
`download_languages`: Downloads the language data wanted here. `progress(done, total)` covers it all.

#### Offered download is started only by the person
`OcrDownload`: A download that would help, for the person to start.

#### Reading languages are listed by their own names
`OcrStatus.reading`: What the engine reads, by the languages' own names.

#### Missing is what app and system want that nothing reads yet
`OcrStatus.missing`: What this app and system want that nothing here reads yet.

#### Reading missing languages needs the Tesseract program
`OcrStatus.needs_program`: Reading `missing` needs the Tesseract program.

#### Status is cheap enough to ask often
`status`: What recognition can do here now. Cheap enough to ask often.

#### Windows recognizer outside pinned languages is still named
`status`: A recognizer outside the pinned languages is still worth naming.

#### Strip spaces in unspaced scripts to match Mac Vision; keep Korean spaces
`collapse_cjk_spaces`: Spaces between words of Chinese, Japanese or Thai, which are written without
them. Tesseract and Windows both put them there; the Mac's Vision doesn't, and
search needs the words whole. Korean does use spaces, and keeps them.

#### Line position is in image pixels
`OcrLine`: One recognized line and where it is in the image, in pixels.

#### Keep one loaded engine since ocrs loads about 12 MB; check is_current
`OcrEngine`: A loaded recognizer, whichever engine it is. ocrs loads about 12 MB of model
weights, so keep one and reuse it, and ask [`Self::is_current`] whether what
this computer has still leads to it.

#### ocrs stands in when another engine can't read this time
`OcrEngine.stand_in`: ocrs, when another engine can't read this time and it is installed.

#### Downloads, removals or language changes can change the chosen engine
`OcrEngine::is_current`: What this computer has still leads to this engine. A download, a removal
or a new language in Settings can change that.

#### Output is one line per recognized line, top to bottom
`OcrEngine::recognize`: The text in an RGBA image, one recognized line per line, top to bottom.

#### Lines with places are used to tell what is near a text field
`OcrEngine::recognize_lines`: The lines in an RGBA image with their places, for telling what is near
a text field.

#### None means ocrs reads, as engine or as stand-in after failure
`OcrEngine::read_without_ocrs`: What Tesseract or Windows read. `None` means ocrs is to read: it is the
engine, or it stands in because the engine failed.

#### Manual timing test of one window using scratch library and RGBA env vars
`tests::recognize_lines_timing`: How long one window takes, for judging autocomplete's window text.
`LOKALBOT_OCR_ROOT` is a scratch library the models download into;
`LOKALBOT_OCR_IMAGE` is raw RGBA named `<name>-<width>x<height>.rgba`.

#### Asking status offers a download but fetches or creates nothing
`asking_what_can_read_downloads_nothing`: An offer at most; nothing was fetched or created to make it.

#### Ignored test downloads real models, about 12 MB
`tests::reads_rendered_text`: Downloads the real models (about 12 MB) and reads rendered text.

#### Blocky test font's K can be misread as E
`tests::reads_rendered_text`: The blocky test font's K can read as E.

### `LinuxWindows/crates/lokalbot-ai/src/ocr/languages.rs`

#### Read only app and system languages because each costs time per capture
Which languages screen text recognition should read here: the app's and the
system's, not every one, because each added language costs time on every
capture. Also the pinned `tessdata_fast` file of each language.

#### Locale named as lokalbot_i18n names it where they overlap
`Language.locale`: The locale it serves, as `lokalbot_i18n` names it where they overlap.

#### Tesseract's language name and the data file stem
`Language.name`: Tesseract's name for it, and the stem of its file.

#### Autonym is shown in Settings
`Language.autonym`: What the language calls itself, shown in Settings.

#### Latin data reads English about as well as eng (97-99% measured)
`Language.latin`: Written in Latin letters. Such data also reads English about as well as
`eng` does (97–99% measured), so these don't need `eng` beside them.

#### Pinned tessdata_fast revision the file digests come from
`TESSDATA_REVISION`: The revision of `tesseract-ocr/tessdata_fast` the files below come from.

#### Table covers the app's languages and most common system ones
`LANGUAGES`: The app's languages and the most common system ones.

#### English is the fallback for every language list
`ENGLISH`: English, the language every list falls back to.

#### Locale forms accepted; None when no pinned data exists
`for_locale`: The language a locale reads, from forms like `zh_TW.UTF-8`, `sr_RS@latin`,
`sr-Cyrl-RS` or `ar-EG`. `None` for a language with no pinned data.

#### Add English beside non-Latin scripts; measured Korean 32% to 97%
`wanted`: What to read here: the app's language and the system's first one, with
English beside any other script, because windows in those languages still
show English (measured on rendered mixed screens: Korean 32% alone, 97%
beside English; Arabic 46% and 99%). Script other than Latin comes first.

#### Windows runs one recognizer at a time, so one tag is chosen
`pick_recognizer`: The recognizer in `available` (BCP 47 tags) for one of the `wanted` languages,
in their order. Windows runs one recognizer at a time, so this is one tag.

#### Hausa and Nigerian Pidgin have no data and read as English
`every_app_language_reads_its_own_script_or_english`: Hausa and Nigerian Pidgin have no data of their own and read as English.

#### Latin data reads English, so English is not added
`only_the_app_and_first_system_language_are_loaded`: Latin data reads English, so nothing is added to it.

#### A language without data still reads Latin letters via English
`only_the_app_and_first_system_language_are_loaded`: A language with no data still reads Latin letters.

#### Traditional recognizer does not serve Simplified; English is left
`recognizers_match_language_and_script`: Traditional is not Simplified: English is what is left.

#### Non-Latin script wins since the Latin recognizer can't read it
`recognizers_match_language_and_script`: Another script is chosen over Latin, whose recognizer can't read it.

### `LinuxWindows/crates/lokalbot-ai/src/ocr/plan.rs`

#### Plan has no I/O so both platforms' rules test anywhere
Which engine reads, from what this computer has. No I/O here, so both
platforms' rules are tested on either.

#### Uses system tesseract with its own data or library folder
`Reader::Tesseract`: The system's `tesseract`, with language data from its own folder or, if
`library`, from `<library>/models/tesseract`.

#### Reading is filled only where the reader can say
`Plan.reading`: What the reader reads, where it can say.

#### Suggested download can only be started by the person
`Plan.download`: The download that would help, which only the person can start.

#### English stays on ocrs: Tesseract reads coloured UIs worse (83% vs 98%)
`with_tesseract`: The Linux rules. English with the ocrs models stays with ocrs: Tesseract is
faster there, yet reads coloured interfaces worse (83% against 98% measured).
Anything else goes to Tesseract, which reads it and ocrs can't. Without
Tesseract, or the data it needs, whatever can read does so until the person
downloads the rest.

#### One run reads one folder, so the fuller one wins
`with_tesseract`: One run reads from one folder, so the fuller one wins.

#### English data still reads Latin letters when no wanted data exists
`with_tesseract`: Data for no wanted language, but English still reads Latin letters.

#### Prefer built-in recognizer, then ocrs, then any installed; none offers ocrs
`with_windows`: The Windows rules: the recognizer built into Windows for a language wanted
here, otherwise ocrs, otherwise any recognizer installed, since it needs no
download. Nothing at all offers the ocrs download.

#### ocrs reads only ASCII, so accented Latin needs its own data
`accented_latin_prefers_tesseract_over_ocrs`: ocrs reads only ASCII, so German needs its own data.

### `LinuxWindows/crates/lokalbot-ai/src/ocr/tesseract.rs`

#### Tesseract runs via pipes only, unlogged, one thread, low priority, killed at deadline
Tesseract as a separate program, for the scripts ocrs can't read.

Pixels reach it over a pipe as a grayscale PGM and text comes back over
another: `tesseract stdin stdout`. No image file exists at any point, and
nothing it prints is logged. It runs on one thread at low priority and is
killed at a deadline, so a slow read can't take the computer from the person.

#### Read deadline 20 s; densest measured screen took 9.4 s
`DEADLINE`: How long one read may take. The densest screen measured took 9.4 s.

#### A timed-out read leaves Tesseract alone for five minutes
`HOLD_OFF`: A read that ran out of time leaves Tesseract alone for this long.

#### Installed-language probe is trusted for 30 seconds
`PROBE_LIFETIME`: How long what the program offers is trusted before asking again.

#### Only images up to 1600 px are enlarged for chosen languages
`ENLARGE_UP_TO`: Images up to this size are enlarged for the languages that need it.

#### Enlarge CJK twice: Japanese 35% to 96%; other scripts gain little
`ENLARGED_LANGUAGES`: Chinese, Japanese and Korean at 11–14 px read far better twice the size
(Japanese 35% to 96% on a downscaled window) for 20–40% more time. Other
scripts gain little and take about 80% more, so they stay as they are.

#### Flat-gray share separates interfaces from photos; enlarging photos finds noise
`FLAT_SHARE`: A window with at least this share of one gray is an interface or a page, not
a picture. Enlarging a photo took 6–20 s to find only noise (1–2 s at its size).

#### Confidence 50 filters picture noise without hurting interface text
`PICTURE_CONFIDENCE`: In a picture, words less sure than this are noise: of 364 characters found in
pure noise 9 stay. Real text would lose too many this way (99% to 93% on
English), so interfaces and pages keep every word.

#### Probe is cached and asked at most every 30 seconds
`probe`: What is installed now, asked at most every [`PROBE_LIFETIME`].

#### Data folder set only when not the program's own
`Tesseract.tessdata`: The folder of the language data, when it isn't the program's own.

#### Lines are reported in the original image's pixels
`Tesseract::read`: The lines in an RGBA image, in the image's pixels.

#### psm 11 sparse text keeps labels apart; English 77% to 83%
`Tesseract::command`: Sparse text suits windows: labels on buttons and in sidebars stay
apart, and colourful screens read better (English 77% to 83%).

#### Single OMP thread: more threads cost 2.7x CPU for 20% time
`Tesseract::command`: More threads cost 2.7 times the CPU for a fifth off the time.

#### Run from root since stdin.uzn is looked up in the working directory
`Tesseract::command`: It looks for `stdin.uzn` here, so nowhere anyone could put one.

#### Stderr discarded; process killed at deadline and held at low priority
`run`: Runs `command`, feeding it `input`, and returns what it prints. Its standard
error goes nowhere. Killed at `deadline`, and held to low priority.

#### setpriority on the just-started child is a pointer-free syscall
`run`: SAFETY: a plain system call with no pointers, on the process just started.

#### A program that stops reading breaks the pipe write, which is ignored
`run`: A program that stops reading ends the write with a broken pipe.

#### Binary grayscale PGM is the smallest form to send over a pipe
`pgm`: The image as a binary grayscale PGM, the form Tesseract reads from a pipe
with the least to send.

#### Word rows level 5 carry boxes; scale maps back; low confidence dropped
`parse_tsv`: The lines in Tesseract's TSV, whose word rows (level 5) carry a box and text.
`scale` is how much the image was enlarged; words below `confidence` are left out.

#### Strip RTL marks; text is already in reading order
`parse_tsv`: Right-to-left runs come marked; the text is already in reading order.

#### Wait until stand-in script runs; forks elsewhere can hold it open
`stand_in`: A stand-in program, written to a folder and run. Forking elsewhere in the
test process can keep it open for a moment, so this waits until it runs.

#### Blocky test font letters can be misread one at a time
`the_real_program_reads_a_rendered_banner_when_it_is_installed`: The blocky test font's letters can be misread one at a time.

### `LinuxWindows/crates/lokalbot-ai/src/ocr/windows_media.rs`

#### Windows.Media.Ocr needs no download and reads installed language packs
`Windows.Media.Ocr`, the recognizer built into Windows. It has no model to
download and reads the languages whose packs are installed on this PC.

#### Installed languages are cached for 30 seconds
`LANGUAGES_LIFETIME`: How long the installed languages are trusted before asking Windows again.

#### Lines are reported in the image's pixels
`Recognizer::read`: The lines in an RGBA image, in the image's pixels.

#### Recognizer expects opaque BGRA like its own samples
`bgra`: RGBA as opaque BGRA, the format the recognizer's own samples hand it.

#### Runs on Windows CI; no language pack is reported as nothing to read
`tests::the_real_recognizer_reads_a_rendered_banner`: Runs on the Windows CI job against the real recognizer. Images without an
OCR language pack have nothing to read with, and that is reported as such.

#### Blocky test font can be misread a letter at a time
`tests::the_real_recognizer_reads_a_rendered_banner`: The blocky test font can be misread a letter at a time.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
