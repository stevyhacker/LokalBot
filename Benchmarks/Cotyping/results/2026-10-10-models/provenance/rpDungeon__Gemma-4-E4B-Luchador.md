Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

---
license: gemma
base_model: google/gemma-4-E4B-it
language:
- en
pipeline_tag: text-generation
tags:
- gemma
- gemma-4
- e4b
- roleplay
- merge
- fisher-protected
- instruct-subspace-mask
- slerp
---

# Gemma-4-E4B-Luchador

An E4B-scale Gemma 4 merge (~4B effective parameters, ~7.5B total after dropping the multimodal adapters) built for roleplay and creative-writing use, with explicit care taken to preserve the base IT model's instruction-following ability while folding in style and prose-quality signal from several upstream fuel adapters and datasets.

A masked entertainer that punches above its weight.

The recipe is conservative-by-design: every component that touched the weights was gated through either an SVD instruct-subspace mask (training time) or a Fisher-importance + per-layer dampening (post-hoc merge time). The final ship was then "healed" against the masked SFT pass via slerp at α=0.3, biased toward the V3 base.

---

## At a glance

| metric | this model |
|---|---|
| IFEval strict-P (n=541, Q6_K GGUF, thinking-off) | **85.95%** |
| IFEval loose-P (n=541) | **82.81%** |
| h_delta vs IT baseline | **+3.07** |
| slop count | 22.6 |
| rep3g | 5.7 |
| word_count | 832 |

(Higher is better for IFEval and h_delta; lower is better for slop and rep3g.)

Baseline: stock `google/gemma-4-E4B-it` Q6_K — strict-P 84.66%, h_delta 0.

---

## What it is

A two-stage E4B merge:

**Stage 1 — V3 base (post-hoc Fisher+layer merge onto IT).**
Four fuel adapters were averaged in delta-space, then applied to `google/gemma-4-E4B-it` at scale `s = 0.3`, gated per-parameter by a Fisher-derived importance mask and per-layer dampening (i.e. parameters/layers the IT model relies on most for instruction-following received the least delta). This produced an "IT-safe" base with most of the fuel-adapter style signal carried in.

**Stage 2 — Glimmer-conv-itmasked SFT heal.**
A LoRA (r=16, α=32) was trained on a 6-dataset conversational mix on top of the *PT* base with the V3-style instruct-subspace mask active during training (r=256 subspace, Fisher-derived layer scaling, `scale_mask` mode, LR 7e-6, 1 epoch, 6k sequence length). The trained adapter was merged into V3 via **spherical linear interpolation** at α=0.3 (i.e. V3 weighted 0.7, masked-SFT weighted 0.3).

The result keeps V3's instruction-following intact (loose-P actually *up* vs IT) while improving prose-quality scores (h_delta +3.07) and reducing slop / repetition.

---

## How it was made

### Stage 1: V3 fuel-adapter delta-average → Fisher+layer onto IT

Fuel adapters (all rank-mixed, trained against `google/gemma-4-E4B-pt` unless noted):

1. **Marvin CPT-style adapter** (r=64) — continued-pretrain on the *Marvin* bible-style instruct dataset (see credits).
2. **Marvin Instruct-tuned adapter** (r=256) — instruct-formatted fine-tune on the same Marvin source data.
3. **glimmer-b200 7-corpus mix adapter** — the public `rpDungeon/glimmer-b200-final` LoRA, trained on a 7-corpus blend of long-form RP / creative-writing data.
4. **SD CPT adapter** — internal continued-pretrain adapter trained with the SVD+Fisher-layer protection recipe (best-of-class training-time protection in our ablations).

These four deltas were averaged in LoRA-delta space, then applied to the IT model with the Fisher+layer post-hoc merge formula:

```
W_final[p] = W_IT[p] + s * (1 - F_norm_param[p]) * (1 - F_norm_layer[layer(p)]) * Δ_avg[p]
```

with `s = 0.3` and `F_*` being min-max-normalized Fisher importance computed on IFEval prompts (n≈200) against `google/gemma-4-E4B-it`.

### Stage 2: Glimmer-conv-itmasked LoRA + slerp heal

LoRA SFT against `google/gemma-4-E4B-pt` (not IT):

- LoRA: r=16, α=32, applied to standard attention + MLP projections
- Instruct-subspace mask: r=256 (top-256 singular directions of the IT–PT delta, per-layer)
- Layer scaling: Fisher-derived `layer_importance.json`
- Mask mode: `scale_mask` (multiplicative dampening of subspace-aligned gradient components)
- LR: 7e-6
- Epochs: 1
- Sequence length: 6144
- Data: 6-dataset conversational mix (RP-style multi-turn)

Final merge: `slerp(V3, glimmer-conv-itmasked, α=0.3)` — V3 weighted 0.7, masked-SFT weighted 0.3.

---

## Techniques used (and why)

This release uses two pieces of in-house tooling:

### 1. SVD instruct-subspace mask (training time)
The IT model's behavior relative to PT lives, to first order, inside a low-rank subspace of the weight delta `W_IT − W_PT`. By SVD-decomposing this delta per-layer and projecting style-LoRA gradients *out of* its top-r directions during training, we let the LoRA learn style/prose-quality signal without overwriting the instruction-following manifold. This recipe consistently recovers more IFEval than uniform-strength LoRA SFT at the same hyperparameters.

### 2. Fisher importance + per-layer dampening (merge time)
The diagonal Fisher `F_i = E[(∂L/∂θ_i)²]` (computed on IFEval prompts against the IT model) tells us which parameters the IT model actually relies on for instruction-following. We min-max-normalize at both the parameter level and the layer level, then use `(1 − F_norm_param) · (1 − F_norm_layer)` as a multiplicative dampener on incoming deltas. High-Fisher parameters / layers see *less* of the merge delta; low-Fisher parameters see *more*. This was the strongest post-hoc merge recipe in our ablations.

### 3. Slerp heal
Spherical linear interpolation (rather than naive linear) keeps the merged weight vector on the same effective norm shell as its endpoints, which empirically gives smoother loss landscapes for tightly-coupled-weight merges than `α·A + (1−α)·B` at the same α.

---

## Limitations and caveats

- Eval coverage so far is IFEval-only for instruction-following and an internal scoreboard for style. We have *not* run external benchmarks (MMLU, HellaSwag, etc.) and would not expect this recipe to move them — the recipe is style-preserving on the instruct side, not knowledge-augmenting.
- The model was trained / merged with conversational and roleplay data. Use for code, math, or safety-critical generation is not recommended.
- Thinking-on prefill behavior is provided but not externally evaluated for chain-of-thought quality.
- This is a research-quality merge from a small team. Reproducibility of intermediate adapters is contingent on toasty's training run archive.

---

## Credits

- **Base model:** Google — [`google/gemma-4-E4B-it`](https://huggingface.co/google/gemma-4-E4B-it).
- **Marvin instruct dataset:** *(Private) — Instruct-style fine-tune data derived from novel-style prose*, by **ToastyPigeon**.
- **B200 7-corpus glimmer adapter:** [`rpDungeon/glimmer-b200-final`](https://huggingface.co/rpDungeon/glimmer-b200-final).
- **Fisher importance + SVD subspace masks:** [`rpDungeon/gemma-4-masks`](https://huggingface.co/rpDungeon/gemma-4-masks) (this model uses the `g4-e4b-it/` directory).
- **Recipe + tooling:** rpDungeon team — **twistedshadows** and **ToastyPigeon**.
- **Training + merge code reference:** internal `instruct_mask` repo (release pending).

---

## License

This model is released under the [Gemma Terms of Use](https://ai.google.dev/gemma/terms). Use of this model is subject to and constitutes acceptance of those terms. The merge components, fine-tunes, and code on top of the Gemma weights are released under the same Gemma terms for downstream redistribution.
