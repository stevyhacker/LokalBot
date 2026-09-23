# Nemotron integration draft

Settings → Recording → **Speaker model** offers **Nemotron 3 (Preview)**. The existing Pyannote Community-1 default is preserved for both fresh and upgraded settings. Selection affects later processing; it does not rewrite completed transcripts. Reprocess a meeting to use another model.

## Runtime and evidence

- FluidAudio is pinned to `0.17.1` / `5c51c5c93afff0d89594a2a93c3103e790ba648c`, the exact runtime evaluated in the [AMI report](results/2026-09-23/REPORT.md).
- The full-precision `offline` CoreML preset is pinned to `53445f72d5735e33406ccce7b92116bce7ab1ab7`, with all five required files verified by byte count and SHA-256. Files occupy 199,164,847 bytes. Only this preset downloads; no preview or quantized weights are substituted.
- A retained actor owns model objects and keeps synchronous inference off the main actor. Preparation uses the existing single-flight primitive. Each track gets fresh Nemotron speaker state. There is no automatic backend fallback on errors; the processing retry UI receives the selected-model error.
- Both microphone and system tracks use the selected backend. Overlapping activity survives conversion and reaches the existing unresolved-speech path. ASR text is not split proportionally or assigned a dominant overlapping voice.
- Partial transcript keys include model/weight/turn-policy identity, so a backend switch cannot reuse the old partitioning.

## Remembered voices

Remembering remains an independent opt-in. Nemotron slots and its 512-dimensional internal cache are not voice identity embeddings. When remembering is enabled, a second Pyannote pass produces the established 256-dimensional vectors. Samples map to transcript speakers only through clean time coverage, not matching ordinal IDs. This adds Pyannote runtime and model residency; the standalone Nemotron timing advantage does not describe this two-pass configuration.

The Pyannote model revision, offline diarizer implementation, audio converter, and embedding preprocessing remain unchanged in the upgrade. Shared array utilities did change. A public ES2004a headset recording exported 739 vectors under FluidAudio 0.15.8 and compared them with the app adapter under 0.17.1: all sample ranges matched, minimum cosine similarity was **0.9999936549579356**, and maximum absolute component difference was **0.000845246**. Outputs are numerically close, not bitwise identical. The compatibility fingerprint remains unchanged; model weights, dimensions, preprocessing, or a failed compatibility check in a later upgrade require a new fingerprint and enrollment policy.

The adapter also reproduced all **522** saved Nemotron segments on that recording, including speaker IDs and boundaries, and repeated output after resetting between tracks. This validates the acoustic adapter and embedding space; it does not calibrate voice recognition or prove end-to-end named ASR accuracy.

## Validation and limits

The local app builds. Across the selected non-UI suites, 156 tests passed and one existing optional test skipped; the explicit public-fixture runtime test ran and passed. Tests cover legacy settings, persisted opt-in, model failure/retry, cancellation before downloading, overlap, clean temporal voice matching, pinned artifacts, existing voice matching, and pipeline preparation. Strict SwiftLint and diff checks pass. The hosted settings test captures the selected model and checks disabling/re-enabling diarization; hosted results are reported in the PR.

An additional 13 existing `MeetingSpeakerIdentityServiceTests` could not complete locally: reading newly written protected synthetic `.sealed` files failed with Cocoa error 257 / POSIX `EPERM`. A standalone Foundation probe reproduced the same failure with `.atomic, .completeFileProtectionUnlessOpen`, while an ordinary atomic write/read succeeded. The unchanged storage code and its protection policy were preserved. Hosted CI runs the full suite; these tests are not reported as locally passing.

This is post-recording inference. It decodes a complete track before calling the batch API, so audio/features grow with recording duration. Cancellation is checked around decoding and synchronous model processing; FluidAudio cannot interrupt an in-progress batch call. No live microphone path, eight-speaker quality study, multi-hour memory study, private-meeting evaluation, or full ASR/name-attribution evaluation is claimed. It has not been installed or released.

The benchmark covers four English AMI conversations with four speakers, each under two microphone conditions. Its 66.5% relative DER reduction and 2.05× warm speedup are evidence for an opt-in pilot, not universal product performance guarantees.
