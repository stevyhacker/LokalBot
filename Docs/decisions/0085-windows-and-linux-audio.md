# 0085. Windows and Linux: audio

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs`, `LinuxWindows/crates/lokalbot-audio/src/capture.rs`, `LinuxWindows/crates/lokalbot-audio/src/cue.rs`, `LinuxWindows/crates/lokalbot-audio/src/decode.rs`, `LinuxWindows/crates/lokalbot-audio/src/export.rs`, `LinuxWindows/crates/lokalbot-audio/src/import.rs`, `LinuxWindows/crates/lokalbot-audio/src/lib.rs`, `LinuxWindows/crates/lokalbot-audio/src/mic_capture.rs`, `LinuxWindows/crates/lokalbot-audio/src/player.rs`, `LinuxWindows/crates/lokalbot-audio/src/process_loopback.rs`, `LinuxWindows/crates/lokalbot-audio/src/recorder.rs`, `LinuxWindows/crates/lokalbot-audio/src/resample.rs`, `LinuxWindows/crates/lokalbot-audio/src/speech_player.rs`, `LinuxWindows/crates/lokalbot-audio/src/splice.rs`, `LinuxWindows/crates/lokalbot-audio/src/stretch.rs`, `LinuxWindows/crates/lokalbot-audio/src/system.rs`, `LinuxWindows/crates/lokalbot-audio/src/track.rs`, `LinuxWindows/crates/lokalbot-audio/src/wav.rs`, `LinuxWindows/crates/lokalbot-audio/src/waveform.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs`

#### Them track records the meeting app when separable; whole output is the safe fallback
Whose sound the "Them" track records (`SystemAudioRecorder.swift`,
`RecordingController.swift`): the meeting app's when it can be separated,
so other sounds stay out, otherwise everything the computer plays.

Everything the meeting app plays is also in the whole output, so the whole
output is always the safe answer: a tap that can't open, or an app with no
open output stream, never costs the recording its other side.

#### Apps closing streams between sentences return to their tap when the stream reopens
`NO_OUTPUT_GRACE`: How long a meeting app may have no output stream before the whole output
is recorded instead. An app that closes its stream between sentences comes
back to its tap as soon as the stream reopens.

#### On Windows the whole process tree of the top process counts
`AppAudioTarget.pid`: The top process of the app. On Windows its whole process tree counts.

#### Same app is recognised even when it restarted under a new process
`AppAudioTarget::same_app`: The same app, even when it restarted under a new process.

#### Mirrors considerDetectedSource: unbound binds to call, bound follows only its own replacement
`next_target`: The target a recording moves to when a call is detected
(`considerDetectedSource`): one with no target binds to the call, and one
bound to an app only follows that app's replacement process. It never moves
to another app's call.

#### Process loopback exists from Windows 10 build 20348
`build_has_process_loopback`: Process loopback exists from Windows 10 build 20348.

#### Chooser is pure so fallback rules are testable without a sound server
`ScopeChooser`: Chooses between the app's tap and the whole output, from what each poll
sees. Pure, so the fallback rules are testable without a sound server.

#### Unreadable app output state changes nothing
`ScopeChooser::observe`: `app_output` is whether the app has an open output stream, or `None`
when that couldn't be read. An unreadable state changes nothing.

#### Stream id is the sink input on Linux, emitting process on Windows
`AppStream.id`: The sink input (Linux) or the emitting process (Windows).

#### A stream that moves to another device is reopened
`AppStream.device`: The output device it plays on. A stream that moves is reopened.

#### A lagging stream counts as silence after MAX_SKEW so others are not held up
`StreamMixer`: Mixes a tap's streams into one track. A stream that stops delivering (it
paused, or the app is about to close it) must not hold up the others, so
it counts as silence once it is `MAX_SKEW` frames behind.

#### MAX_SKEW of 640 frames is 40 ms at 16 kHz
`StreamMixer::MAX_SKEW`: 40 ms at 16 kHz.

### `LinuxWindows/crates/lokalbot-audio/src/capture.rs`

#### Linux cpal uses PulseAudio/pipewire-pulse for readable names, else ALSA; Windows WASAPI
Microphone devices and cpal input streams.

On Linux cpal talks to PulseAudio (or PipeWire through pipewire-pulse) when a
server is running, which gives readable device names, and falls back to ALSA.
On Windows it uses WASAPI.

#### Stored device id has the form host:device
`AudioDevice.id`: Stable identifier to store in settings (`host:device`).

#### Monitor sources and ALSA plumbing devices are not offered as microphones
`is_offered_input`: Inputs worth offering: monitor sources (loopback of speakers) and ALSA
plumbing devices are left out.

#### Mic resolves by stored id, then name, then default, reporting the fallback
`resolve_input_device`: The microphone to record from: the stored id, then a device with that name,
then the system default. The second value explains a fallback.

#### Xruns and automatic reroutes are counted, not treated as failures
`StreamFlags`: Errors reported by a stream's error callback. Xruns and automatic reroutes
are counted, not treated as failures.

#### Windows output device opens as WASAPI loopback stream
`open_stream`: Opens `device` for capture in its preferred format and feeds mono buffers to
`sink`. On Windows, an output device yields a WASAPI loopback stream.

#### Request 30 ms buffers because PulseAudio otherwise delivers 2 s fragments
`open_stream`: Ask for ~30 ms buffers: PulseAudio otherwise delivers 2 s fragments,
which delays meters and stream start. Fall back to the device default.

#### Place buffers by capture time, not arrival time
`build_any input callback`: Place the buffer by when it was captured, not when it arrived.

### `LinuxWindows/crates/lokalbot-audio/src/cue.rs`

#### Dictation start cue mirrors Mac Tink at 0.35 and is synthesized, no sound file
The short cue played when the dictation microphone starts delivering audio
(`DictationCoordinator.startSound`, "Tink" at 0.35 on macOS). It is
synthesized, so no sound file ships with the app.

#### Cue volume 0.35 matches the Mac
`VOLUME`: As quiet as the Mac's.

#### Cue plays on its own thread; machines without output stay quiet
`play_start`: Plays the cue on its own thread. A machine with no output just stays quiet.

#### Hold the output device open until the cue has played
`play_start`: Hold the device until the sound has played.

### `LinuxWindows/crates/lokalbot-audio/src/decode.rs`

#### Symphonia does not trim AAC priming, so trim it from edit list or iTunSMPB like AVFoundation
Meeting tracks in any format the library selects, read as the 16 kHz mono
stream the WAV tracks this app records give. A library recorded on macOS
keeps AAC in `mic.m4a`/`system.m4a`; FLAC tracks read the same way.
Symphonia decodes them. It does not trim the priming an AAC encoder adds,
so that happens here, from the MP4's edit list or the `iTunSMPB` tag
AVFoundation writes instead, as AVFoundation does on macOS: transcript
times then line up with the audio on both platforms.

#### AAC frames overlap, so decode and drop pre-roll frames before a seek target
`PRE_ROLL`: Source frames decoded and dropped before a seek target. AAC frames
overlap, so a frame only decodes right after the one before it.

#### MP4 headers over 64 MiB are not read for edit lists
`MAX_MOOV_BYTES`: An MP4 header larger than this is not read for its edit list.

#### WAV keeps its own rate; compressed tracks are always 16 kHz
`TrackReader::sample_rate`: The rate `read_mono` returns: a WAV file's own, 16 kHz otherwise.

#### Encoder priming delay is measured in source frames
`CompressedReader.delay`: Encoder priming at the start of the stream, in source frames.

#### Playable length is in source frames after the priming
`CompressedReader.playable`: Source frames that play after the priming.

#### Track length is expressed at 16 kHz
`CompressedReader.frames`: The track's length at 16 kHz.

#### Next frame returned is counted at 16 kHz
`CompressedReader.position`: The next frame `read_mono` returns, at 16 kHz.

#### Source frames before this are dropped: priming or seek pre-roll
`CompressedReader.skip_until`: Source frames before this one are dropped: the priming, or a seek's
pre-roll.

#### Pending holds decoded 16 kHz samples with taken already returned
`CompressedReader.pending`: Decoded 16 kHz samples, `taken` of them already returned.

#### Files with several audio tracks, such as screen recordings, open per track
`CompressedReader::open_track`: One audio track of a file with several, such as a screen recording's
microphone and system audio; `None` is the default track.

#### The MP4 edit list describes only the first audio track
`CompressedReader::open_track`: The MP4 edit list read here describes the first audio track.

#### Reopen a fresh reader per seek because Symphonia MP4 cannot seek after end
`CompressedReader::seek_frame`: A fresh reader every time: Symphonia's MP4 reader cannot seek once
it has read to the end, and the decoder starts clean.

#### Failed seek falls back to decoding from the start, only slower
`CompressedReader::seek_frame`: Decoding from the start reaches the target too, only slower.

#### Damaged packets become silence so the tracks stay in step
`CompressedReader::decode_more`: A damaged packet passes as silence, so the tracks stay in step.

#### Total frames include priming and exist only when the container says
`Stream.total`: Frames in the stream, priming included, when the container says.

#### Crash CAFs have data size -1 which Symphonia misreads; present as a closed file
`UnfinishedCaf`: A CAF whose writer never closed it, which is what a Mac's crash audio
(`mic.live.caf`) looks like: its data chunk says -1 for "to the end of the
file", and the file may stop inside a sample. Symphonia's reader takes that
-1 and then reads the audio as if it were more chunks, so this presents the
file as the closed one it would have been.

#### CAF data chunk size includes the four-byte edit count
`UnfinishedCaf::open`: The size counts the data chunk's four-byte edit count too.

#### Commentary and described-video tracks are excluded, default track first
`audio_track_ids`: The IDs of a file's audio tracks that can be decoded, the default first.
Commentary and described-video tracks are left out.

#### ADTS length is a guess from a few frames, so ignore it
`Stream::open`: ADTS doesn't say how long it is. Symphonia's figure is a guess
from a few hundred frames, and reading stops where the length says.

#### AVFoundation writes AAC gapless info as iTunSMPB tag instead of edit list
`itunes_gapless`: Apple's gapless tag, which AVFoundation writes for AAC in place of an edit
list: a `----` item named `iTunSMPB` under `moov/udta/meta/ilst`, holding
hex fields (reserved, priming, padding, frames that play, ...).

#### meta is a full box: version and flags precede children
`itunes_gapless`: `meta` is a full box: its version and flags come before the children.

#### iTunSMPB value follows a type indicator and locale
`itunes_gapless`: The value follows a type indicator and a locale.

#### Recording date is the movie header creation time, as AVAsset.creationDate; zero is unset
`mp4_creation_time`: The body of the top-level `moov` box, wherever it sits in the file.
When an MP4 or QuickTime file says it was recorded: the movie header's
creation time, which `AVAsset.creationDate` reports on macOS. Zero
means unset.

#### MP4 times count seconds since 1904-01-01 UTC
`mp4_creation_time`: Seconds since 1904-01-01 UTC.

#### Empty edits with media time -1 only delay presentation so are skipped
`first_edit`: The first edit that plays media, as (segment duration in the movie's
timescale, media time in the track's). An empty edit (media time -1) only
delays the presentation, so it is passed over.

#### Fixture is a macOS AAC track with 2112 priming and 448 padding frames
`tests::macos_track`: A track the macOS app recorded: AAC-LC, mono, 16 kHz, 140 s, with
2112 frames of encoder priming and 448 of padding around it.

#### Crashed recorder never wrote CAF data size and may stop mid-sample
`tests::crash_tee`: `mic.live.caf`: 16 kHz mono Float32. A recorder that crashed never wrote
the data chunk's size (-1), and may have stopped inside a sample.

#### Test uses an empty edit first then 140 s from frame 2112
`reads_an_edit_list_in_the_movie_and_track_timescales`: An empty edit first, then 140 s (ms timescale) from frame 2112.

### `LinuxWindows/crates/lokalbot-audio/src/export.rs`

#### No AAC encoder on Linux/Windows so export mixes into 16 kHz WAV
"Export audio": a meeting's tracks mixed into one file to keep or share
(`MeetingAudioAsset.exportMixedRecording`). The Mac writes AAC with its
system exporter; there is no AAC encoder here, so this writes a 16 kHz WAV.

#### Read in blocks so long meetings never sit in memory
`export_mixed`: Writes `mic` and `system` summed onto one timeline, reading in blocks so a
long meeting never sits in memory. Returns the length in seconds.

### `LinuxWindows/crates/lokalbot-audio/src/import.rs`

#### Import mixes every audio track to 16 kHz; video picture dropped, source only read
Audio from a file a person imports (`MeetingImportService.exportAudio`):
every audio track of a recording mixed into one 16 kHz track, so a screen
recording's microphone and system audio both reach the transcript. A
video's picture is dropped and the original file is only read.

#### Audio shorter than 0.3 s is treated as nothing to transcribe
`MIN_IMPORT_SECONDS`: Shorter than this is no audio to transcribe.

#### NoAudio covers readable files with none or under MIN_IMPORT_SECONDS
`ImportError::NoAudio`: Readable, but with no audio, or under `MIN_IMPORT_SECONDS` of it.

#### Recorded date is the container creation date when present
`ImportedAudio.recorded_at`: The recorder's own creation date, when the container has one.

#### On failure the destination file is removed
`import_audio`: Decodes `source` into a 16 kHz mono WAV at `dest`. On failure `dest` is removed.

#### Reads are full-length until a track ends so tracks stay aligned
`mix`: Sums the tracks chunk by chunk; each read is full-length until its track
ends, so the tracks stay aligned.

#### ADTS AAC is the one format phone and tablet apps send; ffmpeg recipe
`tests::adts_tone`: One second of a 440 Hz tone as an ADTS AAC stream, the one format the
phone and tablet apps send: `ffmpeg -f lavfi -i
"sine=frequency=440:duration=1" -c:a aac -b:a 32k -f adts`.

#### Dead recorder stops mid-frame; earlier frames are still the recording
`imports_what_a_dead_recorder_left`: A recorder that dies stops in the middle of a frame, and the earlier
frames are still the recording.

#### Symphonia ADTS length guess must not truncate; devices delete copy after storing
`imports_all_of_a_stream_whose_frames_vary_in_size`: ADTS doesn't say how long it is, and Symphonia's figure comes from the
frames at four points in the file. A device deletes its copy once the
meeting is stored, so one that's bigger there than elsewhere must still
arrive whole.

### `LinuxWindows/crates/lokalbot-audio/src/lib.rs`

#### Tracks are 16 kHz mono 16-bit WAV; TrackReader reads macOS AAC/FLAC same way
Audio capture and playback for LokalBot on Linux and Windows.

A meeting is two time-aligned tracks in its folder, `mic.wav` ("Me") and
`system.wav` ("Them"), both 16 kHz mono 16-bit PCM — the format the speech
models read, so no conversion happens before transcription. The macOS app
records AAC `.m4a` files instead; [`TrackReader`] reads those (and FLAC) as
the same 16 kHz stream, so playback, waveforms and transcription work on a
library from either platform.

### `LinuxWindows/crates/lokalbot-audio/src/mic_capture.rs`

#### More than 3 recoveries within 20 s ends dictation, as DictationCoordinator
`MAX_RECOVERIES`: Reconnections allowed before the dictation ends (`DictationCoordinator`:
more than 3 recoveries within 20 s ends it).

#### Hard memory cap of 30 minutes of audio
`MAX_SAMPLES`: Hard cap on memory: 30 minutes of audio.

#### Do not join the timed-out thread; let it end itself on stop
`MicCapture::start`: The thread is still inside the audio system. Joining it
would wait for the call this timeout gave up on, so it is
left to end by itself once it sees the stop.

#### Level is loudness in the range 0 to 1
`MicCapture::level`: Current loudness, 0–1.

#### Overlay dot turns red once the microphone delivers audio
`MicCapture::has_audio`: Whether the microphone delivered any audio yet (the overlay dot turns red).

#### Shutdown never blocks; an unread stop is stop enough
`MicCapture::shutdown`: Never blocks: a stop the thread has not read yet is stop enough.

### `LinuxWindows/crates/lokalbot-audio/src/player.rs`

#### Both tracks share a timeline; gains 0.85 system and 0.55 mic, 1.0 for one
Plays a meeting's two tracks together (`MeetingPlayer.swift`). Both files
share one timeline, so one mixed source reproduces the meeting; the longest
track decides the duration. Gains follow `MeetingAudioAsset`: system 0.85
and mic 0.55 together, 1.0 for a single track.

#### Output block is 20 ms rendered under the lock
`BLOCK`: Output block rendered under the lock: 20 ms.

#### Keep one second of history for WSOLA look-back, drop the rest
`Mix::fill_cache`: Keep a little history for WSOLA's look-back, drop the rest.

#### Position is next timeline frame at 1x and unused while stretching
`State.position`: Next timeline frame at 1× (unused while stretching).

#### Paused or finished output emits silence to keep the stream alive
`PlayerSource::next`: Paused or finished: keep the stream alive with silence.

#### Output device opens lazily on first play; either track may be missing
`Player::open`: Opens the tracks (either may be missing). The output device opens on
the first [`Player::play`].

#### Thread holds the output device until the player goes away
`Player::ensure_output`: Hold the device until the player goes away.

#### Playing at the end restarts from the beginning
`Player::play`: Starts or resumes playback; at the end it starts over.

#### Speed is clamped to 0.75 to 2.0 with pitch preserved
`Player::set_speed`: Playback rate, clamped to 0.75–2.0; pitch is preserved.

### `LinuxWindows/crates/lokalbot-audio/src/process_loopback.rs`

#### WASAPI process loopback needs build 20348, checked at run time, else whole output
Windows: one process tree's sound through WASAPI process loopback, the
counterpart of `CoreAudioProcessTap`. It needs Windows 10 build 20348 or
later, which is checked at run time; older systems record the whole output.

#### Process loopback has no mix format, so use the format Windows' sample records
`SAMPLE_RATE/CHANNELS/BITS`: Windows' own process loopback sample records this format; it mixes down
whatever the process plays. Process loopback has no mix format to ask for.

#### Buffer duration is 200 ms in 100 ns units
`BUFFER_DURATION`: 200 ms, in 100 ns units.

#### Snapshot handle is closed and dwSize set as Process32FirstW requires
`process_parents`: SAFETY: the snapshot handle is closed below; `entry` has dwSize set as
Process32FirstW requires.

#### Returns None when sessions cannot be read
`playing_processes`: The processes of `root`'s tree with an active session on any output.
`None` when the sessions can't be read.

#### COM interfaces are owned here and COM is initialized by the scope
`playing_processes`: SAFETY: COM calls on interfaces this function owns; COM is initialized
by the scope above.

#### Raw union so nothing frees the blob that lives on the stack
`activate`: Raw union, so nothing tries to free the blob, which lives on this stack.

#### variant and parameters outlive the call, which copies them
`activate`: SAFETY: `variant` and `parameters` outlive the call, which copies them.

#### format outlives the calls; event handle closed in drop
`Session::open`: SAFETY: `format` outlives the calls; the event is closed in `drop`.

#### Buffer is read only between GetBuffer and ReleaseBuffer in the set format
`Session::drain`: SAFETY: the buffer is read only between GetBuffer and ReleaseBuffer,
and holds `frames` frames of the format `open` set.

#### Dropping the tap stops the capture
`ProcessLoopback`: A running tap. Dropping it stops the capture.

### `LinuxWindows/crates/lokalbot-audio/src/recorder.rs`

#### Streams live on a control thread because cpal streams are not Send everywhere
Meeting recording: `mic.wav` ("Me") and `system.wav` ("Them") on one timeline.

Streams live on a control thread (cpal streams are not `Send` everywhere),
which also reconnects a lost microphone and follows the default output
device. Each track has its own writer thread. `Recorder` itself only holds
channels and counters, so it is `Send` and can sit behind a mutex.

#### Recently active means within 10 s, as RecordingMemoryHealthSnapshot.isRecent
`RECENT_MS`: A source counts as recently active within this window (`RecordingMemoryHealthSnapshot.isRecent`).

#### Mic delivering nothing for 3 s is reopened
`MIC_STALL_MS`: A microphone that delivers nothing for this long is reopened.

#### Linux monitor delivers silence continuously; 5 s of nothing means broken
`SYSTEM_STALL_MS`: The Linux monitor delivers silence continuously; nothing for this long means it broke.

#### Mic id or name; None or empty means system default
`RecorderOptions.mic_device`: Stored microphone id (see [`crate::AudioDevice::id`]) or name; `None` or
empty records from the system default input.

#### Record the meeting app alone when separable, else everything played
`RecorderOptions.system_app`: The meeting app to record alone when it can be separated. Without one,
or when it can't, everything the computer plays is recorded.

#### Levels are loudness 0 to 1 for the 20-segment meters
`Levels`: Current loudness, 0–1, for the 20-segment meters.

#### Recovery attempt numbering starts at 1
`TrackHealth::Recovering`: Reconnecting the microphone; `attempt` starts at 1.

#### Labels use the macOS health strip wording without attempt or detail
`TrackHealth::label`: The macOS health strip wording (without the attempt number or detail).

#### Age is None before the first audio arrives
`CaptureHealth.mic_age`: Seconds since microphone audio arrived; `None` before the first.

#### Windows loopback delivers nothing while nothing plays
`CaptureHealth.system_quiet_is_normal`: A quiet Windows loopback delivers nothing while nothing plays.

#### Mic must open unless system does; system failure records mic-only with warning like macOS
`Recorder::start`: Starts recording into `dir` (created if needed). The microphone must
open unless system audio does; a system-audio failure records the
microphone alone with a warning, as on macOS.

#### Do not join the timed-out thread; let it end itself on stop
`Recorder::start`: The thread is still inside the audio system. Joining it
would wait for the call this timeout gave up on, so it is
left to end by itself once it sees the stop.

#### Both tracks stop at the same instant to stay aligned
`Recorder::stop`: Stops both tracks at the same instant and closes the files.

#### Reconnect backoff is 0.5 s, 1 s, 2 s, then every 4 s
`retry_delay`: Exponential backoff for reconnecting: 0.5 s, 1 s, 2 s, then every 4 s.

### `LinuxWindows/crates/lokalbot-audio/src/resample.rs`

#### Integer output positions prevent drift; Kaiser sinc at 90% Nyquist, unity DC gain
Streaming windowed-sinc resampler for mono audio.

Output sample `n` sits exactly at input position `n * in_rate / out_rate`
(computed in integers, so hours of audio never drift). The kernel is a
Kaiser-windowed sinc low-pass at 90% of the lower Nyquist frequency, 16 zero
crossings each side, normalised per output sample for exact unity DC gain.

#### buffer[0] corresponds to global input index buffer_start
`Resampler.buffer`: Pending input; `buffer[0]` is global input index `buffer_start`.

#### Flush treats input past the end as silence
`Resampler::flush`: Emits the remaining output, treating input past the end as silence.

#### Resampled tone must have the same phase as the ideal one, no delay
`keeps_passband_tones`: Same phase as the ideal 16 kHz tone (no delay).

### `LinuxWindows/crates/lokalbot-audio/src/speech_player.rs`

#### Read-aloud clip takes any rate and plays once; meeting playback is 16 kHz seekable
Plays one synthesized clip (Read aloud). Meeting playback is 16 kHz and
seekable ([`crate::Player`]); this takes any rate, plays once and stops.

#### Wait 200 ms for audio the device took but has not played
`DRAIN`: Audio the device has taken but not yet played when the clip's samples end.

#### A stopped clip must not wait for a stalled device
`SpeechPlayer::start`: A stopped clip doesn't wait for a stalled device to
ask for its next sample.

### `LinuxWindows/crates/lokalbot-audio/src/splice.rs`

#### Missing or short tracks leave silence so tracks and transcript share a timeline
A merged meeting's tracks (`MeetingMergeService.export`): a part of each
source track laid end to end. A source without that track, or a track
that ends early, leaves silence, so both tracks and the transcript keep
the same timeline.

#### A missing track still takes up end minus start
`SplicePart`: One source's part: `(track, start, end)` in seconds on that source's
timeline. A missing track still takes up `end - start`.

#### Returns which parts contributed; writes nothing when none did
`splice_tracks`: Writes the parts in order into a 16 kHz WAV at `dest` and returns which
parts contributed audio. When none did, nothing is written.

### `LinuxWindows/crates/lokalbot-audio/src/stretch.rs`

#### WSOLA with 40 ms frames, 50% Hann, ±10 ms nudging, like AVAudioPlayer enableRate
WSOLA time stretching: playback at 0.75–2× without changing pitch, like
`AVAudioPlayer` with `enableRate` on macOS.

Frames of 40 ms are overlap-added with a 50% Hann window; each frame's
source position is nudged by up to ±10 ms to best continue the previous
frame's waveform, which keeps voiced speech free of phasing artefacts.

#### Positions past either end read as silence
`SampleSource`: Source of timeline samples; positions past either end read as silence.

#### Each render produces exactly one HOP block of output samples
`Wsola::render`: Renders one block of `HOP` output samples at `speed`.

#### Offset search uses normalised cross-correlation, coarse then refined
`best_offset`: Offset in `-TOLERANCE..=TOLERANCE` whose candidate window best matches
`reference` (normalised cross-correlation, coarse search then refinement).

#### Correlate every other sample: enough for speech, halves cost
`best_offset`: Every other sample is plenty for speech and halves the cost.

### `LinuxWindows/crates/lokalbot-audio/src/system.rs`

#### Linux uses pulse monitor with parec then pw-record fallback; Windows WASAPI loopback
System audio ("Them"): the meeting app's sound when it can be separated
(`app_audio`), otherwise what the computer plays, captured from the default
output device and followed when the user switches outputs.

- Linux: the default sink's monitor through the PulseAudio protocol (works
  with PulseAudio and PipeWire's pipewire-pulse), asking the server for
  16 kHz mono float. Falls back to `parec`, then `pw-record`. An app's own
  sound is a monitor of each of its sink inputs.
- Windows: WASAPI loopback of the default render endpoint. An app's own
  sound is WASAPI process loopback of its process tree.

#### inner is empty only while a capture is being replaced
`SystemCapture.inner`: Empty only for the moment a capture is being replaced.

#### Only a failure of the whole output is an error
`SystemCapture::start`: Starts on the app's sound when it can be separated, else on the whole
output. Only a failure of the whole output is an error.

#### Old capture stops first so no buffer is written twice
`SystemCapture::open`: Replaces the running capture. The old one stops first, so no buffer is
written twice; the track's timeline fills the moment between them. A
tap that won't open falls back to the whole output.

#### A tapped app delivers nothing while silent
`SystemCapture::open`: A tapped app delivers nothing while it plays nothing.

#### Linux default monitor delivers continuous silence; Windows loopback sets it itself
`SystemCapture::open`: The default output's monitor delivers silence continuously on Linux;
Windows loopback sets this for itself.

#### New target takes effect at the next poll
`SystemCapture::set_target`: The call this recording belongs to was found. Takes effect at the next poll.

#### Tap that will not reopen becomes whole output on restart
`SystemCapture::restart`: Reopens what is being recorded. A tap that won't reopen becomes the
whole output here, so only a failure of the whole output is an error.

#### Fragment is 20 ms of 16 kHz mono f32
`FRAGMENT_BYTES`: 20 ms of 16 kHz mono f32.

#### App sound can be separated only when pactl can list it
`platform::tap_supported`: An app's sound can be told apart when `pactl` can list it.

#### Server resolves DEFAULT_MONITOR once, so restart to follow
`Capture::default_device_changed`: The server resolves @DEFAULT_MONITOR@ once; restart to follow.

#### Each app stream reopens when it moves device
`Capture::default_device_changed`: Each stream is reopened when it moves to another device.

#### One monitor per sink input; other output and app routing and volume untouched
`AppCapture`: An app's sound: one monitor of each of its sink inputs, mixed. Nothing
else on the output reaches these streams, and the app's own routing and
volume are left alone.

#### Reopen moved streams because the server ends a monitor on sink input move
`AppCapture::sync`: Opens monitors for new streams and closes those of finished ones.
A stream that moved to another device is reopened there: the server
ends a monitor when its sink input moves.

#### Only zero recordable streams is a failed tap, not one failing stream
`AppCapture::sync`: Nothing to record from at all is a failed tap; one stream that
won't open while others record is not.

#### pactl before PulseAudio 16 has no JSON output, so parse text
`sink_inputs`: pactl before PulseAudio 16 has no JSON output.

#### Run in C locale and give up on a hung server
`pactl`: Runs `pactl` in the C locale, and gives up on a hung server.

#### Match by process or executable name; LokalBot's own streams never count
`matching_streams`: The target's playing sink inputs, in a steady order. A stream counts by
its process or by the same executable, since a call's sound can come
from another process of the app. LokalBot's own never does.

#### Handshake has no timeout so run it on a thread with a timeout
`connect`: The handshake has no socket timeout; never let a hung server block recording.

#### Windows loopback delivers nothing while nothing plays
`platform::Capture::start`: Loopback delivers nothing while nothing plays.

#### Process loopback is not tied to an output device
`Capture::default_device_changed`: Process loopback isn't tied to an output device.

#### Another process of same browser counts; other apps and paused streams do not
`only_the_apps_playing_streams_are_recorded`: Another process of the same browser counts; music and a paused
stream don't.

#### A renamed process still counts by pid
`only_the_apps_playing_streams_are_recorded`: A renamed process still counts by its pid.

#### LokalBot's own playback never counts whatever its name
`only_the_apps_playing_streams_are_recorded`: LokalBot's own playback never counts, whatever it's called.

### `LinuxWindows/crates/lokalbot-audio/src/track.rs`

#### Track writer thread places buffers on timeline, resamples to 16 kHz, appends WAV
One recorded track: the writer thread that places captured buffers on the
meeting timeline, resamples them to 16 kHz and appends them to the WAV file,
plus the health counters the recording strip reads.

#### RMS at or above 0.0005 counts as audible, matching the Swift recorder
`AUDIBLE_RMS`: RMS at or above this counts as audible (`SystemAudioRecorder.audibleRMSThreshold`).

#### Clock jitter up to 20 ms inserts no silence, matching Swift timeline
`JITTER_TOLERANCE_FRAMES`: Small clock and scheduling jitter is tolerated without inserting silence
(`RecordingAudioTimeline.jitterTolerance`, 20 ms).

#### A meter level older than 500 ms reads as silence
`LEVEL_MAX_AGE_MS`: A level older than this reads as silence (`AudioLevelMeter.maximumAgeNanoseconds`).

#### Meter values are the peak over 100 ms windows
`LEVEL_WINDOW`: Meter values are the peak over windows of this length.

#### Bounded callback-to-writer queue holds about 20 s of 10 ms buffers
`QUEUE_CAPACITY`: Bounded queue between the audio callback and the writer (about 20 s of 10 ms buffers).

#### Level is 0 at -55 dBFS room noise, 1 at -10 dBFS loud speech
`normalized_level`: 0 at −55 dBFS (room noise), 1 at −10 dBFS (loud speech), as `AudioLevelMeter.normalized`.

#### Captured chunks are already mixed down to mono
`Chunk`: A captured buffer, already mixed down to mono.

#### received is when the callback delivered it; buffer ends near that instant
`Chunk.received`: When the callback delivered it; the buffer ends at about this instant.

#### Counters are shared by the capture callback, writer thread and UI
`TrackState`: Counters shared by the capture callback, the writer and the UI.

#### attached means the source was attached at least once
`TrackState.attached`: The source was attached at least once.

#### Zero while healthy; otherwise the current reconnection attempt number
`TrackState.recovering_attempt`: 0 while healthy; otherwise the current reconnection attempt.

#### WASAPI loopback sends no packets when idle, so quiet streams read silent not stalled
`TrackState.silent_without_packets`: WASAPI loopback delivers no packets while nothing plays; a quiet but
healthy stream then reads as silent rather than stalled.

#### Capture callbacks feed tracks through a cheap-to-clone sink that never blocks
`ChunkSink`: Feeds a capture callback's buffers to a track. Cheap to clone; never blocks.

#### Only the Linux sound-server capture lacks capture timestamps
`ChunkSink::push`: Only the Linux sound-server capture lacks capture timestamps.

#### Latency is age of first frame; known latency places buffer by capture time
`ChunkSink::push_captured`: `latency` is how long ago the buffer's first frame was captured, when
the backend knows it; the buffer is then placed by capture time.

#### Silence fills gaps beyond jitter tolerance so late starts never shift speech earlier
`Timeline`: Places buffers on the shared meeting timeline: silence fills any gap
longer than the jitter tolerance before a buffer, so a late start, a
reconnect or a quiet loopback never shifts later speech earlier.

#### Start frame on the 16 kHz timeline derives from delivery time and buffer length
`Timeline::start_frame`: Frame on the 16 kHz timeline where a buffer of `frames` at `rate`,
delivered at `received`, began.

#### Account for output the resampler still owes for input already seen
`Timeline::place`: Output the resampler still owes for input it has already seen.

#### Test uses plus/minus 5 ms delivery jitter on a steady 10 ms cadence
`jitter_within_tolerance_inserts_no_silence test`: ±5 ms of delivery jitter around a steady 10 ms cadence at 16 kHz.

### `LinuxWindows/crates/lokalbot-audio/src/wav.rs`

#### WAV header sizes rewritten every ~2 s so crashes leave playable files; repair_wav recovers rest
Meeting tracks on disk: 16 kHz mono 16-bit PCM WAV.

The writer rewrites the RIFF and data sizes every couple of seconds, so a
crash or power loss leaves a playable file missing at most that much audio;
[`repair_wav`] recovers the rest of an interrupted file.

#### All written tracks and speech-model buffers are 16 kHz
`SAMPLE_RATE`: Sample rate of every track LokalBot writes and of every buffer it hands to
speech models.

#### Header refresh interval is about 2 s of 16 kHz mono 16-bit audio
`HEADER_REFRESH_BYTES`: Header refresh interval in bytes of audio (about 2 s at 16 kHz mono 16-bit).

#### Largest data chunk a 32-bit RIFF header can describe
`MAX_DATA_BYTES`: Largest data chunk a RIFF header can describe.

#### Used for spoken summaries at 24 kHz; unfinishable files are removed
`write_wav`: Writes mono `samples` at any rate as 16-bit PCM (spoken summaries, 24 kHz).
A file that can't be finished is removed.

#### data_len is limited to what the file actually holds
`WavInfo.data_len`: Bytes of audio, limited to what the file holds.

#### Header-declared size; an interrupted file declares less than it holds
`WavInfo.declared_data_len`: Data size the header declares (an interrupted file declares less).

#### Parser accepts PCM 8-32 bit, IEEE float 32/64 bit and WAVE_FORMAT_EXTENSIBLE
`read_info`: Parses the RIFF chunks of a WAV file. Accepts PCM (8–32 bit), IEEE float
(32/64 bit) and WAVE_FORMAT_EXTENSIBLE.

#### EXTENSIBLE sub-format GUID starts with the real format tag
`parse_info`: WAVE_FORMAT_EXTENSIBLE: the sub-format GUID starts with the real tag.

#### Data size 0 or 0xFFFFFFFF means a streaming writer did not know the size
`parse_info`: 0 and 0xFFFFFFFF are what streaming writers leave before they know the size.

#### Repair extends data chunk to file end and drops trailing partial frame
`repair_wav`: Fixes the header of a WAV file whose writer stopped before updating it (a
crash or power loss): the data chunk is extended to the end of the file and
a trailing partial frame is dropped. Returns whether anything changed.

#### Ignore declared size: LokalBot never appends chunks after data
`repair_wav`: Ignore the declared size: everything after the data chunk header is audio
for files LokalBot wrote (it never appends chunks after `data`).

#### Unfinished file's header already covers at least the first 2 s
`header_is_refreshed_while_writing test`: Without finishing, the header already covers at least the first 2 s.

### `LinuxWindows/crates/lokalbot-audio/src/waveform.rs`

#### Waveform peak per bucket across tracks, normalised; bins follow longest track time
Peak envelope of a meeting's tracks for the player's waveform
(`WaveformAnalysis.swift`): per bucket the loudest sample of any track,
normalised so the loudest bucket is 1. Bins follow time on the longest
track, so a shorter track never stretches to fill the bar.

#### Peaks cached next to audio, keyed by each file's size and mtime
`waveform_peaks`: Peaks in 0…1, one per bucket. Cached next to the audio, keyed by each
file's size and modification time.

#### A read-only folder must never prevent drawing the waveform
`waveform_peaks`: A read-only folder must never prevent drawing the waveform.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
