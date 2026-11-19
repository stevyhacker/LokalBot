# Qwen3-ASR 0.6B language sampling on the Windows PC — 18 November 2026

**Verdict.** The compact tier behaves like 1.7B. With the shipped sample of 12 windows and a 90% share, the old and new paths picked the same language on all 38 track–layout pairs, and every transcript was byte-identical. The new path decoded 72–75% of the windows overall and 54–56% on the whole AMI meetings. From the measured window times, recognition is 1.31–1.32× faster across all tracks and 1.78–1.79× on AMI. The simulation agrees with the 1.7B choice: no wrong pin with the shipped sampler, and a 0.1% mean chance with random windows.

## Setup

The model was not run on the Mac.
- **Decoding:** on the Windows PC (`pcmakina`, AMD Radeon RX 6600 XT, Vulkan). llama.cpp b12359 `llama-b12359-bin-win-vulkan-x64.zip` is the Windows port's own pinned asset, and its SHA-256 was checked. The model is `ggml-org/Qwen3-ASR-0.6B-GGUF` Q8_0 and its Q8_0 mmproj at revision `928ab95`, with both hashes matching `QwenLlamaASR.compact`.
- **Requests:** `remote/pc_decode.py` starts the server with the app's flags and sends each window as `QwenLlamaASR.makeRequest` does.
- **Windows:** the plain layout uses the VAD spans recorded by the 1.7B replay. The word layout merges them with the 0.6B limits (15 s, 5 s gaps). No voice-activity detection ran again.
- **Vote and paths:** the vote ran on the Mac. `remote/vote.swift` calls Apple's text recognizer as `TranscriptLanguageVote` does, and it matched the app's recorded votes on all 1638 windows of the 1.7B replay. `remote/plan.py` rebuilds both paths from one set of decodes: every window on auto, then every window in each language either path pinned. Decoding is greedy, so each path's output is exact. Rebuilt from the 1.7B decodes, it reproduced all 76 before/after records of the replay: decisions, decode counts and text.
- **Tracks:** the public tracks only, the 17 FLEURS tracks and the two whole AMI meetings. The owner's meetings were not copied to the PC.

## Accuracy and work

| Set | Layout | Tracks | Audio | Same pin | Same text | WER/CER before → after | Non-Latin before → after | Off-script before → after | Windows decoded before → after | Audio decoded before → after |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fleurs | word | 10 | 79 min | 10/10 | 10/10 | 20.5% → 20.5% | 18.3% → 18.3% | 8.1% → 8.1% | 592 → 443 (75%) | 93 → 73 min (78%) |
| switch | word | 7 | 47 min | 7/7 | 7/7 | 24.4% → 24.4% | 26.7% → 26.7% | 0.0% → 0.0% | 286 → 286 (100%) | 46 → 46 min (100%) |
| ami | word | 2 | 42 min | 2/2 | 2/2 | 17.3% → 17.3% | 0.0% → 0.0% | 0.0% → 0.0% | 372 → 210 (56%) | 64 → 38 min (59%) |
| all | word | 19 | 169 min | 19/19 | 19/19 | 20.7% → 20.7% | 16.8% → 16.8% | 3.8% → 3.8% | 1250 → 939 (75%) | 204 → 157 min (77%) |
| fleurs | plain | 10 | 79 min | 10/10 | 10/10 | 20.4% → 20.4% | 18.3% → 18.3% | 8.2% → 8.2% | 705 → 513 (73%) | 90 → 69 min (77%) |
| switch | plain | 7 | 47 min | 7/7 | 7/7 | 23.6% → 23.6% | 26.3% → 26.3% | 0.0% → 0.0% | 366 → 366 (100%) | 43 → 43 min (100%) |
| ami | plain | 2 | 42 min | 2/2 | 2/2 | 18.0% → 18.0% | 0.0% → 0.0% | 0.0% → 0.0% | 634 → 341 (54%) | 58 → 34 min (58%) |
| all | plain | 19 | 169 min | 19/19 | 19/19 | 20.6% → 20.6% | 16.8% → 16.8% | 3.8% → 3.8% | 1705 → 1220 (72%) | 191 → 146 min (77%) |

- **No transcript changed,** as with 1.7B.
- **Serbian, Croatian and Bosnian never pin on 0.6B.** Its auto-detected text votes only 51–62% Croatian on these tracks, against 82–100% on 1.7B. They stay on per-window detection on both paths, at the old cost. Their drift into Cyrillic and other scripts makes up the FLEURS non-Latin and off-script shares, the same before and after. This is the 0.6B tier's own weakness on these languages, and sampling does not change it.
- **Japanese votes on 0.6B.** It writes spaces often enough that the sample decides, so Japanese decodes in one pass here, unlike on 1.7B. Chinese still never votes.
- **Code-switched tracks fall back,** as on 1.7B: no sample reached 90%.

## Time

The times below add up each path's window decodes, measured in one process on the PC. They are not paired live runs, but both paths use the same measured windows, so drift between runs cannot favour either. A CI job was building on the PC during the first part of the auto pass, which slows absolute times, not the ratio. Vulkan on the RX 6600 XT is not Metal, so absolute real-time factors do not carry over to Macs.

| Set | Layout | Tracks | Audio | Decode before → after | RTF before → after | Speed-up |
|---|---|---:|---:|---:|---:|---:|
| fleurs | word | 10 | 79 min | 217 s → 168 s | 22.0× → 28.3× | 1.29× |
| switch | word | 7 | 47 min | 97 s → 97 s | 29.1× → 29.1× | 1.00× |
| ami | word | 2 | 42 min | 123 s → 68 s | 20.6× → 36.9× | 1.79× |
| all | word | 19 | 169 min | 437 s → 334 s | 23.2× → 30.3× | 1.31× |
| fleurs | plain | 10 | 79 min | 219 s → 167 s | 21.7× → 28.5× | 1.31× |
| switch | plain | 7 | 47 min | 99 s → 99 s | 28.4× → 28.4× | 1.00× |
| ami | plain | 2 | 42 min | 132 s → 74 s | 19.2× → 34.1× | 1.78× |
| all | plain | 19 | 169 min | 451 s → 341 s | 22.4× → 29.7× | 1.32× |

Code-switched rows are equal by construction: they fall back, and the fallback decodes exactly the old path's windows.

## Sample size and share

`simulate.py` on these decodes (`simulation.json`):
- **The shipped sampler,** which takes the longest window of each group, made no wrong pin at any size from 4 to 16 at 85% or 90%. At 80% it made one, with 4 windows in the plain layout.
- **With one random window per group,** 12 windows at 90% pinned the 18 mixed track–layouts 0.1% of the time on average (1.1% on the worst one), against 0.7% with 8 windows.
- **Most tracks the old path left on auto are 0.6B's Serbian-language tracks.** They vote far below 80%, which is why random samples rarely pin them.
