"""Score every system without new inference.

AMI chunks are scored against their human references. LokalBot meeting chunks have
no human reference, so each system is scored against a leave-family-out consensus:
a backbone ROVER vote over the systems from *other* vendor families, with each
family's votes summing to one. That measures agreement, not ground truth.
"""
import argparse
import json
import random
import statistics

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

from common import DATA, ROOT, SYSTEMS, load_manifest, load_output
from run_api import PRICES, cost as price

SPELLING = ROOT.parent / 'ModelAlternatives' / '2026-09-07' / 'english-spelling.json'
RUN = 4  # consecutive inserted/deleted words that count as a hallucinated/dropped span
LOW_OVERLAP = 0.3  # AMI windows with less overlapped talk, reported as a secondary subset
MIN_COVERAGE = 0.9  # systems below this share of finished chunks are left out of a set's table
BOOTSTRAP = 2000

normalize = EnglishTextNormalizer(json.loads(SPELLING.read_text()))


def words(text):
    return normalize(text or '').split()


def align(ref, hyp):
    """Full alignment path as (ref index | None, hyp index | None) pairs."""
    path, i, j = [], 0, 0
    for tag, src, dst in Levenshtein.editops(ref, hyp):
        while i < src and j < dst:
            path.append((i, j))
            i, j = i + 1, j + 1
        if tag == 'replace':
            path.append((i, j))
            i, j = i + 1, j + 1
        elif tag == 'delete':
            path.append((i, None))
            i += 1
        else:
            path.append((None, j))
            j += 1
    while i < len(ref) and j < len(hyp):
        path.append((i, j))
        i, j = i + 1, j + 1
    path += [(k, None) for k in range(i, len(ref))] + [(None, k) for k in range(j, len(hyp))]
    return path


def errors(ref, hyp):
    counts = {'ref_words': len(ref), 'sub': 0, 'del': 0, 'ins': 0, 'ins_run_words': 0, 'del_run_words': 0}
    run_kind, run_len = None, 0

    def close():
        if run_len >= RUN:
            counts[f'{run_kind}_run_words'] += run_len

    for r, h in align(ref, hyp):
        kind = 'ins' if r is None else 'del' if h is None else ('sub' if ref[r] != hyp[h] else None)
        if kind:
            counts[kind] += 1
        if kind in ('ins', 'del') and kind == run_kind:
            run_len += 1
        else:
            close()
            run_kind, run_len = (kind, 1) if kind in ('ins', 'del') else (None, 0)
    close()
    return counts


def consensus(hyps, weights):
    """Backbone ROVER: the medoid hypothesis, then a weighted vote per aligned slot."""
    names = list(hyps)
    if not names:
        return []
    distance = {a: sum(weights[b] * Levenshtein.distance(hyps[a], hyps[b]) for b in names if b != a)
                for a in names}
    backbone = min(names, key=lambda n: (distance[n], n))
    base = hyps[backbone]
    slots = [{} for _ in base]
    gaps = [{} for _ in range(len(base) + 1)]
    for name in names:
        weight = weights[name]
        inserted = {k: [] for k in range(len(base) + 1)}
        position = 0
        for r, h in align(base, hyps[name]):
            if r is None:
                inserted[position].append(hyps[name][h])
            else:
                word = None if h is None else hyps[name][h]
                slots[r][word] = slots[r].get(word, 0) + weight
                position = r + 1
        for k, seq in inserted.items():
            key = tuple(seq)
            gaps[k][key] = gaps[k].get(key, 0) + weight
    out = []
    for k in range(len(base) + 1):
        votes = gaps[k]
        best = max(votes, key=lambda s: (round(votes[s], 6), s == ())) if votes else ()
        out.extend(best)
        if k < len(base):
            votes = slots[k]
            word = max(votes, key=lambda w: (round(votes[w], 6), w == base[k]))
            if word is not None:
                out.append(word)
    return out


def family_weights(names):
    per_family = {}
    for name in names:
        per_family[SYSTEMS[name][0]] = per_family.get(SYSTEMS[name][0], 0) + 1
    return {name: 1 / per_family[SYSTEMS[name][0]] for name in names}


def summarize(chunks):
    total = {k: sum(c[k] for c in chunks) for k in
             ['ref_words', 'sub', 'del', 'ins', 'ins_run_words', 'del_run_words']}
    n = max(total['ref_words'], 1)
    total['wer'] = (total['sub'] + total['del'] + total['ins']) / n
    for k in ['sub', 'del', 'ins', 'ins_run_words', 'del_run_words']:
        total[f'{k}_rate'] = total[k] / n
    return total


def bootstrap(per_system, systems, seed=7):
    """Chunk-level bootstrap: 95% WER intervals and P(system beats the best)."""
    ids = sorted(next(iter(per_system.values())))
    rng = random.Random(seed)
    samples = {s: [] for s in systems}
    for _ in range(BOOTSTRAP):
        pick = [rng.choice(ids) for _ in ids]
        for s in systems:
            err = sum(per_system[s][i]['sub'] + per_system[s][i]['del'] + per_system[s][i]['ins'] for i in pick)
            samples[s].append(err / max(sum(per_system[s][i]['ref_words'] for i in pick), 1))
    best = min(systems, key=lambda s: statistics.mean(samples[s]))
    result = {}
    for s in systems:
        ordered = sorted(samples[s])
        result[s] = {'ci95': [ordered[int(0.025 * BOOTSTRAP)], ordered[int(0.975 * BOOTSTRAP) - 1]],
                     'p_better_than_best': sum(a < b for a, b in zip(samples[s], samples[best])) / BOOTSTRAP}
    return best, result


def runtime(records):
    done = [r for r in records if r and r.get('text') is not None]
    for r in done:  # recompute from the current price table
        if r['system'] in PRICES:
            r['cost_usd'] = price(r['system'], r.get('usage'), r['audio_seconds'])[0]
    audio = sum(r['audio_seconds'] for r in done)
    latency = [r['latency_seconds'] for r in done if r.get('latency_seconds') is not None]
    return {'chunks_ok': len(done), 'chunks_failed': sum(1 for r in records if r and r.get('text') is None),
            'chunks_missing': sum(1 for r in records if r is None),
            'audio_minutes': round(audio / 60, 2),
            'median_latency_s': round(statistics.median(latency), 2) if latency else None,
            'speed_x_realtime': round(audio / sum(latency), 1) if latency else None,
            'cost_usd': round(sum(r.get('cost_usd') or 0 for r in done), 4),
            'usd_per_audio_hour': round(sum(r.get('cost_usd') or 0 for r in done) / (audio / 3600), 3)
            if audio else None}


def score(rows, systems, with_reference):
    per_system = {s: {} for s in systems}
    details = []
    for row in rows:
        outputs = {s: load_output(s, row['id']) for s in systems}
        hyps = {s: words((o or {}).get('text')) for s, o in outputs.items()}
        if with_reference:
            refs = {s: words(row['reference']) for s in systems}
        else:
            refs = {}
            for s in systems:
                voters = [v for v in systems if SYSTEMS[v][0] != SYSTEMS[s][0]
                          and SYSTEMS[v][1] != 'production'
                          and (outputs[v] or {}).get('text') is not None]
                refs[s] = consensus({v: hyps[v] for v in voters}, family_weights(voters))
        for s in systems:
            per_system[s][row['id']] = errors(refs[s], hyps[s])
        details.append({'chunk': row['id'], 'hypotheses': {s: ' '.join(h) for s, h in hyps.items()},
                        'references': {s: ' '.join(r) for s, r in refs.items()}})
    best, intervals = bootstrap(per_system, systems)
    table = {}
    for s in systems:
        table[s] = {'label': SYSTEMS[s][2], 'family': SYSTEMS[s][0], 'kind': SYSTEMS[s][1],
                    **summarize(list(per_system[s].values())), **intervals[s],
                    **runtime([load_output(s, r['id']) for r in rows])}
        by_source = {}
        for row in rows:
            key = f'{row["source"]}/{row["track"]}' if not with_reference else row['source']
            by_source.setdefault(key, []).append(per_system[s][row['id']])
        table[s]['by_source'] = {k: round(summarize(v)['wer'], 4) for k, v in by_source.items()}
        if with_reference:
            low = [per_system[s][r['id']] for r in rows if overlap_share(r) < LOW_OVERLAP]
            table[s]['low_overlap'] = {'chunks': len(low), 'ref_words': sum(c['ref_words'] for c in low),
                                       'wer': round(summarize(low)['wer'], 4)}
    return {'best': best, 'systems': table}, details


def overlap_share(row):
    """Share of reference words in utterances that overlap another utterance in time."""
    utterances = json.loads((DATA / 'source' / 'ami' / f'{row["source"]}.utterances.json').read_text())
    window = [u for u in utterances if row['start'] - 0.01 <= u['begin'] and u['end'] <= row['end'] + 0.01]
    total = sum(len(u['text'].split()) for u in window)
    overlapped = sum(len(u['text'].split()) for u in window
                     if any(v is not u and v['begin'] < u['end'] and u['begin'] < v['end'] for v in window))
    return overlapped / max(total, 1)


def print_table(title, result):
    print(f'\n## {title} (best: {result["best"]})')
    low = 'low_overlap' in next(iter(result['systems'].values()))
    print('| System | WER | 95% CI |' + (' Low-overlap WER |' if low else '')
          + ' Sub | Del | Ins | Halluc. runs | Dropped runs | Failed | Median latency | Cost/hr |')
    print('|---|---:|---:|' + ('---:|' if low else '') + '---:|---:|---:|---:|---:|---:|---:|---:|')
    for s, r in sorted(result['systems'].items(), key=lambda kv: kv[1]['wer']):
        extra = f' {r["low_overlap"]["wer"]:.2%} |' if low else ''
        print(f'| {r["label"]} | {r["wer"]:.2%} | {r["ci95"][0]:.1%}–{r["ci95"][1]:.1%} |{extra} {r["sub_rate"]:.1%} | '
              f'{r["del_rate"]:.1%} | {r["ins_rate"]:.1%} | {r["ins_run_words"]} | {r["del_run_words"]} | '
              f'{r["chunks_failed"] + r["chunks_missing"]} | {r["median_latency_s"]}s | '
              f'${r["usd_per_audio_hour"] if r["usd_per_audio_hour"] is not None else 0:.2f} |')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--systems', nargs='*', default=None)
    parser.add_argument('--results', default=str(ROOT / 'results' / 'latest'))
    args = parser.parse_args()
    manifest = load_manifest()
    systems = args.systems or [s for s in SYSTEMS if (DATA / 'outputs' / s).exists()]
    summary, private = {}, {}
    for name, with_reference in [('ami', True), ('meetings', False)]:
        rows = [r for r in manifest if r['set'] == name]
        done = {s: {r['id'] for r in rows if (load_output(s, r['id']) or {}).get('text') is not None}
                for s in systems}
        coverage = {s: len(done[s]) / len(rows) for s in systems if done[s]}
        # Score on the chunks every sufficiently complete system finished, so a
        # quota-limited run is neither penalized nor silently compared on other audio.
        ran = [s for s, share in coverage.items() if share >= MIN_COVERAGE]
        if not rows or not ran:
            continue
        common = [r for r in rows if all(r['id'] in done[s] for s in ran)]
        summary[name], private[name] = score(common, ran, with_reference)
        summary[name]['chunks'] = len(common)
        summary[name]['audio_minutes'] = round(sum(r['duration'] for r in common) / 60, 1)
        summary[name]['excluded_chunks'] = len(rows) - len(common)
        summary[name]['coverage'] = {s: round(v, 3) for s, v in coverage.items()}
        summary[name]['excluded_systems'] = sorted(set(coverage) - set(ran))
        print_table('AMI, human reference' if with_reference else 'LokalBot meetings, leave-family-out consensus',
                    summary[name])
        print(f'{len(common)}/{len(rows)} chunks, {summary[name]["audio_minutes"]} min; '
              f'excluded systems: {summary[name]["excluded_systems"] or "none"}')
    out = DATA / 'results'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'details.json').write_text(json.dumps(private, indent=1, ensure_ascii=False))
    public = ROOT / args.results
    public.mkdir(parents=True, exist_ok=True)
    (public / 'summary.json').write_text(json.dumps(summary, indent=1))
    print(f'\nWrote {public / "summary.json"} (aggregates only) and {out / "details.json"} (private).')


if __name__ == '__main__':
    main()
