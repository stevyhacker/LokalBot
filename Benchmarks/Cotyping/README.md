# Autocomplete quality replay

The [2026-10-02 quality report](results/2026-10-02-quality/REPORT.md) contains
held-out before/after results, a direct Cotabby comparison, tradeoffs and raw data.

`quality_replay.py` scores the production request builder, native llama engine,
token healing and normalizer. It runs before app startup and uses synthetic input
plus an explicit local model; it does not drive the UI, enable autocomplete,
read learned writing, or change installed settings. No prompt is uploaded.

Build Release with `CODE_SIGNING_ALLOWED=NO`, then run:

```sh
uv run --no-project python -S Benchmarks/Cotyping/quality_replay.py \
  --app .build/XcodeDerivedData/Build/Products/Release/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/to/model.gguf \
  --corpus /absolute/path/to/cotabby/CotabbyTests/Fixtures/phrase-prediction-1337.json \
  --split screen --output /absolute/path/to/new-results
```

Use the [Cotabby v2 synthetic corpus](https://github.com/FuJacob/cotabby/blob/7724926b3e93f14e3b576ba46ff52c4f64d9712d/CotabbyTests/Fixtures/phrase-prediction-1337.json)
from pinned revision `7724926b3e93f14e3b576ba46ff52c4f64d9712d` (AGPL-3.0).
It is supplied externally, with its SHA-256 recorded; the runner never downloads
or changes a corpus automatically. The independent `quality-cases.json` contains
32 original synthetic scenarios for email, formatting, longer documents and
multiple languages. Run it with `--split all`.

The screen split takes the first 20 IDs per category sorted by SHA-256 of
`1337:<phrase-id>`; heldout takes the other 171. Freeze a candidate before running
`--split heldout`. `--per-category` selects a deterministic smaller sample from
that partition. `--mode midword` tests every internal character position of words
after the first, separately from next-word checkpoints.

Only previously typed text and app/title/field metadata enter inference. Screen
text, category and future words do not. The reference always advances regardless
of the prediction. Correctness requires an exact first word after joining the
typed fragment and suggestion, ignoring case and straight/curly apostrophe
differences. Suppressed results and errors remain in the denominator. Two- and
three-word rates require consecutive matches and enough reference words remaining.
These lexical scores penalize valid alternate wording; they do not measure user
acceptance or semantic equivalence. The public corpus is English and synthetic.

Each run records app/model/corpus/script hashes, explicit overrides, exact input
requests, visible output, suppression, errors and latency. The process prewarms
the model first; reported latency excludes cold loading, keyboard handling,
debounce, AX validation and overlay presentation. Runs should be serial to avoid
GPU contention. A nonzero exit or missing observations is not a completed run.

The confidence gate (`CotypingFirstWordConfidence`) is on in replays as in the
product; an input with `"confidenceGate": false` turns it off to compare.
Suggestions it hides are recorded with the suppression `lowConfidence`.

`--prompt` and sampling/length flags are experimental controls. A release
qualification must use `--prompt production` and no overrides, so the actual
product renderer and defaults are measured. No experiment changes saved settings.

```sh
uv run --no-project python -S -m unittest discover -s Benchmarks/Cotyping -p 'test_quality_replay.py'
```

`compare_quality.py` checks matching corpora/checkpoints and computes paired,
whole-phrase, category-stratified bootstrap intervals. `compare_cotabby.py`
restricts completed runs to the same deterministic held-out sample, verifies
identical prefixes and surface metadata, and checks that the common lexical
scorer agrees with Cotabby's own scorer. Each product retains its production
prompt and output-length policy; compare first-word accuracy, not generation
latency at unequal completion lengths.

`verify_context_replay.py <result-directory>` checks exact retention of typed
text in the independent challenge's rendered prompts. It intentionally fails
on the original engine, providing a regression control for paragraph and caret
whitespace preservation. Python tools use only the standard library; `-S`
avoids loading unrelated site startup hooks.

## Hosted model comparison

`remote_comparison.py` asks whether a hosted model would beat the local one by
enough to justify its latency. It runs the quality replay above once per
engine over identical checkpoints: the local model, then each candidate in
`remote-candidates.json`. Hosted engines get the same production prompt,
normalizer and scorer through the app's HTTP completion engine and raw
`/v1/completions`; only the generation backend differs. These runs send the
corpus's synthetic prompts to the providers. Nothing from a real library is read.

The candidates were picked from OpenRouter's per-provider latency stats but are
called through each provider's own API: Qwen3.8 27B on Cerebras, Gemma 4 31B on
Modular and Nemotron 3.5 Lightning on CoreWeave. Copy
`remote-autocomplete.env.example` outside the repository, fill in the keys and
`chmod 600` it. Each key reaches only its own provider's replay, as
`LOKALBOT_REPLAY_API_KEY`, and is never put on a command line.

```sh
uv run --no-project python -S Benchmarks/Cotyping/remote_comparison.py \
  --app /absolute/path/to/Release/LokalBot.app/Contents/MacOS/LokalBot \
  --local-model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/gemma-4-E2B.i1-Q6_K.gguf" \
  --corpus /absolute/path/to/phrase-prediction-1337.json \
  --env-file ~/.config/lokalbot/remote-autocomplete.env \
  --output /absolute/path/to/new-results
```

With only an OpenRouter key, add `--via-openrouter`: each candidate then goes
through OpenRouter's raw completions with the same model, pinned to the same
provider with fallbacks off and prompt-retaining providers excluded. This adds
OpenRouter's own hop to every request, so its latency reads somewhat high
next to a direct call. Two routes differ (checked 2026-10-05): OpenRouter adds a
`reasoning_effort` field for Qwen3.8 27B that Cerebras's raw completions reject,
so that model runs on CoreWeave instead, which measures its quality but not
Cerebras's speed; and Gemma 4 31B has no usable route, because ModelRun has no
raw completions and the other hosts continue raw text as gibberish.
`openRouterProvider`, `openRouterLabel` and `openRouterNote` in
`remote-candidates.json` record this.

The default sample is 30 held-out phrases per category (about 1,200
checkpoints) plus the 32-scenario `quality-cases.json`. `--per-category 0`
runs the whole held-out split (6,667 checkpoints), and `--midword-per-category
10` adds mid-word completion on a separate sample, where hosted output must
re-type the healed word fragment. Add `--per-category 1 --skip-challenge` for a
smoke run, and `--only <id>` to run some candidates.
The hosted replays run side by side after the local one. A hosted replay
first sends one untimed request, so a wrong key, model ID or rejected field
stops it before any case. A rate limit or server error is retried up to five
times and only the answering attempt is timed; `retries` counts the extra
attempts. Hosted requests carry only the OpenAI sampling fields (temperature,
`top_p`, seed, stop); `extraBody` adds a provider's own fields such as `top_k`.

Hosted replays use the local engine's token healing. Every word checkpoint ends
in a space, and a model forced to continue after a bare space tokenizes badly:
Gemma 4 E2B served by a loopback llama-server scored 14.3% instead of 37.0% on
the same weights. The hosted prompt is therefore sent cut back to the word
boundary, and only output that re-types the cut text counts; anything else is
suppressed, because a hosted API cannot be constrained to that prefix. With
healing, the loopback server matched the in-process engine (37.0% vs 37.0% on
119 corpus checkpoints, 46.1% vs 46.6% on the 32 scenarios).

`REPORT.md` lists next-word, two- and three-word accuracy, the paired change
against the local model with its bootstrap interval, errors, retries, latency
percentiles and a rough input cost per 1,000 suggestions. Local latency is warm
in-process generation; hosted latency is the full HTTPS request from this Mac.
Neither includes debounce, Accessibility reads or drawing, which add the same
to both.

The replay can also be run directly with `quality_replay.py --completions-url
<base> --completions-model <id> --api-key-env <NAME>` in place of `--model`.

## Saved-memory replay

`memory-cases.json` contains only synthetic saved facts and draft checkpoints.
It measures whether autocomplete recalls an explicitly supplied owner, place,
date or technical detail, while ignoring unrelated facts. This is distinct
from predicting unseen facts or measuring actual user acceptance. Six cases
are for development; twelve factual cases and ten unrelated-writing controls
are held out. Freeze the app and source hashes before running held-out cases.

```sh
uv run --no-project python -S Benchmarks/Cotyping/memory_replay.py \
  --app /absolute/path/to/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/to/model.gguf \
  --split development --output /absolute/path/to/new-results
```

Use `--split heldout` after the freeze. Each paired run uses the same executable,
model, production defaults and saved facts with source permission off/on. Only
draft text, surface metadata and synthetic facts reach inference. Scoring also
checks selected source IDs, and byte-identical prompts/output for unrelated
controls. File, settings and revocation behavior are covered by the provider
and coordinator unit tests; this replay never opens a real library.

### Relevance supplement

`memory-relevance-cases.json` tests the other half of retrieval: leaving writing
alone when no saved fact is relevant. Its saved facts are realistic meeting-note
lines, mostly commitments from generically titled meetings ("Marko will get back
to you on Friday about the invoice."). Distractor drafts share everyday wording
with one of them but name no topic ("I'll get back to "), so the right behavior
is to retrieve nothing and give the same suggestion as with memory off. Relevant
drafts name a topic, including harder forms than the original fixture: a
lowercase name, a fact filed under a generic meeting title, a title matched by
two of its three words, a name with diacritics, and a draft that already
mentions the answer while an outdated version of the fact is also saved.

```sh
uv run --no-project python -S Benchmarks/Cotyping/memory_replay.py \
  --app /absolute/path/to/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/to/model.gguf \
  --corpus Benchmarks/Cotyping/memory-relevance-cases.json \
  --split heldout --output /absolute/path/to/new-results
```

The scorer reports recall and abstention together. A control (`irrelevant` or
`distractor`) passes only when no fact was selected and its prompt and output
match the memory-off run; `falseRetrievals` counts controls that selected
anything. `balancedRelevance` is the mean of the recall and abstention rates, so
a change that recalls more by retrieving indiscriminately does not score higher.
See the [relevance results](results/2026-10-03-relevance/REPORT.md).

Retrieval is also scored without a model: `CotypingMemoryRelevanceTests` runs
every case of all four fixtures through the production selection on each unit
test run, so a threshold change that loses a relevant fact or borrows an
unrelated one fails before any replay.


## Visible context and memory replay

The [visible-context results](results/2026-10-02-visible-context/REPORT.md) record
the frozen prompt evaluation, retrieval regression, and fresh integration supplement.

`visible-context-cases.json` contains 40 original synthetic screen trees, saved
facts, and draft checkpoints: eight development cases and 32 held out. Trees
include text regions, roles, frames, hidden/secure flags, window/field identity,
and origins. `CotypingVisibleContext.capture` traverses the same metadata/text
boundary in live AX and replay, so the eval tests selection before prompt assembly.
Rejected branches are never read; selected IDs and text-read IDs are recorded.
Reference answers, split labels and selection expectations stay outside inference.

```sh
uv run --no-project python -S Benchmarks/Cotyping/visible_context_replay.py \
  --app /absolute/path/to/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/to/model.gguf \
  --split development --output /absolute/path/to/new-results
```

Run serially for LFM and Gemma. Each invocation compares neither source, visible
text only, saved meeting memory only, and both. Freeze source/executable/corpus
hashes before `--split heldout`; do not tune on the held-out results. The default
three-word/five-token budget, renderer, sampler and normalizer are unchanged.
These cases test paraphrased factual continuations, current visible facts versus
older saved facts, form labels, Serbian, and independent privacy permissions.
Twelve held-out controls require identical prompts and completions across all
four conditions. Two ordinary-writing cases also test unrelated nearby content.

The scorer reports complete expected factual words anywhere in the short
continuation, separately from strict first-word accuracy, stale-fact errors,
source-selection accuracy, forbidden reads, suppression, errors and warm model
latency. Errors and suppressed results count as factual misses. Invalid,
reordered, duplicate or prompt-override runs are rejected. This is a small,
synthetic grounding test, not a measure of user acceptance, broad language
quality, live AX compatibility, or end-to-end typing latency. Model timing
excludes model loading, real AX, debounce and overlay work. Local runs are
headless inference and non-UI tests; real UI tests must run remotely.

```sh
uv run --no-project python -S -m unittest discover -s Benchmarks/Cotyping -p 'test_*replay.py'
```


`visible-memory-link-cases.json` adds a separate frozen supplement: two development
and four held-out generic replies whose project is named only in the visible
conversation. The production memory query must use the selected visible text,
and both source grants must be enabled to retrieve the corresponding saved fact.
Visible terms can match a saved source title; only the draft and enabled window
title can qualify the body-overlap fallback. This prevents incidental conversation
words from introducing an unrelated project's facts.
Run it with the same runner and `--corpus Benchmarks/Cotyping/visible-memory-link-cases.json`.
The original context fixture stays unchanged and is rerun as a regression set
when the retrieval integration changes. The scorer checks permission-dependent
source selections, so a correct guess cannot hide a missing or unauthorized lookup.
