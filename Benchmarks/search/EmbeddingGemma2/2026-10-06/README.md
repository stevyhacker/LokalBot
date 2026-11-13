# Reproduce the local embedding comparison

These scripts use only synthetic fixtures and disposable state beneath `/private/tmp/lokalbot-embeddinggemma2-20261006`. They read the installed Harrier weights and llama-server executable, and never write app settings, models or indexes. Run inference serially on an Apple Silicon Mac with Metal access. `vision.swift` runs Vision on PNG files; it does not capture the screen or run UI tests.

From the repository root:

```sh
export UV_CACHE_DIR=/private/tmp/lokalbot-embeddinggemma2-20261006/uv-cache
uv venv --python 3.13 /private/tmp/lokalbot-embeddinggemma2-20261006/.venv
uv pip install --python /private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python -r Benchmarks/search/EmbeddingGemma2/2026-10-06/requirements.txt
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/prepare.py
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/fixtures.py
swiftc -module-cache-path /private/tmp/lokalbot-embeddinggemma2-20261006/swift-cache Benchmarks/search/EmbeddingGemma2/2026-10-06/vision.swift -o /private/tmp/lokalbot-embeddinggemma2-20261006/vision
/private/tmp/lokalbot-embeddinggemma2-20261006/vision /private/tmp/lokalbot-embeddinggemma2-20261006/fixtures/screens.json /private/tmp/lokalbot-embeddinggemma2-20261006/ocr.json
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/run.py harrier
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/run.py gemma-text
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/run.py gemma-vision
/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python Benchmarks/search/EmbeddingGemma2/2026-10-06/score.py
```

Package installation and checkpoint preparation need networking. Inference runs offline. Downloads need roughly 2 GB of free space including the Python environment; checkpoint files stay in the disposable folder and are not included in this report directory. Model files are pinned and verified against public LFS checksums.

The checked-in vectors allow re-scoring without loading either model: copy `results/` and `fixtures/` into the disposable directory and run `score.py`. Inspect [REPORT.md](REPORT.md) for methodology, runtime differences, uncertainty, and adoption limits. `first-pass/` preserves initial scores and timing metadata; the report's headline numbers use `results/`, from the final harness with an explicit 8K Gemma input ceiling.
