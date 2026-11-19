"""Build the benchmark tracks: FLEURS one-language and code-switched tracks, and whole AMI meetings.

FLEURS (CC-BY-4.0): 40 dev utterances per track, joined with 0.8 s of silence, about 7 minutes.
Each language's dev tarball is streamed and dropped after the utterances it needs.
- One-language tracks: English, German, French, Spanish, Japanese, Chinese, Russian, Serbian,
  Croatian and Bosnian.
- Code-switched tracks, named by where the language changes: `late30` ends with 30% of its
  utterances in a second language, `late15` with 15%, `late20` with 20%. `alternating` swaps
  English and German every five utterances; `blocks` repeats four Serbian utterances and one
  English one, as Benchmarks/transcribe/DualASR's `sr+en` did.

AMI (CC-BY-4.0): whole Mix-Headset recordings with the IHM test transcript of every speaker,
read as text columns only through HTTP range requests.

Everything goes to QLS_OUT (default /private/tmp/lokalbot-qwen-sample); items.json lists the
tracks with their references.
"""
import argparse
import csv
import io
import json
import os
import tarfile
import urllib.request
import wave
from pathlib import Path

import numpy as np
import requests

OUT = Path(os.environ.get('QLS_OUT', '/private/tmp/lokalbot-qwen-sample'))
BASE = 'https://huggingface.co/datasets/google/fleurs/resolve/main/data/{lang}'
LANGS = {'en': 'en_us', 'de': 'de_de', 'fr': 'fr_fr', 'es': 'es_419', 'ja': 'ja_jp', 'zh': 'cmn_hans_cn',
         'ru': 'ru_ru', 'sr': 'sr_rs', 'hr': 'hr_hr', 'bs': 'bs_ba'}
PER_TRACK = 40
GAP = np.zeros(int(0.8 * 16000), dtype=np.float32)
# (language, count) runs in order; each run continues that language's utterances.
SWITCHED = {
    'en-de-late30': [('en', 28), ('de', 12)],
    'en-de-late15': [('en', 34), ('de', 6)],
    'en-sr-late20': [('en', 32), ('sr', 8)],
    'sr-en-late30': [('sr', 28), ('en', 12)],
    'sr-en-late15': [('sr', 34), ('en', 6)],
    'en-de-alternating': [('en', 5), ('de', 5)] * 4,
    'sr-en-blocks': [('sr', 4), ('en', 1)] * 8,
}
AMI_MEETINGS = ['ES2004a', 'TS3003a']
AMI_URL = 'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{0}/audio/{0}.Mix-Headset.wav'
AMI_PARQUET = [f'https://huggingface.co/api/datasets/edinburghcstr/ami/parquet/ihm/test/{i}.parquet'
               for i in range(4)]


def transcripts(lang):
    text = requests.get(BASE.format(lang=lang) + '/dev.tsv', timeout=60).text
    rows = csv.reader(io.StringIO(text), delimiter='\t', quoting=csv.QUOTE_NONE)
    return {r[1]: r[2] for r in rows if len(r) > 2}  # file name -> raw transcription


def read_wav(data):
    """16 kHz mono WAV, PCM16 or IEEE float32 (FLEURS ships float)."""
    pos, fmt, rate, channels, bits = 12, None, None, None, None
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], int.from_bytes(data[pos + 4:pos + 8], 'little')
        body = data[pos + 8:pos + 8 + size]
        if tag == b'fmt ':
            fmt = int.from_bytes(body[0:2], 'little')
            channels = int.from_bytes(body[2:4], 'little')
            rate = int.from_bytes(body[4:8], 'little')
            bits = int.from_bytes(body[14:16], 'little')
        elif tag == b'data':
            assert rate == 16000 and channels == 1, (rate, channels)
            if fmt == 3 and bits == 32:
                return np.frombuffer(body, dtype='<f4').astype(np.float32)
            if fmt == 1 and bits == 16:
                return np.frombuffer(body, dtype='<i2').astype(np.float32) / 32768
            raise ValueError(f'unsupported WAV format {fmt}/{bits}')
        pos += 8 + size + (size & 1)
    raise ValueError('no data chunk')


def utterances(lang, count):
    names = transcripts(lang)
    got = []
    with requests.get(BASE.format(lang=lang) + '/audio/dev.tar.gz', stream=True, timeout=60) as response:
        response.raise_for_status()
        with tarfile.open(fileobj=response.raw, mode='r|gz') as tar:
            for member in tar:
                name = Path(member.name).name
                if not member.isfile() or name not in names:
                    continue
                got.append((read_wav(tar.extractfile(member).read()), names[name]))
                if len(got) >= count:
                    break
    return got


def write(path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())


def fleurs_track(track_id, runs, pool, kind):
    used = {code: 0 for code, _ in runs}
    parts, utts, offset = [], [], 0.0
    for code, count in runs:
        for pcm, text in pool[code][used[code]:used[code] + count]:
            utts.append({'language': code, 'start': round(offset, 3), 'end': round(offset + len(pcm) / 16000, 3),
                         'text': text})
            parts += [pcm, GAP]
            offset += (len(pcm) + len(GAP)) / 16000
        used[code] += count
    audio = np.concatenate(parts)
    path = OUT / 'fleurs' / f'{track_id}.wav'
    write(path, audio)
    languages = sorted({u['language'] for u in utts}, key=[c for c, _ in runs].index)
    print(f'{track_id}: {len(utts)} utterances, {len(audio) / 16000 / 60:.1f} min', flush=True)
    return {'id': track_id, 'set': kind, 'wav': str(path), 'languages': languages,
            'reference': ' '.join(u['text'] for u in utts), 'utterances': utts,
            'duration': round(len(audio) / 16000, 1)}


def fleurs_items():
    pool = {code: utterances(lang, PER_TRACK) for code, lang in LANGS.items()}
    items = [fleurs_track(f'fleurs-{code}', [(code, PER_TRACK)], pool, 'fleurs') for code in LANGS]
    items += [fleurs_track(f'switch-{name}', runs, pool, 'switch') for name, runs in SWITCHED.items()]
    return items


def ami_items():
    import duckdb
    con = duckdb.connect()
    con.execute('SET enable_progress_bar=false; INSTALL httpfs; LOAD httpfs;')
    items = []
    for meeting in AMI_MEETINGS:
        path = OUT / 'ami' / f'{meeting}.Mix-Headset.wav'
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(AMI_URL.format(meeting), path)
        rows = con.execute('select begin_time, end_time, text from read_parquet(?) where meeting_id = ?',
                           [AMI_PARQUET, meeting]).fetchall()
        utts = sorted(({'start': float(b), 'end': float(e), 'text': t} for b, e, t in rows),
                      key=lambda u: (u['start'], u['end']))
        with wave.open(str(path)) as w:
            duration = w.getnframes() / w.getframerate()
            assert w.getframerate() == 16000 and w.getnchannels() == 1, (w.getframerate(), w.getnchannels())
        print(f'ami-{meeting}: {len(utts)} utterances, {duration / 60:.1f} min', flush=True)
        items.append({'id': f'ami-{meeting}', 'set': 'ami', 'wav': str(path), 'languages': ['en'],
                      'reference': ' '.join(u['text'] for u in utts), 'utterances': utts,
                      'duration': round(duration, 1)})
    return items


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-ami', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    OUT.chmod(0o700)
    items = fleurs_items()
    if not args.skip_ami:
        items += ami_items()
    (OUT / 'items.json').write_text(json.dumps(items, ensure_ascii=False, indent=1))
    print(f'{len(items)} tracks, {sum(i["duration"] for i in items) / 60:.0f} min', flush=True)


if __name__ == '__main__':
    main()
