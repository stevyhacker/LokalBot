# GBrain vs LokalBot memory (17 November 2026)

Feeds the same public meetings to LokalBot's Ask retrieval and to GBrain, then
compares retrieval accuracy, latency, resource use and how each handles
corrections. The report is [REPORT.md](REPORT.md) once the runs finish.

- Data: QMSum (Zhong et al., NAACL 2021, MIT): 232 meetings (AMI product
  design, ICSI research, Welsh and Canadian parliamentary committees) and its
  1,576 specific questions with human-marked answer spans. No personal data.
- LokalBot: `lokalbot-harness/` drives `lokalbot-core` and `lokalbot-ai` (the
  Windows and Linux crates, same SQLite FTS5 and EmbeddingGemma schema as the
  Mac) the way `lokalbot-ai/src/ask.rs` `gather` does.
- GBrain: the open-source CLI at commit `c5a80f17f37149ccc1c8a514c9971d38368b4f55`
  (v0.60.734.0), PGLite, driven over its stdio MCP server (`gbrain_run.py`).
- Corrections: `corrections_data.py` (authored, synthetic) for stated facts,
  meeting pairs where a later meeting changes a decision, and deletion.

Reproduce keyword-only (any machine with cargo, bun and python3):

```sh
python3 -I prepare.py --qmsum <QMSum checkout> --out <work>
python3 make_corrections.py <work>/corpus.jsonl <work>/corr
# then the steps in run_mac.sh, without the llama-server parts
```

The full run with EmbeddingGemma 2 shared by both systems is `run_mac.sh`
(headless, on a Mac with LokalBot installed; writes only under `Local/`).
