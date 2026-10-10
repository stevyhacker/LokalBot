Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

# LokalBot autocomplete: proposed research queue (2026-10-10)

**Epistemic labels:** **[V]** = I'm confident from memory, but you should still check it. **[U]** = uncertain, must be verified. Nothing here is measured. Every effect described is a hypothesis.

## Do this before downloading anything (zero-cost re-analysis)

Your confirmation result has two possible explanations:

- **Text quality:** Luchador's text is better.
- **Coverage:** Luchador passes the fixed 0.1 / 0.31 gates more often, so it shows more suggestions and earns more rubric credit. Silence scores 0, while any decent suggestion scores above 0.

The tied exact first-word matches (72/160) are consistent with the coverage explanation. Test it with the outputs you already have:

1. Sweep each model's gate over its own confidence scores.
2. Plot utility and exact-match rate against coverage (the fraction of checkpoints that show a suggestion).
3. Compare models at matched coverage.

This also removes the "fixed thresholds across tokenizers" confound for every later trial. Paper 2 below covers the method.

## Model trials, ranked as the next batch

### 1. Control: Luchador's parent checkpoint

- **ID:** [U] Use the parent named on the rpDungeon/Gemma-4-E4B-Luchador model card. Plausibly this is Google's instruction-tuned Gemma 4 E4B (something like `google/gemma-4-E4B-it`), but I don't know which checkpoint it was fine-tuned from. Verify the casing too.
- **Hypothesis:** You already tested E4B base. Adding the parent completes a chain: E4B base → parent → Luchador. That separates three effects:
  - generic post-training sharpening the confidence distribution (more gate passes, different style);
  - Luchador's specific fine-tuning data;
  - scale, which you already isolated via E2B vs E4B base.
- **Why it might help:** If the parent alone reproduces most of the English gain, the production candidate becomes the official checkpoint. That is better documented than a community fine-tune and possibly better on Cyrillic.
- **What invalidates it:**
  - The parent turns out to be E4B base. The chain then collapses, and your existing E4B base result is the control.
  - The instruction-tuned model degrades under raw completion without a chat template. That is a real finding, but it confounds the comparison.
- **Fit:** Drop-in. Same prompt, decoder and Q6_K, same tokenizer family. It is the cheapest comparison to interpret.

### 2. `Qwen/Qwen3-4B-Base`

- **Status:** [V] HF ID, base checkpoint published, Apache-2.0 licence, attention-only (not hybrid). Released around late April 2025.
- **Hypothesis:** It separates architecture/cache cost from quality in the long-context latency gap. Your long-context Qwen3.5-2B number (158 ms) may reflect the recurrent/hybrid prefix reprocessing path [U whether Qwen3.5-2B is hybrid; check its config]. An attention-only ~4B model gets your shared KV prefix reuse.
- **Why it might help:** Qwen3 claims broad multilingual pretraining. It is a non-Gemma, non-Liquid tokenizer at roughly Luchador's size.
- **What invalidates it:**
  - Serbian, especially Cyrillic, may be weak despite the language-count claims.
  - Tokenizer fragmentation could make six tokens produce fewer words (see Paper 1).
- **Fit:** Drop-in.

### 3. `BSC-LT/salamandra-2b`

- **Status:** [V] HF ID and base checkpoint; Apache-2.0 [U]. [U] I believe its training-language list includes Serbian ("sr") and Serbo-Croatian ("sh"). Verify on the model card before trialling, because this is the whole rationale.
- **Hypothesis:** Pretraining weighted toward European languages, at a smaller size than Luchador, closes the Cyrillic gap where Luchador regressed.
- **Why it might help:** Attention-only and small, so it should be cheap on long prefixes.
- **What invalidates it:**
  - English quality, the strength of Luchador and Gemma, may drop.
  - The base model may be weak at conversational register.
- **Alternate in the same slot:** `utter-project/EuroLLM-1.7B` [V ID]. It covers Croatian and Cyrillic-script relatives such as Bulgarian and Russian, but [U] probably not Serbian explicitly. Run one of the two, not both.
- **Fit:** Drop-in.

### 4. `gordicaleksa/YugoGPT`

- **Status:** [U] The ID I recall. I recall a Mistral-7B base with continued pretraining on Bosnian/Croatian/Serbian. Licence and gating need verification.
- **Hypothesis:** Continued pretraining by a language specialist beats general multilingual models on Serbian. It is a justified larger control: its Q6_K file would be roughly Luchador-sized (~6 GB), so file size is comparable.
- **Why it might help:** It is the most direct test of whether a Serbian specialist matters.
- **What invalidates it:**
  - The training mix may be mostly Latin script, giving no Cyrillic gain [U].
  - A 2024-era base may lose clearly on English.
  - 7B dense latency may exceed the speed cliff near 200 ms you previously observed.
- **Fit:** Drop-in.

### 5. Quality ceiling (optional, heavy; time-box it)

- **Preferred:** a Gemma 4 26B MoE (~4B active) *base* checkpoint, if one is published [U whether a base exists and what the exact ID is]. It shares Gemma's tokenizer, so gate comparisons stay closest to your current models.
- **Fallback:** `Qwen/Qwen3-30B-A3B-Base` [V ID; Apache-2.0].
- **Hypothesis:** It tests whether the quality headroom at ~3–4B active compute is large enough to matter under this prompt and decoder. If the ceiling barely beats Luchador at matched coverage, the bottleneck is the prompt, decoder or gating, not the model.
- **What invalidates it:** Memory pressure (a 20+ GB file) and thermal throttling would distort latency.
- **Fit:** Drop-in, but label it a ceiling diagnostic, not a candidate default. Per your notes, large models are upgrade-only.

Ranks 1–4 are the realistic batch. Rank 5 only runs if you have the compute budget. Following your time-box rule, ask before any run longer than about 15–20 minutes and use short batches with cool-downs.

## Papers

### Paper 1: "Language Model Tokenizers Introduce Unfairness Between Languages"

- **Authors:** Aleksandar Petrov, Emanuele La Malfa, Philip H.S. Torr, Adel Bibi (Oxford), NeurIPS 2023.
- **Link:** https://arxiv.org/abs/2305.15425 [V]
- **Experiment it motivates:** Measure each model's tokenizer on the same Serbian Latin, Serbian Cyrillic and English text. Record tokens per character and tokens per word.
- **Why:** A fixed six-token budget plus a four-word cap could truncate Cyrillic suggestions on Cyrillic-unfriendly tokenizers. It also shifts per-token confidence. Either effect could partly explain Luchador's Cyrillic regression.
- **Next step:** If fragmentation differs materially, run a separately labelled trial with a word-based stopping budget instead of a fixed token count.

### Paper 2: "Selective Classification for Deep Neural Networks"

- **Authors:** Yonatan Geifman, Ran El-Yaniv, NeurIPS 2017.
- **Link:** [V title/authors; U arXiv ID] https://arxiv.org/abs/1705.08500
- **Experiment it motivates:** Use the risk–coverage framework to run the re-analysis above. Report the area under the risk–coverage curve per model and language, with wrong-or-harmful suggestions as risk.
- **Next step:** Choose each model's gate to hit a fixed target precision on a held-out split instead of using shared 0.1 / 0.31 values.
- **Companion:** Guo, Pleiss, Sun & Weinberger, "On Calibration of Modern Neural Networks", ICML 2017 (https://arxiv.org/abs/1706.04599 [V]). It supports per-model temperature calibration of the first-word probability.

### Paper 3: "Understanding and Mitigating Tokenization Bias in Language Models"

- **Authors:** [U] Buu Phan, Marton Havasi, Matthew Muckley, Karen Ullrich (Meta), 2024.
- **Link:** [U arXiv ID; I believe 2406.16829, please verify]
- **Relevance:** It analyses how conditioning on a prefix that ends at an arbitrary character boundary biases next-token probabilities. That is the exact case in mid-word autocomplete, and it matters for your gate because the gate reads those probabilities.
- **Experiment it motivates:** Stratify existing results by whether the checkpoint ends mid-word or at whitespace. Then compare your current handling against backing off to the last token boundary and constraining the first generated token to match the remaining characters (token healing). Use each model's own tokenizer.
- **Why:** If mid-word checkpoints account for a disproportionate share of misses or gate rejections, that is a decoder fix that helps every model.

## Caveats

All rationales above are hypotheses. The model IDs, licences, and the language lists for Salamandra and YugoGPT in particular need your independent primary-source check before you add them.
