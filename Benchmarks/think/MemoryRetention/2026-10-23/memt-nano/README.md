# MemT-1.0-Nano: completed memory-retention benchmark

**120/120 cases complete.** Primary English slice: **51/52** useful memories recalled with valid source citations, **6** unwanted proposals, and **39/44** empty cases correct. The complete English case contract passed in 89/96 cases. The separate 24-case Serbian slice is exploratory.

- [Full report](REPORT.md)
- [English chart](memory-retention-with-memt.png) and [SVG](memory-retention-with-memt.svg)
- [Serbian chart](memory-retention-with-memt-serbian.png)
- [Reddit draft — unposted](REDDIT_DRAFT.md)
- [Combined evidence bundle](share-bundle-with-memt.zip)
- [Raw responses](results/memt-nano-nf4-offload.jsonl), [scores](scores.json), [review decisions](review.json), [chart data](chart-data.csv), and [validation](validation.txt)

The cases were frozen on 23 October 2026. MemT ran on 23 and 25 October, using the same pinned configuration. The first 30 responses and their 17 review decisions are preserved unchanged in [resume-evidence/](resume-evidence/); [RUN_HISTORY.md](RUN_HISTORY.md) explains the user-requested stop and resume. The original four-model report and evidence remain in the parent directory.

This is stateless extraction with thinking disabled. Every case starts fresh, so it does not exercise MemT's persistent latent-memory feature. MemT uses experimental NF4 expert offload on a Windows RX 6600 XT; the other configurations use GGUFs and llama.cpp on Ubuntu. Hardware, runtime, quantization and schema-enforcement implementations differ. These are configuration-specific accuracy results, with synthetic cases and unblinded assistant-performed semantic review.

## Audit and reproduce scoring

Run `analyze.py` to reproduce the automatic and reviewed scores from the saved responses, then `validate_results.py` to check frozen inputs, the preserved initial prefix, every semantic decision, score aggregates and chart values. Neither command performs inference. `chart.py` renders the standalone figures using Matplotlib; `build_report.py` regenerates the report, draft and this index. `package_evidence.py` builds and verifies the local ZIP.

The [frozen extension protocol](PROTOCOL_EXTENSION.md), [model manifest](model.json), [verified checkpoint receipt](verified-model-files.json), [runtime requirements](requirements-observed.txt), [inference runner](run_windows.py), and [expert-offload adapter](nf4_offload.py) preserve the tested setup. [Numerical validation](adapter-model-validation.json), [tokenizer validation](tokenizer-validation.json), and [smoke result](smoke-result.json) cover preparation checks. The initial memory-mapped loading failure is preserved in [preparation-failures/](preparation-failures/); the successful loader uses the documented `pread` backend.

The checkpoint itself is downloaded separately through `download_model.py`. Before inference, copy the parent directory's frozen `cases.json`, `prompts.json`, `schema.json`, `score.py` and `frozen.json` beside the runner. The isolated Windows runtime uses AMD PyTorch and process-local `BNB_ROCM_VERSION=714`, `MIOPEN_FIND_MODE=FAST`. The runner verifies identity before resuming, preserves every saved response, and runs an unscored smoke prompt before benchmark cases. See the execution history for the exact existing run.

The report and evidence are submitted through the benchmark pull request. No paid GPU was rented, and the Reddit draft has not been posted. The frozen protocol and archived partial-run materials retain their original publication-status wording.
