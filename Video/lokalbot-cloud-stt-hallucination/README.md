# Cloud STT Hallucination vs Qwen3-ASR v3

A 30-second social video clip (`4:5` 1080x1350 and `9:16` 1080x1920) with burned-in word-highlighted
captions and animated audio waveforms. It contrasts measured results from
[`Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md`](../../Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md)
and the `v0.14.0` default `Qwen3-ASR-1.7B-LokalBot-v3` model (`LokalBot/Engines/QwenLlamaASR.swift`).

## Measured numbers shown

- Quiet 1.2s meeting clip: Gemini 3.8 Flash invented a 30-word fluent sentence (115 invented words
  across 15 chunks in 69.9 minutes of meeting audio, $0.33/hr list price).
- Local `Qwen3-ASR 1.7B LokalBot v3` (`2.52 GB` GGUF `Q8_0`): `100%` clean silence, `0` hallucinated
  words, `$0/hr`, `0 bytes` uploaded.
- Public AMI far-field Mix-Headset benchmark (16 windows, 27.4 minutes, 4,160 reference words):
  local Qwen3-ASR 1.7B scored `17.6%` WER (44x real time on M4 Max), ahead of Qwen3-ASR Flash
  (`18.1%`), Qwen-Audio 3.1 Flash (`18.5%`), GPT-4o mini Transcribe (`21.8%`), GPT Transcribe
  (`22.2%`), and GPT-4o Transcribe (`23.0%`).

## Build and render (Ubuntu dev box)

```sh
python3 build.py --format 4:5 && npx --yes hyperframes@0.8.150 check
npx --yes hyperframes@0.8.150 render --quality high --video-frame-format png -o renders/raw-4x5.mp4
./master.sh renders/raw-4x5.mp4 renders/cloud-stt-hallucination-4x5.mp4

python3 build.py --format 9:16 && npx --yes hyperframes@0.8.150 check
npx --yes hyperframes@0.8.150 render --quality high --video-frame-format png -o renders/raw-9x16.mp4
./master.sh renders/raw-9x16.mp4 renders/cloud-stt-hallucination-9x16.mp4
```
