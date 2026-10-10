Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Corpus attribution

The public English checkpoints in this experiment derive from Cotabby's synthetic v2 corpus, authored by the Cotabby project in September 2026.

- Repository: https://github.com/FuJacob/cotabby
- Revision: `8cdbea2d2619b0f89a73d46eb0bb856504d07343`
- File: `CotabbyTests/Fixtures/phrase-prediction-1337.json`
- SHA-256: `b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`
- License: GNU AGPL version 3; see [COTABBY-LICENSE.txt (archive)](../2026-10-10-experiments.tar.gz).

The benchmark selects eight phrases per category from the existing held-out partition. It extracts already-typed word and midword prefixes plus surface metadata. Screen-context cues are not passed to inference. References remain outside inference. The raw archive retains derived inputs, references and model observations with this attribution and license.

The 32 independent challenge phrases come from LokalBot's `Benchmarks/Cotyping/quality-cases.json`. All inputs are synthetic; no personal writing or screen contents were used. The decoder implementation is an original experiment in LokalBot, not copied Cotabby or Cotypist code.

The cache experiment adds 16 original synthetic typing traces from `Benchmarks/Cotyping/cache-typing-cases.json`, split into four development and twelve held-out traces before the first run. They contain no personal text.
