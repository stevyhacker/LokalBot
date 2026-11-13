# Whistle evaluation — 9 October 2026

**Recommendation: keep the existing transcription choices. Whistle is a low-priority
option for a severely constrained download/memory budget, not an accuracy upgrade
for LokalBot.** On this Mac its English latency advantage over Parakeet Ultra was
about 16 ms at the median, while its word error rate was more than twice as high.
It also failed the unsupported Serbian probe. Its small download, low process
memory, silence handling, vocabulary biasing, and working streaming API are real
advantages, but they do not offset the measured accuracy loss for this product.

## Main result

Apple M4 Max, 48 GB, macOS 27.0.1. All inference was local with network access
blocked by macOS. The primary sample contains **44 human-transcribed English clips,
810 reference words, 295.17 seconds**: 24 AMI headset meeting utterances and 20
FLEURS test utterances. Every engine heard identical 16 kHz PCM. Language detection
was automatic. Accuracy uses the first pass; latency uses the median of three
passes for each clip, excluding model load, warm-up, and file reading.

| Model and tested runtime | English WER ↓ | Median complete call ↓ | p95 complete call ↓ | Throughput ↑ | Model download |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whistle, native C++ C API | **20.25%** | **31.7 ms** | **60.8 ms** | **200.2× realtime** | **16.92 MB** |
| Parakeet Ultra 0.6B, FluidAudio 0.17.5 | 8.89% | 48.0 ms | 66.1 ms | 135.6× realtime | 632.16 MB |
| Qwen3-ASR 1.7B 8-bit, speech-swift/MLX | **7.65%** | 157.0 ms | 272.9 ms | 40.4× realtime | 2,467.85 MB |

Whistle made 164 word edits, Parakeet 72, and Qwen 62. Its excess WER versus
Parakeet was **11.36 percentage points**, with an exploratory paired clip-bootstrap
95% interval of **7.42–16.30 points**. Against Qwen the excess was **12.59 points**
(8.72–17.22). Correlated speakers and the small sample limit these intervals;
they are not estimates across all meetings or accents.

Whistle was 1.48× faster than Parakeet on aggregate English decode time, and
4.96× faster than Qwen. The absolute difference to the existing fast option was
small: both Whistle and Parakeet finished 95% of these short English clips within
about 66 ms. This test does not justify choosing between Qwen and Parakeet as the
meeting default; it is a bounded evaluation of the proposed new model.

## Accuracy by condition

WER is lower-is-better. English subsets and each other language are kept separate;
the unsupported Serbian probe is excluded from the primary aggregate.

| Condition | Clips | Reference words | Whistle | Parakeet Ultra | Qwen3-ASR 1.7B |
| --- | ---: | ---: | ---: | ---: | ---: |
| AMI IHM meeting utterances | 24 | 385 | 25.97% | 10.39% | 9.09% |
| English FLEURS | 20 | 425 | 15.06% | 7.53% | 6.35% |
| German FLEURS | 8 | 182 | 19.78% | 1.65% | 2.20% |
| French FLEURS | 8 | 227 | 25.11% | 7.93% | 7.93% |
| Polish FLEURS | 8 | 139 | 42.45% | 9.35% | 20.86% |
| Serbian FLEURS, unsupported by Whistle | 8 | 154 | 111.69% | 24.03% | 26.62% |
| English plus synthetic white noise, 10 dB SNR | 6 | 123 | 16.26% | 4.88% | 5.69% |
| Synthetic names/technical terms, no hints | 3 | 41 | 36.59% | 17.07% | 12.20% |
| Same synthetic names/terms, with hints | 3 | 41 | 21.95% | 17.07%* | 2.44% |
| Continuous synthetic speech fixture | 1 | 59 | 0% | 0% | 0% |
| One English clip attenuated by 20 and 40 dB | 2 | 38 | 5.26% | 52.63% | 5.26% |

*Parakeet has no vocabulary-prompt input; its hinted rows are unchanged repeats.
Whistle's keyword bias reduced the name-case errors from 15 to 9, but Qwen with
the same vocabulary had one error. WER can exceed 100% when insertions add to
substitutions/deletions, as in Whistle's Serbian outputs. The Serbian probe should
be interpreted as evidence against silently routing unsupported speech to Whistle.

Whistle and Qwen handled the two quiet versions much better than Parakeet. This
is one source sentence, so it is a useful follow-up signal rather than a general
low-volume robustness claim. The white-noise conditions also do not represent
all real meeting noise. No overlapping-speaker or full-meeting accuracy was measured.

## Memory and preparation

| Measurement | Whistle | Parakeet Ultra | Qwen3-ASR 1.7B |
| --- | ---: | ---: | ---: |
| Maximum process RSS (`time -l`) | **131.6 MiB** | 645.9 MiB | 2.45 GiB |
| Process peak memory footprint (`time -l`) | 130.8 MiB | 80.3 MiB | 7.42 GiB |
| MLX peak allocation | — | — | 3.65 GiB |
| Observed model-load call | 4.9 ms | 10.87 s | 0.50 s |
| Observed first five-second warm-up | 25.8 ms | 60.1 ms | 3.59 s |

**RSS is not the total memory cost of an accelerated model.** Core ML can place
allocations in services outside the runner, and MLX/unified memory is accounted
for differently across these measures. Do not add RSS, footprint and MLX values
or compare them as interchangeable quantities. Whistle's 16.9 MB weight file
also does not mean 16.9 MB of runtime RAM.
The native static library is another 1.53 MB on disk, in addition to Whistle's
16.92 MB model file and a small C header/wrapper.

Preparation observations have unequal file/compilation/cache histories and are
not comparable cold-start benchmarks. The baseline files were cloned into the
benchmark directory, and Core ML compiled/prepared that copy. Timed warm inference
started only after each engine's warm-up. The Mac remained in normal use with
other builds and model processes; the latency figures are not idle-machine or
battery measurements.

## Functional checks

- **97 batch conditions × three passes × three engines: 873 successful calls,
  zero engine errors.** Normalized transcripts were unchanged across passes for
  every model and condition.
- **Silence/noise:** all three models returned zero words for zero PCM at 1, 5,
  15 and 30 seconds, a steady 440 Hz tone, and steady Gaussian noise. These six
  controls do not establish hallucination rates on arbitrary silence/background audio.
- **Word timestamps:** Whistle returned 1,794 words across the first batch pass,
  with no negative/reversed times, clip overruns beyond 100 ms, or decreasing
  starts. This checks structure only; no word-level acoustic ground truth was used.
  Parakeet's 3,797 subword/token timings also passed those checks. Qwen's separate
  aligner was not loaded or measured.
- **Streaming:** a 55.28-second concatenation crossed the 30-second boundary and
  finalized successfully. Its 123-word reference had eight errors (**6.50% WER**).
  First committed words appeared after **three seconds of supplied audio**;
  the longest one-second update took **128.9 ms**, with 3.05 seconds total compute.
  The source clips were easier than the full primary set; do not compare this
  stream's WER directly with the 44-clip English aggregate. Updates were supplied
  faster than real time, so this is not measured microphone-to-screen latency.

## Privacy and integration

The model and native binaries were downloaded at immutable revisions and checked
against their published LFS hashes. The 18 Parakeet files matched LokalBot's
pinned catalog; the six Qwen files matched their cached revision/ETags. The
baseline package pins match `project.yml` at the inspected source commit.

No Python Needle package was installed or imported. Whistle ran through the
publisher's static native library with `NEEDLE_TELEMETRY=0` and `DO_NOT_TRACK=1`,
inside `(deny network*)`. An outbound TCP attempt failed with **EPERM** before
inference. All test audio was public or synthetic; no meeting-library content
was read and no inference payload was sent to a service.

The [Python SDK's telemetry](https://github.com/cactus-compute/needle/blob/ef3cf7543204d99878c0dd913a05f6a506da4be8/needle/_telemetry.py)
is enabled by default, and the README's native-binary telemetry statement is
in tension with its deployment documentation. This evaluation proves operation
under an enforced network block, not the absence of network attempts without it.
Any product integration would need its own enforceable network policy and runtime
provenance review. The C API has process-global, non-thread-safe model state and
no exposed per-call cancellation/unload handle; a Swift wrapper needs serialized
ownership, with process isolation worth considering for cancellation and cleanup.

No app implementation, installation, release, or settings change was made.

## Reproduction and evidence

- [Harness, methodology, and commands](../../README.md)
- [Aggregate measurements and paired intervals](summary.json)
- [Host, source pins, and limits](provenance.json)
- [Pinned Whistle/native downloads](downloads.json)
- [Verified baseline file hashes](baseline-assets.json)
- [Fixture identifiers and PCM hashes](fixtures.json)
- [Network-denial assertion](network-denial.json)
- [Swift dependency resolution](swift-package-resolved.json)
- [Python dependency freeze](requirements.freeze.txt)

The raw local outputs, audio and diagnostic logs are at
`/private/tmp/lokalbot-whistle-eval-20261009`; that directory is temporary and is
not part of the checkout. English normalization, unsupported-language handling,
sample limitations, and the difference between engine calls and the production
pipeline are detailed in the methodology.
