# Notes with each model's default reasoning: better notes, 5–6× slower on Qwen3.5 4B

Measured November 21, 2026 for PR #570. **Letting the built-in Qwen3.5 4B think made its notes 5–6× slower and mostly better**: Serbian notes came out in Serbian instead of English and recalled 8 of 14 key facts instead of 3, English recall rose from 9 to 11 of 14, and no request ran out of room or needed the thinking-off fallback. Its English key points turned into near-verbatim transcript quotes, though, and one Serbian decision contradicted the meeting. **Inkling 2 Mini wrote the best notes in both languages** (11/14 and 13/14 facts, every decision, action and the open question in the Serbian notes) at about 3.5× Qwen's thinking time.

Each condition ran the Windows and Linux app's own notes code (`LinuxWindows/crates/lokalbot-ai/examples/notes_replay.rs`, on this PR's branch) against `llama-server` on one rented RTX 3090 (vast.ai, driver 570, CUDA 12.8 build of llama.cpp **b12613**), with the app's server arguments: `-c 32768 -ngl 99 --jinja --cache-ram 2048 --reasoning auto`. A logging proxy between the two recorded every request and reply ([log_proxy.py](scripts/log_proxy.py)). Inputs were the bundled synthetic sample meeting in English and Serbian and AMI's manual transcript of ES2004a (CC BY 4.0); no personal data left the Mac. One run per condition, temperature 0. The macOS notes code makes the same requests but was not run: the Mac's screen was locked, which keeps the unit-test host from starting.

| Condition | Sample (en) | Sample (sr) | AMI ES2004a (2,578 words) |
| --- | ---: | ---: | ---: |
| **Qwen3.5 4B, thinking off** (today) | 6.4 s · 923 tok | 5.0 s · 698 tok | 11.5 s · 1,414 tok |
| **Qwen3.5 4B, model default** (this PR) | 32.2 s · 5,076 tok | 33.1 s · 5,200 tok | 70.1 s · 10,658 tok |
| **Inkling 2 Mini, model default** | 120.6 s · 6,186 tok | 114.3 s · 5,838 tok | 170.0 s · 8,159 tok |

Times are whole notes jobs; tokens are generated tokens, thinking included. Qwen3.5 4B `Q4_K_M` generated about 155–160 tokens/s and Inkling 2 Mini `IQ4_NL` about 51–56 on the 3090. On a Mac, Qwen3.5 4B decodes at about 85 tokens/s (see the Benchmarks README), so expect roughly twice these Qwen times there.

| Sample meeting | Qwen off | Qwen default | Inkling default |
| --- | --- | --- | --- |
| Facts recalled, en (names, numbers, dates; 14) | 9 | 11 | 11 |
| Facts recalled, sr (14) | 3 | 8 | **13** |
| Language of the Serbian notes | **English** | Serbian | Serbian |
| Changed decision (no v3, optional field, Nov 11) | en key points; sr TL;DR | en key points (quoted); sr in Decisions, plus one contradicting entry | **en TL;DR; sr TL;DR and Decisions** |
| Open question (backfill, ask Priya) | en key points; sr open questions | en only as an action; sr TL;DR | **en and sr open questions** |
| Expected actions found (spec and changelog, ask Priya, email partners, tell Lena, contract tests) | en 3/5, sr 1/5 | en 2/5, sr 1/5 | **en 5/5, sr 5/5** (plus one extra) |

Facts recalled are the `expected.*.json` entities found in the notes text (substring match, [analyze.py](scripts/analyze.py)); the other rows are from reading the notes in [results](results/). All nine jobs completed. No request stopped at its output limit, so the retry-without-reasoning fallback never fired. **Both models thought up to the cap on almost every request**: a 4,096-token answer allowance gave about 4,100 tokens of thinking before a roughly 1,000-token answer, and a 640-token one about 640. llama-server closed the thinking turn at the budget and the answer still came; Inkling handled that forced close too. The cap (the answer size, at most 8,192) is therefore what sets notes time: raising it would make notes slower still.

**Style regression on Qwen.** With thinking on, Qwen3.5 4B's English key points became near-verbatim transcript lines, and its TL;DR repeated the recording's "this is a synthetic sample" disclaimer. The facts are there, but the notes read worse than the paraphrased ones it wrote without thinking. Serbian did not show this.

**Inkling cannot be switched off this way.** A separate probe sent Inkling the thinking-off request this PR keeps for instant tasks (`thinking_budget_tokens: 0` and `enable_thinking: false`). It looped `<|content_thinking|><|end_message|>` until the 8,192-token limit. Inkling's chat template has no `enable_thinking`; its control is `reasoning_effort` (`none` to `max`, default 0.9). Inkling must not get a zero thinking budget, so its catalog entry needs its own off request.

Reproduce: [make_inputs.py](scripts/make_inputs.py) builds the transcripts, [run_bench.sh](scripts/run_bench.sh) runs the three conditions on a CUDA host with llama.cpp and both checksum-verified models in `$BENCH_DIR`, and `analyze.py` writes [summary.tsv](results/summary.tsv). Per-request logs are `results/requests-*.jsonl`.
