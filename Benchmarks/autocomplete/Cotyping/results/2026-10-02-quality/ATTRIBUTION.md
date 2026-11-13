# Benchmark attribution

The external synthetic phrase corpus and Cotabby-generated benchmark artifacts
come from [FuJacob/cotabby](https://github.com/FuJacob/cotabby), revision
`7724926b3e93f14e3b576ba46ff52c4f64d9712d`.

Original corpus:
[`CotabbyTests/Fixtures/phrase-prediction-1337.json`](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/CotabbyTests/Fixtures/phrase-prediction-1337.json),
SHA-256 `b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`.

The upstream project publishes it under GNU AGPL version 3. A verbatim copy
of its [license](COTABBY-LICENSE.txt) accompanies these artifacts. The raw archive
includes derived synthetic typed-prefix inputs and reference words, not a
separate complete copy of the original corpus. `cotabby-gemma-matched` contains
upstream report structures and selected phrase records. The corpus is consumed
only by benchmark tooling; it is not bundled into the application.

The independent `Benchmarks/autocomplete/Cotyping/quality-cases.json` fixture was authored
for this evaluation and does not copy Cotabby phrases. All benchmarks use
synthetic writing, not the user's messages or saved writing history.

The compared Gemma quantization is
[`mradermacher/gemma-4-E2B-i1-GGUF`](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF/tree/a9bf638e53783fc93778f357cc5c672eab5393b1),
file `gemma-4-E2B.i1-Q6_K.gguf`. Its pinned revision, size and verified checksum
are in [gemma-model.json](gemma-model.json). No model weights are included here.
