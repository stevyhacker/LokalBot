"""Score the old auto path (`before`) against language sampling (`after`).

  score.py --results results/<date> [--timing QLS_OUT/runs-paired.jsonl]

Accuracy and work come from runs.jsonl. Decoding is greedy, so they do not depend on when a run
happened: WER or CER (pooled over a set; Japanese and Chinese by character), letters outside
Latin script on tracks in Latin-script languages, letters outside the track's own scripts, the
pinned language, identical text, and the windows and audio seconds decoded. Serbian Cyrillic
is read as Latin on tracks with Serbian, Croatian or Bosnian, as the app writes them, and counts
as Serbian's own script.

Wall time comes from `--timing`, a paired run (make_manifest.py --alternate): both paths decode
each track back to back, in alternating order, so they share the machine's load and heat.
Times from runs made minutes apart are not compared.

Word-layout tracks that go to speaker regions have no transcript here: the regions decode the
same way after both, so only their decode work and decision are compared. The owner's meetings
have no reference and are named only by letter. `results/` gets aggregates only.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import errors, items, runs, script_shares

SETS = ['fleurs', 'switch', 'ami', 'meetings']
LATIN = {'en', 'de', 'fr', 'es', 'hr', 'bs', 'sr'}


def measure(record, item):
    languages = item.get('languages') or []
    spans = record['spans']
    out = {'seconds': record['decodeSeconds'], 'audio': record['audioSeconds'], 'pinned': record.get('pinned'),
           'twice': record['decodedTwice'], 'regions': record['needsSpeakerRegions'],
           'decodes': len(record['windows']), 'windows': len(spans),
           'decodedAudio': sum(spans[w['index']][1] - spans[w['index']][0] for w in record['windows'])}
    if not record['needsSpeakerRegions']:
        letters = sum(1 for ch in record['text'] if ch.isalpha())
        non_latin, off = script_shares(record['text'], languages)
        out.update(letters=letters, offScript=off * letters)
        if item['set'] == 'meetings' or set(languages) <= LATIN:
            out.update(latinLetters=letters, nonLatin=non_latin * letters)
        if item.get('reference'):
            out['errors'], out['words'] = errors(item['reference'], record['text'], languages)
    return out


def rate(part, whole):
    return f'{100 * part / whole:.1f}%' if whole else '–'


def name_tracks(data, known):
    names, meetings = {}, {}
    for track, _, _ in sorted(data):
        if known[track]['set'] == 'meetings':
            meeting, side = track.rsplit('-', 1)
            meetings.setdefault(meeting, f'meeting {chr(65 + len(meetings))}')
            names[track] = f'{meetings[meeting]} {side}'
        else:
            names[track] = track
    return names


def pairs(data, known):
    names = name_tracks(data, known)
    rows = []
    for (track, layout, mode), record in sorted(data.items()):
        if mode != 'before' or (track, layout, 'after') not in data:
            continue
        item, after = known[track], data[(track, layout, 'after')]
        rows.append({'track': names[track], 'set': item['set'], 'layout': layout,
                     'before': measure(record, item), 'after': measure(after, item),
                     'sameText': record['text'] == after['text'] or record['needsSpeakerRegions']})
    return rows


def totals(group, mode):
    keys = ['seconds', 'audio', 'errors', 'words', 'letters', 'offScript', 'latinLetters', 'nonLatin', 'decodes',
            'decodedAudio']
    return {k: sum(r[mode].get(k, 0) for r in group) for k in keys}


def groups(rows):
    for layout in ['word', 'plain']:
        for name in SETS + ['all']:
            group = [r for r in rows if r['layout'] == layout and (name == 'all' or r['set'] == name)]
            if group:
                yield name, layout, group


def accuracy_table(rows):
    summary = []
    print('| Set | Layout | Tracks | Audio | Same pin | Same text | WER/CER before → after '
          '| Non-Latin before → after | Off-script before → after | Windows decoded before → after '
          '| Audio decoded before → after |')
    print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    for name, layout, group in groups(rows):
        m, b = totals(group, 'before'), totals(group, 'after')
        same_pin = sum(1 for r in group if r['before']['pinned'] == r['after']['pinned'])
        same_text = sum(1 for r in group if r['sameText'])
        summary.append({'set': name, 'layout': layout, 'tracks': len(group), 'audioMinutes': round(m['audio'] / 60, 1),
                        'samePin': same_pin, 'sameText': same_text, 'before': m, 'after': b})
        wer = f'{rate(m["errors"], m["words"])} → {rate(b["errors"], b["words"])}' if m['words'] else '–'
        non_latin = f'{rate(m["nonLatin"], m["latinLetters"])} → {rate(b["nonLatin"], b["latinLetters"])}' \
            if m['latinLetters'] else '–'
        print(f'| {name} | {layout} | {len(group)} | {m["audio"] / 60:.0f} min | {same_pin}/{len(group)} '
              f'| {same_text}/{len(group)} | {wer} | {non_latin} '
              f'| {rate(m["offScript"], m["letters"])} → {rate(b["offScript"], b["letters"])} '
              f'| {m["decodes"]} → {b["decodes"]} ({b["decodes"] / m["decodes"]:.0%}) '
              f'| {m["decodedAudio"] / 60:.0f} → {b["decodedAudio"] / 60:.0f} min '
              f'({b["decodedAudio"] / m["decodedAudio"]:.0%}) |')
    return summary


def timing_table(rows):
    summary = []
    print('\n| Set | Layout | Tracks | Audio | Decode before → after | RTF before → after | Speed-up |')
    print('|---|---|---:|---:|---:|---:|---:|')
    for name, layout, group in groups(rows):
        m, b = totals(group, 'before'), totals(group, 'after')
        summary.append({'set': name, 'layout': layout, 'tracks': len(group), 'audioMinutes': round(m['audio'] / 60, 1),
                        'beforeSeconds': round(m['seconds'], 1), 'afterSeconds': round(b['seconds'], 1)})
        print(f'| {name} | {layout} | {len(group)} | {m["audio"] / 60:.0f} min | {m["seconds"]:.0f} s → '
              f'{b["seconds"]:.0f} s | {m["audio"] / m["seconds"]:.1f}× → {b["audio"] / b["seconds"]:.1f}× '
              f'| {m["seconds"] / b["seconds"]:.2f}× |')
    print('\n| Track | Layout | Windows | Pin | Decodes before → after | Decode before → after | RTF before → after |')
    print('|---|---|---:|---|---:|---:|---:|')
    for r in rows:
        m, b = r['before'], r['after']
        print(f'| {r["track"]} | {r["layout"]} | {m["windows"]} | {m["pinned"] or "auto"}'
              f'{" (regions)" if m["regions"] else ""} | {m["decodes"]} → {b["decodes"]} '
              f'| {m["seconds"]:.1f} s → {b["seconds"]:.1f} s '
              f'| {m["audio"] / m["seconds"]:.1f}× → {b["audio"] / b["seconds"]:.1f}× |')
    return summary


def track_table(rows):
    print('\n| Track | Layout | Windows | Before pin | After pin | Decodes before → after | WER/CER before → after |')
    print('|---|---|---:|---|---|---:|---:|')
    for r in rows:
        m, b = r['before'], r['after']
        wer = f'{rate(m["errors"], m["words"])} → {rate(b["errors"], b["words"])}' if m.get('words') else \
            ('regions' if m['regions'] else '–')
        pins = [f'{x["pinned"] or "auto"}{" (regions)" if x["regions"] else ""}' for x in (m, b)]
        print(f'| {r["track"]} | {r["layout"]} | {m["windows"]} | {pins[0]} | {pins[1]} '
              f'| {m["decodes"]} → {b["decodes"]} | {wer} |')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', required=True)
    parser.add_argument('--runs', help='runs file (default QLS_OUT/runs.jsonl)')
    parser.add_argument('--timing', help='paired runs file for wall time')
    args = parser.parse_args()
    known = items()
    rows = pairs(runs(args.runs), known)
    result = {'accuracy': accuracy_table(rows)}
    track_table(rows)
    result['tracks'] = [{k: v for k, v in r.items()} for r in rows]
    if args.timing:
        result['timing'] = timing_table(pairs(runs(args.timing), known))
    out = Path(args.results)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'summary.json').write_text(json.dumps(result, indent=1))


if __name__ == '__main__':
    main()
