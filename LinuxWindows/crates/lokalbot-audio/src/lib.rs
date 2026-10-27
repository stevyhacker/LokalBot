//! Audio capture and playback for LokalBot on Linux and Windows.
//!
//! A meeting is two time-aligned tracks in its folder, `mic.wav` ("Me") and
//! `system.wav` ("Them"), both 16 kHz mono 16-bit PCM — the format the speech
//! models read, so no conversion happens before transcription. The macOS app
//! records AAC `.m4a` files instead; [`TrackReader`] reads those (and FLAC) as
//! the same 16 kHz stream, so playback, waveforms and transcription work on a
//! library from either platform.

mod capture;
mod decode;
mod import;
mod mic_capture;
mod player;
mod recorder;
mod resample;
mod splice;
mod stretch;
mod system;
mod track;
mod wav;
mod waveform;

pub use capture::{AudioDevice, input_devices};
pub use decode::{CompressedReader, TrackReader, audio_track_ids, mp4_creation_time};
pub use import::{ImportError, ImportedAudio, MIN_IMPORT_SECONDS, import_audio};
pub use mic_capture::MicCapture;
pub use player::{MAX_SPEED, MIN_SPEED, Player};
pub use recorder::{
    Levels, MIC_FILE, Recorder, RecorderOptions, RecordingResult, SYSTEM_FILE, TrackHealth,
    TrackStatus,
};
pub use resample::{Resampler, resample};
pub use splice::{SplicePart, splice_tracks};
pub use track::{normalized_level, rms};
pub use wav::{
    SAMPLE_RATE, SampleEncoding, WavInfo, WavReader, WavWriter, duration_seconds, read_info,
    read_mono_16k, repair_wav, write_wav_16k,
};
pub use waveform::waveform_peaks;
