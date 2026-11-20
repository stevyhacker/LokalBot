# 0055. Mac app: Transcription

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Transcription/`, `LokalBot/Services/Transcription/`, `LokalBotTests/Models/Transcription/`, `LokalBotTests/Services/Transcription/`.

## Decisions

### `LokalBot/Models/Transcription/AppleSpeechLocaleResolver.swift`

#### Sort locale lists since Apple's sets return arbitrary regional variants
`AppleSpeechLocaleResolver`: Deterministic locale and module selector for macOS `SpeechAnalyzer`.

Apple's `supportedLocales` and `supportedLocale(equivalentTo:)` iterate an
unordered set and can return arbitrary regional variants (such as `en_IN` or
`en_ZA` for `"en"`). Resolving over sorted locale lists keeps selection
deterministic across runs and matches LokalBot's language picker.

#### 22 languages covered; Serbian unsupported by both modules and omitted
`AppleSpeechLocaleResolver.canonicalLocale`: Canonical fallback locale identifiers for the 22 LokalBot languages
covered by `SpeechTranscriber` or `DictationTranscriber`. Serbian (`sr`)
is unsupported by both modules and omitted.

#### All picker languages supported except Serbian
`AppleSpeechLocaleResolver.isLanguageSupported`: True when Apple Speech covers `language` (all picker choices except Serbian).

### `LokalBot/Models/Transcription/LanguageCode.swift`

#### Name Serbian explicitly for Qwen: 14.1 vs 17.1 WER; auto reads Croatian
`LanguageCode.transcriptionSupported`: Serbian is not on Qwen3-ASR's list, but naming it explicitly measured
14.1% against 17.1% WER on 1.7B and 44.3% against 54.2% on 0.6B, where
auto detection reads it as Croatian (Benchmarks/transcribe/QwenSpanLength).

### `LokalBot/Models/Transcription/SerbianLatinScript.swift`

#### Keep Serbian-family transcripts in Latin because models drift between scripts
`SerbianLatinScript`: Serbian, Croatian, Bosnian and Montenegrin are one language written in two
scripts. Speech models drift between them mid-meeting: Qwen3-ASR pinned to
Serbian writes about half its windows in Cyrillic, and on auto-detect it
slips into Macedonian or Russian spellings of Serbian words. A transcript
that switches script line by line is hard to read and to search, so
meeting transcripts in this language are kept in Latin script, the script
LokalBot's own Serbian interface uses.

#### Serbian-only ђ/ћ; Apple's recognizer reads Serbian Cyrillic as Kazakh
`SerbianLatinScript.isSerbianCyrillic`: Cyrillic text with ђ or ћ, letters only Serbian writes (Macedonian
has ѓ and ќ in their place), and none that only another Cyrillic
language writes. Apple's language recognizer reads Serbian Cyrillic
as Kazakh with full confidence.

#### Non-Serbian Cyrillic letters map to closest Serbian Latin; rest unchanged
`SerbianLatinScript.latin`: `text` with every Cyrillic letter spelled in Serbian Latin. Letters
outside the Serbian alphabet, which appear when a model drifts into
Russian, Macedonian or Ukrainian, take their closest Serbian Latin
spelling. Everything else is left exactly as it was.

#### Uppercase digraph is title case unless inside uppercase word
`SerbianLatinScript.latin`: An uppercase digraph letter is title case ("Ljubljana") unless
it sits in an uppercase word ("LJUBLJANA").

#### Convert only when language is Serbian-family or auto vote reaches 80%
`SerbianLatinScript.latinTranscript`: `transcript` with its Cyrillic lines in Latin script when it is in
this language: transcribed with the language set to one of its codes,
or, on auto-detect, voted at least 80% Serbian, Croatian, Bosnian or
Montenegrin. Any other transcript is returned unchanged, so a Russian
or Ukrainian meeting keeps its script.

### `LokalBot/Models/Transcription/Transcript.swift`

#### Transcript lives in Models so lokalbot-cli reads it without engine dependencies
`Transcript`: Speaker-attributed transcript of a meeting. Persisted as `transcript.json`
next to the audio; rendered to `transcript.md` for human reading.

Lives in `Models/` (not `Engines/`) because the embedded `lokalbot-cli`
reads it without linking WhisperKit / FluidAudio. The transcription engines
fill it in, but it's just a data shape — no engine dependency.

#### Coarse text spans fallback windows; unsafe for destructive filtering
`Transcript.Segment.TimingPrecision.coarse`: The text covers a fallback window or whole track; its words are
not localized closely enough to support destructive filtering.

#### Speaker is me, them, or a diarized label
`Transcript.Segment.speaker`: "me" | "them" | diarized label

#### Optional for old transcripts; missing is unknown and never used for deletion
`Transcript.Segment.timingPrecision`: Optional keeps older persisted transcripts source-compatible. A
missing value is unknown and therefore never used for deletion.

#### Prompt turns keep source boundary and ID so quotes resolve back
`Transcript.PromptTurn`: A bounded piece of one source segment used only for model prompts.
Keeping its source boundary visible lets the model copy a quote and
the exact ID that resolves that quote back to the transcript.

#### Normalize once per transcript change, not per row per playback tick
`Transcript.DisplaySegment`: Immutable, UI-ready segment data. Building this value performs the
control-token/whitespace normalization once when a transcript changes,
instead of once per row on every playback timer tick.

#### Keep source order for segments; sort only private lookup
`Transcript.DisplayIndex`: Cached transcript presentation plus a chronological interval index for
playback highlighting. `segments` deliberately remains in source order;
only the private lookup is sorted, so malformed/legacy files do not
silently reorder what the user sees.

#### Prefix maximum ends let active query stop early
`Transcript.DisplayIndex.prefixMaximumEnds`: Maximum effective end among `intervals[0...index]`. This lets an
active-segment query stop as soon as no earlier interval can overlap.

#### Binary search plus prefix maxima; return all overlaps for simultaneous speakers
`Transcript.DisplayIndex.activeSegmentIDs`: IDs of all visible segments containing `time`. A binary search skips
future segments, and the prefix maxima bound the backwards overlap
scan. Returning every overlap preserves simultaneous-speaker
highlighting from the previous per-row comparison.

#### Aliases keyed by stable segment speaker label
`Transcript.speakerAliases`: Per-meeting display-name overrides keyed by the stable speaker label
stored on each segment, e.g. "them 2" -> "Ana".

#### Store opaque participant IDs; emails stay in meeting metadata
`Transcript.speakerCalendarIdentityIDs`: Opaque calendar-participant IDs selected for speaker aliases. Email
addresses remain in meeting metadata and never enter the transcript.

#### transcript.md line format with bracketed timestamp and bold speaker
`Transcript.markdown`: Renders `transcript.md` — "[00:14:32] **Me:** …"

#### IDs derived from immutable order and timing, no migration fields
`Transcript.segmentID`: Stable source IDs used by outcome extraction and evidence links. The ID
is derived from immutable source order and timing, so re-opening the same
transcript resolves citations without adding migration-only fields to
every legacy segment.

#### Short prompt IDs resolve against exact snapshot; persisted claims keep stable IDs
`Transcript.summaryCitationID`: Short prompt references avoid asking a model to reproduce long timing
IDs. Resolution always uses this exact transcript snapshot; persisted
claims and audio links retain the original stable segment IDs.

#### IDs in schema notation so model cites only resolvable segments
`Transcript.evidenceMarkdown`: Source-ready transcript for grounded extraction. IDs appear in the
exact notation required by the schema so the model can only cite known
segments that LokalBot can resolve back to audio.

#### Keep timestamps and labels out; they skew Apple language recognizer
`Transcript.languageDetectionText`: Plain spoken text used for language detection and similar NLP passes.
Keep timestamps, speaker labels, and Markdown out of the sample: Apple's
language recognizer can over-weight that short formatting noise.

#### Preserve source boundaries; split long spans at words keeping source ID
`Transcript.summaryPromptTurns`: Preserve each source boundary even for consecutive same-speaker spans.
A pathological/legacy span is split at word boundaries, retaining its
source ID so downstream token-aware chunking has safe split points.

#### Merge tracks by timestamp; mic is me, system is them
`Transcript.merged`: Merge per-track transcripts (mic = "me", system = "them") by timestamp.

#### Mixed voices and echo cannot outvote the labelled speaker's identity
`Transcript.speakerIdentity`: Mixed voices and suspected echo are not the labelled speaker's own
voice, so they cannot outvote that speaker's identity. They remain
unresolved individually and cannot prove ownership.

#### Mic default is correctable without diarization; mixed and echo cannot name a person
`Transcript.setSpeakerIsUser`: The microphone default is correctable even without diarization.
Mixed voices and suspected echo still cannot name one person.

#### Strip Whisper control tokens emitted as text before persisting
`Transcript.normalizedText`: Whisper-family models can emit control/timestamp tokens as plain text.
Persist and render only the human transcript text.

### `LokalBot/Models/Transcription/TranscriptSanitizer.swift`

#### Remove only pathological ASR output; keep normal emphasis
`TranscriptSanitizer`: Removes only objectively pathological ASR output: extreme repetition,
rows that merely repeat the vocabulary prompt, and precisely timed rows
too fast to be speech. Normal conversational emphasis is left intact:
word/phrase collapse requires a long repeated cycle plus an impossible
rate or a fast, overwhelmingly repetitive burst.

#### Precisely timed 8+ words at 10 words/sec is aligner-packed invention, not speech
`TranscriptSanitizer.implausibleRateMinimumWords`: A precisely timed row with at least this many words at this rate is
not speech: the forced aligner packs words a model made up for a
near-silent gap into a fraction of a second (8–12 words in under one).
Coarse or unknown timing never authorizes removal, and a collapsed
filler loop is judged by the words it keeps.

#### Rows that only repeat the vocabulary prompt are removed
`TranscriptSanitizer.sanitize`: `prompt` is the vocabulary prompt the transcript was made with, when
known. Rows that only repeat it are removed (`TranscriptionPromptEcho`).

#### Loop-dominated rows collapse even below the 12 words/sec gate
`TranscriptSanitizer.sanitize`: Timestamp-less ASR can place 135 identical filler words in
a 15-second VAD window: below the old 12 words/sec gate.

#### Delete only repeated span; rebuilding from tokens rewrites numbers
`TranscriptSanitizer.collapseWordLoops`: Delete only the repeated span. Rebuilding from word tokens
would also rewrite unrelated amounts, signs and decimals.

#### Never collapse numeric runs; they can be amounts or identifiers
`TranscriptSanitizer.collapseExtremeCharacterRuns`: Collapse extreme verbal emphasis, but never numeric runs: repeated
digits can be an amount, identifier, or exact quoted evidence.

### `LokalBot/Models/Transcription/TranscriptionLanguageSupport.swift`

#### Ukrainian support follows pinned engines' model cards, not the shared picker
`UkrainianTranscriptionSupport`: Ukrainian is a newly exposed choice. Keep existing language behavior,
including the separately benchmarked Serbian Qwen hint, unchanged.
Coverage comes from the pinned engines and their publishers' model cards;
a shared language picker is not evidence of model support.

#### FluidAudio 0.17.7 maps Ukrainian and Russian to same script filter
`TranscriptionModelChoice.ukrainianSupport`: FluidAudio 0.17.7 maps Ukrainian and Russian to the same script filter.

#### Reject unsupported saved Ukrainian before loading rather than silently transcribing otherwise
`TranscriptionModelChoice.validateLanguage`: Validate before loading weights, reading audio, or falling back to auto
detection. A saved Ukrainian choice must survive model switches, but an
unsupported engine must not silently transcribe it in another language.

### `LokalBot/Models/Transcription/TranscriptionPromptEcho.swift`

#### Drop rows copied from vocabulary prompt on near-silent spans, one shared definition
`TranscriptionPromptEcho`: Text a speech model copied from its vocabulary prompt instead of hearing.

On a near-silent span, prompt-capable recognizers (Qwen3-ASR, Whisper)
return the hint itself or its tail — "Them 6 · source 2, Mila Novak,
Orion Launch, Acme." — as a row of 8–12 words timed to a fraction of a
second. Such rows are not speech: they reach the notes model as evidence,
fill speaker review, and vote in language detection. The Qwen engine, the
track transcriber, and `TranscriptSanitizer` drop them through this one
definition.

#### Match only multi-term rows; a single name may be spoken
`TranscriptionPromptEcho.matches`: True when every word of `text` is a prompt word and the text is more
than one vocabulary term. A row that is only "Mila Novak" may be a
person saying a name; a row of several listed terms is the list.

#### Accent- and case-fold words; ignore separators
`TranscriptionPromptEcho.words`: Letter and digit runs, lowercased and accent-folded, so "Marković",
"Markovic", and "MARKOVIC" are one word and "·" or "," never count.

### `LokalBot/Models/Transcription/TranscriptionVocabulary.swift`

#### Vocabulary prompt uses only local library sources, never addresses
`TranscriptionVocabulary`: Names and terms LokalBot already knows, offered to speech models that
accept a vocabulary prompt (Whisper, Qwen and Granite 5). Every source is local and
already part of the library: calendar attendee display names (never
addresses or names derived from addresses), speaker names the user applied
in related meetings, Dream project names, and distinctive meeting-title
terms. Speaker evidence, suggestions, and voice-profile links are not read.

#### Per-meeting record keeps retries on the same prompt and checkpoints
`TranscriptionVocabulary.Record`: Per-meeting record so crash resumes and retries use the same prompt
(and therefore reuse transcription checkpoints) even if the library
changes in between.

#### Priority order, dedupe, bound; exclude placeholder labels and merge suffixes
`TranscriptionVocabulary.terms`: Priority order: attendees, then names the user applied before, then
projects, then title terms. Deduplicated case- and accent-insensitively
and bounded so the prompt never crowds out the audio context.
Placeholder speaker labels and the suffix meeting merges add to names
never reach the recognizer.

#### User's manual vocabulary stays first and verbatim
`TranscriptionVocabulary.prompt`: The user's own vocabulary stays first and verbatim; known terms follow.

#### Tracked Projects names are confirmed spellings
`TranscriptionVocabulary.sources`: Names the person tracks in Projects are confirmed spellings too.

#### Dictation uses recent attendees and projects, most-met first
`TranscriptionVocabulary.recentSources`: Recent attendee names and projects for dictation, which has no
meeting of its own. Most frequently met people come first.

#### Only pinned projects; unpinned labels from mishearings bias later transcripts
`TranscriptionVocabulary.endorsedProjectNames`: Only projects the person pinned. Unpinned Dream projects are model
labels, often built from earlier mishearings ("Ave vault accounting and
compliance"); as speech-model vocabulary they biased the next
transcript toward the same errors.

#### Post-transcription cleanup reuses manual vocabulary plus saved terms
`TranscriptionVocabulary.savedPrompt`: The prompt a finished meeting was transcribed with, for cleanup that
runs after transcription: the manual vocabulary plus the saved terms.

#### Common department words relate series but caused prompt-echo rows as vocabulary
`TranscriptionVocabulary.commonTitleWords`: Department and format words name a series ("Product standup", so they
still relate its meetings) but are ordinary words a speech model spells
on its own; as vocabulary, "Product" came back in prompt-echo rows.

#### Capitalized and acronym title words are likely names worth spelling
`TranscriptionVocabulary.titleTerms`: Capitalized or mixed-case words and acronyms from a title ("Acme",
"iOS", "SDK") are likely names worth spelling; generic words are not.

#### Placeholder labels as vocabulary came back as rows on silent spans
`TranscriptionVocabulary.isPlaceholderName`: Placeholder speaker labels ("Them 6", "Speaker unclear", "Local
speaker") and collective words carry no spelling value; fed to a
recognizer, a label came back as transcript rows on silent spans.

#### Strip merge suffix naming a recording, plus whitespace and edge punctuation
`TranscriptionVocabulary.cleanedTerm`: Meeting merges suffix applied names with "· source 2", which names a
recording rather than a person; whitespace and edge punctuation go too.

### `LokalBot/Models/Transcription/WhisperStockPhrases.swift`

#### Drop English stock-phrase rows Whisper hallucinates on non-English tracks
`WhisperStockPhrases`: Whisper answers audio it cannot make out (a pause, a breath, a faint
voice leaking from the other side of a call) with an English stock phrase
from its subtitle-heavy training data, whatever language it was set to:
on Serbian speech set to Bosnian it still writes "Thank you." where
Qwen3-ASR writes nothing. In a track that is not in English such a row is
not speech, so it is dropped. English tracks keep theirs: there it can be
what someone said.

#### Stock phrases match whole rows, lowercased, punctuation removed
`WhisperStockPhrases.phrases`: Whole rows, lowercased with punctuation removed.

#### Remove only when language is known non-English or 80% vote
`WhisperStockPhrases.removing`: `transcript` without stock-phrase rows when its language is known and
not English: `language` as set, or on auto-detect, a vote of at least
80% for another language.

### `LokalBot/Services/Transcription/AttributedTrackTranscriber.swift`

#### Diarization partitions audio before ASR; text never divided proportionally or by majority label
`AttributedTrackTranscriber`: Diarization partitions AUDIO before ASR. Text is never divided proportionally
across speaker turns, and overlapping voices never inherit a majority label.

#### Failed regions under one second are skipped; longer ones surface engine errors
`AttributedTrackTranscriber.rejectableRegionSeconds`: A region shorter than this whose transcription fails is skipped rather
than failing the track. Longer regions keep normal error handling, so a
broken engine still surfaces.

#### Regions with under 0.3 s detected speech are not decoded due to VAD padding
`AttributedTrackTranscriber.minimumRegionSpeech`: A region with less detected speech than this is not decoded. Detection
pads speech by a fraction of a second, so the pause after a turn holds
a sliver of it; a missed one-word reply still holds more.

#### Unclassified audio preserved; microphone defaults to me, overlapping voices unresolved
`AttributedTrackTranscriber.attributedTranscript`: Preserve unclassified audio as well. Microphone speech follows
the “My microphone is me” default; overlapping voices remain unresolved.

#### Aligner fetched before timing words; tests replace it to check necessity
`AttributedTrackTranscriber.AlignerPreparation`: Fetches the forced aligner before it times words. Tests replace it to
see whether the aligner is needed at all.

#### speech marks VAD-heard speech; regions without it are skipped; nil decodes all
`AttributedTrackTranscriber.transcribe`: `speech` is where voice activity detection heard speech on the track;
speaker regions without any are not decoded. Nil decodes every region.

#### Drop near-silent rows where prompt-echo words were aligned into sub-second segments
`AttributedTrackTranscriber.transcribe`: A prompt-capable model answers a near-silent span with its
vocabulary hint, and forced alignment then packs those words into a
sub-second row of their own. Nothing downstream should see one.

#### Microphone default applies without diarization using whole-file VAD path
`AttributedTrackTranscriber.attributedTranscript`: The microphone default also applies without speaker separation or
remembered voice profiles, using the optimized whole-file VAD path.

#### Skip regions lacking speech since Whisper hallucinates stock phrases on silence
`AttributedTrackTranscriber.attributedTranscript`: Regions also cover the pauses between turns, so unattributed
speech is kept. Given silence instead, Whisper writes a stock
phrase such as "Thank you.", and decoding it is wasted time.

#### Withdrawn transcription server is not a rejected sliver and must not be skipped
`AttributedTrackTranscriber.attributedTranscript`: A withdrawn transcription server is not a sliver
the engine rejected: skipping it would finish the
track without the rest of its audio.

#### Skip short slivers engines reject (Parakeet under 0.3 s) rather than fail meeting
`AttributedTrackTranscriber.attributedTranscript`: Turn boundaries leave slivers shorter than some engines accept
(Parakeet rejects audio under 0.3 s). Losing one sliver is far
better than failing the track, and with it the whole meeting.

#### 1 s tolerance gave 34.5% cpWER versus 51.1% strict midpoint on AMI
`AttributedTrackTranscriber.wordGapTolerance`: Words this close to a speaker turn take that speaker. Diarizer turn
edges and aligner word edges disagree by a few hundred milliseconds;
on AMI a 1 s tolerance gave 34.5% cpWER against 51.1% for a strict
midpoint rule (Benchmarks/transcribe/QwenSpanLength).

#### 0.75 s pause starts a segment; max 15 s keeps granularity of long windows
`AttributedTrackTranscriber.wordPauseSplit`: A pause this long between aligned words starts a new segment (FluidAudio
VAD's own split), and no segment grows past `maxSegmentSeconds`. Long
decode windows then keep the segment granularity of short ones.

#### Transcribe whole track then attribute words; regions when language or aligner unsupported
`AttributedTrackTranscriber.alignedWordTranscript`: Transcribes the whole track, then attributes timed words, so speaker
turns never cut the audio the model hears. Words come from the engine
when it times them (`providesWordTimings`), otherwise from the forced
aligner. `.regions` means "use regions": an unsupported language or an
unavailable aligner with no engine word times to fall back on.

#### Without engine word times the aligner is fetched before transcribing
`AttributedTrackTranscriber.alignedWordTranscript`: Without engine word times the aligner was fetched before transcribing.

#### Short-window auto-detection drifts languages, so keep the track's own language
`AttributedTrackTranscriber.alignedWordTranscript`: Decoding a few seconds at a time, auto-detection drifts
into other languages and scripts: keep the track's own.

#### Use engine word times when segment text can be cut at them, else forced aligner
`AttributedTrackTranscriber.engineWords`: The engine's own word times when `attribute` can cut the segment's
text at them; otherwise the forced aligner times the segment.

#### Nil language is decided after transcription; downloads the aligner if needed
`AttributedTrackTranscriber.alignerAvailable`: Whether the forced aligner can time words in `language` (nil: decided
after transcription), downloading it first if needed.

#### Failed alignment leaves segment with one speaker chosen at its midpoint
`AttributedTrackTranscriber.alignSegments`: The segment keeps one speaker, chosen at its midpoint.

#### Split at speaker change, pause, or max length; text cut never proportional; widen to turn edges
`AttributedTrackTranscriber.attribute`: Splits each engine segment where its aligned words change speaker,
pause for `wordPauseSplit`, or would outgrow `maxSegmentSeconds`.
Labels and attributions follow `regions`: one active turn names the
speaker, overlapping turns are unclear, and words away from every turn
keep the track label. Text is cut from the segment, never divided
proportionally. Speaker pieces then widen to the edges of their own
turns, without crossing a neighbour, so acoustic turns stay supported.

#### Match words in order by letters and digits; nil keeps segment whole
`AttributedTrackTranscriber.wordStarts`: Where each aligned word begins in `text`, matched in order on its
letters and digits (the aligner keeps adjacent punctuation on its
surface form). Nil when a word cannot be found, so the caller keeps
the segment whole rather than guessing a cut.

#### Recomputed embeddings map via retained audio intervals, not diarizer ordinal names
`AttributedTrackTranscriber.turns`: Recomputed embeddings (including crash resumes) map through retained
audio intervals, never through a diarizer's ordinal speaker names.

#### Call speech pauses between sentences, so coverage thresholds tolerate pauses
`AttributedTrackTranscriber.samples`: Call speech pauses between sentences; the voice model weighs only
the speaker's own frames, so a pause is not another person.

### `LokalBot/Services/Transcription/LiveMeetingTranscriber.swift`

#### Serialize live PCM work off main; seek into append-safe CAF suffix without copying
`LiveMeetingAudioPreparationWorker`: Serializes the filesystem and PCM work for both live meeting tracks away
from the main actor. The source CAF is append-safe, so preparation opens a
point-in-time reader and seeks directly to the unprocessed suffix; it never
copies the full, ever-growing meeting file.

#### One bounded reader supplies availability and audio suffix
`LiveMeetingAudioPreparationWorker.prepareNextChunk`: One bounded reader supplies both availability and the audio suffix.

#### Returns whole VAD chunks up to a maximum; empty if less than one or no file
`LiveMeetingAudioPreparationWorker.readChunks`: Whole voice-activity chunks recorded on a track since `frame`, at most
`maximumChunks` of them. Empty while less than one chunk is waiting or
the track has no file yet.

#### Recorder may be mid-append so fewer frames than reported can return
`LiveMeetingAudioPreparationWorker.readChunks`: The recorder may be mid-append, so fewer frames can come back than the file reports.

#### Turn cutting counts frames at the 16 kHz rate speech detection hears
`LiveMeetingAudioPreparationWorker.requireTurnFormat`: Turn cutting counts frames at the rate speech detection hears them.

#### A single read may fall short, so loop until frames or end of file
`LiveMeetingAudioPreparationWorker.read`: One read may stop short of what was asked for, so this reads until it
has the frames or the file has no more.

#### Recent preview shares one time origin; lagging tracks cannot backfill older audio
`LiveMeetingAudioPreparationWorker.initialCursors`: Recent preview uses one shared time origin, even when one track is
shorter or temporarily missing. Lagging tracks wait for that origin so
they cannot backfill audio older than the disclosed preview start.

#### Cursors belong to the recording, not a polling task, so pause or retry never replays chunks
`LiveMeetingTranscriber`: Explicitly enabled preview. Cursors belong to a recording, rather than to
a polling task, so pause/retry cannot replay already accepted chunks.

#### Preview text source: 4-12 s windows, opt-in turn-by-turn, or opt-in Muse streaming
`LiveMeetingTranscriber.Engine`: Where the preview's text comes from: the Transcribe model in windows
of 4 to 12 seconds, the same model one turn at a time (opt-in), or
Muse Voice Transcribe streaming turn by turn (opt-in).

#### In-progress turn is re-shown after 2 s more audio
`LiveMeetingTranscriber.Timing.interimEverySeconds`: A turn still being spoken is shown again after this much more audio.

#### Interim shown only if model answers within 0.25 s so finished turns never wait
`LiveMeetingTranscriber.Timing.interimBudgetSeconds`: It is shown only while the model answers this quickly, so a
finished turn never waits long behind a courtesy.

#### Returns speech probability for the next 256 ms with the model state handed back
`LiveMeetingTranscriber.VoiceActivity`: How likely the next 256 ms of a track are speech, with the model's
memory of that track handed back and forth.

#### At most one in-progress turn per track, with fast live text
`LiveMeetingTranscriber.partials`: Turns still being spoken, at most one per track, with fast live text.

#### Closed turns wait oldest first and belong to the recording so pause loses none
`LiveMeetingTranscriber.pendingTurns`: Turns that have closed and wait for the model, oldest first. They
belong to the recording like the cursors, so a pause loses none.

#### Last decode time judges whether the model is quick enough to show in-progress turns
`LiveMeetingTranscriber.lastDecodeSeconds`: How long the model took last time, to judge whether it is quick
enough to also show a turn that is still being spoken.

#### Speech detection hears 16 kHz, the rate both live files are written at
`LiveMeetingTranscriber.turnSampleRate`: Speech detection hears 16 kHz, the rate both live files are written at.

#### At most 8 s of one track per look so neither track waits on a backlog
`LiveMeetingTranscriber.chunksPerLook`: At most 8 s of one track per look, so neither track waits on a backlog.

#### Start choice applies only to first activation; retry and resume keep cursors
`LiveMeetingTranscriber.activate`: The start choice applies only to the first activation. Retry and resume
retain their cursors even if the recording has grown in the meantime.

#### Window mode continues from the cursor, discarding turns left waiting
`LiveMeetingTranscriber.activate`: Windows carry on from the cursor, past any turn left waiting.

#### Only a known calendar handoff carries opt-in forward; other idles clear it
`LiveMeetingTranscriber.stop`: Only a known calendar stop/start may carry the opt-in forward. An idle
transition after a failed start or an ordinary stop clears it again.

#### UI-test script plays timed lines with no audio or model, typing partials when fast text is on
`LiveMeetingTranscriber.uiTestScript`: UI-test host only: `LOKALBOT_UI_TEST_LIVE_SCRIPT` names a JSON array of
`{time, speaker, text}`. Each line appears `time` seconds after the
preview starts, as transcribed chunks would, with no audio or model.
With fast live text on, each line is first typed out word by word as a
partial, the way Muse Voice Transcribe's turns arrive; the words are
the script's, since the runner has no meeting audio.

#### Per-track turn state: cutter, VAD memory, last 1.5 s tail for length cuts, last interim frame
`LiveMeetingTranscriber.TrackState.cutter`: Turn by turn: the cutter and speech detection's memory of this
track up to `processedFrames`, the last 1.5 s heard (where a
length cut looks for quiet), and the frame the turn in progress
was last shown at.

#### Process buffered audio immediately; poll without spinning once caught up, backoff per track
`LiveMeetingTranscriber.run`: Already-buffered audio can be processed immediately. Once
caught up, poll without spinning; backoff is per track.

#### Start choice sets each track's cursor once per recording; false if session ended
`LiveMeetingTranscriber.initializeCursors`: The start choice sets each track's cursor once per recording. Returns
false when the session ended meanwhile.

#### Tee formats fixed at 16 kHz; chunk timestamps still use reader's rate
`LiveMeetingTranscriber.initializeCursors`: Both tee formats are fixed at 16 kHz. Actual chunk timestamps
still use the reader's sample rate.

#### Turns close about half a second after the speaker stops, decoded in closing order
`LiveMeetingTranscriber.runTurns`: Hears both tracks as they are recorded, cuts them at pauses
(`LiveTurnCutter`), and transcribes each turn once its pause is long
enough: about half a second after the speaker stops, against the
several seconds a window takes to fill. Turns are transcribed one at a
time in the order they closed. In between, a model that answers
quickly also shows the turn still being spoken.

#### Track state advances only when the whole look succeeds so failures replay from same frame
`LiveMeetingTranscriber.hear`: Runs what one track recorded since the last look through speech
detection and the turn cutter. Returns whether there was anything.
The track's state moves only when the whole look succeeded, so a
failed one is heard again from the same frame.

#### Turn closed without text leaves nothing to replace its shown partial, so drop it
`LiveMeetingTranscriber.dropFinishedPartials`: A turn that closed without text (too short to keep) leaves nothing to
replace what was shown of it.

#### Interim only with idle fast local model; remote servers hear each turn once to avoid re-uploads
`LiveMeetingTranscriber.showTurnInProgress`: With nothing waiting for the model, and a model on this Mac that has
just answered quickly, shows what the longest-running open turn says
so far. Its failure costs nothing: the turn's own text follows when
the speaker pauses. A transcription server hears each turn once, when
it is finished: showing it sooner would upload the same audio again
every two seconds.

#### User's name passed so Muse spells it correctly
`LiveMeetingTranscriber.keywords`: Your name, so Muse spells it as you do.

#### Session ended after running long (60-minute cap) reconnects; early drops count as failures
`LiveMeetingTranscriber.streamMuse`: One track's sessions. A session the server ends after running a while
(its 60-minute cap) reconnects at once; one that fails to start or
drops early counts as a failure and backs off, as local chunks do.

#### Missing track file means no call audio yet; wait and retry
`LiveMeetingTranscriber.streamMuse`: The track's file doesn't exist yet (no call audio so far).

### `LokalBot/Services/Transcription/LiveTranscriptChunker.swift`

#### Speech detection belongs to shared VAD; quietest speech is not a noise estimate
`LiveTranscriptChunker`: Bounded live-audio windows and inexpensive signal cleanup. Speech detection
belongs to the shared VAD; a chunk's quietest speech is not a noise estimate.

#### Guard Double rounding of Int64 frame count at the extreme
`LiveTranscriptChunker.nextChunk`: `available` is a valid Int64, but its Double representation may round
up at the extreme. The normal path only converts a bounded 12 s span.

#### Cut in quietest 200 ms window using vector reductions instead of per-sample loops
`LiveTranscriptChunker.refinedCutOffset`: Choose a cut inside a quiet 200 ms window. Vector reductions avoid the
repeated per-sample Swift loops over overlapping windows.

#### Gate is not a speech verdict; only silence and subsonic drift discarded, rest goes to VAD
`LiveTranscriptChunker.speechCandidate`: Returns a candidate for speech detection, NOT a positive speech verdict.
Only silence and predominantly subsonic/DC drift are discarded here.
Steady speech, room noise, and tones must reach VAD for classification.

### `LokalBot/Services/Transcription/LiveTurnCutter.swift`

#### Follows FluidAudio streaming rules plus eager long-turn close and max length; settings benchmarked
`LiveTurnCutter`: Cuts one live track into turns while it is being recorded. It hears only
the voice-activity model's verdict on each 256 ms chunk, and closes a turn
once the pause after it is long enough, so the turn can be transcribed
while the speaker is still quiet. No audio and no model: the caller runs
the model and reads the turn's samples.

The rules are FluidAudio's streaming ones (`VadManager.processStreamingChunk`)
with two additions: a long turn closes at its first quiet chunk, and a
turn with no pause at all is handed over at a maximum length.
Benchmarks/transcribe/LiveTurns measured the settings.

#### Probability at or above 0.85 counts as speech, as after a meeting
`LiveTurnCutter.Settings.speechThreshold`: A chunk at or above this probability is speech, as after a meeting.

#### Below 0.70 is quiet; between thresholds nothing changes
`LiveTurnCutter.Settings.quietThreshold`: A chunk below this one is quiet. In between, nothing changes.

#### Two quiet chunks close a turn, about half a second pause
`LiveTurnCutter.Settings.quietChunksToClose`: Quiet chunks that close a turn: two are a pause of about half a second.

#### Turns over 4 s close at first quiet chunk because multi-voice tracks pause briefly
`LiveTurnCutter.Settings.eagerAfterSeconds`: A turn this long closes at its first quiet chunk. Several voices
on one track leave shorter pauses between them than one voice
leaves inside a sentence, and a long turn has context to spare.

#### Under one chunk of speech after a length cut is not a turn
`LiveTurnCutter.Settings.minimumTurnSeconds`: Less than one chunk of speech is what a length cut leaves behind
when the speaker stops right after it, not a turn.

#### quietPoint picks the cut for max-length turns; default is end of chunk
`LiveTurnCutter.consume`: Takes the verdict on the next chunk and returns the turn it closed.
`quietPoint` picks where to cut a turn that reached the maximum
length, between the two frames it is given; without it the cut is at
the end of the chunk.

### `LokalBot/Services/Transcription/NemotronDiarizationModels.swift`

#### v2 CoreML export fixes M3 ANE compilation; pinned integrity-checked cache, not mutable main
`NemotronDiarizationModels`: The v2 CoreML export fixes ANE compilation on M3 while retaining the GA
checkpoint weights. Keep an immutable, integrity-checked cache rather than
following the upstream downloader's mutable `main` revision.

### `LokalBot/Services/Transcription/NeuralDiarizationEngine.swift`

#### Engine owns CoreML buffers off main actor; diarizer reset per track
`NeuralDiarizationEngine`: Acoustic speaker clustering for microphone and system-audio tracks.
Clusters identify distinct voices within a track; confirmation and identity
evidence determine whether a voice belongs to the user or someone else.

Owns CoreML buffers off the main actor. Nemotron's mutable prediction buffers
are used synchronously here and a fresh diarizer resets speaker state per track.

#### Release diarization models after idle; prewarm does not start timer
`NeuralDiarizationEngine.idle`: Like the transcription engines, release the models once processing
has been idle for a while; they used to stay resident until quit.
Recording-time prewarm does not start the timer, so a prewarmed model
waits for the meeting it was loaded for.

#### Size check lets background work skip download; load verifies all bytes
`NeuralDiarizationEngine.voiceModelInstalled`: The Pyannote voice model is on disk, so background work can use it
without a download. Loading still verifies every byte.

#### Verify pinned revision bytes before CoreML parses; avoid alternate cache paths
`NeuralDiarizationEngine.loadPinnedCommunityModels`: Preserve FluidAudio's existing immutable revision, but verify all
bytes before CoreML parses them and avoid its alternate cache paths.

#### Community-1 defaults tuned for meetings: short interjections, conservative merging
`NeuralDiarizationEngine.configuration`: Start from `community-1` defaults, override the knobs that matter
for meeting recordings (short interjections, conservative cluster
merging, never collapse to one speaker).

#### Clustering threshold 0.70 preserves existing app tuning
`NeuralDiarizationEngine.configuration`: preserve the existing app tuning

#### warmStartFa 0.07 is the pyannote default for VBx precision
`NeuralDiarizationEngine.configuration`: pyannote default; VBx precision

#### Minimum segment 0.3 s keeps brief interjections
`NeuralDiarizationEngine.configuration`: keep brief interjections

#### Minimum gap 0.05 s tolerates closely spaced turns
`NeuralDiarizationEngine.configuration`: tolerate close turns

#### Exclusive segments give each word one owner; FluidAudio 0.18.2 default keeps overlaps
`NeuralDiarizationEngine.configuration`: One speaker at a time, so each transcript word has one owner.
FluidAudio 0.18.2 changed the community default to keep overlaps.

#### Step ratio 0.15 gives finer windows: slower, better recall
`NeuralDiarizationEngine.configuration`: finer windows (slower but better recall)

#### Coalesce prewarm and processing loads; failed loads stay retryable
`NeuralDiarizationEngine.prepareModels`: Coalesce recording-time prewarm and processing; failed loads remain retryable.

#### Errors surface to retry UI, never saved as generic-speaker checkpoints
`NeuralDiarizationEngine.diarizeDetailed`: Errors are surfaced to the retry UI, never saved as successful generic-speaker checkpoints.

#### Nemotron slots are anonymous; voice samples map by temporal coverage, not slot ID
`NeuralDiarizationEngine.diarizeDetailed`: Nemotron slots are anonymous, not identity embeddings. Preserve the
existing 256-D voice space. AttributedTrackTranscriber maps these
samples by clean temporal coverage, never by a cross-model slot ID.

#### Silent track is an empty observation; other failures surface for retry
`NeuralDiarizationEngine.communityResult`: A valid silent track is an empty observation, not a failed
recording. Other model/file failures still surface for retry.

#### Segment keeps only start, end, raw speaker id; voice samples stay private
`DiarizedSegment`: FluidAudio's segment, distilled to what the pipeline actually uses (start,
end, raw speaker id like `"S1"`). Optional voice samples remain private.

### `LokalBotTests/Models/Transcription/SerbianLatinScriptTests.swift`

#### A model drifting out of Serbian writes Russian or Macedonian letters
`SerbianLatinScript.latin`: A model drifting out of Serbian writes Russian or Macedonian letters.

#### Apple's recognizer reads Serbian Cyrillic as Kazakh or Ukrainian, so Serbian letters decide
`SerbianLatinScript.isSerbianCyrillic`: Apple's recognizer reads Serbian Cyrillic as Kazakh or Ukrainian, so
Serbian's own letters decide it.

### `LokalBotTests/Models/Transcription/TranscriptSanitizerTests.swift`

#### llama.cpp Qwen3-ASR lacks repetition block and can loop to the token cap
`TranscriptSanitizer.sanitize`: llama.cpp decodes Qwen3-ASR without speech-swift's repetition block.
On the 0.6B benchmark one 8.3 s window looped "hey," until the token
cap (Benchmarks/transcribe/QwenLlamaCpp/results/2026-11-16-0.6b).

#### Test rows mimic prompt-echo microphone rows: speaker local, user identity, every ten seconds
`TranscriptSanitizerTests.makeTranscript(rows:)`: Microphone rows like the ones a prompt echo produced: speaker "local",
identity user, one row every ten seconds.

### `LokalBotTests/Models/Transcription/TranscriptionLanguageReplayTests.swift`

#### Opt-in replay of track transcription per engine and language; nothing leaves the Mac
`TranscriptionLanguageReplayTests`: Opt-in replay of track transcription on a saved recording, for checking
how each engine handles the meeting's language and silent stretches.
Runs the steps processing runs for one track (speaker separation,
attributed transcription, cleanup) on copies of the tracks, once per
engine and language condition. Nothing leaves this Mac.

#### Engine values are whisper, qwen-1.7b or qwen-0.6b
`TranscriptionLanguageReplayTests.Manifest.Condition.engine`: "whisper", "qwen-1.7b" or "qwen-0.6b".

#### Language is a transcription language code, nil for auto-detect
`TranscriptionLanguageReplayTests.Manifest.Condition.language`: A transcription language code, or nil for auto-detect.

#### Vocabulary is the meeting's saved transcription-vocabulary.json
`TranscriptionLanguageReplayTests.Manifest.vocabulary`: A meeting's saved `transcription-vocabulary.json`, if any.

#### Content range is in seconds, as saved in meta.json
`TranscriptionLanguageReplayTests.Manifest.contentRange`: The meeting's content range in seconds, as saved in meta.json.

#### Report folder must be outside the repository
`TranscriptionLanguageReplayTests.Manifest.output`: Report folder; keep it outside the repository.

#### Mirrors the two halves of ProcessingPipeline.transcribedTrack to report before and after cleanup
`TranscriptionLanguageReplayTests.testTracksAcrossEnginesAndLanguages`: The two halves of `ProcessingPipeline.transcribedTrack`, so
the report holds the transcript before and after cleanup.

### `LokalBotTests/Models/Transcription/TranscriptionPromptEchoTests.swift`

#### A prompt-capable model answers a near-silent span with its vocabulary hint
`TranscriptionPromptEcho`: A prompt-capable speech model answers a near-silent span with its
vocabulary hint. Synthetic names stand in for the rows seen in a library.

### `LokalBotTests/Models/Transcription/TranscriptionVocabularyTests.swift`

#### Merged source suffixes and placeholder speaker labels are dropped; recognizer returned them as rows
`TranscriptionVocabulary.terms`: A merged meeting's applied names carry "· source N", and labels such as
"Them 6" name nobody; fed to the recognizer they came back as rows.

### `LokalBotTests/Models/Transcription/UkrainianLanguageSelectionTests.swift`

#### Escaped-bug regression for #368, no models or audio needed
`UkrainianLanguageSelectionTests`: Escaped-bug regression for #368. These tests need no models or audio.

### `LokalBotTests/Models/Transcription/UkrainianTranscriptionTests.swift`

#### Cover meeting, dictation/live-preview and word-attribution entry points
`UkrainianTranscriptionTests`: Exercise meeting, dictation/live-preview, and word-attribution entry points.

### `LokalBotTests/Services/Transcription/AppleSpeechWordAttributionTests.swift`

#### Continuous words split into chunks of at most 15 seconds
`testBuildTimedSegmentsSplitsOnPausesAndDurationLimitWhileKeepingPunctuation`: 45 seconds of continuous 0.5 s words splits into \<= 15 s chunks.

### `LokalBotTests/Services/Transcription/LiveMeetingTranscriberTests.swift`

#### Calendar handoff emits idle between the two recording states
`testCalendarStopStartPreservesActivePreview`: Actual handoff emits idle between the two recording states.

#### Starting-to-idle failure must be observed though neither state has a meeting ID
`testFailedCalendarStartClearsPendingOptIn`: A starting -> idle failure must be observed even though neither
state has a meeting ID.

### `LokalBotTests/Services/Transcription/LiveTranscriptChunkerTests.swift`

#### Cut search window is 200 ms; shorter tails cut at their end
`testShortTailCutsAtItsEnd`: shorter than the 200 ms window

#### Energy alone cannot separate steady speech from steady background noise
`testStationaryRoomToneIsLeftForVAD`: Room tone reaches the speech detector; energy alone cannot reliably
distinguish steady speech from steady background noise.

#### Steady signal must not be rejected solely for lacking dynamics
`testStationaryHumIsLeftForVAD`: A steady signal must not be rejected solely for lacking dynamics.

#### Mic tee 10-50 Hz drift cleared the dynamics gate and made Granite hallucinate
`testAmplitudeModulatedSubsonicRumbleHasNoSpeech`: Regression: the live mic tee carried strong 10–50 Hz drift whose
changing amplitude cleared the dynamics gate and made Granite emit
fluent sentences in random languages. It has no speech-band energy.

#### Very quiet speech about 4.7x the absolute floor must pass the gate
`testQuietBurstsJustAboveAbsoluteFloorHaveSpeech`: Very quiet speech (burst RMS ≈ 0.014, ~4.7× the absolute floor) over
a near-silent room must still pass the gate.

#### Dynamics rescue speech that an absolute threshold would misjudge over hot room tone
`testSpeechOverHotRoomToneHasSpeech`: Dynamics rescue what an absolute threshold would misjudge: the same
hot room tone as the regression case, plus real speech bursts.

#### Rumble filter must keep harmonics of a 95 Hz voice
`testLowVoiceFundamentalAndHarmonicsStillHaveSpeech`: A 95 Hz fundamental is below the cleanup cutoff, but a natural voice
carries harmonics above it. The rumble filter must not erase that.

#### Do not reject brief replies by duration; VAD separates them from thumps
`testShortBurstIsLeftForVAD`: Do not reject brief replies based on duration. VAD distinguishes
an actual short utterance from a thump or keyboard click.

#### 400 Hz period divides gate window and hop exactly, making tests deterministic
`LiveTranscriptChunkerTests.tone`: 400 Hz sine: its 40-sample period at 16 kHz divides the gate's window
and hop exactly, so every full window has RMS = amplitude/√2 and every
test is fully deterministic.

### `LokalBotTests/Services/Transcription/LiveTurnTextTests.swift`

#### Turn-by-turn live text tests use tone as speech, silence as pause
`LiveTurnTextTests`: Turn-by-turn live text on this Mac: the preview cuts each track at pauses
and transcribes one turn at a time. Speech detection and the model are
stand-ins; a tone is speech and digital silence is a pause.

#### A turn starts up to one 256 ms chunk plus 0.1 s padding early
`testEachPauseDeliversItsTurn`: A turn starts up to one 256 ms chunk and 0.1 s of padding before its first word.

#### Write beside the track then move, so running preview never sees partial file
`LiveTurnTextTests.write`: Written beside the track and moved into place, so a preview that
is already running never opens a half-written file.

### `LokalBotTests/Services/Transcription/NemotronRuntimeTests.swift`

#### Public-fixture test is opt-in; CI stays offline; see benchmark README
`NemotronRuntimeTests`: Explicit public-fixture test. CI stays offline; see the benchmark README for
preparing these pinned models, AMI audio, and the old runtime's voice vectors.

#### Silence still runs the model; no VAD mask bypasses inference
`testPinnedV2ModelRunsAndResetsOnCPUAndNeuralEngine`: Opt-in hardware check on the same pinned v2 files the app downloads.
Silence still runs the model; no VAD mask bypasses inference here.

#### Voice profiles compare normalized directions since CoreML rounding differs across builds
`testPublicRecordingResetAndVoiceCompatibility`: Profiles compare normalized directions, not bitwise-equal model output.
CoreML execution can round differently across builds/accelerator routes.

### `LokalBotTests/Services/Transcription/WordAttributionTests.swift`

#### Transcribe whole track first, then assign forced-aligned words to diarized turns
`WordAttributionTests`: Transcribe-first speaker attribution: forced-aligned words are assigned
to diarized turns after whole-track ASR, instead of cutting audio first.

#### 1.7B used 60 s windows with MLX aligner; CoreML aligner takes 30 s
`testQwenTiersAttributeAlignedWordsWithTheirMeasuredWindows`: 1.7B used 60 s with the MLX aligner; the CoreML aligner takes 30 s at most.

#### 0.6B stays at 15 s windows; longer decoded 5-10x slower
`testQwenTiersAttributeAlignedWordsWithTheirMeasuredWindows`: 0.6B stays at 15 s: longer windows decoded 5–10× slower for a small gain.

#### Aligner snapshot ships compiled bundles only; mlpackage would compile on every load
`testAlignerLanguagesAndPinnedSnapshot`: Compiled bundles only: an .mlpackage would compile on every load.

#### Settings and PRIVACY.md state the aligner download as about 1.1 GB
`testAlignerLanguagesAndPinnedSnapshot`: Settings and PRIVACY.md describe this download as about 1.1 GB.

#### Aligner windows must fit 30 s encoder including flooring sample
`testWordAttributionWindowsFitTheAlignerEncoder`: Every window handed to the aligner fits its 30 s encoder, including the
extra sample that flooring both edges can add.

#### SpanAudioReader floors both frame positions
`testWordAttributionWindowsFitTheAlignerEncoder`: SpanAudioReader floors both frame positions.

#### Over-long segments are refused before model load so one-speaker fallback applies
`testAlignerRefusesSegmentsLongerThanItsEncoder`: A segment past the encoder's 30 s is refused before any model loads,
so the caller's one-speaker fallback applies without a download.

#### MLX aligner folder is deleted once CoreML snapshot verifies; others and symlinks stay
`testObsoleteAlignerFolderIsRemovedByExactPath`: The MLX aligner's folder is deleted once the CoreML snapshot is
verified; other folders and symlinked ones are left alone.

#### Short regions decode in track language; Qwen misreads breaths as CJK or Russian
`testRegionsFallbackDecodesInTheLanguageTheTrackSettledOn`: On auto-detect, a track the aligner cannot time falls back to speaker
regions. Those regions are seconds long, too short to detect the
language again: Qwen reads breaths and short replies in them as
Chinese, Japanese or Russian. They decode in the language the whole
track settled on instead.

#### Engine stopping after language sample still goes to speaker regions
`testEngineThatStoppedForRegionsIsAttributedByRegionsInItsLanguage`: Qwen stops after its language sample when the track settles on a
language the aligner cannot time, and returns no segments: the track
still goes to speaker regions, decoded in that language, rather than
being saved empty.

#### Whisper writes stock phrases for silent regions, so skip them
`testRegionsWithoutDetectedSpeechAreNotDecoded`: Speaker regions also cover the pauses between turns. Given one with
no speech, Whisper writes a stock phrase such as "Thank you.", so a
region without detected speech is not decoded.

#### Opt-in hardware check of pinned digests with network disallowed
`testCachedAlignerVerifiesPinsAndTimesEveryWord`: Opt-in hardware check: the pinned digests match the real files, which
load offline and time every word. No network access is allowed.

#### CoreML pass leaks 12 MB autoreleased arrays; needs pool per pass
`testCachedAlignerKeepsFootprintFlatAcrossSegments`: Opt-in hardware check: many passes over segments of different lengths
keep the footprint flat. Each CoreML pass returns about 12 MB of
autoreleased arrays; without a pool per pass, a long track's footprint
grew from 0.8 GB to 4.6 GB.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
