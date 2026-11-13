**FunASR versus LokalBot's native Qwen speech pipeline — 8 September 2026**

Keep the native Qwen runtime. Adapt word alignment and finer speaker assignment into a native integration pilot. The tested FunASR configuration was slower, used more memory, and had worse recognition and diarization scores on the meeting excerpts. It modestly improved the final speaker-labeled transcript score. Word alignment improved that score more substantially without rerunning native recognition.

This is a comparison of the Qwen approach discussed in the task. LokalBot's default Granite Speech engine was not rebenchmarked here. No production source, installed app, user settings, or meeting library was changed. All inference used public audio locally; no UI tests were run.

| Meeting metric | Native Qwen + Silero + pyannote | FunASR Qwen + FSMN + CAM++ + aligner |
|---|---:|---:|
| Audio evaluated | 270 s | Same 270 s |
| Processing time, after initial warmup | 29.47 s | 93.14 s |
| Processing speed relative to audio duration | 9.16× | 2.90× |
| Normalized word error rate | 28.34% (297/1,048) | 31.68% (332/1,048) |
| Diarization error rate, no collar, overlap included | 36.56% | 43.62% |
| Diarization error rate, 250 ms collar, overlap included | 31.86% | 38.57% |
| Speaker-labeled transcript error, cpWER | 66.32% | 63.73% |
| OS physical-memory peak, separate first-excerpt repeat | Approximately 7.01 GiB | 10.07 GiB |

Errors are lower-is-better. cpWER concatenates each speaker's words and chooses the minimum-error mapping between anonymous reference and predicted speaker labels. It measures recognition and speaker assignment together; it is not the percentage of speakers identified incorrectly. DER measures the acoustic speaker timeline independently of transcript words.

The 24 short-clip control used the exact native VAD spans in both recognizers. Native produced 22 errors in 417 normalized words (5.28% WER); FunASR produced 21 (5.04%). That one-word difference is not evidence of a material recognition improvement. Native VAD plus recognition took 13.86 s; FunASR recognition on the already supplied spans took 31.56 s, so this control does not charge FunASR for VAD or diarization.

**Alignment experiment**

The existing native pipeline assigns an entire ASR speech span to the single diarization interval with greatest overlap. Several spans contain multiple speakers. A separate Qwen forced-alignment pass was applied to the already generated native transcript, then the same overlap rule was applied to individual words.

| Postprocessing experiment | Meeting cpWER | Added alignment time |
|---|---:|---:|
| Existing native span assignment | 66.32% | — |
| Native transcript + word alignment + existing pyannote timeline | 53.11% | 7.39 s |
| FunASR transcript + corrected word timing + CAM++ timeline | 49.76% | Included in the FunASR run |
| FunASR transcript + corrected word timing + native pyannote timeline | 53.21% | Included in the FunASR run |

The native alignment experiment reduced cpWER by 13.21 percentage points, about 20% relative, on these excerpts. Alignment took 2.63 / 2.07 / 2.69 s per excerpt, with a separate 1.47 s model load. Adding the measured stages gives 36.86 s, excluding that load. This is a sequential prototype estimate, not a measured integrated Swift application latency.

Alignment token formatting changed two normalized word edits in the native output and four in the FunASR output. Native ordinary WER changed from 28.34% to 28.53%; this small text difference is retained in the artifacts rather than presented as a perfectly text-preserving experiment. The much larger cpWER change mainly reflects speaker assignment. The corrected CAM++ word result also shows that the worse overall DER alone does not settle which diarizer best supports word assignment; more meetings are needed.

The alignment control used the Python/MPS reference aligner separately. Native MLX/CoreML integration, combined memory use, model lifecycle, unsupported-language fallback, and full-meeting performance remain unmeasured. The app's Swift speech dependency already contains forced-aligner APIs, but this comparison did not implement or validate their production use.

**Confirmed upstream adapter defect**

At FunASR commit `130e57a6fdb9661e2b0cc59199fb31ef81f2b9e9`, its Qwen adapter casts the reference aligner's floating-point seconds directly to integers in a field consumed as milliseconds. In the real smoke test, the word “decide” spans 0.40–0.80 seconds in raw alignment and becomes `[0, 0]` in the wrapper. The intended millisecond interval is `[400, 800]`. [Pinned adapter source](https://github.com/modelscope/FunASR/blob/130e57a6fdb9661e2b0cc59199fb31ef81f2b9e9/funasr/models/qwen3_asr/model.py#L297), [official Qwen ASR project](https://github.com/QwenLM/Qwen3-ASR).

The tested `vad_segment` mode still uses valid VAD start/end times for its sentence speaker labels, so this defect is not asserted to cause its measured DER or cpWER. It prevents using the adapter's word timestamps correctly downstream. The alignment experiments use the captured original floating-point times. The upstream package was not patched, and no issue or external message was submitted.

Qwen supplies its own punctuation, so no separate punctuation model was added. FunASR otherwise falls back to VAD-based sentence assignment in this configuration; merely adding an aligner does not make the wrapper assign each word to a speaker.

**Inputs, implementations, and measurement limits**

- Apple M4 Max, 48 GiB unified memory. Native app source: `9b68398352f00b50b858e6a1fd3f80a7164def49`; focused non-UI test harness in an isolated checkout. Each of the two native benchmark runs passed its one requested test, with zero failures or skips.
- Three fixed windows from AMI test meeting EN2002a: 120–210, 600–690, and 1500–1590 seconds, chosen before inference. All four speakers occur in each window. Overlapping speech occupies 69.27 seconds of the 270-second audio, making this a challenging but narrow pilot.
- The natural audio is the original mono 16 kHz Mix-Headset recording. References come from manual annotations 1.6.2, with punctuation-only tokens removed and window-boundary words selected by midpoint. The 24 short controls are the first 12 AMI and first 12 LibriSpeech clips from the earlier pinned September 7 fixture. Total audio: 425.24 seconds.
- Native: `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, actual cached artifacts fingerprinted; production Silero VAD, 15-second maximum spans, production dynamic token cap and English hint, production FluidAudio pyannote configuration, and production greatest-interval-overlap assignment. Loaded native ASR weights occupy 2.463 GB on disk, excluding small VAD/diarizer artifacts.
- FunASR: pinned source above; `qwen-asr==0.0.6`, `transformers==4.57.6`, PyTorch/torchaudio 2.8.0, MPS GPU, BF16; pinned official Qwen 1.7B and forced-aligner weights; `funasr/fsmn-vad`; the usual `funasr/campplus` Chinese-common checkpoint; 15-second maximum VAD spans, batch duration 15 seconds, ASR internal batch limit one, four CPU threads, no oracle speaker count, no VAD merging. Model artifacts total 6.573 GB. Other FunASR speaker models or configurations were not evaluated.
- This compares plausible integrations, not pure framework overhead. Native MLX uses 8-bit weights; the upstream PyTorch path uses BF16, a different decoder implementation, different VAD boundaries, and a different diarizer. Timing or quality differences cannot be attributed solely to the wrapper or quantization.
- Inference ran serially. Model setup was 2.97 s for native Qwen plus diarizer and 6.75 s for FunASR. Initial first-excerpt warmup was 13.15 s and 40.33 s respectively. Timed tables exclude these initial costs and downloads. Shape-specific compilation may remain for later excerpts. FunASR spent 11.87 s of the timed meeting pass inside alignment; removing that cost arithmetically still leaves substantially more time than native, but no unaligned end-to-end counterfactual was run.
- Separate memory probes each ran the first 90-second excerpt once for warmup and once for measurement. Native repeated at 9.65 s; FunASR at 21.45 s. Memory uses macOS `proc_pid_rusage` lifetime maximum physical footprint, which includes charges missed by plain RSS. Native was sampled externally every 250 ms, so its reported maximum is approximate; FunASR also captured the counter inside its process. The native app test host and Python host differ. The earlier FunASR external sampling window ended before the final peak; use the in-process 10.07 GiB value. Separate allocator/RSS figures are retained but not added together.
- WER uses Transformers 4.57.6's Whisper English normalizer and the pinned spelling map. DER uses pyannote.metrics 3.2.1 with the whole excerpt as evaluation region, both zero and 250 ms collars, and overlapping speech included. cpWER uses Hungarian minimum-cost assignment over edit distances, with unmatched speakers represented by empty transcripts.
- This is English-only, one meeting, three short windows, and a single main timing pass. It does not establish multilingual behavior, hour-long latency, real user meeting accuracy, streaming latency, energy use, or full installed-app performance. It does not justify changing transcription defaults.

**Decision and next implementation candidate**

Adapt word alignment and split transcript segments at reliable speaker changes inside the existing native pipeline. Preserve coarse timing for unsupported languages or failed alignment. Validate the native aligner on more meetings and measure its combined memory/lifecycle cost before shipping. Keep the existing native runtime and model defaults for now. The corrected FunASR/CAM++ result is worth retaining as a research comparison, not adopting as the app's backend from this pilot.

**Artifacts and reproduction**

`results/` contains raw public-audio outputs, scores, alignment controls, memory probes, and test summaries. `fixture.json`, `short-clips-manifest.json`, `models.json`, and `environment.json` contain source URLs, revisions, actual artifact sizes and hashes. `FunASRComparisonTests.swift` is an opt-in harness copy, not a test added to the production project. No model binaries or audio files are committed in this directory.

To reproduce on this Mac, copy the Python scripts, requirements lock, short-clip manifest and spelling map into an isolated scratch directory; create a Python 3.12 virtual environment and install `requirements-lock.txt`. Run `prepare.py` there. It downloads the pinned public model/audio assets and creates `fixture.json`; set `nativeModelDirectory` to the downloaded native 8-bit cache if it differs from this machine's path. Apple GPU access must be available to both runtimes; the Python runner refuses CPU fallback.

In an isolated checkout of the pinned app source, copy the Swift harness to `LokalBotTests`, run `xcodegen generate`, and run only `FunASRComparisonTests` through `Scripts/test/unit-tests.sh`. Set `TEST_RUNNER_LOKALBOT_FUNASR_FIXTURE` to the scratch `fixture.json` and `TEST_RUNNER_LOKALBOT_FUNASR_REPORT` to scratch `native.json`. Then run, sequentially, `run_funasr.py --smoke`, `run_funasr.py`, `align_native.py`, `score.py`, and `score_alignment.py` from the scratch environment. The Python runner reuses `native.json` spans for the short controls. Run the memory probe separately using `run_funasr.py --memory-probe`, and a native harness fixture restricted to the first excerpt while `measure_memory.py` observes its process. Neither harness needs a user's private recordings.

AMI audio and annotations are provided by the AMI Consortium under [CC BY 4.0](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml). These benchmark excerpts are cropped and their annotations normalized as described above. [Original audio](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/EN2002a/audio/EN2002a.Mix-Headset.wav), [original annotations](https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip), [LibriSpeech corpus](https://www.openslr.org/12).
