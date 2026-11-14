# Qwen3-ASR 1.7B: llama.cpp vs MLX (2026-11-14)

**Verdict.** Qwen3-ASR 1.7B can move to llama.cpp without losing accuracy or the Serbian and vocabulary behaviour, and it would use much less memory. The cost is about 10–17% less throughput. Both backends ran on the same windows with the same prompts:

- **Shipped English layout:** AMI WER was 17.80% on MLX and 17.76% on llama.cpp (Δ −0.05, 95% CI −0.40…+0.27).
- **Meetings:** the two backends disagree on 1.7% of words.
- **Serbian:** an explicit `sr` plus a vocabulary list gave 13.4% on MLX and 12.4% on llama.cpp. Both recovered 11 of the 12 listed names.
- **Speed:** llama.cpp decoded at 39–42× real time against 47× for MLX.
- **Memory:** llama-server peaked at a 2.3 GB footprint (4.2 GB RSS including the memory-mapped weights). The MLX process peaked at 3.9 GB of MLX allocations and an 8.5 GB footprint with its buffer cache.

There is one hard requirement. The app must send Qwen's own prompt layout through `/completion`, not llama-server's `/v1/audio/transcriptions`. In v0.9.0 that endpoint turns `language` and `prompt` into user-turn text, which is not how Qwen3-ASR was trained. It also returns the `language X<asr_text>` prefix unstripped.

## Setup

- **Machine:** Apple M4 Max with 48 GB, macOS 27.2.1 (26B131). The backends ran one after the other, each in its own process. Spotlight indexing was running in the background during both runs.
- **MLX:** `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, the app's copy, 2.47 GB on disk. It ran through the speech-swift fork at `33f42bc`, with mlx-swift 0.32.3 and FluidAudio 0.17.7, the app's current pins.
- **llama.cpp:** `ggml-org/Qwen3-ASR-1.7B-GGUF` at revision `36a6786`:
  - `Qwen3-ASR-1.7B-Q8_0.gguf`: 2,165,034,944 bytes, SHA-256 `58e22d05…1fc57`.
  - `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`: 355,709,344 bytes, SHA-256 `46c1d533…164c0d`.
  - Together that is 2.52 GB. It ran on the app's pinned llama-server v0.9.0 (build 12110), which supports Qwen3-ASR through mtmd's `qwen3a` projector, so no newer build was needed.
  - Server flags were `-ngl 99 -c 4096 --parallel 1 --cache-ram 256`, the same flags `GraniteSpeechEngine` uses.
- **Prompt:** identical for both arms. The system turn carries the context, the user turn carries the audio, and the assistant turn starts with `language <code>` and then `<asr_text>`. Decoding was greedy, with the app's token cap.
- **Language hint:** passed as the app passes it, the code verbatim (`en`, `sr`), so Qwen sees `language sr`.
- **N-gram blocking:** neither compared layout triggers speech-swift's repetition block, which llama.cpp lacks. `merge-60-off-v14` disables it, and `engine-15` windows never exceed 15 s.
- **Determinism:** every llama.cpp transcript came out byte-identical across three full runs, with different server flags.
- **Layouts:**
  - `merge-60-off-v14`: VAD regions of up to 14 s merged across pauses of 5 s or less into windows of up to 60 s, with no n-gram block. This is the layout the app ships for 1.7B.
  - `engine-15`: the plain path, with 14 s VAD regions split at 15 s.
- **Data:** CloudSTT's chunks were regenerated today with `prepare.py`. That gave 16 AMI windows (27.4 min) and 106 chunks from three meetings (73.4 min), the same counts as on 30 September. The FLEURS tracks came from `fetch_fleurs.py`: German, Japanese, Russian and Serbian, plus a code-switched English/German track, 5–7 minutes each.

## English

### AMI Mix-Headset (human reference)

| Layout | MLX | llama.cpp | Δ llama − MLX (95% CI) | P(llama better) |
|---|---:|---:|---:|---:|
| merge-60-off-v14 (shipped) | 17.80% | 17.76% | −0.05 (−0.40…+0.27) | 0.58 |
| engine-15 | 18.21% | 18.78% | +0.57 (−0.09…+1.19) | 0.05 |

### MLX vs llama.cpp disagreement (llama.cpp scored against MLX)

The vendor transcripts behind CloudSTT's meeting consensus were deleted along with the old `/private/tmp` data. The meetings were therefore not scored against a reference. This table shows how far the two backends drift apart instead.

| Set | Layout | Disagreement | Sub / Del / Ins | Inserted-run words | Deleted-run words |
|---|---|---:|---:|---:|---:|
| AMI | merge-60-off-v14 | 2.04% | 0.74 / 0.57 / 0.74 | 6 | 0 |
| AMI | engine-15 | 3.07% | 1.23 / 1.29 / 0.55 | 5 | 12 |
| Meetings | merge-60-off-v14 | 1.70% | 1.03 / 0.30 / 0.37 | 7 | 4 |
| Meetings | engine-15 | 2.11% | 1.13 / 0.40 / 0.58 | 18 | 4 |

30 of the 106 meeting chunks were word-for-word identical. Most of the differences are single substitutions, so the Q8_0 GGUF and the MLX 8-bit weights round differently. Neither backend produces systematic hallucinations or drops speech that the other doesn't.

## FLEURS language tracks

These are error rates: WER, and CER for Japanese. Each cell reads MLX → llama.cpp, then Δ with a 95% CI from bootstrapping the 30 reference utterances of each track. The English/German track has no single true language, so its `oracle` rows run on auto.

| Condition | German | Japanese (CER) | Russian | Serbian | English + German |
|---|---|---|---|---|---|
| ≤60 s, true language | 4.5 → 3.9 (−0.6, −1.6…0.0) | 7.1 → 6.5 (−0.6, −1.5…+0.1) | 10.2 → 10.0 (−0.2, −1.0…+0.6) | 14.9 → 13.2 (−1.7, −3.6…+0.2) | 14.7 → 10.9 (−3.9, −11.6…0.0) |
| ≤60 s, auto | 4.4 → 3.9 (−0.5) | 6.8 → 6.6 (−0.2) | 10.2 → 7.7 (−2.6, −7.7…+0.4) | 17.5 → 17.1 (−0.4) | 14.7 → 10.9 (−3.9) |
| ≤60 s, vote and pin | same as true language | same | same | 17.5 → 17.1 (stays auto) | 14.7 → 10.9 (stays auto) |
| ≤14 s, true language | 4.9 → 4.7 (−0.2) | 8.0 → 8.5 (+0.5) | 8.0 → 8.6 (+0.5) | 16.4 → 16.8 (+0.4) | 9.8 → 10.2 (+0.4) |
| ≤14 s, auto | 4.5 → 4.9 (+0.3) | 7.8 → 8.5 (+0.8) | 8.0 → 8.0 (0.0) | 19.0 → 17.5 (−1.5) | 9.8 → 10.2 (+0.4) |

No difference is significant. On the merged layout llama.cpp is slightly ahead, and its largest gains each trace to one window where MLX dropped or garbled a sentence and llama.cpp did not. One example is a 55 s Russian window where MLX left out the opening sentence. On ≤14 s windows MLX is slightly ahead. Vote and pin made the same choices on both backends: it pinned de, ja and ru, and left Serbian and English/German on auto.

## Serbian: auto, `sr`, `sr` + vocabulary

The vocabulary prompt is `Moldavija, Japan, Božić, Isus, WiFi, Egipćani, Irak, UN, Argentina, SAD, Džordž Buš.`. These are the proper nouns of the reference, in Latin script, joined the way `TranscriptionVocabulary` joins terms. It was the same for both backends. "Recovered" counts reference occurrences of the 10 stems (12 occurrences) that appear in the output after transliteration.

| Condition | MLX | llama.cpp | Δ (95% CI) | Names recovered, MLX / llama |
|---|---:|---:|---:|---:|
| ≤60 s, auto | 17.5% | 17.1% | −0.4 (−2.2…+1.3) | 9 / 8 |
| ≤60 s, `sr` | 14.9% | 13.2% | −1.7 (−3.6…+0.2) | 7 / 8 |
| ≤60 s, `sr` + vocabulary | **13.4%** | **12.4%** | −0.9 (−2.7…+0.8) | **11 / 11** |
| ≤60 s, auto + vocabulary | 16.4% | 16.8% | +0.4 (−0.9…+1.7) | 11 / 11 |
| ≤14 s, auto | 19.0% | 17.5% | −1.5 (−3.4…+0.6) | 8 / 9 |
| ≤14 s, `sr` | 16.4% | 16.8% | +0.4 (−1.6…+2.6) | 7 / 8 |
| ≤14 s, `sr` + vocabulary | 16.6% | 17.7% | +1.1 (−1.3…+3.5) | 10 / 10 |

Both backends reproduce the September result that an explicit `sr` beats auto (−2.6 to −3.9 points on the merged layout). The vocabulary prompt helps both the same way: it lifts name recovery from 7–8 of 12 to 11 of 12 and takes another 0.8–1.0 points off on the merged layout. On ≤14 s windows the vocabulary prompt recovers names but does not lower the overall error on either backend. So the language hint and the context both reach the model through llama.cpp, and they act as they do on MLX.

The harness's vote does not apply the app's newer Serbian/Croatian alias, so Serbian stays on auto in both arms. One difference matters under the app's rule, though. On the merged layout, MLX's auto pass voted Croatian at 100%, while llama.cpp's voted Croatian at only 79%. That falls just under the app's 80% pin threshold, so llama.cpp would leave this track on auto where MLX would pin it. On ≤14 s windows both backends voted 81–82%.

## Speed and memory

| | MLX (speech-swift) | llama.cpp (llama-server) |
|---|---:|---:|
| English, merged ≤60 s (101 min of audio) | 46.7× | 42.0× |
| English, ≤14 s | 46.9× | 39.2× |
| FLEURS, true language, merged / ≤14 s | 42.9× / 46.6× | 39.7× / 39.2× |
| FLEURS, vote and pin (two passes) | 23.3× / 23.7× | 20.3× / 19.9× |
| Serbian + vocabulary, merged | 32.4× | 29.7× |
| Whole job (11 conditions, 6.1 h of audio decoded) | 608 s | 701 s |
| Load before the first request | ~1–4 s for a cold process (MLX loads lazily) | server ready in 0.5–0.9 s |
| Peak memory | MLX peak 3.86 GB; process footprint 8.5 GB (MLX buffer cache), max RSS 2.9 GB | server footprint peak 2.3 GB, peak RSS 4.2 GB (includes 2.5 GB of mmapped weights); harness client 0.6 GB |
| Model on disk | 2.47 GB | 2.52 GB (2.17 GB + 0.36 GB mmproj) |

Of llama.cpp's 701 s, 194 s went to the audio encoder plus prompt prefill (346k tokens) and 458 s to generation (86k tokens, about 189 tokens/s). The throughput gap is mostly the generation loop.

The memory figures are not directly comparable. llama.cpp memory-maps the GGUF, so its weights count in RSS but not in the footprint. MLX loads the weights into its own allocations and keeps a buffer cache, which the harness does not trim the way the app's `MLXMemoryRelease` does.

llama-server's default `--cache-ram 8192` matters. With the default host prompt cache, the server grew to a 14 GB footprint peak (14.6 GB RSS) during the merged-window meetings. Any Qwen integration must pass a small `--cache-ram`, as Granite does.

## What was not run

- **Meetings accuracy against a reference:** the vendor consensus was deleted. Only MLX vs llama.cpp agreement was measured.
- **The app's prompt-echo filter:** `withoutPromptEchoes` drops windows that only repeat the vocabulary. The harness does not apply it, so a few near-silent windows may echo the vocabulary list. This affects both arms the same way.
- **Other quantizations:** only Q8_0 was tested, and only on this Mac. Each condition ran once with greedy decoding.

`summary.json` holds the aggregates. Transcripts and audio stay in the private `SPAN_BENCH_OUT` folder. Meeting audio was read through `lokalbot-cli path`, which is read-only. Apart from model and dataset downloads, the only network traffic was localhost requests to llama-server.
