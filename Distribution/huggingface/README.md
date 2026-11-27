# Hugging Face presence kit: publishing runbook

Everything in this directory ships LokalBot's Hugging Face presence: our curated model Collection (covering the four v0.14.0 Apache-2.0 `stevyhacker/*-LokalBot-GGUF` fine-tunes plus unmodified upstream dependencies), a static benchmark Space, and the synced benchmark data both present. **Unmodified third-party weights are never mirrored**: Nemotron 3 and EmbeddingGemma 2 link straight to their upstream owners' repos.

## Live resources

- [LokalBot recommended local stack](https://huggingface.co/collections/stevyhacker/lokalbot-recommended-local-stack): public Collection of LokalBot's v0.14.0 stack (`COLLECTION.md` holds the updated six-item list including the four Apache-2.0 `stevyhacker/*-LokalBot-GGUF` fine-tunes, ready for the next Collection sync).
- [LokalBot Local-Stack Benchmarks](https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks): public Static Space synced from `Website/public/benchmarks.json`, linking back to the interactive [Local Desktop AI Leaderboard](https://www.lokalbot.com/benchmarks), [benchmarks.json](https://www.lokalbot.com/benchmarks.json), and [Local AI Hardware & RAM Calculator](https://www.lokalbot.com/hardware).
- Apache-2.0 v0.14.0 fine-tuned model repos:
  - [`stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF) (`v3`, 2.52 GB GGUF Q8_0 + mmproj)
  - [`stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF) (`v1`, 1.02 GB GGUF Q8_0 + stock mmproj)
  - [`stevyhacker/Qwen3.5-4B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3.5-4B-LokalBot-GGUF) (`v4`, 2.74 GB GGUF Q4_K_M)
  - [`stevyhacker/Gemma-4-E2B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Gemma-4-E2B-LokalBot-GGUF) (`v4`, 3.02 GB GGUF i1-Q5_K_M + PLE Q4_K)

## Files

| File | Purpose |
| --- | --- |
| `benchmark-summary.md` | Generated from `Website/public/benchmarks.json` with source links and gaps. |
| `COLLECTION.md` | Spec for the "LokalBot recommended local stack" collection: repo ids, curation notes, sync steps. |
| `SPACE-benchmark.md` | Spec for the static Space hosting the benchmark summary, frontmatter, and cross-links. |
| `scripts/sync_from_leaderboard.py` | Regenerates and verifies `benchmark-summary.md` from `Website/public/benchmarks.json`. |
| `scripts/create_collection.py` | Verifies model repos against the HF API, then creates or syncs the public Collection. |
| `scripts/render_space.py` | Renders `benchmark-summary.md` into the static Space HTML (`space/index.html`). |
| `scripts/create_space.py` | Creates or updates the public static Space through `huggingface_hub`. |
| `space/` | Space-card template, generated `README.md`, `index.html`, and `style.css`. |

## Prerequisites

- A Hugging Face account (`stevyhacker`) matching the GitHub namespace.
- For the API path: `uv tool install hf` (or `uvx hf`), then `hf auth login` with a write token.
- No other runtime required; the Space is static HTML/CSS.

## Step 1: Sync the Collection

Verify every referenced repo id and file against the HF API and update the Collection:

```sh
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_collection.py
```

If using a fine-grained token without Collection write scope, follow the web-UI checklist in `COLLECTION.md`.

## Step 2: Sync and render the benchmark Space

First regenerate `benchmark-summary.md` from `Website/public/benchmarks.json`, then render the static Space HTML and publish:

```sh
python3 Distribution/huggingface/scripts/sync_from_leaderboard.py
uv run --with markdown python Distribution/huggingface/scripts/render_space.py \
  --collection-url "https://huggingface.co/collections/stevyhacker/lokalbot-recommended-local-stack"
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_space.py
```

## Step 3: Publish checklist

- [x] Collection lists all four v0.14.0 Apache-2.0 fine-tunes plus Nemotron 3 and EmbeddingGemma 2.
- [x] Space renders the v0.14.0 reference stack, all 20 benchmark suites, and the gaps table.
- [x] Space header and footer link to `lokalbot.com/benchmarks`, `lokalbot.com/hardware`, and GitHub.
- [x] Collection description links `https://github.com/stevyhacker/lokalbot` and stays under 150 characters.
- [x] Zero unmodified third-party weights are mirrored or reuploaded.

## Maintenance rules

- Update `Website/public/benchmarks.json` first, then run `python3 Distribution/huggingface/scripts/sync_from_leaderboard.py` and re-render the Space HTML. Never hand-edit `space/index.html`.
- Every quoted number must point to a checked-in `Benchmarks/` report or a published Apache-2.0 model card.
- Verify repo ids and filenames via `https://huggingface.co/api/models/<id>` before publishing Collection updates.
