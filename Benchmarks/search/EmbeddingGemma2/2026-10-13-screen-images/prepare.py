"""Sample real screenshots and decrypt them into the private benchmark folder.

CPU only. Input is a read-only `.backup` copy of lokalbotv3.sqlite. The
screenshot key is read from the login Keychain through `security`, which
shows one macOS approval prompt; it is kept in memory only and never printed.
Decrypted PNGs, OCR text and the manifest stay under ROOT (mode 700) and must
never be copied into the repository.
"""
import json
import random
import re
import sqlite3
import subprocess
import sys
from collections import Counter
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path('/private/tmp/lokalbot-screen-images-20261013')
SNAPSHOT = ROOT / 'library.sqlite'
TARGETS = 48
CORPUS = 720
PER_APP = 4
SEED = 61013
OCR_CHARS = 1_500  # EmbeddingIndex.performScreenTextReindex truncation

EN_STOP = set('the and is are to of that this it in for on with you we was be have not what but so can will'.split())
SR_STOP = set(('je da i se na u to što sto ali nije ovo za sa od kao samo ima smo su bi li ja ti mi '
               'ne ni kad kada jer pa ako koji koja koje tako treba može moze').split())
WORD = re.compile(r'\w+', re.UNICODE)


def language(text):
    words = [w.lower() for w in WORD.findall(text)]
    sr = sum(w in SR_STOP for w in words) + 2 * sum(c in 'čćšžđČĆŠŽĐ' for c in text)
    en = sum(w in EN_STOP for w in words)
    if sr == en == 0:
        return 'unknown'
    return 'bcs' if sr > en else 'en'


def screenshot_key():
    output = subprocess.run(
        ['security', 'find-generic-password', '-s', 'me.dotenv.LokalBot', '-a', 'screenshot-key', '-w'],
        capture_output=True, check=True).stdout.strip()
    if len(output) == 64 and re.fullmatch(rb'[0-9a-fA-F]{64}', output):
        return bytes.fromhex(output.decode())
    if len(output) == 32:
        return output
    raise SystemExit('screenshot-key is not a 32-byte AES key')


def main():
    database = sqlite3.connect(f'file:{SNAPSHOT}?mode=ro', uri=True)
    rows = database.execute("""
        SELECT s.id, s.ts, s.app, s.path, s.similarity_group, s.capture_trigger,
               COALESCE((SELECT o.text FROM ocr_fts AS o
                         WHERE CAST(o.snapshot_id AS INTEGER) = s.id LIMIT 1), '')
        FROM screenshots AS s WHERE s.path != '' ORDER BY s.id""").fetchall()
    shots = [{'id': i, 'ts': ts, 'app': app, 'path': path, 'group': group, 'trigger': trigger,
              'text': text[:OCR_CHARS], 'language': language(text)}
             for i, ts, app, path, group, trigger, text in rows if Path(path).exists()]

    rng = random.Random(SEED)
    order = rng.sample(shots, len(shots))
    targets, groups, per_app = [], set(), Counter()
    for shot in order:
        if len(shot['text']) < 200 or shot['group'] in groups or per_app[shot['app']] >= PER_APP:
            continue
        groups.add(shot['group'])
        per_app[shot['app']] += 1
        targets.append(shot)
        if len(targets) == TARGETS:
            break
    chosen = {shot['id'] for shot in targets}
    distractors = [shot for shot in order if shot['id'] not in chosen][:CORPUS - len(targets)]
    corpus = targets + distractors  # run.py embeds images in this order

    key = AESGCM(screenshot_key())
    (ROOT / 'images').mkdir(mode=0o700, exist_ok=True)
    scratch = ROOT / 'private' / 'heic'
    scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    for index, shot in enumerate(corpus):
        sealed = Path(shot['path']).read_bytes()
        heic = scratch / f"{shot['id']}.heic"
        heic.write_bytes(key.decrypt(sealed[:12], sealed[12:], None))
        png = ROOT / 'images' / f"{shot['id']}.png"
        subprocess.run(['sips', '-s', 'format', 'png', str(heic), '--out', str(png)],
                       capture_output=True, check=True)
        heic.unlink()
        png.chmod(0o600)
        shot['image'] = str(png)
        del shot['path']
        if index % 100 == 0:
            print(f'decrypted {index + 1}/{len(corpus)}', file=sys.stderr, flush=True)

    for shot in corpus:
        shot['role'] = 'target' if shot['id'] in chosen else 'distractor'
    manifest = ROOT / 'private' / 'corpus.json'
    manifest.write_text(json.dumps(corpus, ensure_ascii=False))
    manifest.chmod(0o600)
    days = sorted({int(shot['ts'] // 86_400) for shot in corpus})
    print(json.dumps({
        'pixel_screenshots_on_disk': len(shots),
        'corpus': len(corpus), 'targets': len(targets),
        'target_apps': len({shot['app'] for shot in targets}),
        'target_languages': Counter(shot['language'] for shot in targets),
        'corpus_similarity_groups': len({shot['group'] for shot in corpus}),
        'corpus_days': len(days),
        'corpus_triggers': Counter(shot['trigger'] for shot in corpus),
    }, indent=1))


if __name__ == '__main__':
    main()
