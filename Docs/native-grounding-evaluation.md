# Native grounding and offline evaluation

Factual meeting answers use the actual `ChatAgent` source-selection flow:
original tool evidence, exact source anchors, a separate support verdict, and
typed citation rendering. The model's generated prose never acquires authority
just because it includes a valid link. Explicit composition requests retain the
existing draft behavior.

The October synthetic comparison used archived native retrieval followed by a
shared structured answerer. It did not exercise this native grounding flow.
Four unnecessary abstentions occurred even though the required source text was
present. Additional failures involved speaker IDs instead of display names,
unnecessary citations, and exact answer-format expectations. Those results and
labels remain historical evidence; this change does not rescore them.

This implementation makes the following changes:

- Question-relevant original sources appear earlier in the grounding catalog.
  Matching can cross Latin/Cyrillic scripts and use the recorded meeting title.
  It changes presentation order only. It preserves every retrieved source,
  its exact text, citation authority, speaker label, and date; ties retain the
  retrieval order. It does not translate the quoted answer or determine truth.
- The native catalog export preserves human speaker labels and recorded dates
  alongside original text and typed citations. It never derives a person's
  name from an internal ID. Same-named people retain separate source records.
- The selection, proposal, and verification instructions distinguish a known
  negative event from an unknown quantity or identity. “Not handed over” can
  answer a handover question; “no recorded payment amount” cannot establish a
  payment amount, including zero.
- An optional in-process observer reports selection, repair, proposal,
  verification, recovery, and final-answer stages. It contains enum values
  only, has no persistent logger, and cannot change a grounding decision.

Citation safeguards remain mandatory: only authorized tool evidence is usable;
quote anchors must exist in selected original sources; the separate verifier
must approve the original question with no issues; later corrections remain
visible; output uses exact source excerpts and typed citations. Recovery has
one additional scoped search and bounded reselection, never an unbounded retry
until a model approves an answer. Whole-source and request-size limits remain
in place. If a whole retrieved source is omitted by a size/count limit, support
fails closed rather than approving an earlier statement while hiding a possible
correction. Unknown, ambiguous, unsupported, malformed, and over-budget evidence
fails closed.

Run the offline regressions after dependencies have been cached by a normal
build:

```sh
bash Scripts/native-grounding-regression.sh
```

The command selects nine non-UI test classes, limits the build to four jobs,
and disables package updates. It does not install an app, start a model server,
load model weights, read a private corpus, or accept a corpus/model endpoint.
The ordinary app's runtime binaries are build dependencies, not inference jobs.
`LOKALBOT_GROUNDING_PACKAGES` can point at an existing Swift package cache.

`NativeGroundingEvaluationTests` drives real `ChatAgent`, `ChatGrounding`, and
`ChatCitationParser` code. Authored model responses exercise explicit negatives,
separate milestones, multilingual history, empty-selection repair, and minimal
citations. Negative cases cover unknown amounts, wrong projects and milestones,
superseded facts, ambiguous people, quoted instructions, forged handles,
unselected sources, and invented quote anchors. Removing the supporting source
must restore abstention; changing unrelated evidence must not change the answer.

Most cases replay a fixed synthetic tool-result snapshot. A separate case also
creates a temporary transcript with a trusted speaker alias, runs actual
`SearchIndex` ingestion and `MeetingChatTools`, and then traverses the same
native answer flow. Semantic embeddings are explicitly disabled. Neither mode
is a new common-answerer comparison or a real-model quality measurement.

The `.xcresult` bundle retains JSON attachments named **Native grounding replay**
with case answers, typed citations, stage traces, scripted call counts, and an
explicit `inference_calls: 0` / `model_quality_measured: false` declaration. A
scripted positive verdict tests the application's enforcement of that verdict;
it does not establish that a model will produce a correct verdict.

Future model-quality evaluation should use a new, untouched synthetic set and
report native-product responses separately from the common-answerer lane.
Measure unnecessary and required abstentions, factual coverage, identity
attribution, citation precision, and latency independently. Preserve the frozen
older scores and use explicit, versioned equivalence rules instead of broad
substring matching or dropping negation. No quality improvement or private-
corpus result is claimed by these offline tests.
