# Live transcript, turn by turn

This harness measures how soon the live transcript preview can show what someone said, using only models on the Mac. It compares cutting each track at pauses and transcribing one turn at a time ("turns", the opt-in **Turn-by-turn live text** setting) with what the preview does by default, 4 to 12 second windows ("windows"), and with a streaming recognizer that the app links but does not use. It was built to find out whether fast live text needs Meta's Muse Voice Transcribe.

Read the [results of 10 November 2026](results/2026-11-10/REPORT.md).

## Protocol

- **Recordings.** The bundled sample meeting, a scripted 3½-minute call between two synthetic voices, in English and Serbian (`LokalBot/Resources/SampleMeeting`). Its reference transcript has each turn's measured start and end. Each recording is used twice: as the one mixed track it ships as, which stands for a call track that carries several voices, and split into one track per speaker by `split_tracks.py`, the way the app records the microphone and the call audio.
- **Replay.** `LiveTurnLatencyBenchmarkTests` is an opt-in unit test, so it runs the app's own engines, speech detection and `LiveTurnCutter`. It hears each track one 256 ms chunk at a time, as live audio arrives. A turn's text is counted as ready at the recording time its pause was long enough, plus the time the model then took, with turns decoded one at a time across both tracks. The windows pass repeats `LiveMeetingTranscriber.run` on the same clock: a window is taken once 4 s are waiting, cut at a quiet point, and the preview looks again a second after it had nothing to do. Decoding is timed for real; only the recording's clock is simulated, and each recording gets one second of silence at its end so the last turn can close.
- **Hand-overs.** The delay is reported for every reference turn after which the other person speaks, 25 per recording: the time from the turn's last word to its text. A turn that follows the same speaker's previous one is not a hand-over.
- **Accuracy.** Word error rate of all pieces in order against the reference text, lower-cased with punctuation removed. Cyrillic output is transliterated before scoring, and its share is reported. Numbers are not normalized, so a model that writes "forty-two" for "42" is charged for it in both passes alike.
- **Streaming.** `testStreamingRecognizerDelay` feeds each turn to FluidAudio's `StreamingNemotronMultilingualAsrManager` 160 ms at a time and records when each token came out against the time it was spoken.
- **Real time.** `testPreviewReplayInRealTime` writes the two tracks to disk at the speed they were recorded and runs `LiveMeetingTranscriber` on them with the real speech detection and model, as in a meeting. It reports when each line reached the preview.

## Reproduce

Build the test bundle optimized; an unoptimized build decodes slower. Keep the build and the audio outside `~/Documents`, or macOS asks the freshly built test host for access to that folder and the run stalls.

```sh
OUT=/private/tmp/lokalbot-live-turns
mkdir -p $OUT/audio
for L in en sr-Latn; do
  cp LokalBot/Resources/SampleMeeting/orders-api.$L.m4a $OUT/audio/${L%-Latn}.m4a
  python3 Benchmarks/LiveTurns/split_tracks.py $OUT/audio/${L%-Latn}.m4a \
    LokalBot/Resources/SampleMeeting/reference.$L.json $OUT/audio/${L%-Latn}
done
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Release -derivedDataPath $OUT/dd \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  'OTHER_SWIFT_FLAGS=$(inherited) -DDEBUG -DLOKALBOT_TEST_HOOKS' -only-testing:LokalBotTests build-for-testing

AUDIO="en=$OUT/audio/en.m4a|$OUT/audio/en.maya.wav|$OUT/audio/en.daniel.wav;sr=$OUT/audio/sr.m4a|$OUT/audio/sr.maya.wav|$OUT/audio/sr.daniel.wav"
run() {  # run <test> [VAR=value ...]
  test=$1; shift
  env TEST_RUNNER_LOKALBOT_LIVE_TURN_BENCH=$OUT/results TEST_RUNNER_LOKALBOT_LIVE_TURN_AUDIO="$AUDIO" "$@" \
    xcodebuild test-without-building -xctestrun $OUT/dd/Build/Products/*.xctestrun \
    -destination 'platform=macOS,arch=arm64' -only-testing:LokalBotTests/LiveTurnLatencyBenchmarkTests/$test
}
run testTurnByTurnDelay TEST_RUNNER_LOKALBOT_LIVE_TURN_MODELS=parakeet-v3,qwen3-asr-1.7b
run testTurnByTurnDelay TEST_RUNNER_LOKALBOT_LIVE_TURN_MODELS=parakeet-v3 TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=sr=hr
python3 Benchmarks/LiveTurns/fetch_stream_model.py multilingual/560ms $OUT/nemotron-multilingual-560
run testStreamingRecognizerDelay TEST_RUNNER_LOKALBOT_LIVE_STREAM_MODEL=$OUT/nemotron-multilingual-560 \
  TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=en=en-US,sr=hr-HR
run testPreviewReplayInRealTime TEST_RUNNER_LOKALBOT_LIVE_TURN_MODELS=parakeet-v3 TEST_RUNNER_LOKALBOT_LIVE_REPLAY_SECONDS=90
python3 Benchmarks/LiveTurns/score.py $OUT/results LokalBot/Resources/SampleMeeting --json scores.json
```

Models are named by their Settings identifiers (`TranscriptionModelChoice`), and only ones already downloaded run; nothing is fetched except by `fetch_stream_model.py`. `TEST_RUNNER_LOKALBOT_LIVE_TURN_RULES=2:4,2:off,1:off` times other pause rules (quiet chunks to close a turn, and the turn length from which one is enough) instead of the app's. A run with a language hint is saved beside the plain one, as `run-<model>-sr@hr.json`. Whisper takes about four minutes for both recordings; the others well under two.

While the test host runs it is a second LokalBot in the Dock. Leave it alone: opening it makes the unsigned build ask for the Keychain.

## Limits

One scripted call per language, with synthetic voices, no noise, no overlapping speech and none of the other side's voice in the microphone track. Pauses between speakers are 0.5 to 0.85 s; people often leave less, and hesitate more inside a turn. The Serbian recording is voiced by multilingual voices, so its error rates say which model copes better, not how well any of them reads a native speaker. Everything ran on one Mac, an M4 Max; a slower Mac decodes slower, and the delay grows by that much. CPU time is the process's own, so work on the GPU and the Neural Engine is not in it.
