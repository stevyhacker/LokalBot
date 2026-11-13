# Muse Voice Transcribe diarization on AMI

This harness measures Meta's Muse Voice Transcribe (`muse-voice-transcribe-1.0`) in realtime `DIARIZATION` mode on the eight AMI recording conditions of the [Nemotron 3 study](../NemotronDiarization/results/2026-09-23/REPORT.md), with the same references and scorer settings, so its error rate sits beside LokalBot's local diarizers. Launch coverage cites a Meta-reported 17.5% average DER across AMI-IHM, AMI-SDM and VoxConverse; no independent check had been published when this was written. It was built during the Meta Global AI Developer Hackathon (26 October – 4 November 2026) for live meeting work, and it does not change the app.

Read the [completed evaluation](results/2026-10-27/REPORT.md).

## Protocol

- **Inputs.** The study's eight full recordings: four AMI test meetings (EN2002a, ES2004a, IS1009a, TS3003a), each as Mix-Headset and Array1-01, 184.55 minutes in all. `prepare.py` checks every file against the study's SHA-256 record. The references are the study's checked-in forced-alignment RTTMs.
- **Requests.** `wss://api.meta.ai/v1/asr/realtime`, mode `DIARIZATION`, `PCM_16KHZ` (the server resamples to its native 24 kHz), `languageBias: ["English"]`, no keywords or speaker-count hint. The file endpoint is not used: it caps audio at 10 minutes, and speaker labels only hold within one session, so splitting a meeting would hide confusion across pieces.
- **Pacing.** Audio leaves in 100 ms frames on an absolute real-time schedule, as from a live microphone. The server rejects streams more than five seconds ahead. All eight sessions run at once, about 36 minutes for the longest. After the last frame the client sends `endStream` and keeps reading until the server closes or 30 seconds pass without an event.
- **Segments.** The API reports turn positions only (`audioProcessedMs`, which Meta describes as not precise acoustic boundaries) and no word timings. A turn runs from `speechStart` to `speechEnd`. Each `speaker` event labels the audio since the previous `speechStart` or `speaker` event, so a turn is split at its speaker events and the remainder keeps the last label. A turn with no speaker event gets its own `unknown-<turnId>` label. Output has one speaker at a time, so overlapping speech can only be partly right.
- **Scoring.** pyannote.metrics with overlap scored, zero and 250 ms collars, the whole recording as the evaluated region, optimal label mapping, pooled by reference speaker time: the study's settings. `score.py` re-scores the study's checked-in predictions for the comparison rows and stops if the full set does not reproduce its published totals (43.435%, 14.555% and 16.478% zero-collar DER).
- **Two views.** *Full* scores each system as it is. Muse turns are endpointing turns, which can hold several seconds of silence (one smoke-test turn ran 20 s around 3 s of reference speech), so its full score is mostly false alarm. *Oracle speech* first cuts every system's output, the local ones included, to the reference's speech regions. False alarms disappear, and what remains is speech given the wrong speaker plus speech left unlabelled. It is not a deployable configuration; it shows labelling quality apart from speech detection.
- **Latency.** Seconds from the moment a turn's `speechEnd` position was sent to the arrival of that turn's final text (`speechComplete`) and of its first speaker label. Measured on the client clock, network included. It applies to real-time runs only.

## Reproduce

From this folder:

```sh
export UV_CACHE_DIR=/private/tmp/muse-voice-uv
D=/private/tmp/lokalbot-muse-voice-bench
uv venv $D/env && uv pip install --python $D/env/bin/python -r requirements.txt
$D/env/bin/python selftest.py                   # mock server; no key or network
$D/env/bin/python prepare.py                    # about 350 MB of AMI audio
$D/env/bin/python run.py --smoke 60 ES2004a_mhm # one minute, to check the key and protocol
$D/env/bin/python score.py --raw raw-smoke
caffeinate -i $D/env/bin/python run.py          # all eight, about 36 minutes
$D/env/bin/python score.py --save results/<date>
```

The key is read from `META_API_KEY` in the environment or in `~/.config/lokalbot-stt-bench.env`, the file the CloudSTT benchmark uses. It is never written to the repository or to saved records. A full run streams 184.55 minutes of audio, about $0.55 at $0.18 per hour.

`run.py` keeps every server event with its arrival time, transcripts included, under `$MUSE_BENCH_DATA` (default `/private/tmp/lokalbot-muse-voice-bench`), so segment rules can change without streaming again. Rerunning skips recordings that completed. `--save` copies only segments, aggregates and session metadata into the repository.

## Limits

This is one set of four-speaker English meetings, as in the study. It does not cover more speakers, other languages, LokalBot's echo-affected mic and system tracks, or word-level attribution. Muse runs in Meta's cloud: the audio leaves the computer, which the local systems it is compared with never do.
