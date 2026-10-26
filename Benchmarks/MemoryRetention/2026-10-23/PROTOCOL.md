# Memory retention contrast test — frozen protocol

Authored 2026-10-23, before running any candidate on these cases. This is a local, timestamped protocol, not an externally registered preregistration.

Question: can a memory writer extract useful personal facts while obeying an explicit retention policy? This evaluates proposed memories from the current LokalBot About-you prompt, not retrieval, a complete memory framework, persisted application state, or general model intelligence.

## Dataset and scope

120 new synthetic cases in 60 contrast pairs, separate from the existing 36-case development pilot. 96 English cases (48 pairs) form the primary slice; 24 Serbian cases (12 pairs, half Latin/half Cyrillic) are exploratory. The new dataset contains 65 required memories and 55 cases where an empty response is required. English: 52 required memories, 44 empty cases. Serbian: 13 required memories, 11 empty cases.

Twelve categories: ownership, hypotheticals, durability, known duplicates, excluded sensitive information, typed requests, dictation, negation, changed known facts, quoted prompt injection, goals versus tasks, and mixed eligible/excluded information on one line. Each pair has the same distractors and positions. Most pairs change whether one memory qualifies; five pairs require remembering the opposite preference/fact. Known facts are supplied directly; this is not a simulation of several days of accumulated state. New corrections qualify, unchanged known facts do not. Each case has at most one gold memory, so this suite does not test prioritization when more than three useful memories compete.

The assistant authored and checked the cases. They are not human-authored, independently human-validated, representative real-user data, or evidence of training-set decontamination. The cases are held out from prompt tuning in this run, but the policy/categories are informed by the old pilot. The distribution is intentionally adversarial and balanced; do not extrapolate its percentages to production. Pair members are related; do not call 120 cases 120 independent samples.

Only synthetic text is sent to the user's Ubuntu server. No private library, recordings, credentials, screen data, or personal memory is used. The benchmark's synthetic sensitive details are deliberately excluded by the product's policy; their retention is not necessarily fabrication or a universal model safety failure.

## Frozen inference

Use the exact prompt text extracted from the checked-in `PersonalLearning.swift` snapshot, plus the app's JSON schema. Copy the source into this directory. No model-specific prompt tuning. Temperature 0, seed 0, maximum 1024 completion tokens, thinking disabled, 8192 context, one request and one model process at a time, 12 CPU threads, native chat templates. All arms use the same existing llama.cpp v0.7.0 CPU build if compatible. Record binary/version/template hashes and any compatibility deviations. No inference on the Mac.

Planned arms: Qwen3.5 4B Q4_K_M, Qwen3.5 9B Q4_K_M, official Tencent Hy-Memory 30B-A3B Q4_K_M imatrix, and LiquidAI LFM2.5 24B-A2B QAD Q4_0. Pin files and revisions in models.json before inference. The official Hy GGUF is a different quantization from the old pilot; do not merge its scores or attribute any change solely to the larger dataset. These are practical downloadable configurations, not matched-precision architecture ablations. All arms get a single greedy pass. Preserve raw completions, errors, timings and server logs. Transport errors, truncations and malformed responses remain in denominators; retry only an interrupted run with no completed record, never replace an observed failure with a better answer.

Freeze cases, prompts, schema, protocol, input source snapshot, model manifest, runner and scoring implementation by SHA-256 before the first request. Analysis/figure code may be written afterward. Never change gold labels or inference settings after seeing results. Record any discovered annotation defect as a limitation or separately reported sensitivity analysis. Retain the frozen automatic score alongside any reviewed semantic score.

## Scoring and review

Primary decision metric: fraction of cases whose proposed source handles exactly select the eligible line, once, or return a valid empty list when no line qualifies. Invalid JSON, invalid schema, truncated/error responses, duplicate proposals, and invalid/wrong handles fail. This is a source-selection metric; it does not by itself certify factual content.

Semantic metrics: required memories recalled (one per expected claim, correct evidence line), unwanted proposals (excluded/duplicate/unsupported/wrong-provenance), clean empty cases, and cases with fully correct contents. Recall and unwanted proposals are separate: an empty-everywhere model has zero recall. Kind, original language/script and relative-year compliance are recorded separately. A partial useful claim can count as semantic recall if it preserves the gold fact; an item mixing the eligible claim with excluded information counts as recalled AND unwanted. A contradictory or fabricated claim does not count as recalled. A correctly remembered new fact does not prove the old fact was removed from storage.

Frozen anchor matching supplies a reproducible provisional semantic score. An assistant then reviews every emitted item against the source and gold, records verdicts and reasons in an append-only review file, and checks empty and error cases mechanically. This is model-assisted judgment, not blinded independent human review. Model identity may be visible. Publish both automatic and reviewed scores; do not silently revise regexes. Review flags distinguish (a) true but excluded information, (b) unsupported/fabricated or reversed content, (c) provenance/duplication errors, and (d) presentation errors. Human review remains desirable before making strong public claims.

Report English and Serbian separately. Pair success requires both members to pass. Use exact numerators and denominators. Do not claim statistical significance or population confidence bounds: this authored convenience sample and its 60 related pairs do not justify them. Do not rank speed on a shared CPU host. Timings are diagnostic only; log load, CPU, available RAM, model file sizes and runtime.

## Deliverables

Self-contained test set, frozen manifests, runner, scorer checks, raw outputs, review decisions, result CSV/JSON, report, PNG/SVG chart with an accurate subtitle, and a Reddit draft disclosing affiliation, synthetic data and AI assistance. No publishing or posting is authorized.
