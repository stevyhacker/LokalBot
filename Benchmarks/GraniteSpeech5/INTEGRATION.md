# Granite Speech 5.0 2B optional integration

Implemented on 21 October 2026 using the official [Granite Speech 5.0 2B GGUF release](https://huggingface.co/ibm-granite/granite-speech-5.0-2b-GGUF). The [base model card](https://huggingface.co/ibm-granite/granite-speech-5.0-2b) describes its accuracy, language coverage, and recommended quantization.

## Product behavior

- Settings → Models → Transcribe → Change offers **Granite Speech 5.0 2B**, separate from Granite 4.1 and the English-only 470M TurboCTC option. The same model handles dictation when selected. CLI settings accept `graniteSpeech5`, stored as `granite-speech-5.0-2b`.
- The optional download uses IBM's Q8_0 decoder and matching F16 projector: **3,115,509,856 bytes** combined, displayed as 3.12 GB. Both files are pinned to revision `df3833f5e22e7d51c3f5dfedd4726260f7ec7cb5` with byte sizes and SHA-256 digests.
- Preparation reuses the bundled local llama.cpp runtime, authenticated loopback endpoint, existing VAD, and region-based speaker attribution. It does not add a remote inference origin, Python dependency, or new Swift package.
- Manual and existing scoped known-name vocabulary are passed through the prompt-bearing engine method. The combined vocabulary is capped at 480 characters to leave room in the existing 4,096-token server context. This integration does not expose the publisher's full 2,000-keyword maximum. The existing echo filters continue to apply.
- Existing 4.1 choices, custom configurations, cache paths, and prompt behavior are preserved. Qwen3-ASR 1.7B remains recommended. The 5.0 preset's revision-scoped cache is separate from 4.1, including its identically named projector. Download detection, size estimates, and deletion resolve the correct pair.

## Validation

- **App build and 80 affected non-UI tests passed**, zero failures/skips. The Xcode result bundle was inspected with `xcresulttool`, rather than relying only on the shell exit code. Coverage includes settings persistence and the CLI registry; pinned artifact URLs/digests; vocabulary/authentication/language request fields and bounds; size labels; and both directions of cache deletion isolation.
- **SwiftLint strict passed** with `--no-cache` (the sandbox denied SwiftLint's normal cache write).
- **Two native server smoke calls passed** using the repository's ten-second synthetic `ModelChecks/speech.wav`: one plain transcription and one with vocabulary hints. Both returned the expected meeting/release/schedule words. This verifies the exact pinned model/projector load and HTTP decode path on the bundled runtime, not general accuracy, full production VAD/diarization, or UI behavior. The hinted output differed in wording and punctuation from the plain output; do not interpret successful hint delivery as guaranteed punctuation or improved accuracy.
- Each downloaded model's complete SHA-256 matched the configured pin. Inference used only synthetic audio and a temporary loopback server, which was stopped after the checks. The installed app, settings, and model cache were not changed.

The build emitted pre-existing actor-isolation/closure warnings and an anomalous SwiftCompile diagnostic saying a command failed with exit code 0. The final test bundle reports **Passed**, 80/80 tests, with no runtime warnings. This diagnostic was not treated as test failure or silently used as proof of success.

**Validation scope:** the 80 local tests and native smoke checks above ran before the feature was moved into an isolated PR branch on current master. The feature applied without conflicts; upstream changes in `SettingRegistry.swift` and `DEVELOPMENT.md` were preserved. Hosted build, unit, and UI checks on the PR establish validation of that submitted revision. The hosted-only `ModelsSettingsUITests/testGraniteSpeech5IsOfferedAndCancelKeepsTheCurrentModel` verifies discovery, download labeling, and cancellation, and captures `models-granite-speech5-option`. No UI tests ran locally. Nothing was installed or released.

Machine-readable evidence is in [integration-validation.json](2026-10-21/integration-validation.json). A reproducible short native check is [native-smoke.py](native-smoke.py):

```sh
UV_CACHE_DIR=/private/tmp/lokalbot-granite5-uv uv run --offline --no-project python \
  Benchmarks/GraniteSpeech5/native-smoke.py \
  --models /absolute/temporary/model-directory \
  --output /absolute/native-smoke.json
```

The runner requires the two downloaded files already present, verifies both hashes, and launches only `Vendor/llama-cpp/llama-server`. It does not launch LokalBot or read a meeting library. Its two call times are smoke-test observations with unequal cache state, not a performance comparison.
