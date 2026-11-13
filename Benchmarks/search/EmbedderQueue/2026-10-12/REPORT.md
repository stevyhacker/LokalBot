# Embedder queue — 12 October 2026

Ask and Quick Recall embed the typed query after a typing pause of 160 ms (Ask) or 120 ms (Quick Recall). The embedder llama-server runs `--parallel 1` and encodes inputs first in, first out, so a query waited behind every input that background indexing had already posted. This run measures that wait before and after [stevyhacker/LokalBot#240](https://github.com/stevyhacker/LokalBot/pull/240). In that change, indexing sends at most 8 inputs and 2,000 characters per request, one request at a time, and `EmbeddingRequestGate` holds the next background request while a query is in flight.

**Result: a query sent during indexing waited 1.1–2.5 s before the change and 39–46 ms after, and at most 51 ms at 8 random arrival times. Vectors are unchanged, and background indexing took 1–5% longer.**

Hardware: Apple M4 Max / 48 GiB. Runtime: llama.cpp `b11474` from `Vendor/llama-cpp`, the app's pin. Model: `embeddinggemma-2-Q8_0.gguf`, whose SHA-256 matches the app's pin. The server ran on private port 18873 with the app's exact embedder arguments (`-c 2048 -ngl 99 --embeddings -b 2048 -ub 2048 --parallel 1`). Every request was preceded by the `/health` and `/v1/models` probes that an inference lease runs, and each caller kept one connection open, as URLSession does. All inputs were synthetic. Raw output: [`results/output.txt`](results/output.txt).

Inputs:

- **Screen backfill:** 32 OCR-like rows of 1,500 characters, about 884 tokens each. `performScreenTextReindex` embeds 32 rows of at most 1,500 characters at a time, and `LlamaServer` notes that real OCR reaches about 950 tokens.
- **Meeting:** 100 transcript-like chunks of 500 characters, about 93 tokens each. `EmbeddingIndex.index(_:)` used to send all of a meeting's chunks in one request.

## Before and after

Query sent 50 ms after background work started, 3 trials each:

| Background work | Query wait before (median / max) | Query wait after (median / max) | Background time before → after |
|---|---:|---:|---:|
| Screen backfill, 32 rows | 1,421 / 1,442 ms | 39 / 47 ms | 1,475 → 1,501 ms |
| Meeting, 100 chunks | 1,073 / 1,088 ms | 40 / 43 ms | 1,147 → 1,201 ms |
| Both at once | 2,547 / 2,599 ms | 46 / 50 ms | 2,622 → 2,685 ms |
| Both at once, query at random 20–600 ms offsets (8 trials) | 2,350 / 2,534 ms | 34 / 51 ms | — |

A query alone took 5 ms, including the lease probes.

## Why the limits are characters as well as inputs

Cost follows tokens. An OCR row took 46–65 ms and a transcript chunk 11–12 ms, depending on the laptop's thermal state. Query wait 50 ms after background work started, 3 trials, from the `strategies` mode:

| Requests | Screen backfill, 32 rows | Meeting, 100 chunks | Both at once |
|---|---:|---:|---:|
| One request (before) | 2,015 ms | 1,119 ms | 2,981 ms |
| 16 inputs | 884 ms | 138 ms | — |
| 8 inputs | 414 ms | 43 ms | 443 ms |
| 4 inputs | 177 ms | 46 ms | — |
| 8 inputs, gated | — | — | 58 ms |
| 8 inputs and 2,000 characters | — | — | 57 ms |
| 8 inputs and 2,000 characters, gated (after) | 13 ms | 45 ms | 56 ms |

A fixed 8 inputs per request still left 414 ms behind OCR rows. The 2,000-character cap sends one OCR row per request, or about four transcript chunks.

When meeting indexing and screen backfill run together, each has a request on the server. At 8 inputs per request, that left 443 ms, and the gate brought it to 58 ms. At the shipped limits, both in-flight requests are small, and the gate made no measurable difference with two callers (57 vs 56 ms). It keeps the bound at one request however many background callers run.

## Cost of splitting

Total time for the same inputs with no queries, 3 runs (median):

| Requests | Meeting, 100 chunks | Screen backfill, 32 rows |
|---|---:|---:|
| One request | 1,161 ms (1 request) | 1,532 ms (1 request) |
| 8 inputs | 1,183 ms (13) | 1,539 ms (4) |
| 8 inputs and 2,000 characters (app) | 1,215 ms (25) | 1,548 ms (32) |
| 1 input | 1,241 ms (100) | 1,558 ms (32) |

Each extra request cost 0.5–2.3 ms. A request with one tiny input took 6.7 ms including the probes, and the probes alone took 0.2 ms.

## Other findings

- `/health` and `/v1/models` answered in 0.2–0.3 ms while the server was encoding a meeting. The lease probes do not queue behind embeddings.
- Grouping never changed a vector. The largest absolute difference was 0.0 for one request against 4 × 8 inputs, one input per request, and the app's rule, and for a query embedded alone against one embedded behind a meeting. Each input is encoded on its own, and requests set `cache_prompt: false`.
- An earlier quick measurement put the wait behind a 32-row backfill at about 435 ms. That run used text with fewer tokens per character. At about 884 tokens per row, the wait was 1.4–2.0 s.

## Limits

- The request rule and the gate are modelled in Python. `app_rule` and `Gate` in [`embedder_queue.py`](embedder_queue.py) mirror `EmbeddingIndex.backgroundRequestRanges` and `EmbeddingRequestGate`. The app's own requests were not timed; it adds main-actor hops and lease bookkeeping per request. `EmbeddingIndexQueryTests` checks the app's ordering with held requests.
- The run used synthetic text, 3 trials per cell (8 for random offsets), and one machine. The laptop's thermal state changed during the run: the same one-request screen backfill took 2,015 ms in the first mode and 1,421 ms in the last. Compare rows within a table.
- After the change, a query waits for at most one background request: one OCR row, or up to 2,000 characters of other text, plus its own encoding. A query sent while the server starts or the model downloads waits for that too.
- The installed app was running with its own embedder server on port 17873. The run did not use it, but both servers shared the GPU.

## Reproduce

Needs `Vendor/llama-cpp` (`Scripts/build/fetch-llama.sh`) and the app's downloaded model, or `--model` with another copy. The script refuses the app's port 17873 and any port already in use, and stops its server when it finishes.

```sh
python3 -I Benchmarks/search/EmbedderQueue/2026-10-12/embedder_queue.py strategies overhead before-after
```

The three modes take about 5 minutes of GPU time on an M4 Max, with a 1-minute cool-down between modes.
