"""Generate the additional report and unposted draft only from reviewed results."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent
ARM = 'memt-nano-nf4-offload'


def ratio(n, d):
    return f'{n}/{d} ({100*n/d:.1f}%)'


def main():
    models = json.loads((BASE/'models.json').read_text()) + [
        {'arm': ARM, 'label': 'MemT-1.0-Nano', 'quantization': 'Experimental NF4 experts / BF16 dense'}]
    scores = {**json.loads((BASE/'scores.json').read_text()), **json.loads((ROOT/'scores.json').read_text())}
    en = scores[ARM+'/reviewed']['en']
    sr = scores[ARM+'/reviewed']['sr']
    assert (en['cases'], en['gold'], en['empty_cases']) == (96, 52, 44)
    assert (sr['cases'], sr['gold'], sr['empty_cases']) == (24, 13, 11)
    scoring_comparison = ['| Slice / scoring | Recall | Unwanted proposals |', '|---|---:|---:|']
    for lang, label in [('en', 'English'), ('sr', 'Serbian')]:
        for mode in ['automatic', 'reviewed']:
            s = scores[ARM+'/'+mode][lang]
            scoring_comparison.append(f"| {label} / {mode} | {s['recalled']}/{s['gold']} | {s['unwanted']} |")
    reviewed = json.loads((ROOT/'details.json').read_text())['reviewed']
    issue_labels = sorted({item['issue'] for row in reviewed for item in row['items'] if item['unwanted']})
    issue_table = ['| Unwanted-proposal label | English | Serbian |', '|---|---:|---:|']
    for issue in issue_labels:
        counts = [sum(item['unwanted'] and item['issue']==issue for row in reviewed
                      if (row['language']=='en') == (lang=='en') for item in row['items'])
                  for lang in ['en', 'sr']]
        issue_table.append(f"| {issue.replace('_', ' ')} | {counts[0]} | {counts[1]} |")
    categories = ['| English category | Eligible memories recalled | Unwanted | Empty cases correct |',
                  '|---|---:|---:|---:|']
    for category in sorted({r['category'] for r in reviewed if r['language']=='en'}):
        selected = [r for r in reviewed if r['language']=='en' and r['category']==category]
        recalled = sum(r['recalled'] for r in selected)
        gold = sum(r['gold'] for r in selected)
        empty = sum(r['empty'] for r in selected)
        clean = sum(r['clean_empty'] for r in selected)
        recall_ratio = f'{recalled}/{gold}' if gold else '—'
        empty_ratio = f'{clean}/{empty}' if empty else '—'
        categories.append(f"| {category.replace('_', ' ')} | {recall_ratio} | {sum(r['unwanted'] for r in selected)} | {empty_ratio} |")
    by_id = {r['id']:r for r in reviewed}
    cases = {c['id']:c for c in json.loads((BASE/'cases.json').read_text())}
    raw = {r['id']:r for r in (json.loads(line) for line in (ROOT/'results'/f'{ARM}.jsonl').read_text().splitlines())}
    failed = [by_id[p['id']] for p in json.loads((BASE/'prompts.json').read_text())
              if by_id[p['id']]['language']=='en' and not by_id[p['id']]['perfect']]
    examples = []
    for row in failed[:10]:
        case = cases[row['id']]
        expected = '; '.join(g['text'] for g in case['expected']) or 'Empty items list'
        observed = raw[row['id']].get('content', '') or raw[row['id']].get('error', 'No content')
        known = ('Known: '+ '; '.join(case['known'])+' ') if case['known'] else ''
        target_text = next(line['text'] for line in case['lines'] if line['handle']==case['target'])
        examples.append(f"- **{row['id']} / {row['category']}** — {known}Target source: `{target_text.replace('`', chr(39))}` Expected: {expected} Observed: `{observed.replace(chr(10), ' ').replace('`', chr(39))}`")
    failures = '\n'.join(examples) if examples else 'Every English case passed the complete case contract.'
    worked = []
    for key, behavior in [('P33-yes', 'Updating a known residence'),
                          ('P45-yes', 'Keeping an occupation while removing salary'),
                          ('P46-yes', 'Removing health details from a useful preference'),
                          ('P43-yes', 'Resolving a relative year')]:
        if by_id[key]['perfect']:
            source = next(line['text'] for line in cases[key]['lines'] if line['handle']==cases[key]['target'])
            content = json.loads(raw[key]['content'])['items'][0]['text']
            worked.append(f'- **{behavior} ({key})** — source: “{source}” Saved: “{content}”')
    tables = {}
    for lang in ['en', 'sr']:
        lines = ['| Model / configuration | Useful memories recalled | Unwanted proposals | Empty cases correct |',
                 '|---|---:|---:|---:|']
        for model in models:
            s = scores[model['arm']+'/reviewed'][lang]
            lines.append(f"| {model['label']} ({model['quantization']}) | {ratio(s['recalled'],s['gold'])} | {s['unwanted']} | {ratio(s['clean_empty'],s['empty_cases'])} |")
        tables[lang] = '\n'.join(lines)
    setup = """The original four configurations ran sequentially with llama.cpp on the same Ryzen 7 9700X Ubuntu host. The added MemT configuration ran on Windows 11 with an Intel i5-13400F, RX 6600 XT (8 GB VRAM) and 32 GB RAM, using Transformers and an experimental NF4 expert-offload adapter. Expert weights use NF4, blocksize 64, without double quantization; dense and native-memory weights remain BF16. Compressed experts stay in system RAM and selected experts execute on the GPU. This is not an official MemT quantization or a controlled same-runtime/same-precision comparison. Timings are diagnostic, not a speed ranking.

All five use the same frozen cases, application messages, JSON schema, source handles and scoring contract. Decoding is greedy, seed 0, with thinking explicitly disabled through native chat templates, a 1024-token output cap and one completion per case. MemT uses a different schema-enforcement implementation (lm-format-enforcer). Results describe these configurations, not each model's best achievable performance.

**MemT scope:** every case starts with fresh state and all evidence in the prompt. Its official forward method bypasses the native-memory branch when no prior memory state is supplied. This measures stateless extraction by the checkpoint; it does not test the benefit or quality of MemT's persistent latent-memory feature."""
    setup += "\n\nThe pinned model card names Qwen3.6-35B-A3B as MemT's backbone. This comparison has no matched unmodified backbone control, so differences cannot be attributed specifically to MemT's training or architecture."
    scoring = """Recall requires accurate content and a valid source-line citation. Correct content with the wrong or missing handle fails recall. Unwanted proposals include true but policy-excluded information, wrong speaker attribution, known duplicates and unsupported claims. A mixed proposal can recall a useful fact while also containing unwanted information. Unwanted counts cover all cases in the slice, including cases with an eligible memory, and can exceed the case count when multiple items are emitted. Empty-case success requires a valid completion containing `{"items":[]}`. Always returning that answer would score 44/44 on English empty cases and 0/52 recall.

Cases contain at most one eligible memory. The policy excludes transient information, facts about other people and specified sensitive categories; it is one application's retention policy, not a universal definition of what memory systems should store. The synthetic pairs were assistant-authored, deliberately difficult, and are not a random sample of user logs. Semantic review was performed by an assistant with model names visible, without independent human validation. Automatic scores and every review decision are retained. No statistical-significance or general-intelligence claim is made."""
    report = f"""# Recall vs. restraint: MemT extension

The added configuration completed all 120 frozen cases. On the 96 English cases, MemT recalled **{en['recalled']}/52** eligible memories with valid source citations, emitted **{en['unwanted']}** unwanted proposals, and handled **{en['clean_empty']}/44** empty cases correctly. It had {en['errors']} invalid, incomplete or failed English completions. Interpret this as an experimental configuration result, with the runtime and native-memory limitations below.

The complete English case contract passed in **{en['perfect']}/96** cases; source selection was correct in **{en['decision_correct']}/96**. The reviewed English outputs had {en['kind_errors']} kind mismatches and {en['format_errors']} presentation/length errors. These additional constraints are distinct from the recall and unwanted-proposal counts.

## English comparison

{tables['en']}

![English comparison](memory-retention-with-memt.png)

## Configuration and scope

{setup}

Checkpoint: [MemTensor/MemT-1.0-Nano](https://huggingface.co/MemTensor/MemT-1.0-Nano), revision `30fe0b22422c4cc4c87475f98db5c8baa5c1a902`. Exact file hashes are in [model.json](model.json); the pre-inference execution identity is in [the run metadata](results/{ARM}.meta.json). The original cases, prompts, schema and scorer are unchanged. See [the frozen extension protocol](PROTOCOL_EXTENSION.md).

Execution spanned 23 and 25 October 2026. The user stopped the first session after 30 completed cases, then requested completion. The remaining cases resumed under the same frozen inference identity; the original 30-response byte stream and its 17 review decisions are preserved and checked unchanged. The interrupted case had no saved completion and was started afresh. See [execution history](RUN_HISTORY.md) and [resume verification](resume-evidence/preflight.json). No saved completion was retried or replaced.

The resumed [hardware snapshot](resume-evidence/hardware-20261025.json) records AMD driver version `32.0.21045.16010` and Windows build `26300`. Exact Python package versions, source hashes, process-local ROCm/MIOpen settings and the schema-enforcer revision are recorded in the run metadata and requirements.

## Scoring and limitations

{scoring}

The adapter passed tiny-model parity checks against the native model with the same NF4 round-trip weights: prefill, cached decode, memory commit and memory read. These establish tested implementation behavior; they do not establish zero quantization loss relative to the BF16 checkpoint. All checkpoint tensors are accounted for during loading. Tokenizer/schema checks and a separate non-benchmark empty-JSON smoke prompt passed before the actual cases.

### Frozen mechanical score and semantic review

{'\n'.join(scoring_comparison)}

The automatic score uses the original frozen handle/anchor rules and is provisional. Semantic review can accept a supported paraphrase or translation that misses an anchor, or reject a superficially matching unsupported claim. Language/script and kind errors are tracked separately. Every adjustment is traceable to the raw response and its source-evidence hash.

## Where the MemT configuration failed

{'\n'.join(issue_table)}

These labels describe the assistant's review of unwanted proposals; they count items, including unwanted extras in otherwise positive cases. Each reason and source is preserved in the semantic-review log.

{'\n'.join(categories)}

The first {min(10, len(failed))} English cases that did not satisfy the complete contract, in frozen request order, are shown below. Full case-level results and semantic decisions remain in the evidence bundle. A dash marks a category with no eligible or empty case for that metric.

{failures}

## Worked examples

{'\n'.join(worked)}

These are illustrative passing cases selected after inspection. The full-case counts and category table include every case, including failures.

## Exploratory Serbian slice

{tables['sr']}

[Serbian comparison chart](memory-retention-with-memt-serbian.png)

MemT had {sr['errors']} invalid, incomplete or failed Serbian completions. It passed the complete case contract in **{sr['perfect']}/24** cases, with {sr['kind_errors']} kind mismatches and **{sr['format_errors']} presentation/length errors**. A translation that preserves the eligible meaning and source citation can count as recall while separately failing the original-language/script requirement. These presentation flags are preserved in each semantic decision. Hy-Memory advertises English/Chinese coverage, so this slice should not be generalized to its intended language performance.

Observed Serbian failures include retained health information (`P60-no`), religious practice (`P53-no`), a request limited to today's task (`P51-no`), and English translations of Cyrillic preferences (`P56-yes` and `P56-no`). In the paired `P60-yes` case, MemT did remove the migraine detail while keeping the teaching occupation from the same sentence. These examples describe individual cases; the aggregate metrics cover the entire slice.

## Audit and reproduction

See [raw responses](results/{ARM}.jsonl), [item audit](audit.jsonl), [semantic decisions](review.json), [automatic and reviewed scores](scores.json), [case details](details.json), [chart data](chart-data.csv), and [validation output](validation.txt). The [Reddit draft](REDDIT_DRAFT.md) is unposted. The [combined evidence bundle](share-bundle-with-memt.zip) includes the original experiment plus this extension; it excludes model weights and the application-source snapshot. This report and evidence are submitted through the benchmark pull request. The Reddit draft remains unposted.
"""
    draft = f"""# Reddit draft — not posted

**Title:** Recall vs. Restraint: Testing when local LLMs should save nothing (Qwen3.5, Hy-Memory, LFM2.5, MemT)

I’m building LokalBot, a local work-memory app, and wanted to test a specific failure mode in memory extraction: **can a local model capture useful facts while obeying explicit rules about what to ignore?**

A good memory writer needs both recall and restraint. “I live in Valencia” should save a memory; “My colleague said, ‘I live in Valencia’” should not. A new preference should be saved; the same preference already in the known-memories list should be skipped. A job title mentioned alongside a salary should be kept without the salary, under this particular retention policy.

The test set has **120 synthetic cases / 60 contrast pairs**. The main comparison is the **96 English cases**: 52 containing one useful memory and 44 where the only correct answer is an empty items list. There is a separate 24-case Serbian slice in the bundle.

**Thinking was disabled in every configuration.** These are application-configuration results, not claims about the models at their best settings.

{tables['en']}

*Attach `memory-retention-with-memt.png` here.*

Hy-Memory captured all 52 eligible English facts, but emitted 76 unwanted items and failed all 44 empty-output cases. The Qwen models were more selective under this prompt and configuration, while missing more useful memories. LFM recalled 40/52 and emitted 53 unwanted proposals; some outputs copied “I live in Belgrade” from a prompt example without supporting evidence.

**MemT’s added configuration recalled {en['recalled']}/52, emitted {en['unwanted']} unwanted proposals and passed {en['clean_empty']}/44 empty cases.** There is an important qualification: I ran it with experimental NF4 expert offload on my Windows RX 6600 XT, using Transformers. The original four used GGUFs and llama.cpp on an Ubuntu Ryzen 7 9700X. The prompt, cases and scoring contract are identical, but runtime, hardware, quantization and schema enforcement differ. This is not a speed comparison or a controlled quantization comparison.

Two English failure examples: it returned an empty answer when the user explicitly changed a known preference from prose to bullet points, and it saved a political affiliation and campaign donation despite the exclusion rule. Both outputs are in the bundle.

**This also does not evaluate MemT’s native persistent-memory feature.** Every case starts fresh with the evidence in context; no prior latent-memory state is supplied. It tests stateless memory extraction by that checkpoint. A commit-and-recall experiment would be a different benchmark.

MemT uses a Qwen3.6-35B-A3B backbone; I did not run a matched unmodified-backbone control, so these scores do not isolate the effect of MemT’s training.

**Scoring:** A recalled memory needs both accurate content and the correct source-line citation ID. A correct fact with a wrong or missing ID fails the contract. “Unwanted” does not mean everything was hallucinated: many proposals are true things the policy forbids saving, alongside duplicates, misattributed quotes and unsupported additions. Always returning `{{"items":[]}}` gets 44/44 empty cases and 0/52 recall, which is why both metrics matter.

Unwanted proposal counts cover all 96 English cases, including positive cases, and a model can emit several unwanted items in one answer.

**Setup:** same frozen application messages and JSON schema; native chat templates; greedy decoding, seed 0, thinking disabled, one completed response per case, maximum 1024 output tokens. MemT’s experimental adapter preserves dense and memory weights in BF16 and stores experts in NF4. It passed numerical parity checks against a tiny native model with the same quantized weights before the benchmark. That is an implementation check, not evidence of lossless quantization.

MemT ran in two sessions (23 and 25 October): I stopped after 30 completed cases, then resumed the remaining cases with the same pinned configuration. The original responses were retained; no saved completion was rerun or replaced.

**Limitations:** Assistant-authored synthetic edge cases, at most one target memory per case, and semantic grading performed by an assistant with model names visible. No independent human validation or statistical-significance claim. This tests one personal-memory retention policy, not long-term retrieval or general intelligence. The separate Serbian slice should not be used to judge Hy-Memory’s advertised English/Chinese coverage.

**Evidence bundle:** [add the reviewed GitHub PR or bundle download link before posting] — frozen cases, full prompts, exact revisions and hashes, raw completions, scorer, semantic-review decisions, runtime/adapter code and chart data. The report and bundle are published through the benchmark pull request; this Reddit draft has not been posted.

What retention rule or edge case would you add as a paired test? I’d particularly appreciate a second pair of eyes on the gold labels and disputed outputs.
"""
    (ROOT/'REPORT.md').write_text(report)
    (ROOT/'REDDIT_DRAFT.md').write_text(draft)
    readme = f"""# MemT-1.0-Nano: completed memory-retention benchmark

**120/120 cases complete.** Primary English slice: **{en['recalled']}/52** useful memories recalled with valid source citations, **{en['unwanted']}** unwanted proposals, and **{en['clean_empty']}/44** empty cases correct. The complete English case contract passed in {en['perfect']}/96 cases. The separate 24-case Serbian slice is exploratory.

- [Full report](REPORT.md)
- [English chart](memory-retention-with-memt.png) and [SVG](memory-retention-with-memt.svg)
- [Serbian chart](memory-retention-with-memt-serbian.png)
- [Reddit draft — unposted](REDDIT_DRAFT.md)
- [Combined evidence bundle](share-bundle-with-memt.zip)
- [Raw responses](results/{ARM}.jsonl), [scores](scores.json), [review decisions](review.json), [chart data](chart-data.csv), and [validation](validation.txt)

The cases were frozen on 23 October 2026. MemT ran on 23 and 25 October, using the same pinned configuration. The first 30 responses and their 17 review decisions are preserved unchanged in [resume-evidence/](resume-evidence/); [RUN_HISTORY.md](RUN_HISTORY.md) explains the user-requested stop and resume. The original four-model report and evidence remain in the parent directory.

This is stateless extraction with thinking disabled. Every case starts fresh, so it does not exercise MemT's persistent latent-memory feature. MemT uses experimental NF4 expert offload on a Windows RX 6600 XT; the other configurations use GGUFs and llama.cpp on Ubuntu. Hardware, runtime, quantization and schema-enforcement implementations differ. These are configuration-specific accuracy results, with synthetic cases and unblinded assistant-performed semantic review.

## Audit and reproduce scoring

Run `analyze.py` to reproduce the automatic and reviewed scores from the saved responses, then `validate_results.py` to check frozen inputs, the preserved initial prefix, every semantic decision, score aggregates and chart values. Neither command performs inference. `chart.py` renders the standalone figures using Matplotlib; `build_report.py` regenerates the report, draft and this index. `package_evidence.py` builds and verifies the local ZIP.

The [frozen extension protocol](PROTOCOL_EXTENSION.md), [model manifest](model.json), [verified checkpoint receipt](verified-model-files.json), [runtime requirements](requirements-observed.txt), [inference runner](run_windows.py), and [expert-offload adapter](nf4_offload.py) preserve the tested setup. [Numerical validation](adapter-model-validation.json), [tokenizer validation](tokenizer-validation.json), and [smoke result](smoke-result.json) cover preparation checks. The initial memory-mapped loading failure is preserved in [preparation-failures/](preparation-failures/); the successful loader uses the documented `pread` backend.

The checkpoint itself is downloaded separately through `download_model.py`. Before inference, copy the parent directory's frozen `cases.json`, `prompts.json`, `schema.json`, `score.py` and `frozen.json` beside the runner. The isolated Windows runtime uses AMD PyTorch and process-local `BNB_ROCM_VERSION=714`, `MIOPEN_FIND_MODE=FAST`. The runner verifies identity before resuming, preserves every saved response, and runs an unscored smoke prompt before benchmark cases. See the execution history for the exact existing run.

The report and evidence are submitted through the benchmark pull request. No paid GPU was rented, and the Reddit draft has not been posted. The frozen protocol and archived partial-run materials retain their original publication-status wording.
"""
    (ROOT/'README.md').write_text(readme)
    print('Wrote reviewed-result report, unposted draft and completed-run index.')


if __name__ == '__main__':
    main()
