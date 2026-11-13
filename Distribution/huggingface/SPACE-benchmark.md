# SPACE-benchmark.md — static HF Space for the benchmark summary

## Recommendation: a static Space

The simplest viable hosting for `benchmark-summary.md` is a **static Space**: no Python runtime, no Docker, no build step, free tier, and it renders plain HTML/CSS (with markdown pre-converted). It exists only to present the extracted benchmark numbers publicly with a stable URL that lokalbot.com, the repo README (maintainer follow-up), and the HF Collection can link to.

## Space layout

```
lokalbot-benchmarks/
├── README.template.md # Source template kept in the LokalBot repo
├── README.md          # Generated HF Space card with YAML frontmatter (below)
├── index.html         # rendered version of benchmark-summary.md
└── style.css          # minimal dark/light styling (optional but recommended)
```

`index.html` is generated from `benchmark-summary.md` (tables must render as real `<table>` elements — static Spaces do not render markdown directly):

```sh
uv run --with markdown python Distribution/huggingface/scripts/render_space.py \
  --collection-url "https://huggingface.co/collections/<collection-slug>"
```

Regenerate and push whenever `benchmark-summary.md` changes. Keep the Space content generated from the repo file — never hand-edit the HTML, so the repo stays the single source of truth.

## Space `README.md` (frontmatter)

```markdown
---
title: LokalBot Local-Stack Benchmarks
emoji: 📊
colorFrom: gray
colorTo: green
sdk: static
pinned: false
license: gpl-3.0
short_description: Measured on-device model benchmarks behind LokalBot (macOS, M4 Max)
---

# LokalBot local-stack benchmarks

Extracted, sourced benchmark numbers for the local model stack behind
[LokalBot](https://github.com/stevyhacker/lokalbot): speaker diarization,
summaries, semantic search, speech recognition, autocomplete, and OCR on an
Apple M4 Max. Every figure links back
to its source file in the repository; nothing is estimated.

- Repo: https://github.com/stevyhacker/lokalbot
- Source of truth: `Distribution/huggingface/benchmark-summary.md`
- Recommended models: the HF Collection "LokalBot recommended local stack" (see repo)
```

The `license: gpl-3.0` matches the app; the Space contains only data/documentation derived from the GPL repo, so it inherits the same license.

## Creation steps

1. Create the Space under your account: **New Space** → name `lokalbot-benchmarks` → SDK **Static** → License **gpl-3.0** → Public.
2. `git clone https://huggingface.co/spaces/<username>/lokalbot-benchmarks`, add the three files above, `git push`.
3. Verify the tables render and every **Source** path in the tables is present as text (paths are repo-relative; the page header should link each section's source file to its GitHub URL, e.g. `https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/search/OCR/RESULTS-2026-06-24.md`).
4. Optional: enable the Space's "Link to GitHub" card field pointing at the repo.

## Cross-link plan

| Direction | Action | Owner |
| --- | --- | --- |
| Space → repo | Header + footer link to `https://github.com/stevyhacker/lokalbot` and the `Distribution/huggingface/` source paths | Space publisher (this kit) |
| Collection → Space/Repo | Collection description already links the repo; optionally add a "space" item for the benchmark Space | `COLLECTION.md` steps |
| Repo README → Space | Add one line under the model-stack table: "Interactive benchmark summary: <space URL>". **Not part of this kit — maintainer follow-up.** | Maintainer |
| lokalbot.com → Space | Footer or the "local transcription models compared" blog post links to the Space. **Maintainer follow-up.** | Maintainer |

## Update cadence

Re-publish only when a new dated results file lands in `Benchmarks/` (e.g. a cross-chip M1/M2/M3 run or a WER study closing gaps from `benchmark-summary.md`). Regenerate `index.html` from the updated summary, push, done — no CI required.
