"""Extract the indexed corpus from a library snapshot and sample query targets.

Input is a read-only `.backup` copy of the user's lokalbotv3.sqlite. Output
stays in the private disposable folder: it contains real transcript and OCR
text and must never be copied into the repository.
"""
import json
import random
import re
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-reallib')
SNAPSHOT = ROOT / 'library.sqlite'
INDEX_VERSION = 'harrier-oss-v1-0.6b-q8-last-chunks-v1'
MEETING_TARGETS = 150
SCREEN_TARGETS = 100
BCS_EXTRA = 30
SEED = 61007

EN_STOP = set('the and is are to of that this it in for on with you we was be have not what but so can will'.split())
SR_STOP = set(('je da i se na u to što sto ali nije ovo za sa od kao samo ima smo su bi li ja ti mi '
               'ne ni kad kada jer pa ako koji koja koje tako treba može moze').split())
WORD = re.compile(r'\w+', re.UNICODE)


def language(text):
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 'unknown'
    if sum('Ѐ' <= c <= 'ӿ' for c in letters) / len(letters) > .3:
        return 'bcs'
    words = [w.lower() for w in WORD.findall(text)]
    sr = sum(w in SR_STOP for w in words) + 2 * sum(c in 'čćšžđČĆŠŽĐ' for c in text)
    en = sum(w in EN_STOP for w in words)
    if sr == en == 0:
        return 'unknown'
    return 'bcs' if sr > en else 'en'


def vector(blob):
    values = np.frombuffer(blob, dtype='<f4')
    assert values.shape == (1024,) and np.isfinite(values).all()
    return values / np.linalg.norm(values)


def main():
    database = sqlite3.connect(f'file:{SNAPSHOT}?mode=ro', uri=True)
    assert {row[0] for row in database.execute('SELECT model_id FROM embedded_meetings')} == {INDEX_VERSION}
    meetings = [
        {'id': f'm{rowid}', 'meeting_id': meeting_id, 'start': start, 'text': text}
        for rowid, meeting_id, start, text in database.execute(
            'SELECT rowid, meeting_id, start, text FROM embeddings ORDER BY rowid')]
    meeting_vectors = np.stack([vector(blob) for (blob,) in database.execute(
        'SELECT vec FROM embeddings ORDER BY rowid')])
    screens = [
        {'id': f's{snapshot_id}', 'snapshot_id': snapshot_id, 'ts': ts, 'app': app, 'text': text,
         'group': group}
        for snapshot_id, ts, app, text, group in database.execute("""
            SELECT e.snapshot_id, e.ts, e.app, e.text, s.similarity_group
            FROM screen_embeddings AS e JOIN screenshots AS s ON s.id = e.snapshot_id
            WHERE e.model_id = ?1 ORDER BY e.snapshot_id""", (INDEX_VERSION,))]
    screen_vectors = np.stack([vector(blob) for (blob,) in database.execute(
        'SELECT vec FROM screen_embeddings WHERE model_id = ?1 ORDER BY snapshot_id', (INDEX_VERSION,))])
    for row in meetings + screens:
        row['language'] = language(row['text'])

    rng = random.Random(SEED)
    by_meeting = defaultdict(list)
    for row in meetings:
        if len(row['text']) >= 150 and row['language'] != 'unknown':
            by_meeting[row['meeting_id']].append(row)
    candidates = []
    for rows in by_meeting.values():
        candidates.extend(rng.sample(rows, min(2, len(rows))))
    meeting_targets = rng.sample(candidates, min(MEETING_TARGETS, len(candidates)))
    # The library is mostly English; add a small BCS set so same-language
    # Serbian/Montenegrin retrieval is measured on more than one passage.
    chosen, per_meeting = {row['id'] for row in meeting_targets}, Counter()
    for row in rng.sample(meetings, len(meetings)):
        if (row['language'] == 'bcs' and len(row['text']) >= 150 and row['id'] not in chosen
                and per_meeting[row['meeting_id']] < 3):
            meeting_targets.append(row)
            per_meeting[row['meeting_id']] += 1
            if sum(per_meeting.values()) == BCS_EXTRA:
                break

    seen_groups, per_app = set(), Counter()
    screen_targets = []
    for row in rng.sample(screens, len(screens)):
        if len(row['text']) < 200 or row['language'] == 'unknown':
            continue
        if row['group'] and row['group'] in seen_groups:
            continue
        if per_app[row['app']] >= 12:
            continue
        seen_groups.add(row['group'])
        per_app[row['app']] += 1
        screen_targets.append(row)
        if len(screen_targets) == SCREEN_TARGETS:
            break

    (ROOT / 'corpus').mkdir(exist_ok=True)
    (ROOT / 'corpus/meetings.json').write_text(json.dumps(meetings, ensure_ascii=False))
    (ROOT / 'corpus/screens.json').write_text(json.dumps(screens, ensure_ascii=False))
    np.save(ROOT / 'corpus/harrier-meetings.npy', meeting_vectors)
    np.save(ROOT / 'corpus/harrier-screens.npy', screen_vectors)
    targets = ([{'corpus': 'meetings', 'target': row['id']} for row in meeting_targets]
               + [{'corpus': 'screens', 'target': row['id']} for row in screen_targets])
    (ROOT / 'corpus/targets.json').write_text(json.dumps(targets))
    print(json.dumps({
        'meeting_chunks': len(meetings), 'meetings': len({r['meeting_id'] for r in meetings}),
        'meeting_languages': Counter(r['language'] for r in meetings),
        'screen_documents': len(screens), 'screen_apps': len({r['app'] for r in screens}),
        'screen_languages': Counter(r['language'] for r in screens),
        'meeting_targets': len(meeting_targets),
        'meeting_target_languages': Counter(r['language'] for r in meeting_targets),
        'meeting_targets_at_start_zero': sum(r['start'] == 0 for r in meeting_targets),
        'screen_targets': len(screen_targets),
        'screen_target_languages': Counter(r['language'] for r in screen_targets),
    }, indent=1))


if __name__ == '__main__':
    main()
