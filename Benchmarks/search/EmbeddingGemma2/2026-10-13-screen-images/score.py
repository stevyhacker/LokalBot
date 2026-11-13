"""Known-item scoring for text, image and fused screen search. CPU only.

A query hits when a result shares the target's similarity group (the target
itself or a near-duplicate capture). Keyword search runs the app's FTS query
against the snapshot's own `ocr_fts`, restricted to the embedded corpus.
`--publish PATH` writes aggregate numbers only.
"""
import argparse
import json
import random
import re
import sqlite3
from collections import defaultdict
from pathlib import Path

import numpy as np

ROOT = Path('/private/tmp/lokalbot-screen-images-20261013')
PRIVATE = ROOT / 'private'
SNAPSHOT = ROOT / 'library.sqlite'
INDEX_VERSION = 'embeddinggemma-2-q8-mean-768-v1'
SCREEN_FLOOR = 0.58  # EmbeddingIndex.screenSimilarityFloor
SEMANTIC_LIMIT = 200  # RecallWorkspaceState semantic screen limit
RRF_K = 60
DRAWS = 10_000
STOP_WORDS = set("""a an the and or but if of to in on at for with about as by from into is are was were be
been being do does did doing have has had what when where who whom which why how we i you he she it they
me us them my our your this that these those can could would should will shall may might must any some
there""".split())  # SearchIndex.stopWords
SR_STOP = set(('je da i se na u to što sto ali nije ovo za sa od kao samo ima smo su bi li ja ti mi '
               'ne ni kad kada jer pa ako koji koja koje tako treba može moze').split())
WORD = re.compile(r'\w+', re.UNICODE)
SYSTEMS = {
    'keyword': ('fts',),
    'text': ('text',),
    'text, no floor': ('text_nofloor',),
    'image': ('image',),
    'production (keyword + text)': ('fts', 'text'),
    'text + image': ('text', 'image'),
    'keyword + image': ('fts', 'image'),
    'proposed (keyword + text + image)': ('fts', 'text', 'image'),
}
COMPARISONS = [
    ('image', 'text'),
    ('image', 'text, no floor'),
    ('text + image', 'text'),
    ('proposed (keyword + text + image)', 'production (keyword + text)'),
]


def fts_query(raw, match_all=True, drop_stop_words=False):
    """Port of SearchIndex.ftsQuery."""
    terms = [t.replace('"', '') for t in raw.split()]
    terms = [t for t in terms if t]
    if drop_stop_words:
        content = [t for t in terms if t.lower() not in STOP_WORDS]
        terms = content or terms
    if not terms:
        return None
    if not match_all:
        return ' OR '.join(f'"{t}"' for t in terms)
    return ' '.join(f'"{t}" *' if i == len(terms) - 1 else f'"{t}"' for i, t in enumerate(terms))


def keyword_ranking(database, text, ids):
    """Mirror of RecallWorkspaceState: AND-match first, OR without stop words if empty.
    Returns the ranking and which query form produced it."""
    placeholders = ','.join('?' * len(ids))
    for match_all, drop in ((True, False), (False, True)):
        match = fts_query(text, match_all, drop)
        if match is None:
            return [], 'none'
        rows = database.execute(f"""
            SELECT CAST(ocr_fts.snapshot_id AS INTEGER) FROM ocr_fts
            JOIN screenshots AS shot ON shot.id = CAST(ocr_fts.snapshot_id AS INTEGER)
            WHERE ocr_fts MATCH ? AND CAST(ocr_fts.snapshot_id AS INTEGER) IN ({placeholders})
            ORDER BY ocr_fts.rank, CAST(ocr_fts.ts AS REAL) DESC, shot.id LIMIT 2000""",
                                [match, *ids]).fetchall()
        if rows:
            return [row[0] for row in rows], 'and' if match_all else 'or'
    return [], 'none'


def semantic_ranking(vectors, query, ids, floor=None):
    scores = vectors @ query
    order = np.argsort(-scores, kind='stable')
    if floor is not None:
        order = [i for i in order if scores[i] > floor]
    return [ids[i] for i in order[:SEMANTIC_LIMIT]]


def fuse(rankings, lexical_first):
    """ScreenSearchRanker.fuse generalised to any number of lists. With
    `lexical_first`, list 0 is keyword search and wins equal fused scores."""
    ranks = [{sid: position + 1 for position, sid in reversed(list(enumerate(ranking)))} for ranking in rankings]

    def key(sid):
        score = sum(1 / (RRF_K + r[sid]) for r in ranks if sid in r)
        best = min(r.get(sid, 10 ** 9) for r in ranks)
        return (-score, lexical_first and sid not in ranks[0], best, sid)
    return sorted(set().union(*ranks), key=key)


def first_hit(ranking, relevant):
    for position, sid in enumerate(ranking):
        if sid in relevant:
            return position + 1
    return None


def metrics(ranks):
    n = len(ranks)
    return {
        'queries': n,
        'top1': sum(r == 1 for r in ranks),
        'top5': sum(r is not None and r <= 5 for r in ranks),
        'found': sum(r is not None for r in ranks),
        'mrr': round(sum(1 / r for r in ranks if r) / n, 3) if n else None,
    }


def bootstrap(rows, system_a, system_b, cutoff):
    by_target = defaultdict(list)
    for row in rows:
        a, b = row['ranks'][system_a], row['ranks'][system_b]
        by_target[row['target']].append(((a is not None and a <= cutoff) - (b is not None and b <= cutoff)))
    clusters = list(by_target.values())
    total = sum(len(c) for c in clusters)
    observed = sum(map(sum, clusters)) / total
    rng = random.Random(61013)
    draws = []
    for _ in range(DRAWS):
        sample = [clusters[rng.randrange(len(clusters))] for _ in clusters]
        draws.append(sum(map(sum, sample)) / sum(map(len, sample)))
    draws.sort()
    return {'points': round(100 * observed, 1),
            'ci95': [round(100 * draws[int(.025 * DRAWS)], 1), round(100 * draws[int(.975 * DRAWS)], 1)]}


def language(text):
    words = [w.lower() for w in WORD.findall(text)]
    return (sum(w in SR_STOP for w in words) + 2 * sum(c in 'čćšžđČĆŠŽĐ' for c in text)) > 0


def bcs_check(queries):
    """Is content_bcs a translation, not a copy? Aggregates only."""
    by_target = defaultdict(dict)
    for query in queries:
        by_target[query['target']][query['kind']] = query['text']
    pairs = [(q['content_en'], q['content_bcs']) for q in by_target.values()
             if 'content_en' in q and 'content_bcs' in q]

    def words(text):
        return {w.lower() for w in WORD.findall(text)}
    overlap = [len(words(en) & words(bcs)) / max(1, len(words(en) | words(bcs))) for en, bcs in pairs]
    return {
        'pairs': len(pairs),
        'identical': sum(en.strip().lower() == bcs.strip().lower() for en, bcs in pairs),
        'mean_word_jaccard': round(float(np.mean(overlap)), 3) if overlap else None,
        'english_stop_word_share': round(float(np.mean([
            np.mean([w in STOP_WORDS for w in WORD.findall(bcs.lower())] or [0]) for _, bcs in pairs])), 3),
        'serbian_letters_or_stop_words': round(float(np.mean([language(bcs) for _, bcs in pairs])), 3),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--publish', type=Path)
    arguments = parser.parse_args()

    corpus = {shot['id']: shot for shot in json.loads((PRIVATE / 'corpus.json').read_text())}
    ids = json.loads((PRIVATE / 'embedded-ids.json').read_text())
    queries = json.loads((PRIVATE / 'queries.json').read_text())
    query_vectors = np.load(PRIVATE / 'query-vectors.npy')
    text_vectors = np.load(PRIVATE / 'text-vectors.npy')
    image_vectors = np.load(PRIVATE / 'image-vectors.npy')
    meta = json.loads((PRIVATE / 'run-meta.json').read_text())
    assert len(ids) == len(text_vectors) == len(image_vectors) and len(queries) == len(query_vectors)
    group_members = defaultdict(set)
    for sid in ids:
        group_members[corpus[sid]['group']].add(sid)
    position = {sid: i for i, sid in enumerate(ids)}

    database = sqlite3.connect(f'file:{SNAPSHOT}?mode=ro', uri=True)
    stored = {}
    for sid, blob in database.execute(
            f"SELECT snapshot_id, vec FROM screen_embeddings WHERE model_id = ? AND snapshot_id IN "
            f"({','.join('?' * len(ids))})", [INDEX_VERSION, *ids]):
        vector = np.frombuffer(blob, dtype='<f4')
        stored[sid] = vector / np.linalg.norm(vector)
    parity = [float(stored[sid] @ text_vectors[position[sid]]) for sid in stored]

    rows = []
    target_image_scores, unrelated_image_scores = [], []
    target_text_scores, unrelated_text_scores = [], []
    rng = np.random.default_rng(61013)
    for query, vector in zip(queries, query_vectors):
        target = query['target']
        relevant = group_members[corpus[target]['group']]
        keyword, keyword_mode = keyword_ranking(database, query['text'], ids)
        lists = {
            'fts': keyword,
            'text': semantic_ranking(text_vectors, vector, ids, SCREEN_FLOOR),
            'text_nofloor': semantic_ranking(text_vectors, vector, ids),
            'image': semantic_ranking(image_vectors, vector, ids),
        }
        ranks = {}
        for name, parts in SYSTEMS.items():
            if len(parts) == 1:
                ranking = lists[parts[0]]
            else:
                ranking = fuse([lists[p] for p in parts], lexical_first=parts[0] == 'fts')
            ranks[name] = first_hit(ranking, relevant)
        rows.append({'target': target, 'kind': query['kind'], 'ranks': ranks, 'keyword_mode': keyword_mode})
        scores = image_vectors @ vector
        text_scores = text_vectors @ vector
        target_image_scores.append(float(scores[position[target]]))
        target_text_scores.append(float(text_scores[position[target]]))
        unrelated = [i for i in rng.choice(len(ids), 40, replace=False) if ids[i] not in relevant]
        unrelated_image_scores.extend(float(scores[i]) for i in unrelated)
        unrelated_text_scores.extend(float(text_scores[i]) for i in unrelated)

    kinds = sorted({row['kind'] for row in rows})
    result = {
        'run': meta,
        'corpus_screens': len(ids),
        'corpus_similarity_groups': len(group_members),
        'targets': len({row['target'] for row in rows}),
        'queries': len(rows),
        'text_vector_parity_with_production': {
            'compared': len(parity), 'min_cosine': round(min(parity), 6) if parity else None,
            'median_cosine': round(float(np.median(parity)), 6) if parity else None},
        'systems': {name: {'all': metrics([r['ranks'][name] for r in rows]),
                           **{kind: metrics([r['ranks'][name] for r in rows if r['kind'] == kind])
                              for kind in kinds}}
                    for name in SYSTEMS},
        'paired_differences': {
            f'{a} vs {b}': {
                cutoff_name: {'all': bootstrap(rows, a, b, cutoff),
                              **{kind: bootstrap([r for r in rows if r['kind'] == kind], a, b, cutoff)
                                 for kind in kinds}}
                for cutoff_name, cutoff in (('top1', 1), ('top5', 5))}
            for a, b in COMPARISONS},
        'keyword_query_form': {
            mode: {'queries': len(subset),
                   **{name: metrics([r['ranks'][name] for r in subset])
                      for name in ('keyword', 'text', 'production (keyword + text)')}}
            for mode in ('and', 'or', 'none')
            for subset in [[r for r in rows if r['keyword_mode'] == mode]] if subset},
        'floors': {
            'image': {f'{floor:.2f}': {
                'targets_kept': round(float(np.mean(np.array(target_image_scores) > floor)), 3),
                'unrelated_kept': round(float(np.mean(np.array(unrelated_image_scores) > floor)), 3)}
                for floor in (0.60, 0.62, 0.64, 0.66, 0.68)},
            'text': {f'{floor:.2f}': {
                'targets_kept': round(float(np.mean(np.array(target_text_scores) > floor)), 3),
                'unrelated_kept': round(float(np.mean(np.array(unrelated_text_scores) > floor)), 3)}
                for floor in (0.55, SCREEN_FLOOR, 0.60)},
        },
        'image_cosine': {
            'target_median': round(float(np.median(target_image_scores)), 3),
            'target_p10': round(float(np.percentile(target_image_scores, 10)), 3),
            'unrelated_median': round(float(np.median(unrelated_image_scores)), 3),
            'unrelated_p99': round(float(np.percentile(unrelated_image_scores, 99)), 3),
        },
        'query_quality': {
            kind: {
                'mean_words': round(float(np.mean([len(q['text'].split()) for q in queries if q['kind'] == kind])), 1),
                'content_words_on_screen': round(float(np.mean([
                    np.mean([w.lower() in corpus[q['target']]['text'].lower() for w in WORD.findall(q['text'])
                             if w.lower() not in STOP_WORDS] or [0])
                    for q in queries if q['kind'] == kind])), 3),
                'looks_bcs': round(float(np.mean([language(q['text']) for q in queries if q['kind'] == kind])), 3),
            } for kind in kinds},
        'bcs_vs_english_query': bcs_check(queries),
    }
    print(json.dumps(result, indent=1, ensure_ascii=False))
    if arguments.publish:
        arguments.publish.parent.mkdir(parents=True, exist_ok=True)
        arguments.publish.write_text(json.dumps(result, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
