# EmbeddingGemma 2 vs Harrier on the real library — 7 October 2026

This test used a read-only snapshot of the user's own `lokalbotv3.sqlite`: 4,302 meeting chunks from 104 meetings and 2,785 screen-OCR documents. Everything ran locally. Passages, generated queries and per-query rows stay in a private folder (`/private/tmp/lokalbot-embeddinggemma2-reallib`, mode 700). This folder holds scripts and aggregate numbers only. Text was not inspected; quality checks were aggregate only.

**Result: on this library, EmbeddingGemma 2 is better when you search in Serbian and about the same when you search in English. For meetings, its top result answers the query more often: 242 vs 220 of 312, +7.1 points, 95% interval +2.5 to +11.6. All of the gain comes from Serbian queries, most of which search English meetings. For English queries it ties on meetings and is somewhat weaker on screens.**

## Method

- **Queries.** The installed Qwen3.5-4B, running locally, read 277 sampled passages and wrote one English and one Serbian/Montenegrin (Latin) query for each. It skipped 21 passages as small talk, which leaves 256 targets and 512 queries.
  - The 156 meeting targets allow at most 2 per meeting, plus extra BCS chunks: the library is 95% English, with BCS in 17 meetings.
  - The 100 screen targets come from different similarity groups, at most 12 per app.
  - Qwen is a different model family from Gemma. Harrier is Qwen-derived, so any bias from the query writer favours the incumbent.
- **Query quality, aggregate only.** No query copies its passage: only 9% of English 4-grams appear in it. English queries share 82% of their content words with their passage, which makes them easy, as real searches often are. BCS queries share 25%, because most are cross-language.
- **Models.** Both run on llama.cpp b11469 with Q8 GGUFs. Harrier uses production prompts and last-token pooling. Gemma uses the checkpoint's `task: search result | query: ` and `title: none | text: ` prompts. Both embed exactly the same stored chunk text.
- **Scoring.** Two independent measures:
  1. *Known item.* Where does the passage the query was written from rank? Neighbours within 60 s in the same meeting also count.
  2. *Judged top-1.* Does the top result answer the query? The local Qwen judges each unique (query, top result) pair blind to which model retrieved it. Calibration: the judge accepts 34/40 source meeting passages and 36/40 source screens, against 1/40 random passages in each corpus. A first, stricter judge prompt rejected 143 of 181 source passages and was discarded.
- **Intervals.** Paired cluster bootstrap: queries are clustered by meeting for meetings and by target for screens. 10,000 draws.

## Meetings — 312 queries

| Top result relevant (judged) | Harrier | Gemma 768d | Gemma 512d |
|---|---:|---:|---:|
| All | 220 | **242** | 239 |
| English queries (156) | **141** | 138 | 136 |
| BCS queries (156) | 79 | **104** | 103 |

Gemma 768d vs Harrier, judged top-1:

| Queries | Difference | 95% interval |
|---|---:|---|
| All | +7.1 points | +2.5 to +11.6 |
| English | −1.9 points | −5.9 to +1.8 |
| BCS | +16.0 points | +8.2 to +23.9 |

Known-item scoring agrees. Gemma ranks the source passage first for 202 queries against Harrier's 185, and in the top five for 278 against 249, with mean reciprocal rank 0.751 vs 0.679. The breakdown by language:

| Query → passage | Harrier source first | Gemma source first |
|---|---:|---:|
| English → English | **106/133** | 100/133 |
| BCS → English | 46/133 | **69/133** |
| BCS → BCS | 18/23 | 18/23 |

## Screens — 200 queries

| Top result relevant (judged) | Harrier | Gemma 768d | Gemma 512d |
|---|---:|---:|---:|
| All | 115 | **116** | 114 |
| English queries (100) | **75** | 67 | 67 |
| BCS queries (100) | 40 | **49** | 47 |

Gemma 768d vs Harrier, judged top-1:

| Queries | Difference | 95% interval |
|---|---:|---|
| All | +0.5 points | −7 to +8 |
| English | −8 points | −17 to +1 |
| BCS | +9 points | −2 to +20 |

Known-item scoring shows the same pattern. Gemma ranks the exact capture first more often, 41 vs 29, but finds fewer near-duplicate captures in the top five.

## Similarity floor

Harrier's `screenSimilarityFloor` of 0.45 lets **76%** of unrelated query-screen pairs through on real OCR. Unrelated pairs score a median of 0.49, so the floor filters little in practice. Gemma scores everything higher: unrelated pairs have a median of 0.61 and a 99th percentile of 0.74. Admitting the same unrelated share as Harrier's floor needs a Gemma floor of **0.58**, which keeps every relevant result. A real migration should set the floor deliberately rather than copying either number.

## Side finding: 300-character previews in older meetings

For 64 of 104 meetings, 2,835 chunks, the stored `embeddings.text` is the first 300 characters while the vector covers the whole chunk. The code at `0a0265a` (2026-09-08) stored `chunk.text.prefix(300)`; current code stores the full text. Re-embedding the stored text reproduced every other vector exactly. Several other explanations were tested and ruled out:
- the llama.cpp version: b10173, v0.4.1, v0.6.0 and b11469 all give identical vectors;
- request batching and prompt-cache reuse;
- mean pooling;
- the earlier Qwen3-Embedding model.

Search uses the correct vectors, so only snippets and evidence text for those meetings are short. Any `indexVersion` bump, such as a model switch, rebuilds them.

This test embedded the stored text, previews included, for both models, so the comparison is fair. The production Harrier vectors cover full chunks while the queries came from the first 300 characters, so they are not comparable here and are excluded from the headline.

## Limits

- These are component scores. The app fuses semantic ranks with FTS through reciprocal-rank fusion, which this test did not simulate. English queries share most of their words with their target, so FTS likely recovers much of Gemma's English shortfall. Cross-language queries share almost no words with their target, so FTS cannot help them and the semantic gain should carry through. This is reasoning, not a measurement.
- The queries are model-written known-item queries. Which language the user actually searches in decides the net effect. Chat history is encrypted and was not read.
- One library, mostly English, with BCS in 17 meetings. The judge is a 4B local model with roughly 10–15% noise on source passages; the noise applies equally to both models.

## Reproduce

```sh
P=/private/tmp/lokalbot-embeddinggemma2-20261006/.venv/bin/python   # 6 October environment
sqlite3 "file:$HOME/Library/Application Support/me.dotenv.LokalBot/lokalbotv3.sqlite?mode=ro" \
  ".backup /private/tmp/lokalbot-embeddinggemma2-reallib/library.sqlite"
$P prepare.py && $P queries.py --limit 140 && $P queries.py --limit 140
$P embed.py harrier && $P embed.py gemma
$P score.py --publish results/scores.json
$P judge.py --calibrate && $P judge.py --limit 450 && $P judge.py --limit 450
$P judge_score.py --publish results/judged.json
```

The run took about 15 minutes of local compute on the M4 Max, in batches of 3 minutes or less.
