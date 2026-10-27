"""Publish numeric aggregates only; meeting text and audio remain in private OUT."""
import collections
import json
import re
import sys
import unicodedata
import wave
from pathlib import Path

from rapidfuzz.distance import Levenshtein
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

out, destination = map(Path, sys.argv[1:3])
clips = {c['id']: c for c in json.loads((out / 'clips.json').read_text())}
durations = {}
for clip in clips.values():
    with wave.open(clip['wav']) as audio:
        durations[clip['id']] = audio.getnframes() / audio.getframerate()
normalizer = BasicTextNormalizer()
cyrillic = dict(zip('абвгдђежзијклљмнњопрстћуфхцчџш',
    ['a','b','v','g','d','đ','e','ž','z','i','j','k','l','lj','m','n','nj','o','p','r','s','t','ć','u','f','h','c','č','dž','š']))

def words(text):
    text = re.sub(r'<\|[^>]*\|>', ' ', text)
    return normalizer(''.join(cyrillic.get(c, c) for c in text.lower())).split()

rows = []
process = {}
for filename in ('current-turbo', 'full-large-v3', 'stage-turbo'):
    path = out / f'{filename}.jsonl'
    if not path.exists():
        continue
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not records:
        continue
    log = (out / f'{filename}.log').read_text(errors='replace')
    memory = re.search(r'(\d+)\s+maximum resident set size', log)
    footprint = re.search(r'(\d+)\s+peak memory footprint', log)
    process[records[0]['model']] = {'loadSeconds': records[0]['loadSeconds'],
        'maxRSSBytes': int(memory.group(1)) if memory else None,
        'peakFootprintBytes': int(footprint.group(1)) if footprint else None,
        'completedRows': len(records)}
    rows.extend(records)

groups = collections.defaultdict(list)
for row in rows:
    groups[(row['model'], row['group'], row['language'])].append(row)
summary = []
for (model, group, language), records in sorted(groups.items()):
    edits = reference_words = 0
    for record in records:
        ref = words(clips[record['id']]['reference'])
        edits += Levenshtein.distance(ref, words(record['text']))
        reference_words += len(ref)
    seconds = sum(r['audioSeconds'] for r in records)
    decode = sum(r['decodeSeconds'] for r in records)
    timing_violations = sum(1 for r in records for s in r['segments']
        if s.get('start') is None or s.get('end') is None
        or s['start'] < -0.05 or s['end'] < s['start'] or s['end'] > r['audioSeconds'] + 0.5)
    letters = [c for r in records for c in r['text'] if c.isalpha()]
    non_latin = sum('LATIN' not in unicodedata.name(c, '') for c in letters)
    summary.append({'model': model, 'group': group, 'language': language, 'clips': len(records),
        'audioSeconds': seconds, 'decodeSeconds': decode, 'realtimeFactor': seconds / decode,
        'metric': 'synthetic_script_WER' if group == 'control' else 'disagreement_with_saved_ASR',
        'wordEditPercent': 100 * edits / reference_words, 'referenceWords': reference_words,
        'nonLatinLetters': non_latin, 'emptyClips': sum(not r['text'].strip() for r in records),
        'segmentTimingViolations': timing_violations})

throughput = []
for model in sorted(process):
    records = [r for r in rows if r['model'] == model and r['language'] == 'auto' and r['group'] != 'control']
    seconds = sum(r['audioSeconds'] for r in records)
    decode = sum(r['decodeSeconds'] for r in records)
    throughput.append({'model': model, 'clips': len(records), 'audioSeconds': seconds,
                       'decodeSeconds': decode, 'realtimeFactor': seconds / decode})

payload = {'date': '2026-10-08',
    'qualityCaveat': 'Real-meeting references are existing Qwen3-ASR output, not human ground truth. '
                     'Disagreement is not accuracy. Only the synthetic control has a known script.',
    'sample': {'meetingClips': sum(c['group'] != 'control' for c in clips.values()),
               'meetingSeconds': sum(durations[c['id']] for c in clips.values() if c['group'] != 'control'),
               'controlSeconds': sum(durations[c['id']] for c in clips.values() if c['group'] == 'control')},
    'process': process, 'meetingThroughput': throughput, 'results': summary}
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(payload, indent=2) + '\n')
for r in summary:
    print(f'{r["model"]:20} {r["group"]:8} {r["language"]:5} '
          f'{r["realtimeFactor"]:6.1f}x  {r["wordEditPercent"]:6.1f}% edits '
          f'({r["referenceWords"]} words) timing={r["segmentTimingViolations"]}')
print(json.dumps(process, indent=2))
