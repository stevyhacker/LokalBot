# Speech model integrity manifests

`pinned-speech-models.json` records the selected files from the publisher Hugging Face
model API at each recorded immutable Git commit. `digest` is the publisher LFS
SHA-256, or Git blob SHA-1 (including the `blob <size>\0` header) for ordinary files.
Metadata was retrieved on 2026-09-25 without downloading model weights. Community-1
retains the commit already pinned by FluidAudio 0.17.1. Qwen manifests are compiled
alongside `PinnedModelSnapshot` in `PinnedSpeechModels.swift`; ONNX archive pins
come from the publisher GitHub release-asset digest and byte count.

Model updates require explicit review of the revision, file set, sizes, and digests;
the app must not resolve `main` to pick a new model at runtime. Synthetic integrity
tests use local files and do not establish model quality or run speech inference.
