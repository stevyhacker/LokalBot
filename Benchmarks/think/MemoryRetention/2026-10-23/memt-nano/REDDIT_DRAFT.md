# Reddit draft — not posted

**Title:** Recall vs. Restraint: Testing when local LLMs should save nothing (Qwen3.5, Hy-Memory, LFM2.5, MemT)

I’m building LokalBot, a local work-memory app, and wanted to test a specific failure mode in memory extraction: **can a local model capture useful facts while obeying explicit rules about what to ignore?**

A good memory writer needs both recall and restraint. “I live in Valencia” should save a memory; “My colleague said, ‘I live in Valencia’” should not. A new preference should be saved; the same preference already in the known-memories list should be skipped. A job title mentioned alongside a salary should be kept without the salary, under this particular retention policy.

The test set has **120 synthetic cases / 60 contrast pairs**. The main comparison is the **96 English cases**: 52 containing one useful memory and 44 where the only correct answer is an empty items list. There is a separate 24-case Serbian slice in the bundle.

**Thinking was disabled in every configuration.** These are application-configuration results, not claims about the models at their best settings.

| Model / configuration | Useful memories recalled | Unwanted proposals | Empty cases correct |
|---|---:|---:|---:|
| Qwen3.5 4B (Q4_K_M) | 30/52 (57.7%) | 3 | 42/44 (95.5%) |
| Qwen3.5 9B (Q4_K_M) | 37/52 (71.2%) | 5 | 40/44 (90.9%) |
| Hy-Memory 30B-A3B (Official Q4_K_M) | 52/52 (100.0%) | 76 | 0/44 (0.0%) |
| LFM2.5 24B-A2B (QAD Q4_0) | 40/52 (76.9%) | 53 | 10/44 (22.7%) |
| MemT-1.0-Nano (Experimental NF4 experts / BF16 dense) | 51/52 (98.1%) | 6 | 39/44 (88.6%) |

*Attach `memory-retention-with-memt.png` here.*

Hy-Memory captured all 52 eligible English facts, but emitted 76 unwanted items and failed all 44 empty-output cases. The Qwen models were more selective under this prompt and configuration, while missing more useful memories. LFM recalled 40/52 and emitted 53 unwanted proposals; some outputs copied “I live in Belgrade” from a prompt example without supporting evidence.

**MemT’s added configuration recalled 51/52, emitted 6 unwanted proposals and passed 39/44 empty cases.** There is an important qualification: I ran it with experimental NF4 expert offload on my Windows RX 6600 XT, using Transformers. The original four used GGUFs and llama.cpp on an Ubuntu Ryzen 7 9700X. The prompt, cases and scoring contract are identical, but runtime, hardware, quantization and schema enforcement differ. This is not a speed comparison or a controlled quantization comparison.

Two English failure examples: it returned an empty answer when the user explicitly changed a known preference from prose to bullet points, and it saved a political affiliation and campaign donation despite the exclusion rule. Both outputs are in the bundle.

**This also does not evaluate MemT’s native persistent-memory feature.** Every case starts fresh with the evidence in context; no prior latent-memory state is supplied. It tests stateless memory extraction by that checkpoint. A commit-and-recall experiment would be a different benchmark.

MemT uses a Qwen3.6-35B-A3B backbone; I did not run a matched unmodified-backbone control, so these scores do not isolate the effect of MemT’s training.

**Scoring:** A recalled memory needs both accurate content and the correct source-line citation ID. A correct fact with a wrong or missing ID fails the contract. “Unwanted” does not mean everything was hallucinated: many proposals are true things the policy forbids saving, alongside duplicates, misattributed quotes and unsupported additions. Always returning `{"items":[]}` gets 44/44 empty cases and 0/52 recall, which is why both metrics matter.

Unwanted proposal counts cover all 96 English cases, including positive cases, and a model can emit several unwanted items in one answer.

**Setup:** same frozen application messages and JSON schema; native chat templates; greedy decoding, seed 0, thinking disabled, one completed response per case, maximum 1024 output tokens. MemT’s experimental adapter preserves dense and memory weights in BF16 and stores experts in NF4. It passed numerical parity checks against a tiny native model with the same quantized weights before the benchmark. That is an implementation check, not evidence of lossless quantization.

MemT ran in two sessions (23 and 25 October): I stopped after 30 completed cases, then resumed the remaining cases with the same pinned configuration. The original responses were retained; no saved completion was rerun or replaced.

**Limitations:** Assistant-authored synthetic edge cases, at most one target memory per case, and semantic grading performed by an assistant with model names visible. No independent human validation or statistical-significance claim. This tests one personal-memory retention policy, not long-term retrieval or general intelligence. The separate Serbian slice should not be used to judge Hy-Memory’s advertised English/Chinese coverage.

**Evidence bundle:** [add the reviewed GitHub PR or bundle download link before posting] — frozen cases, full prompts, exact revisions and hashes, raw completions, scorer, semantic-review decisions, runtime/adapter code and chart data. The report and bundle are published through the benchmark pull request; this Reddit draft has not been posted.

What retention rule or edge case would you add as a paired test? I’d particularly appreciate a second pair of eyes on the gold labels and disputed outputs.
