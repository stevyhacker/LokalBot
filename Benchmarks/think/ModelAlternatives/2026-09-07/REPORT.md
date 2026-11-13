# LokalBot local model alternatives — 7 September 2026

Harrier is the strongest search replacement candidate from this pilot. Granite Speech 5 is a promising English speed option: normalized accuracy was comparable to Granite 4.1, with substantially lower inference time. MiniCPM5 does not qualify as a replacement for the main Qwen model because of summary and attribution regressions. No app defaults, runtime bundles, or live indexes were changed.

All inference ran serially on the same Apple M4 Max with 48 GiB of unified memory. The GGUF comparisons used the installed llama.cpp **b10173** with Metal and one slot. Granite 5 used **mlx-audio 0.5.3 / MLX 0.32.2**, with local weights and offline Hub settings. These are direct engine benchmarks, not UI or full recording-pipeline tests.

**Semantic search: Harrier versus Qwen3 Embedding**

The corpus contains 24 synthetic product/meeting passages, 36 synthetic distractors, and 50 chunks from one consented local transcript used only as distractors. The 48 authored queries comprise 24 English queries and 24 Serbian/Montenegrin equivalents, including Latin and Cyrillic text. Relevant passage IDs were fixed before inference. Both models used Q8 weights, last-token pooling, 1,024 dimensions, L2 normalization, a 2,048-token context, and the current app's query/document prefixes.

| Measure | Qwen3 Embedding 0.6B Q8 | Harrier 0.6B Q8 |
|---|---:|---:|
| Correct passage ranked first | 35/48 (72.9%) | **40/48 (83.3%)** |
| Correct passage in top five | 45/48 (93.8%) | **47/48 (97.9%)** |
| English top one | 22/24 | 22/24 |
| Serbian/Montenegrin top one | 13/24 | **18/24** |
| Mean reciprocal rank | 0.814 | **0.903** |
| Repeated query latency, median | 11.85 ms | 11.97 ms |
| Repeated query latency, p95 | 13.60 ms | 13.66 ms |
| GGUF file size | 639.15 MB | 639.45 MB |

Removing the document prefix did not improve the overall result: top-one accuracy was 33/48 for Qwen and 40/48 for Harrier, while Harrier's top-five score fell to 45/48. Keep the current prefix for the next pilot. Replacing embeddings requires a new index version and a complete rebuild; equal vector dimensions do not make vectors from different models compatible.

**Decision:** integrate Harrier as the next search candidate, then validate with annotated queries over a larger real library before making it the default. The multilingual gain is useful evidence, but 48 correlated, authored queries are not a general retrieval benchmark. The Harrier GGUF is a checksum-pinned community conversion; its upstream model is [Microsoft Harrier](https://huggingface.co/microsoft/harrier-oss-v1-0.6b).

**Speech recognition: Granite 4.1 versus Granite 5**

The fixed set contains **44 public clips / 271.3 seconds**: 24 conversational [AMI](https://huggingface.co/datasets/edinburghcstr/ami) clips selected across four offsets and 20 clean [LibriSpeech](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy) clips. All models received identical 16 kHz mono PCM files. A separate synthetic speech fixture warmed each engine and was excluded from accuracy scores. Inference timing includes feature extraction and decoding; llama.cpp additionally includes its local HTTP request. No VAD, diarization, punctuation restoration, or UI processing is included.

| Measure | Granite 4.1 Q4 — app default | Granite 4.1 Q8 — saved choice | Granite 5 TurboCTC BF16 |
|---|---:|---:|---:|
| Standard normalized word-error rate | 4.42% (35/791) | 4.93% (39/791) | 5.18% (41/791) |
| AMI normalized word-error rate | 8.83% | 9.09% | 10.13% |
| LibriSpeech normalized word-error rate | 0.25% | 0.99% | 0.49% |
| Total warm inference time, 44 clips | 8.18 s | 9.25 s | **0.97 s** |
| Median clip latency | 161 ms | 187 ms | **17.5 ms** |
| Audio seconds processed per second | 33.2× | 29.3× | **280.2×** |
| Process/model startup | 1.05 s | 1.48 s | 2.46 s |
| First separate warm-up transcription | 0.48 s | 0.57 s | 1.24 s |
| Sampled peak process RSS | 2.87 GiB | 3.62 GiB | 1.05 GiB |

Granite 5 was **8.4× faster than Q4 and 9.6× faster than Q8** in warm inference. Its final normalized error count was six above Q4 and two above Q8; this small set does not establish a reliable accuracy ordering. Q8 demonstrated no consistent accuracy advantage over Q4.

The initial baseline pass retained llama.cpp's default prompt-cache limit. A final baseline pass explicitly matched the app's 256 MiB limit and is shown in the table. Initial normalized WER was 5.69% for Q4 and 5.82% for Q8, versus 4.42% and 4.93% in the final pass. No deterministic decoding override was added to the app's ASR request. The cause of that output variation was not isolated, and it should not be attributed to the cache setting. Both passes are retained. Speed was stable across the baseline passes; accuracy should be described as comparable, with a possible tradeoff, rather than a Granite 5 accuracy win.

The initial literal-word comparison was misleading for general ASR accuracy: it scored Granite 5 at 10.82%, Q4 at 5.67%, and Q8 at 6.19%. Granite 5 frequently expands contractions and colloquial forms: “I've” becomes “I have,” and “gonna” becomes “going to.” Applying the same standard Whisper English normalizer to references and hypotheses removes those differences. Both scoring versions and the normalized strings are retained in the results. Literal wording may still matter for verbatim transcription.

Granite 5 emits lowercase text without the punctuation supplied by the existing Granite 4.1 prompt, and supports English only. It has no native LokalBot engine integration yet. The measured speed excludes any later punctuation restoration. RSS is process accounting, not a complete unified-memory measurement; MLX separately reported a 1.33 GiB peak allocation, so cross-runtime memory figures are indicative.

**Decision:** prototype [Granite Speech 5 TurboCTC](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc) as an English fast-transcription option. Retain Granite 4.1 for the existing multilingual and punctuated-output workflow until the new engine is integrated and evaluated end to end. Prefer the Apache-2.0 checkpoint tested here, not the separate NC variant.

**Main LLM: MiniCPM5 versus Qwen3.5**

Both models ran with Q4_K_M weights, a 32,768-token context, one slot and the app's reasoning-enabled server configuration. The three summary scenarios used the production meeting-system prompt, including the Me/Others ownership rules, at temperature 0.2, a 4,096-token output limit and a requested 1,024-token thinking budget. Separate schema-constrained extraction and short Compose tasks tested output contracts. The scenarios cover release handoffs, vault-risk decisions and mixed English/Serbian/Montenegrin corrections. No numerical action-completeness score is claimed for these small manually reviewed cases.

| Measure | Qwen3.5-4B Q4 | MiniCPM5-2B Q4 |
|---|---:|---:|
| GGUF file size | 2.741 GB | **1.561 GB** |
| Summary latency, median of three first attempts | 15.12 s | 15.65 s |
| First-attempt summaries reaching a normal stop | 3/3 | 2/3 |
| Schema-constrained outputs parsing as JSON | 3/3 | 3/3 |
| Structured extraction latency, median | 8.66 s | **3.96 s** |
| Facts recovered from the same 106,707-character archive | 6/6 | 6/6 |
| Long-context end-to-end latency | 32.41 s | **18.68 s** |
| Long-context input tokens, before chat template | 25,506 | 21,423 |

The smaller tokenizer count is part of MiniCPM5's efficiency on this identical text. The archive contains six facts distributed from early to late positions; it is a synthetic retrieval stress case, not proof of full long-meeting summarization quality. The original Qwen stress fixture was too large and was rejected by the harness before inference; it was replaced by the identical, bounded fixture reported above. That preparation error is not counted as a model failure.

MiniCPM5's summary failures are material:

- The release-handoff summary entered a repetition loop and exhausted 4,096 output tokens. The same case also exhausted its output allowance at the author's recommended temperature 1.0 / top-p 0.95.
- In the vault summary, it attributed the user's cap-table assignment to Ana in the narrative and also duplicated it under Ana's actions. It discarded unresolved risk and transfer-restriction questions.
- Mixed-language and vendor-sampling outputs leaked drafting/reasoning text or failed to produce a usable visible summary. Structured extraction assigned the tester-meeting task to Jelena even though it was directed to Me, and produced malformed timestamp strings in several records.
- The larger 6,144-token, zero-thinking-budget recovery produced a readable release summary, but still misattributed the checklist in the TL;DR and omitted timestamps from the user's action items.

Qwen is also imperfect: it omitted some structured actions, dropped deadlines from one summary's action section, and emitted a stray closing thinking tag in some raw responses. The app has output-sanitization/recovery paths that this engine-level comparison does not fully exercise. JSON validity alone should not be treated as extraction correctness.

**Decision:** retain Qwen3.5-4B as the main default. [MiniCPM5-2B](https://huggingface.co/openbmb/MiniCPM5-2B) offers smaller weights and faster long-context retrieval, but these results do not justify accepting its summary regressions.

**Separate finding: zero-budget reasoning control**

With the installed Qwen GGUF and b10173, short requests using `thinking_budget_tokens: 0` spent the entire 512-token allowance in reasoning and returned no visible text in all six cases. Adding `reasoning_effort: "none"` did not resolve those cases. These are deliberately short engine tests; they do not demonstrate that the full app's Compose flow always fails, because that flow uses different output limits.

A minimal four-variant reproduction isolated a working control:

| Request control, same correction task | Result |
|---|---|
| `thinking_budget_tokens: 0` | Empty visible output, 256-token limit reached |
| `reasoning_budget_tokens: 1` | Correct visible sentence |
| `chat_template_kwargs: {"enable_thinking": false}` | Correct visible sentence |
| `reasoning_effort: "none"` with unrestricted budget | Empty visible output, 256-token limit reached |

Using the explicit template setting on all six Qwen Compose controls produced visible completions in **6/6**, taking 0.24–0.65 seconds. It preserved the email address, names, numbers, uncertainty and requested language. A wording-only difference such as “15 i 30 sati” versus “15:30” is not counted as a semantic failure. The initial generic Compose comparison is therefore not evidence that MiniCPM5 is a better Compose model.

The durable app change to consider is explicitly setting `chat_template_kwargs.enable_thinking` to false when the effective requested thinking budget is zero, merging existing template arguments rather than replacing them, and verifying that path against the bundled runtime. No such app change was made by this benchmark. The exact upstream API parsing can be inspected in [b10173 server-common.cpp](https://github.com/ggml-org/llama.cpp/blob/b10173/tools/server/server-common.cpp).

**Evidence and reproduction**

- `results/` contains raw public/synthetic model outputs, per-query ranks, timing, memory samples and the two ASR scoring variants.
- `models-manifest.json` and `baseline-artifacts.json` pin model revisions, byte sizes and verified SHA-256 digests. `environment.json` pins runtime and relevant source-file hashes. The source baseline is `879314487d32f4e2ae3f8f126aabc432cc07b9a6`; relevant benchmarked source files were unchanged by concurrent commits during the run.
- `audio-manifest.json` records public dataset rows and audio hashes. `requirements-lock.txt` records the isolated Python environment. The Whisper spelling map is checksum-recorded in `normalizer-manifest.json`.
- `prepare.py` downloads candidates and public audio. `fixtures.py` creates the authored cases. `run.py` runs one model/role at a time. `followups.py`, `budget_probe.py` and `compose_control.py` reproduce the bounded follow-up checks. `score_asr.py` recalculates accuracy without running inference.
- Models, audio and the private distractor transcript remain under `/private/tmp/lokalbot-model-alternatives-20260907`. The private transcript and full retrieval corpus are not copied into this repository. Exact reproduction of the 110-document search corpus requires that retained local fixture; running with only the public authored material yields a different corpus and must be reported separately.
- Sample commands: `python prepare.py models`, `python prepare.py audio`, `python fixtures.py`, `python run.py embedding harrier`, `python run.py generation minicpm5`, `python run.py asr granite5`, and `python score_asr.py`. Use the isolated Python environment and provide Metal/process access. Run inference commands serially. Candidate files are roughly 3.15 GB in total; they are not installed in the app.

This pilot has one inference pass per primary case, a repeated ASR baseline to align the cache setting, repeated query-latency measurements, and targeted follow-ups justified by observed failures. It does not cover a large annotated private library, noisy far-field microphones, all supported languages, speaker diarization, voice quality, power/thermal control, or hosted UI validation. VibeVoice and Supertonic were outside this first three-candidate test pass.
