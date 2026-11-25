"""Build long dictation-length recordings from LibriSpeech test chapters.

--freeze writes the selection (public utterance IDs only) before any run; later calls rebuild the audio from it.
"""
import argparse
import hashlib
import json
import subprocess
import tarfile
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUBSETS = {'test-clean': '32fa31d27d2e1cad72775fee3f4849a9', 'test-other': 'fb5a50374b501bb3bac4815ee91d3135'}
TARGETS = [30, 60, 90, 120]
CHAPTERS_PER_SUBSET = 16
GAP_SECONDS = 0.4
RATE = 16000


def md5(path):
    digest = hashlib.md5()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def extract(downloads, work):
    root = work / 'LibriSpeech'
    for subset, expected in SUBSETS.items():
        archive = downloads / f'{subset}.tar.gz'
        if md5(archive) != expected:
            raise SystemExit(f'{archive.name}: checksum mismatch')
        if not (root / subset).exists():
            with tarfile.open(archive) as tar:
                tar.extractall(work, filter='data')
    return root


def chapters(root, subset):
    found = []
    for speaker in sorted((root / subset).iterdir(), key=lambda p: int(p.name)):
        for chapter in sorted(speaker.iterdir(), key=lambda p: int(p.name)):
            lines = (chapter / f'{speaker.name}-{chapter.name}.trans.txt').read_text().splitlines()
            utterances = [line.split(' ', 1) for line in lines if line.strip()]
            found.append((chapter, sorted(utterances)))
    return found


def samples(flac):
    raw = subprocess.run(['flac', '-d', '-s', '-c', '--force-raw-format', '--endian=little', '--sign=signed', str(flac)],
                         check=True, capture_output=True).stdout
    return raw


def freeze(root, manifest):
    clips = []
    for subset in SUBSETS:
        picked = 0
        for chapter, utterances in chapters(root, subset):
            if picked == CHAPTERS_PER_SUBSET:
                break
            target = TARGETS[picked % len(TARGETS)]
            chosen, seconds = [], 0.0
            for uid, _ in utterances:
                length = len(samples(chapter / f'{uid}.flac')) / 2 / RATE
                seconds += length + (GAP_SECONDS if chosen else 0)
                chosen.append(uid)
                if seconds >= target:
                    break
            if seconds < target:
                continue
            clips.append({'id': f'{subset}-{chosen[0]}', 'subset': subset, 'targetSeconds': target,
                          'utterances': chosen})
            picked += 1
    manifest.write_text(json.dumps({
        'source': 'LibriSpeech (openslr.org/12), CC BY 4.0', 'archives': SUBSETS,
        'rule': f'per subset, chapters in speaker/chapter order; targets cycle {TARGETS} s; consecutive utterances '
                f'from the chapter start until the target is reached, joined with {GAP_SECONDS} s of silence; '
                f'{CHAPTERS_PER_SUBSET} chapters per subset; a chapter too short for its target is skipped',
        'clips': clips}, indent=1) + '\n')


def build(root, manifest, out):
    spec = json.loads(manifest.read_text())
    (out / 'audio').mkdir(parents=True, exist_ok=True)
    cases = []
    gap = b'\x00\x00' * int(GAP_SECONDS * RATE)
    for clip in spec['clips']:
        texts, pcm = [], b''
        for uid in clip['utterances']:
            speaker, chapter, _ = uid.split('-')
            folder = root / clip['subset'] / speaker / chapter
            transcript = dict(line.split(' ', 1) for line in
                              (folder / f'{speaker}-{chapter}.trans.txt').read_text().splitlines() if line.strip())
            texts.append(transcript[uid])
            pcm += (gap if pcm else b'') + samples(folder / f'{uid}.flac')
        path = out / 'audio' / f"{clip['id']}.wav"
        with wave.open(str(path), 'wb') as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes(pcm)
        cases.append({'id': clip['id'], 'audio': f"audio/{clip['id']}.wav", 'language': 'en',
                      'seconds': round(len(pcm) / 2 / RATE, 3), 'subset': clip['subset'],
                      'targetSeconds': clip['targetSeconds'], 'reference': ' '.join(texts)})
    (out / 'cases.json').write_text(json.dumps({'cases': cases}, indent=1) + '\n')
    print(f'{len(cases)} recordings, {sum(c["seconds"] for c in cases) / 60:.1f} minutes -> {out}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--downloads', type=Path, required=True, help='folder with test-clean.tar.gz and test-other.tar.gz')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=HERE / 'long-dictation-v1.json')
    parser.add_argument('--freeze', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    root = extract(args.downloads, args.out)
    if args.freeze:
        if args.manifest.exists():
            raise SystemExit(f'{args.manifest.name} is already frozen')
        freeze(root, args.manifest)
    build(root, args.manifest, args.out)


if __name__ == '__main__':
    main()
