# Reddit draft — not posted

**Proposed title:** I tested four local memory writers on 120 synthetic cases. Can they tell when to remember nothing?

**Author note:** Review and rewrite this AI-assisted draft in your own voice before posting. Add a public link to the evidence bundle only after separately deciding to publish it. No public artifact URL exists yet.

---

I work on LokalBot, a local work-memory app. I wanted to test a specific part of memory writing: can a model keep useful facts while obeying explicit rules about what it should skip?

For example, “I live in Valencia” should produce a memory. “My colleague said, ‘I live in Valencia’” should not. A new preference should be remembered; the same preference already in the known list should not be repeated. A job title in a sentence containing a salary should be kept without the salary.

I expanded our earlier pilot into **120 new synthetic cases / 60 contrast pairs**. The main comparison below is the **96 English cases**: 52 useful memories and 44 cases where the correct output is empty. There is a separate 24-case Serbian slice.

| Model | Useful memories recalled | Unwanted proposals | Empty cases correct |
|---|---|---|---|
| Qwen3.5 4B (Q4_K_M) | 30/52 (57.7%) | 3 | 42/44 (95.5%) |
| Qwen3.5 9B (Q4_K_M) | 37/52 (71.2%) | 5 | 40/44 (90.9%) |
| Hy-Memory 30B-A3B (Official Q4_K_M) | 52/52 (100.0%) | 76 | 0/44 (0.0%) |
| LFM2.5 24B-A2B (QAD Q4_0) | 40/52 (76.9%) | 53 | 10/44 (22.7%) |

Attach `memory-retention.png` here.

The clearest contrast: Hy-Memory found every eligible English fact, but also retained 76 unwanted items and never returned the required empty answer. The Qwen models missed more useful facts and were much more selective. LFM recalled 40/52 but emitted 53 unwanted proposals. In some cases it copied "I live in Belgrade" from the prompt examples even though no evidence line said that. This is why I would want both recall and a retention-policy test when choosing a memory writer.

**Setup:** Qwen3.5 4B and 9B Q4_K_M, Tencent's official Hy-Memory 30B-A3B Q4_K_M imatrix, and LFM2.5 24B-A2B QAD Q4_0. Same application prompt, native chat templates, JSON schema, temperature 0, seed 0, thinking off, one pass. All inference ran sequentially on the same Ryzen 7 9700X Ubuntu machine with llama.cpp. This is not a speed comparison.

Recall requires correct content **and a correct source-line citation**. Correct text with an invalid citation fails this application contract. “Unwanted” does **not** mean every item was fabricated. Some outputs are true things the prompt explicitly says not to retain. Others get ownership wrong, repeat known information, or add unsupported details. Recall and restraint both matter: a model that always returns an empty list gets 44/44 on the empty cases but 0/52 recall.

LFM sometimes returned the source sentence instead of its ID. In a separate post hoc diagnostic, 9 of 18 invalid English citations could be mapped by exact text match. That changes correct source selection from 51/96 to 56/96; it does not certify the memory content. The table retains the original contract scores.

**Limitations:** The cases were assistant-authored and the semantic review was assistant-assisted, with model names visible. There is no independent human validation. I kept the frozen automatic scores, raw outputs and every semantic-review decision so the judgments can be checked. These are deliberately difficult paired examples, not a random sample of real users. No statistical-significance claim.

This tests one personal-memory writing policy, not Mem0, long-term retrieval, or the models' overall capability. Each case has at most one useful memory. The separate Serbian results should not be used to generalize about Hy-Memory's advertised English/Chinese coverage.

Evidence to attach/link before posting: frozen cases and prompts, exact model revisions and hashes, raw completions, scorer, review decisions and chart data. The local `share-bundle.zip` contains those artifacts; it has not been published.

What retention rule would you add as a paired test? I would especially like independent review of the gold labels and disputed outputs.
