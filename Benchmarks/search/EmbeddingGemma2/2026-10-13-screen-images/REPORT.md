# Screenshot image vectors on the real library — 13 October 2026

This test checked whether EmbeddingGemma 2's image encoder finds real captured screens better than the screen-text vectors LokalBot uses today. It follows the [7 October synthetic run](../2026-10-07/REPORT.md), which found +20 points on constructed fixtures.

Everything ran locally on the user's Mac, under a 5-minute GPU budget, at 01:03. Decrypted screenshots, the library snapshot, queries and per-query rows lived in a private folder (mode 700). That folder was deleted after scoring. This folder holds scripts and aggregate numbers only. Screens, screen text and queries were not inspected.

**Result: on this sample, image vectors find the right screen more often than text vectors, for every kind of query. Adding them to today's screen search improves the top result from 44 to 56 of 138 queries: +8.7 points, 95% interval +2.9 to +14.5. Top five improves from 76 to 90: +10.1 points, +5.1 to +15.9. Image vectors on their own did best of all, at 71 of 138. That points to a second issue: as shipped, keyword fusion pulls semantic results down on descriptive queries.**

## Method

- **Corpus.**
  - 720 screens were sampled at random from the 7,291 screenshots that still had encrypted pixels: 28 September to 12 October, 15 days, 57 apps.
  - 48 of them were targets: from different similarity groups, at most 4 per app, each with at least 200 characters of screen text. Targets were embedded first.
  - The budget covered 505 screens (489 similarity groups), and every system searched exactly those 505.
- **Queries.**
  - Qwen3-VL-8B-Instruct (UD-Q4_K_XL, run locally) saw only the screenshot, capped at 768 image tokens. It wrote three queries per target:
    - *content* in English: what the screen was about;
    - *appearance* in English: what it looked like;
    - *content* in Serbian/Montenegrin (Latin).
  - Within its 2-minute cap it covered 46 targets in 117 s, with no skips: 138 queries. Qwen is a different model family from Gemma.
- **Query quality, aggregate only.**

  | | English content | English appearance | Serbian content |
  |---|---:|---:|---:|
  | Mean words | 6.6 | 7.6 | 6.8 |
  | Content words that appear in the screen text | 58% | 27% | 16% |

  The Serbian queries are rewrites, not copies of the English ones:
  - none is identical to its English pair;
  - they share 11% of their words with it;
  - they contain no English stop words.

  A crude detector found Serbian letters or stop words in only 7% of them. That is expected for short queries without diacritics, but it means their language was not verified any further.
- **Representations.**
  - *Text*: the screen text, truncated to 1,500 characters and embedded with `title: none | text: `, exactly as `EmbeddingIndex` does. The text was re-embedded because production vectors have stalled since 8 October (see below). 342 of the 505 screens have a stored production vector, and every one matched: minimum cosine 0.99946, median 1.0.
  - *Image*: the screenshot sent as a bare image input, using llama.cpp's default image token budget.
  - *Queries*: embedded with `task: search result | query: `.
- **Search systems.**
  - *Keyword*: a port of the app's FTS search. It first requires every term (the last as a prefix), then falls back to OR without stop words when nothing matches. It ran against the snapshot's own `ocr_fts`, limited to the corpus.
  - *Text*: top 200 above the 0.58 floor. Dropping the floor changed nothing.
  - *Image*: top 200, no floor.
  - *Fusion*: reciprocal-rank fusion with k=60. Ties go to keyword hits, as in `ScreenSearchRanker.fuse`.
- **Scoring.**
  - *Known item*: a result counts when it is the target or one of its near-duplicates (same similarity group).
  - Paired cluster bootstrap by target, 10,000 draws.
  - There was no relevance judge.
- **Runtime.** Vendored llama.cpp b11474, M4 Max on AC power, 299.4 s in total including model loads.

## Results — 138 queries

| System | Top one | Top five | Found in top 200 | MRR |
|---|---:|---:|---:|---:|
| Keyword | 30 | 55 | 95 | 0.305 |
| Text | 52 | 84 | 122 | 0.477 |
| **Image** | **71** | **107** | **138** | **0.634** |
| Production: keyword + text | 44 | 76 | 129 | 0.423 |
| Text + image | 70 | 92 | 138 | 0.586 |
| Keyword + image | 54 | 87 | 138 | 0.501 |
| Proposed: keyword + text + image | 56 | 90 | 138 | 0.517 |

Top one by query kind, 46 queries each:

| System | English content | English appearance | Serbian content |
|---|---:|---:|---:|
| Text | 27 | 6 | 19 |
| Image | **34** | **11** | **26** |
| Production | 25 | 5 | 14 |
| Proposed | 31 | 7 | 18 |

Paired differences, in points, with 95% intervals:

| Comparison | Top one | Top five |
|---|---|---|
| Image vs text, all | **+13.8** (+3.6 to +24.6) | **+16.7** (+6.5 to +26.8) |
| — English content | +15.2 (0.0 to +30.4) | +15.2 (+2.2 to +28.3) |
| — English appearance | +10.9 (0.0 to +21.7) | +21.7 (+2.2 to +39.1) |
| — Serbian content | +15.2 (−4.3 to +34.8) | +13.0 (−2.2 to +28.3) |
| Text + image vs text | **+13.0** (+5.1 to +21.7) | +5.8 (+1.4 to +10.1) |
| Proposed vs production | **+8.7** (+2.9 to +14.5) | **+10.1** (+5.1 to +15.9) |

Image vectors beat text even on English content queries, which share most of their words with the screen text. They also reach every target within the top 200; text misses 16. Appearance queries are hard for every system, but image vectors put the target in the top five for 25 of 46, against 15 for text.

## Keyword fusion pulls semantic results down on these queries

Keyword + text scores lower than text alone (44 vs 52), and keyword + text + image scores lower than text + image (56 vs 70). The cause is the OR fallback:

| Keyword query form | Queries | Keyword top one | Text top one | Production top one |
|---|---:|---:|---:|---:|
| Every term matched | 15 | 7 | 8 | 7 |
| Fell back to OR | 119 | 23 | **43** | 36 |
| Nothing matched | 4 | 0 | 1 | 1 |

These queries are descriptive sentences, so 123 of 138 found no screen containing every term, and 119 of them fell back to OR. The OR list they fell back to is long and noisy, and reciprocal-rank fusion gives it the same weight as the semantic list. Real searches are often shorter and more literal, and [stevyhacker/LokalBot#149](https://github.com/stevyhacker/LokalBot/pull/149) deliberately keeps exact matches first. Treat this as a signal to measure on real queries, not as a verdict. One option is to fuse only full matches, or to give OR-fallback keyword hits less weight.

## Cost

- **Image tokens.** Real screenshots (up to 1,500 px wide) cost more tokens than the synthetic fixtures (319) and the reference processor's 280.

  | Image tokens | Screens (of 505) |
  |---:|---:|
  | 407 | 273 |
  | 438 | 64 |
  | 624 | 34 |
  | 810 | 51 |
  | Other values, up to 874 | 83 |
- **Latency.** **247 ms p50 and 631 ms p95** per screenshot, one per request.
  - This library captures about 490 screenshots a day (7,291 over 15 days), which is about two minutes of GPU per day.
  - Screen text embeds in batches of 32: 720 screens took 15.5 s.
- **Download and memory.** The projector adds 555 MB to the download. Peak memory was not measured in this run; on 7 October the server peaked at 2.05 GiB with the projector loaded.

## Similarity floors

The query-to-screenshot cosine for targets has a median of 0.715 and a 10th percentile of 0.666. For unrelated screens it has a median of 0.595 and a 99th percentile of 0.704.

| Image floor | Targets kept | Unrelated kept |
|---:|---:|---:|
| 0.60 | 100% | 45% |
| 0.62 | 98% | 29% |
| **0.64** | **97%** | **17%** |
| 0.66 | 94% | 8% |
| 0.68 | 81% | 3% |

An image floor near **0.64** keeps 97% of targets and drops most unrelated screens. For comparison, the shipped 0.58 text floor keeps 98% of targets and 79% of unrelated screens on these queries, so it filters little, as the 7 October run also found.

## Limits

- **The sample is small:** 46 targets and 138 queries. The per-kind intervals are wide, and the Serbian difference is not significant.
- **The queries come from pixels.** The query writer looked at the screenshot, which may favour the image path, since it can describe things screen text misses. English content queries still share 58% of their content words with the screen text, and image vectors win there too.
- **The scoring is known-item only, with no judge.** When a different but relevant screen ranks first, every system is marked wrong.
- **The corpus has 505 screens,** not the full library. Absolute scores will be lower at full scale, and the gap may change.
- **Only the default image token budget was tested** (407–874 tokens). The 280-token budget, which would roughly halve the cost, was not, and on 7 October llama.cpp's token counts reordered some categories of synthetic fixtures.
- **It was one run on one library,** with the machine otherwise idle.

## Side finding: production screen vectors have stalled since 8 October

The live library's newest screen vector is from 2026-10-08 12:09. 2,224 screens captured since then have screen text but no vector, so Quick Recall finds them only by keyword. The snapshot was taken on 12 October. A fix is in progress in a separate session. This benchmark re-embedded screen text itself, so it was not affected.

## Recommendation

**Build the image path, as part of "Text + visual context".**

1. Add image vectors as a third list in `ScreenSearchRanker.fuse`.
2. Download the projector only when the user selects visual context. The default is Activity only.
3. Delete image vectors with the pixels, after 14 days by default, and say so in PRIVACY.md.
4. Start the image floor at 0.64.

Before shipping, run one more pass with the same scripts and a larger budget:
- the 280-token budget against the default, comparing speed and quality;
- short, literal queries alongside these descriptive ones;
- the OR-fallback weighting in keyword fusion. That fix may be worth more than the image path for users who don't capture pixels.

## Reproduce

```sh
R=/private/tmp/lokalbot-screen-images-20261013   # mode 700; delete afterwards
sqlite3 "file:$HOME/Library/Application Support/me.dotenv.LokalBot/lokalbotv3.sqlite?mode=ro" ".backup $R/library.sqlite"
sqlite3 $R/library.sqlite "PRAGMA journal_mode=DELETE;"
# mmproj-embeddinggemma-2-Q8_0.gguf from ggml-org/embeddinggemma-2-GGUF at the revision in
# ../2026-10-07/model-checksums.txt, saved to $R/mmproj/
$R/.venv/bin/python prepare.py          # one Keychain prompt for the screenshot key; CPU only
$R/.venv/bin/python run.py --budget 300 # Qwen3-VL-8B from the Hugging Face cache, vendored llama-server
$R/.venv/bin/python score.py --publish results/scores.json
rm -rf $R
```

The environment needs `numpy`, `cryptography` and `requests`. Aggregates are in [results/scores.json](results/scores.json).
