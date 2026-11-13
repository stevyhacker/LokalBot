**Fixed-prompt E2B IT Q6 comparison — protocol frozen before inference**

Compare the installed mradermacher E2B **base** i1-Q6_K with the standard
Unsloth and Bartowski E2B **instruction-tuned** Q6_K files. The checkpoint
change is intentional in this follow-up. Dynamic XL/L and QAT releases are
outside this three-arm comparison. Keep the installed default unchanged.

Reuse the preceding study's frozen 48 fictional bilingual sentence pairs,
yielding 144 English and 144 Serbian Latin checkpoints. This corpus has been
evaluated before; it is not a new holdout. The IT models have not been tuned on
these outputs. Rerun all three models and judge all anonymous suggestions anew;
do not pool old timing observations or Claude scores.

The Release executable, native decoder, prompt renderer, six-token/four-word
budget, temperature 0.1, seed 0xC0FFEE, sampling settings, certified prefix
search and two generation/two prefill threads remain fixed. Prompts are the
raw typed prefixes produced by the existing renderer. No instruction/chat
template is added, and no personal meeting, screen or typing context is used.
This measures IT models as substitutes under the requested current prompt,
not their best performance with an IT-specific prompt.

Inspect the GGUFs before replay. If automatic BOS insertion differs, align
only that boolean in temporary APFS-cloned evaluation files to current Q6.
Retain original files and hashes, verify every other byte unchanged, and check
the vocabulary/input-tokenizer metadata. Preserve the publisher's stopping
metadata and weights. Record the tensor precision mix, since a Q6_K label can
contain higher-precision embeddings. Downloads are pinned by revision and
full SHA-256. No remote model code is executed.

Run 39 serial native processes: two reverse-order rounds of fresh, long-field,
typing/backspace and cancellation fixtures, two additional predeclared warm
fresh rounds, one confidence trace and two matched-frequency fresh rounds.
Each process excludes eight warmups. Total: 7,776 measured observations and
312 warmups. Do not run native inference alongside downloads, builds or Claude.

For frequency matching, use only unlabeled native confidence traces. Preserve
ungated midword outputs and the 3.1 fallback/primary threshold ratio. Target
current Q6's production shown count separately per language. If necessary,
lower to the greatest common feasible rate; report any change to current
Q6's rate or outputs. If native gates have no common feasible rate, report that
limitation rather than selectively dropping inconvenient outputs. Rerun the
actual native thresholds for timing and assert trace/output/count parity.
These cutoffs fit this evaluation corpus and are not production calibration.

After local timing finishes, send only fictional prefixes and shuffled,
anonymous unique continuations to Claude Opus 5.5, with tools disabled. It
receives no model labels, code, timing or intended future. Use the established
−2..2 utility rubric, silence zero, with every checkpoint in the denominator.
Include 24 reversed-option repeat cases; preserve all original responses,
failures and preferred-option inconsistencies.

Report helpful/poor counts, overall and language-specific utility, mean/p95
native latency, shown-only timing, peak RSS and exploratory cancellation
recovery. Use 5,000 paired bootstrap draws clustered by the 48 bilingual source
scenarios. Repeats are not independent quality cases. Intervals are exploratory
and not corrected for multiple comparisons; Claude opinions do not establish
human acceptance. Native timing excludes load/debounce/accessibility/rendering,
and four cancellation scenarios do not establish reliable tail behavior.

Archive the protocol, public model metadata, synthetic inputs, raw outputs,
judge receipts and analysis. Keep the current installed model/default and
app unchanged regardless of results. No local UI tests, CI management or
production inference settings changes are part of the experiment.
