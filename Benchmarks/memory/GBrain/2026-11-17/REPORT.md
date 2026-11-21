# GBrain vs LokalBot memory: retrieval, cost and corrections

Date: 17 November 2026. GBrain v0.60.734.0 (commit `c5a80f17`), LokalBot
`LinuxWindows` crates at `67496510`. Main run: Apple M4 Max (Mac16,5), 48 GB,
headless. A keyword-only repeat ran on a 4-core Intel Xeon cloud host
([results-cloud](results-cloud/summary.md)). Its accuracy numbers match the
Mac's exactly. Only its times differ.

## Short answer

- **Finding the right meeting:** LokalBot's Ask retrieval, as shipped with
  EmbeddingGemma 2, beats GBrain with the same embedder.
  - R@1: 0.280 vs 0.239 (paired 95% CI of the difference +0.019 to +0.062).
  - R@4 (the four meetings Ask reads): 0.475 vs 0.367 (CI +0.082 to +0.133).
- **Keyword-only:** GBrain is better. R@1 0.253 vs 0.193, and the answer turn
  reaches the reader in 40% vs 26% of questions. GBrain's best mode on this
  data is its keyword-only search.
- **Cost:**
  - Context: GBrain hands the reader a median of about 97,000 characters per
    question (whole transcripts). LokalBot hands over 1,248 characters.
  - Speed: GBrain answers 6.5 times slower (p50 255 vs 39 ms).
  - Memory: GBrain's server holds about 1 GB resident, against about 50 MB
    for LokalBot's retrieval process. Both also use the same 0.5 GB embedding
    server.
  - Disk: about equal (247 vs 167 MB).
- **Corrections:**
  - Explicit edits, replacements and deletions work in both. GBrain's
    `remember --replaces` showed the current fact 40/40; LokalBot's claim edit
    showed it 39/40. Neither showed any stale value.
  - Neither notices a contradiction when a fact is restated rather than edited.
    Both keep and show the old and the new versions (40/40 stale).
    - LokalBot lists the newer one first in 28/39 cases, dates every line, and
      tells the model to prefer the newer.
    - GBrain with embeddings lists the stale one first in 38/40 cases.
  - When a later meeting changes a decision, neither prefers the later meeting:
    it ranks above the older one in 7/20 (LokalBot) and 8/20 (GBrain) cases.
    Deleting the older meeting removes the stale evidence completely in both.

Nothing here argues for replacing LokalBot's pipeline with GBrain. Three
things GBrain does better are worth taking (see *What to take from this*).

## Setup

**Data.** [QMSum](https://github.com/Yale-LILY/QMSum) (Zhong et al., NAACL
2021, MIT), a public stand-in for real meetings. It has 232 meetings
(129,177 turns, 2.1M words): AMI product design, ICSI research, and Welsh and
Canadian parliamentary committees. Its 1,576 "specific" questions each carry
human-marked answer spans. No personal data was used.
- QMSum has no timestamps, so turn *i* becomes a LokalBot segment at 10·*i*
  seconds.
- Each meeting gets its own synthetic date, and a title naming only its
  QMSum id, so neither system can use dates or titles.
- `prepare.py` writes one corpus that both systems ingest. GBrain gets one
  Markdown page per meeting, with "Speaker: text" paragraphs.

**LokalBot.** `lokalbot-harness` calls the `lokalbot-core` and `lokalbot-ai`
crates the way `lokalbot-ai/src/ask.rs` `gather()` does for an unscoped
question. These are the Windows and Linux crates, with the same FTS5 and
EmbeddingGemma schema as the Mac app.
- Keyword: FTS5 BM25, every word first, then any word, 30 rows.
- Meaning: EmbeddingGemma over transcript chunks, 15 hits, floor 0.61.
- Fusion: title match first, then reciprocal rank fusion (k = 60).
- Evidence: the top 4 meetings, each with up to 6 moments of at most 400
  characters.
- The Swift app's Ask agent picks its own search words with a model. This
  benchmark exercises the deterministic retrieval underneath it, with the raw
  question.

**GBrain.** The open-source CLI on PGLite, called over its stdio MCP server
the way an agent would (`gbrain_run.py`). Each question goes to the `query`
tool, the one GBrain documents for natural-language questions.
- Calls use `snippet_chars: 0` and the default `return_unit` ("auto"). A
  second call with `return_unit: chunk` gives ranked passages.
- Hybrid runs use `llama-server:embeddinggemma-2` (768 dimensions), the same
  GGUF and llama-server binary as LokalBot. One server instance on port 18473
  serves both systems.
- `init` picked the **conservative** search mode, because the brain had no
  chat key and no reranker. Voyage reranking is hosted, and the local Qwen3
  reranker wasn't downloadable here. Query expansion stayed off.
- Conversation archiving and automatic maintenance were turned off after
  `init`.

**Metrics** (`score.py`):
- *Meeting R@k / MRR*: the rank of the question's meeting among retrieved
  meetings.
- *Gold turn in evidence*: whether the text handed to the answering model
  contains a turn from the answer span.
- *Passage hit@k*: whether one of the top k passage pointers, each widened to
  about 2,000 characters, overlaps the answer span.
  - GBrain's pointers are its own chunks of about 2,000 characters.
  - LokalBot's are single rows, widened to the same size.
- *Latency*: one round trip per question, measured as follows:
  - LokalBot: in process, including the embedding call.
  - GBrain: an MCP round trip, with the result's JSON.
- Paired bootstrap 95% CIs over questions (2,000 resamples).

## Retrieval (M4 Max)

| | LokalBot keyword | GBrain keyword | LokalBot hybrid | GBrain hybrid |
|---|---:|---:|---:|---:|
| Meeting R@1 | 0.193 | **0.253** | **0.280** | 0.239 |
| Meeting R@4 | 0.335 | 0.412 | **0.475** | 0.367 |
| Meeting R@10 | 0.456 | 0.468 | **0.595** | 0.370 |
| MRR | 0.274 | 0.325 | **0.379** | 0.295 |
| Gold turn in evidence | 0.260 | **0.402** | 0.367 | 0.340 |
| Median evidence characters | 718 | 97,444 | 1,248 | 96,761 |
| Passage hit@1 / hit@5 | 0.145 / 0.265 | **0.190 / 0.314** | 0.145 / 0.265 | 0.149 / 0.268 |
| Query p50 / p95 ms | 3 / 8 | 159 / 212 | 39 / 52 | 255 / 342 |

Paired differences (95% CI):
- LokalBot hybrid − GBrain hybrid:
  - R@1: +0.041 (+0.019, +0.062)
  - R@4: +0.109 (+0.082, +0.133)
  - Gold in evidence: +0.027 (+0.001, +0.051)
- LokalBot keyword − GBrain keyword:
  - R@1: −0.060 (−0.084, −0.037)
  - Gold in evidence: −0.142 (−0.167, −0.119)
- GBrain keyword − GBrain hybrid:
  - R@1: +0.015 (−0.008, +0.036)
  - R@4: +0.046 (+0.023, +0.069)

How to read it:
- **Embeddings help LokalBot and not GBrain here.** LokalBot gains 8.7 points
  of R@1 from meaning search. GBrain loses ground at R@4 and R@10. Its hybrid
  R@10 (0.370) is barely above its R@4, so conservative mode returns only a
  few distinct meetings. Three things are likely to hold GBrain's hybrid back,
  but none was isolated:
  - It sends EmbeddingGemma raw text, without the `task: search result |
    query:` and `title: none | text:` prompts that LokalBot uses.
  - Its reranker was off.
  - `embed --stale` covered only 5,519 of 5,689 chunks (221 of 232 pages).
- **GBrain's keyword ranking picks meetings better than LokalBot's.** It ranks
  2,000-character chunks with Postgres full-text search plus a title arm.
  LokalBot ranks single transcript rows with BM25. A natural-language question
  rarely matches one short row on every word, so it falls back to "any word",
  and one chatty row can win. Counting rows per meeting instead of taking the
  best row did not help: R@1 0.171, recomputed from the same hits.
- **GBrain's "gold in evidence" edge costs a lot of context.** Its `auto`
  return unit delivers whole conversations. The median is 97k characters, far
  past the 4K-token budget its conservative mode describes. LokalBot hands over about
  1.2k characters. In a local model's context window, GBrain's payload would
  be cut off long before its first transcript ends.
- The scorer could not map some of GBrain's returned rows to transcript turns:
  133 keyword and 333 hybrid rows. That doesn't change meeting ranks, which
  come from page slugs. In the cloud keyword run, only 2 of 1,576 questions had
  an unmapped row from the right meeting that might have held the answer.

## Cost (M4 Max)

| | LokalBot | GBrain |
|---|---:|---:|
| Ingest 232 meetings, keyword index | 8.7 s | 7.7 s |
| Embed | 176 s (EmbeddingGemma, own prompts) | not timed (`embed --stale` after import) |
| Peak resident memory while querying | 50 MB (harness process) | 0.97–1.06 GB (`gbrain serve`) |
| Shared llama-server (EmbeddingGemma Q8_0) | 496 MB peak | same server |
| Disk, keyword-only / with vectors | 80 MB (cloud) / 167 MB | 185 MB / 247 MB |
| Mean query time, keyword / hybrid | 3.5 / 40.7 ms | 158 / 261 ms |

On the cloud Xeon, the keyword p50 was 6 ms for LokalBot and 388 ms for
GBrain, and GBrain's server peaked at 664 MB.

## Corrections

All cases are authored and synthetic (`corrections_data.py`), with markers
checked so each identifies only its own statement.

**Stated facts.** 40 facts plus 40 unrelated ones are stated, then corrected
a day later in one of three ways:
- **edit:** LokalBot `PersonalModel::update`; GBrain `remember --replaces`.
- **restate:** a new statement with no link to the old one.
- **forget:** LokalBot `remove`; GBrain `forget`.

Then each question goes through:
- LokalBot: `select_context`, Ask's Personal Context block of 2,000
  characters.
- GBrain: `recall --question`.

| | mode | current shown | stale shown | both shown, current first | items returned | characters |
|---|---|---:|---:|---:|---:|---:|
| LokalBot | edit | 39/40 | 0/40 | – | 23 | 1,989 |
| LokalBot | restate | 39/40 | 40/40 | 28/39 | 23 | 1,983 |
| LokalBot | forget | – | 0/40 | – | 30 | 2,001 |
| GBrain, EmbeddingGemma | edit | 40/40 | 0/40 | – | 50 | 6,430 |
| GBrain, EmbeddingGemma | restate | 40/40 | 40/40 | 2/40 | 50 | 6,347 |
| GBrain, EmbeddingGemma | forget | – | 0/40 | – | 40 | 4,758 |
| GBrain, keyword-only (cloud) | edit / restate | 38/40 / 38/40 | 0/40 / 40/40 | 23/38 | 1–3 | 168–330 |

- LokalBot's miss: "What do we run CI on?" `content_words` drops words under
  three letters, so "CI" matched nothing. The corrected fact then lost to newer
  items in the 2,000-character budget.
- GBrain records `superseded` on `--replaces` and hides the old fact. It did
  not supersede on its own when the same entity got a conflicting fact, even
  with embeddings on.
- With embeddings, GBrain's `recall` returned every fact (50 items, about
  6.4k characters) and put the older of two conflicting facts first in 38/40
  cases. Keyword-only recall returned 1 to 3 items.
- A write takes under 0.1 ms in memory in LokalBot (before its encrypted save)
  and 40 to 50 ms per MCP call in GBrain.

**Changed decisions across meetings.** There are 20 pairs of short meetings
a week apart, where the later one reverses the earlier one ("Snowflake" then
"ClickHouse"). They sit among 60 QMSum meetings, with one question per pair.
Afterwards, the 20 older meetings are deleted:
- LokalBot: `Library::delete_meeting`, which tombstones and reindexes.
- GBrain: `delete --force`, a soft delete hidden from search.

| | newer ranked above older | stale text in evidence | current before stale | after deleting the older meeting: stale in evidence |
|---|---:|---:|---:|---:|
| LokalBot hybrid | 7/20 | 19/20 | 7/20 | 0/20 |
| GBrain hybrid | 8/20 | 14/20 | 8/20 | 0/20 |
| LokalBot keyword (cloud) | 3/20 | 19/20 | 3/20 | 0/20 |
| GBrain keyword (cloud) | 6/20 | 19/20 | 6/20 | 0/20 |

Neither system uses recency by default. GBrain has a `recency` boost that
was left off, and LokalBot has none for meetings. In practice the answering
model gets both versions and must notice the dates.

## What to take from this

1. **Rank meetings over passages, not single rows.** A chunk-level FTS table
   (about 2,000-character windows), used for meeting ranking in `gather`,
   targets the 6-point keyword gap directly. It wouldn't change what Ask shows.
   Re-run this benchmark to check it.
2. **Prefer the later meeting when two say different things.** A small recency
   term in the fusion, or a date-aware tie-break among the top meetings, would
   fix the 7/20. GBrain doesn't solve this either.
3. **Offer replacement when a restated fact clashes.** `is_near_duplicate`
   already exists. On `add`, a claim sharing most content words with an older
   claim could be offered as "replace?". That covers the restate case that
   neither system handles, at no model cost.
4. **Keep short tokens in claim matching.** Allow two-letter all-caps tokens
   (CI, QA, HR) in `content_words`.

## Limits

- QMSum questions name speakers by role ("Grad B", "Professor") and topics,
  not by meeting. Absolute recall is low for both systems. The comparison
  between them is what matters.
- These are public meetings, not Stevan's. No activity or screen data was
  compared: QMSum is meetings only, and GBrain has no screen-memory ingest.
  Running this on the real library would need its own approval, and would
  stay on the Mac.
- GBrain ran without a reranker or query expansion. Both need a hosted key or
  a model this run couldn't download. Its "balanced" mode was not tried.
- GBrain's embedding time wasn't captured. `run_mac.sh` now times
  `embed --stale`.
- The raw per-question files for the Mac run stayed on the Mac
  (`Local/gbrain-bench/` in the run's worktree). The cloud run's raw files are
  in `results-cloud/raw.tar.gz`.
- One run each, one machine. The corrections cases are few (40 facts and 20
  pairs) and authored by the assistant.
