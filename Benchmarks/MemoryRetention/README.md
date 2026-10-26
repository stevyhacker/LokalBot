# Recall vs. restraint: memory-retention benchmark

The frozen suite tests whether a local model can extract useful personal memories while obeying explicit retention rules. It has 120 authored synthetic cases in 60 contrast pairs: 96 English cases and a separate exploratory 24-case Serbian slice. Semantic grading was performed by an assistant with model identities visible; there is no independent human validation or significance claim.

- [Completed five-configuration report, including MemT](2026-10-23/memt-nano/REPORT.md)
- [Comparison chart](2026-10-23/memt-nano/memory-retention-with-memt.png)
- [Evidence bundle](2026-10-23/memt-nano/share-bundle-with-memt.zip)
- [Original four-model report](2026-10-23/REPORT.md)
- [Frozen protocol](2026-10-23/PROTOCOL.md)

MemT's added configuration recalled 51/52 eligible English memories, emitted 6 unwanted proposals, and passed 39/44 empty cases. It uses experimental NF4 expert offload on Windows; the other arms use GGUF/llama.cpp on Ubuntu. This tests stateless extraction with thinking disabled and does not exercise MemT's persistent latent-memory feature.

Reproduce scoring and archive checks without inference:

```sh
uv run --no-project python Benchmarks/MemoryRetention/2026-10-23/test_score.py
uv run --no-project python Benchmarks/MemoryRetention/2026-10-23/memt-nano/verify_bundle.py
```

The Reddit draft is included for review and has not been posted.
