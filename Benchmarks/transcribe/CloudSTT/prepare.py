"""Cut identical 16 kHz mono chunks from LokalBot meetings and public AMI meetings.

Meeting audio is read (never written) through `lokalbot-cli path`. Each track is
split at voice-activity pauses into chunks of at most MAX_CHUNK seconds, so every
system receives the same audio and silences longer than GAP_SPLIT are not sent.
AMI windows are cut where no reference utterance crosses the boundary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

import duckdb
import numpy as np
import torch
from silero_vad import get_speech_timestamps, load_silero_vad

from common import DATA, SAMPLE_RATE, write_wav

DEFAULT_MEETINGS = ['2b5676c6', '63e27646', '84fd7a3e']
AMI_MEETINGS = ['ES2004a', 'IS1009a', 'TS3003a', 'EN2002a']
AMI_POSITIONS = [0.15, 0.35, 0.55, 0.75]
AMI_URL = 'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{0}/audio/{0}.Mix-Headset.wav'
AMI_PARQUET = [f'https://huggingface.co/api/datasets/edinburghcstr/ami/parquet/ihm/test/{i}.parquet'
               for i in range(4)]
MAX_CHUNK = 120.0
GAP_SPLIT = 5.0
MIN_SPEECH = 0.6
PAD = 0.25


def decode(path):
    """Decode any container to 16 kHz mono float32 (stereo is averaged)."""
    raw = subprocess.run(
        ['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path), '-ac', '1', '-ar', str(SAMPLE_RATE),
         '-f', 'f32le', '-'], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype='<f4').copy()


def speech_regions(audio, vad):
    stamps = get_speech_timestamps(torch.from_numpy(audio), vad, sampling_rate=SAMPLE_RATE,
                                   min_silence_duration_ms=500, speech_pad_ms=200, return_seconds=True)
    return [(float(s['start']), float(s['end'])) for s in stamps]


def quietest_cut(audio, start, end):
    """Split an over-long region at its lowest-energy 100 ms frame in the last 30 s."""
    lo, hi = max(start, end - 30), end - 1
    frame = SAMPLE_RATE // 10
    best, best_energy = hi, None
    t = lo
    while t < hi:
        i = int(t * SAMPLE_RATE)
        energy = float(np.mean(audio[i:i + frame] ** 2))
        if best_energy is None or energy < best_energy:
            best, best_energy = t + 0.05, energy
        t += 0.1
    return best


def chunk_regions(audio, regions):
    pieces = []
    for start, end in regions:
        while end - start > MAX_CHUNK:
            cut = quietest_cut(audio, start, start + MAX_CHUNK)
            pieces.append((start, cut))
            start = cut
        pieces.append((start, end))
    chunks, current = [], None
    for start, end in pieces:
        if current and (start - current[1] <= GAP_SPLIT) and (end - current[0] <= MAX_CHUNK):
            current = [current[0], end, current[2] + end - start]
        else:
            if current:
                chunks.append(current)
            current = [start, end, end - start]
    if current:
        chunks.append(current)
    total = len(audio) / SAMPLE_RATE
    return [(max(0.0, s - PAD), min(total, e + PAD), speech)
            for s, e, speech in chunks if speech >= MIN_SPEECH]


def lokalbot_meeting(meeting_id):
    folder = Path(subprocess.run(['lokalbot-cli', 'path', meeting_id], check=True,
                                 capture_output=True, text=True).stdout.strip())
    meta = json.loads(subprocess.run(['lokalbot-cli', 'get', meeting_id, '--include', 'metadata',
                                      '--format', 'json'], check=True, capture_output=True, text=True).stdout)
    return folder, meta


def prepare_meetings(meeting_ids, vad):
    rows = []
    for meeting_id in meeting_ids:
        folder, meta = lokalbot_meeting(meeting_id)
        for track in ['mic', 'system']:
            source = folder / f'{track}.m4a'
            if not source.exists():
                continue
            audio = decode(source)
            chunks = chunk_regions(audio, speech_regions(audio, vad))
            for n, (start, end, speech) in enumerate(chunks):
                chunk_id = f'{meeting_id}-{track}-{n:03d}'
                path = DATA / 'audio' / 'meetings' / f'{chunk_id}.wav'
                write_wav(path, audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)])
                rows.append({'id': chunk_id, 'set': 'meetings', 'source': meeting_id,
                             'title': meta.get('title'), 'date': meta.get('date'), 'track': track,
                             'start': round(start, 3), 'end': round(end, 3), 'duration': round(end - start, 3),
                             'speech_seconds': round(speech, 3), 'path': str(path)})
            print(f'{meeting_id} {track}: {len(audio) / SAMPLE_RATE:.0f}s audio, {len(chunks)} chunks, '
                  f'{sum(c[1] - c[0] for c in chunks):.0f}s sent', flush=True)
    return rows


def ami_utterances(meeting):
    """Read only the transcript columns of the IHM test parquet via HTTP range requests."""
    cache = DATA / 'source' / 'ami' / f'{meeting}.utterances.json'
    if cache.exists():
        return json.loads(cache.read_text())
    con = duckdb.connect()
    con.execute('SET enable_progress_bar=false; INSTALL httpfs; LOAD httpfs;')
    rows = con.execute(
        'select begin_time, end_time, speaker_id, text from read_parquet(?) where meeting_id = ?',
        [AMI_PARQUET, meeting]).fetchall()
    utterances = sorted(({'begin': float(b), 'end': float(e), 'speaker': s, 'text': t} for b, e, s, t in rows),
                        key=lambda u: (u['begin'], u['end']))
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(utterances))
    return utterances


def ami_windows(utterances, positions, min_len=90.0, max_len=MAX_CHUNK, margin=0.3):
    total = max(u['end'] for u in utterances)
    windows = []
    for position in positions:
        i = next(k for k, u in enumerate(utterances) if u['begin'] >= position * total)
        while i < len(utterances):
            prior_end = max((u['end'] for u in utterances[:i]), default=-1)
            start = utterances[i]['begin']
            if prior_end > start - margin:
                i += 1
                continue
            cover, j = utterances[i]['end'], i + 1
            while j < len(utterances):
                if cover - start >= min_len and utterances[j]['begin'] > cover + margin:
                    break
                cover = max(cover, utterances[j]['end'])
                j += 1
            if cover - start <= max_len and (j == len(utterances) or utterances[j]['begin'] > cover + margin):
                windows.append((start, cover, utterances[i:j]))
                break
            i += 1
    return windows


def prepare_ami():
    rows = []
    for meeting in AMI_MEETINGS:
        source = DATA / 'source' / 'ami' / f'{meeting}.Mix-Headset.wav'
        if not source.exists():
            source.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(AMI_URL.format(meeting), source)
        digest = hashlib.file_digest(source.open('rb'), 'sha256').hexdigest()
        audio = decode(source)
        for n, (start, end, utts) in enumerate(ami_windows(ami_utterances(meeting), AMI_POSITIONS)):
            lo, hi = start - 0.15, end + 0.15
            chunk_id = f'ami-{meeting}-{n}'
            path = DATA / 'audio' / 'ami' / f'{chunk_id}.wav'
            write_wav(path, audio[int(lo * SAMPLE_RATE):int(hi * SAMPLE_RATE)])
            rows.append({'id': chunk_id, 'set': 'ami', 'source': meeting, 'track': 'Mix-Headset',
                         'start': round(lo, 3), 'end': round(hi, 3), 'duration': round(hi - lo, 3),
                         'speakers': len({u['speaker'] for u in utts}), 'utterances': len(utts),
                         'reference': ' '.join(u['text'] for u in utts), 'source_sha256': digest,
                         'path': str(path)})
        print(f'{meeting}: {sum(r["duration"] for r in rows if r["source"] == meeting):.0f}s in windows', flush=True)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--meetings', nargs='*', default=DEFAULT_MEETINGS)
    parser.add_argument('--skip-ami', action='store_true')
    args = parser.parse_args()
    DATA.mkdir(parents=True, exist_ok=True)
    DATA.chmod(0o700)
    vad = load_silero_vad()
    rows = prepare_meetings(args.meetings, vad)
    if not args.skip_ami:
        rows += prepare_ami()
    (DATA / 'manifest.json').write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    for name in ['meetings', 'ami']:
        subset = [r for r in rows if r['set'] == name]
        print(f'{name}: {len(subset)} chunks, {sum(r["duration"] for r in subset) / 60:.1f} min', flush=True)


if __name__ == '__main__':
    main()
