"""Build the written report and unpublished Reddit draft from reviewed results."""
import collections
import json
from pathlib import Path
from score import aggregate

ROOT=Path(__file__).resolve().parent
models=json.loads((ROOT/'models.json').read_text())
scores=json.loads((ROOT/'scores.json').read_text())
details=json.loads((ROOT/'details.json').read_text())
frozen=json.loads((ROOT/'frozen.json').read_text())
citations=json.loads((ROOT/'citation-diagnostic.json').read_text())

def ratio(a,b):return f'{a}/{b} ({100*a/b:.1f}%)' if b else 'n/a'
def table(language,extra=True):
    header='| Model | Useful memories recalled | Unwanted proposals | Empty cases correct |'
    if extra:header+=' Fully correct cases | Both pair members fully correct |'
    lines=[header,'|'+'---|'*(6 if extra else 4)]
    for m in models:
        s=scores[m['arm']+'/reviewed'][language]
        line=f"| {m['label']} ({m['quantization']}) | {ratio(s['recalled'],s['gold'])} | {s['unwanted']} | {ratio(s['clean_empty'],s['empty_cases'])} |"
        if extra:line+=f" {s['perfect']}/{s['cases']} | {s['pairs_perfect']}/{s['pairs']} |"
        lines.append(line)
    return '\n'.join(lines)

report=['# When should a memory writer remember nothing?',
    '', '120 new synthetic cases, run remotely on 2026-10-23. Completed results are kept separate from the 36-case development pilot.',
    '', '## Main result: English', '', table('en'), '',
    'Hy-Memory recalled all 52 eligible English memories but emitted 76 unwanted proposals and returned no correct empty response on 44 empty cases. Qwen3.5 9B recalled 37/52 with five unwanted proposals, while 4B recalled 30/52 with three. These are different tradeoffs under this exact policy; the evidence does not establish a universally best memory model.', '',
    'Useful recall requires correct content AND the correct source-line handle; correct wording with an invalid citation does not count. Recall and unwanted proposals must be read together. An always-empty baseline would recall 0/52 useful memories while passing all 44 empty cases. “Unwanted” includes true but excluded information, wrong ownership, duplicates, unsupported additions, and incorrect evidence; it is not a synonym for hallucination. A mixed item can preserve a useful fact and also contain unwanted information.',
    '', '![English comparison](memory-retention.png)', '',
    'The primary frozen mechanical metric, exact source selection, and the reviewed semantic results answer different questions. Selecting the right line does not prove that the extracted content is correct.',
    '', '| Model | Exact source selection, English | Automatic anchor recall | Reviewed recall | Automatic unwanted | Reviewed unwanted |', '|---|---:|---:|---:|---:|---:|']
for m in models:
    a=scores[m['arm']+'/automatic']['en'];r=scores[m['arm']+'/reviewed']['en']
    report.append(f"| {m['label']} | {r['decision_correct']}/96 | {a['recalled']}/52 | {r['recalled']}/52 | {a['unwanted']} | {r['unwanted']} |")
report += ['', 'The frozen regexes were not tuned after inference. The review overlay is explicit in [review.json](review.json); each reviewed item carries a source/output digest and a reason. All raw completions, including empty responses, are retained.',
    '', '## What was tested', '',
    'The current LokalBot personal-profile writing prompt asks for up to three durable first-person facts, goals or preferences. It excludes temporary tasks, quotations, hypotheticals, other people\'s private details, already-known facts, and health, money, politics, religion and sexuality. It asks for original-language text and absolute years for relative dates; this benchmark also checks preservation of the original script. This is a product-specific retention policy.', '',
    'The expansion contains 48 English scenario pairs and 12 Serbian pairs. Most pairs toggle whether a fact qualifies; five pairs change which preference or fact is correct. Each pair shares distractors and source positions. The suite has at most one eligible memory per case. It tests a single writing pass with supplied known facts, not a stateful multi-day memory bank or retrieval benchmark.', '',
    'The assistant authored the cases, froze them before inference, and reviewed every emitted item with model identity visible. There is no independent human validation or blinded judging. “Held out” means not used for prompt tuning in this run; it does not establish absence from model training. Cases are informed by failures in the older pilot.', '',
    '## Category breakdown', '', '| Category | '+ ' | '.join(m['label'] for m in models)+' |', '|---|'+'---:|'*len(models)]
categories=sorted({r['category'] for r in details[models[0]['arm']+'/reviewed'] if r['language']=='en'})
for cat in categories:
    row=[cat]
    for m in models:
        rr=[r for r in details[m['arm']+'/reviewed'] if r['language']=='en' and r['category']==cat]
        s=aggregate(rr);row.append(f"{s['perfect']}/{s['cases']}")
    report.append('| '+' | '.join(row)+' |')
report += ['', 'Each cell is fully correct English cases, including correct kind and formatting. These small category slices are diagnostic; they are not reliable population rankings. Exact-kind scoring uses one frozen label: the ongoing furniture-restoration hobby is labeled fact, so calling it a goal fails kind compliance even though the content is supported. Main recall and unwanted-proposal metrics do not penalize that kind choice.',
    '', '## Error categories', '', '| Model | Reviewed unwanted item categories, English |', '|---|---|']
for m in models:
    counter=collections.Counter(i['issue'] for r in details[m['arm']+'/reviewed'] if r['language']=='en' for i in r['items'] if i['unwanted'])
    report.append(f"| {m['label']} | "+', '.join(f'{k}: {v}' for k,v in sorted(counter.items()))+' |')
lfm_cite=citations['lfm25-24b']['slices']['en']
report += ['', '## Post hoc citation diagnostic', '',
    f"LFM2.5 emitted {lfm_cite.get('invalid_citations',0)} invalid citation fields among {lfm_cite['proposals']} English proposals. Of those, {lfm_cite.get('exact_quote_repairs',0)} exactly match one source sentence. Mapping only those exact quotes back to their source IDs changes mechanically correct source-selection cases from {lfm_cite['source_selection_before']}/96 to {lfm_cite['source_selection_after']}/96.", '',
    'This is an explicitly post hoc adapter diagnostic, not a replacement for the frozen primary scores or a new model run. It changes citation identifiers only, never the memory text. It does not establish semantic accuracy: copied examples, wrong durations, excluded information and duplicate content can remain. See [citation-diagnostic.json](citation-diagnostic.json) for every mapping and [citation_diagnostic.py](citation_diagnostic.py) for the exact-match rule. A model-specific citation adapter or tighter schema is a separate follow-up experiment.', '']
report += ['', '## Concrete examples', '',
    '- **True but excluded (P45-yes):** Hy-Memory and LFM returned the cartographer role together with the 51000-euro salary. The role is eligible; the salary is explicitly excluded. This counts as useful recall and an unwanted proposal.',
    '- **Unsupported dates (P36-yes):** the source changes a German-learning goal to Italian and gives no date. Qwen 4B adds 2027; Qwen 9B adds 2026. Both fail reviewed recall because the stored goal would carry a fabricated date. Hy-Memory preserves the undated goal.',
    '- **Copied instruction example (P23-no):** the user asks about formatting a CSV and says they have no connection to Larch Robotics. LFM returns "I live in Belgrade", which appears in the prompt examples but nowhere in the evidence.', '',
    'See the complete [audit worksheets](audit/) for all sources and outputs. The reason attached to each item is the authoritative explanation of its reviewed classification.',
    '', '## Serbian exploratory slice', '', table('sr'), '',
    'These are 24 cases (12 pairs), with 13 eligible memories and 11 empty cases. Half use Latin script and half Cyrillic. Semantic recall can count a correctly translated fact, while full compliance fails translation. Hy-Memory\'s model card lists English and Chinese; this Serbian slice is explicitly exploratory and excluded from the primary chart.', '',
    '![Serbian comparison](memory-retention-serbian.png)', '',
    '## Runtime and model provenance', '',
    'All inference ran on the user\'s Ubuntu server: AMD Ryzen 7 9700X, 16 logical CPUs, approximately 64 GB RAM, CPU-only, 12 inference threads, one model and request at a time. No inference ran on the Mac. The shared host was not isolated, so timings are retained as diagnostics and not ranked.', '',
    'All arms used the same existing llama.cpp binary in the v0.7.0 directory. It reports `0.7.0-dev (build 0, commit unknown)`, built with GNU 13.3.0. The original source archive was no longer present. [Live binary/library checksums](runtime-checksums.txt) and per-arm metadata provide the verified runtime identity; exact Git provenance is not independently established by the binary.', '',
    '| Model | Pinned source | SHA-256 |', '|---|---|---|']
for m in models:
    report.append(f"| {m['label']} · {m['quantization']} | [{m['repo']}@{m['revision'][:8]}](https://huggingface.co/{m['repo']}/tree/{m['revision']}) | `{m['sha256']}` |")
report += ['', 'Hy-Memory uses Tencent\'s official imatrix Q4_K_M. It is a different file from the custom quantization in the older pilot; scores must not be pooled or their differences attributed only to dataset size. LFM uses QAD Q4_0, so these are practical downloadable configurations, not controlled matched-precision ablations.', '',
    'Identical requests: temperature 0, seed 0, max 1024 completion tokens, 8192 context, thinking disabled, native chat templates, app JSON schema. One greedy pass per arm; no best-of selection and no model-specific prompt tuning.', '',
    'Before any first request, inputs were frozen at '+frozen['frozen_utc']+'. The original local-only manifest was amended before inference to omit the full app-source snapshot from remote transfer. Only synthetic inputs, rendered prompts and benchmark code were transferred. All cases, prompts and scoring rules stayed unchanged.', '',
    'The 9B startup initially stopped before sending any request because the conservative socket probe encountered TCP TIME_WAIT. Resuming after cooldown skipped the completed 4B arm; no observed model response was replaced. See [README.md](README.md) for per-arm ports when reproducing rapid sequential runs.', '',
    '## Limits and validation', '',
    '- 120 authored edge cases are 60 related pairs, not 120 independent samples. English and Serbian are not pooled for the headline.',
    '- The artificial balance and topic choices do not estimate everyday failure rates. No significance test or population confidence interval is claimed.',
    '- Assistant-authored gold and assistant semantic judgment introduce correlated bias. Independent human review is the main remaining validation limitation.',
    '- Every case has at most one gold memory; there are no long histories, retrieval questions, multi-memory capacity tests, or persisted-state checks.',
    '- Passing the writing test does not show that application grounding, consent, review, storage, correction/deletion or retention behavior works end to end.',
    '- The automatic scorer deliberately remains imperfect. Its scores and all reviewed disagreements are exposed rather than silently editing regexes.',
    '- Some annotation choices merit human challenge: unchanged-employer/city contrasts treat a rejected alternative (for example, not joining Maple Instruments) as no useful new profile update. This is a relevance judgment, not fabrication. Gold labels remain frozen; the excluded_nonupdate review tag makes this choice visible.',
    '', 'The verification script checks 480 unique responses, frozen hashes, pinned model/runtime identities, complete item review, review/source hashes, aggregate scores, and exact chart CSV values. All 480 responses ended normally and parsed successfully, with zero transport errors or nonempty reasoning fields. Prompts were at most 613 tokens and completions at most 146, below the configured limits. The scorer has 12 checks covering invalid JSON, transport/truncation failures, duplicates, wrong handles, incomplete review, negated anchor traps, mixed excluded content and test-set integrity.', '',
    '## Artifacts', '',
    '[Protocol](PROTOCOL.md) · [Cases](cases.json) · [Prompts](prompts.json) · [Scorer](score.py) · [Raw results](results/) · [Review decisions](review.json) · [Scores](scores.json) · [Chart CSV](chart-data.csv) · [English PNG](memory-retention.png) · [English SVG](memory-retention.svg) · [Reddit draft](REDDIT_DRAFT.md)', '',
    'Status: remote benchmark and local analysis only. Nothing posted, published, committed, installed or released. No app defaults changed.', '']
(ROOT/'REPORT.md').write_text('\n'.join(report))

draft=['# Reddit draft — not posted', '',
    '**Proposed title:** I tested four local memory writers on 120 synthetic cases. Can they tell when to remember nothing?', '',
    '**Author note:** Review and rewrite this AI-assisted draft in your own voice before posting. Add a public link to the evidence bundle only after separately deciding to publish it. No public artifact URL exists yet.', '',
    '---', '',
    'I work on LokalBot, a local work-memory app. I wanted to test a specific part of memory writing: can a model keep useful facts while obeying explicit rules about what it should skip?', '',
    'For example, “I live in Valencia” should produce a memory. “My colleague said, ‘I live in Valencia’” should not. A new preference should be remembered; the same preference already in the known list should not be repeated. A job title in a sentence containing a salary should be kept without the salary.', '',
    'I expanded our earlier pilot into **120 new synthetic cases / 60 contrast pairs**. The main comparison below is the **96 English cases**: 52 useful memories and 44 cases where the correct output is empty. There is a separate 24-case Serbian slice.', '',
    table('en',extra=False), '',
    'Attach `memory-retention.png` here.', '',
    'The clearest contrast: Hy-Memory found every eligible English fact, but also retained 76 unwanted items and never returned the required empty answer. The Qwen models missed more useful facts and were much more selective. LFM recalled 40/52 but emitted 53 unwanted proposals. In some cases it copied "I live in Belgrade" from the prompt examples even though no evidence line said that. This is why I would want both recall and a retention-policy test when choosing a memory writer.', '',
    '**Setup:** Qwen3.5 4B and 9B Q4_K_M, Tencent\'s official Hy-Memory 30B-A3B Q4_K_M imatrix, and LFM2.5 24B-A2B QAD Q4_0. Same application prompt, native chat templates, JSON schema, temperature 0, seed 0, thinking off, one pass. All inference ran sequentially on the same Ryzen 7 9700X Ubuntu machine with llama.cpp. This is not a speed comparison.', '',
    'Recall requires correct content **and a correct source-line citation**. Correct text with an invalid citation fails this application contract. “Unwanted” does **not** mean every item was fabricated. Some outputs are true things the prompt explicitly says not to retain. Others get ownership wrong, repeat known information, or add unsupported details. Recall and restraint both matter: a model that always returns an empty list gets 44/44 on the empty cases but 0/52 recall.', '',
    f"LFM sometimes returned the source sentence instead of its ID. In a separate post hoc diagnostic, {lfm_cite.get('exact_quote_repairs',0)} of {lfm_cite.get('invalid_citations',0)} invalid English citations could be mapped by exact text match. That changes correct source selection from {lfm_cite['source_selection_before']}/96 to {lfm_cite['source_selection_after']}/96; it does not certify the memory content. The table retains the original contract scores.", '',
    '**Limitations:** The cases were assistant-authored and the semantic review was assistant-assisted, with model names visible. There is no independent human validation. I kept the frozen automatic scores, raw outputs and every semantic-review decision so the judgments can be checked. These are deliberately difficult paired examples, not a random sample of real users. No statistical-significance claim.', '',
    'This tests one personal-memory writing policy, not Mem0, long-term retrieval, or the models\' overall capability. Each case has at most one useful memory. The separate Serbian results should not be used to generalize about Hy-Memory\'s advertised English/Chinese coverage.', '',
    'Evidence to attach/link before posting: frozen cases and prompts, exact model revisions and hashes, raw completions, scorer, review decisions and chart data. The local `share-bundle.zip` contains those artifacts; it has not been published.', '',
    'What retention rule would you add as a paired test? I would especially like independent review of the gold labels and disputed outputs.', '']
(ROOT/'REDDIT_DRAFT.md').write_text('\n'.join(draft))
print('Built REPORT.md and REDDIT_DRAFT.md from reviewed scores')
