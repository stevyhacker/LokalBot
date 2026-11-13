#!/usr/bin/env python3
"""Score the live-turn measurement (LokalBotTests/LiveTurnLatencyBenchmarkTests).

For every reference turn that ends with a change of speaker (a hand-over), how long after its
last word did the text exist? Reported for turn-by-turn decoding, for the preview's windows, for
the streaming recognizer and for the real-time replay, with word error rate against the
reference transcript where the whole recording was decoded.

Usage: score.py <results dir> <LokalBot/Resources/SampleMeeting> [--json out.json]
"""
import glob
import json
import os
import re
import statistics
import sys
import unicodedata

REFERENCE = {"en": "en", "sr": "sr-Latn", "de": "de", "zh": "zh"}
CHUNK = 4096 / 16000

CYRILLIC = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž", "з": "z", "и": "i",
    "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "ћ": "ć", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "č", "џ": "dž", "ш": "š",
}


def words(text):
    text = unicodedata.normalize("NFC", text).lower()
    text = "".join(CYRILLIC.get(ch, ch) for ch in text)
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE).replace("_", " ")
    return text.split()


def cyrillic_share(text):
    letters = [ch for ch in text if ch.isalpha()]
    return sum(1 for ch in letters if "Ѐ" <= ch <= "ӿ") / len(letters) if letters else 0.0


def wer(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    previous = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        current = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] != h[j - 1]))
        previous = current
    return 100.0 * previous[-1] / max(1, len(r))


def quantile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, max(0, round(q * (len(values) - 1))))] if values else float("nan")


def summary(values):
    if not values:
        return {"median": float("nan"), "p90": float("nan"), "max": float("nan"), "n": 0}
    return {"median": statistics.median(values), "p90": quantile(values, 0.9), "max": max(values), "n": len(values)}


def load_reference(sample, label):
    name = REFERENCE.get(label.split("-")[0])
    path = os.path.join(sample, f"reference.{name}.json")
    if not name or not os.path.exists(path):
        return None
    turns = json.load(open(path))["turns"]
    order = []
    for turn in turns:
        if turn["speaker"] not in order:
            order.append(turn["speaker"])
    for index, turn in enumerate(turns):
        turn["track"] = order.index(turn["speaker"])
        following = turns[index + 1] if index + 1 < len(turns) else None
        turn["handsOver"] = following is None or following["speaker"] != turn["speaker"]
        turn["nextStart"] = following["start"] if following else float("inf")
    return turns


def covering(pieces, turn, layout, slack):
    """The piece that holds the turn's last word, on the turn's own track."""
    track = turn["track"] if layout == "tracks" else 0
    mine = [p for p in pieces if p["track"] == track]
    for piece in mine:
        if piece["start"] - slack <= turn["end"] <= piece["end"] + slack:
            return piece
    later = [p for p in mine if p["end"] >= turn["end"]]
    return min(later, key=lambda p: p["end"]) if later and slack > 0 else None


def mean_age(pieces):
    """Average age of the audio in a piece when its text appears, weighted by length."""
    total = sum(p["end"] - p["start"] for p in pieces)
    if total <= 0:
        return float("nan")
    return sum((p["ready"] - (p["start"] + p["end"]) / 2) * (p["end"] - p["start"]) for p in pieces) / total


def rule_label(rule):
    if not rule:
        return "windows"
    eager = rule.get("eagerAfterSeconds")
    return f"{rule['quietChunks']} quiet" + (f", 1 after {eager:g} s" if eager else "")


def rounded(value):
    """Milliseconds are enough, and a missing number is null, which every JSON reader takes."""
    if isinstance(value, float):
        return None if value != value else round(value, 3)
    if isinstance(value, dict):
        return {key: rounded(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rounded(item) for item in value]
    return value


def main():
    results, sample = sys.argv[1], sys.argv[2]
    out = {"cuts": [], "passes": []}

    for path in sorted(glob.glob(os.path.join(results, "cut-*.json"))):
        cut = json.load(open(path))
        reference = load_reference(sample, cut["recording"])
        if not reference:
            continue
        waits, caught, handovers = [], 0, 0
        for turn in reference:
            if not turn["handsOver"]:
                continue
            handovers += 1
            piece = covering(cut["pieces"], turn, cut["layout"], 0.35)
            if piece is None:
                continue
            waits.append(piece["decision"] - turn["end"])
            if not piece["forced"] and piece["end"] <= turn["nextStart"] - 0.05:
                caught += 1
        lengths = [p["end"] - p["start"] for p in cut["pieces"]]
        out["cuts"].append({
            "recording": cut["recording"], "layout": cut["layout"], "rule": rule_label(cut["rule"]),
            "pieces": len(cut["pieces"]), "forced": sum(1 for p in cut["pieces"] if p["forced"]),
            "handovers": handovers, "caught": caught, "wait": summary(waits),
            "medianSeconds": statistics.median(lengths), "longestSeconds": max(lengths),
            "under2s": sum(1 for x in lengths if x < 2),
        })

    for path in sorted(glob.glob(os.path.join(results, "run-*.json"))):
        run = json.load(open(path))
        reference = load_reference(sample, run["recording"])
        if not reference:
            continue
        reference_text = " ".join(t["text"] for t in reference)
        for item in run["passes"]:
            pieces = item["pieces"]
            windows = item["kind"] == "windows"
            delays, missing = [], 0
            for turn in reference:
                if not turn["handsOver"]:
                    continue
                piece = covering(pieces, turn, item["layout"], 0.0 if windows else 0.35)
                if piece is None or piece["start"] > turn["end"]:
                    missing += 1
                else:
                    delays.append(piece["ready"] - turn["end"])
            text = " ".join(p["text"] for p in sorted(pieces, key=lambda p: (p["start"], p["track"])))
            audio = sum(p["end"] - p["start"] for p in pieces)
            decode = [p["decodeSeconds"] for p in pieces]
            closed = [p for p in pieces if not p["forced"]]
            out["passes"].append({
                "model": run["model"], "recording": run["recording"], "optimized": run["optimized"],
                "language": run["language"], "layout": item["layout"], "kind": item["kind"], "rule": rule_label(item.get("rule")),
                "loadSeconds": run["loadSeconds"], "firstDecodeSeconds": run["firstDecodeSeconds"],
                "footprintMB": run["footprintMegabytes"], "pieces": len(pieces),
                "forced": sum(1 for p in pieces if p["forced"]),
                "decode": summary(decode), "decodePerAudioSecond": sum(decode) / audio if audio else float("nan"),
                "afterPause": summary([p["ready"] - p["end"] for p in closed]) if not windows else None,
                "delay": summary(delays), "missing": missing, "age": mean_age(pieces),
                "wer": wer(reference_text, text), "cyrillic": cyrillic_share(text),
                "cpuPerAudioMinute": 60 * sum(p["cpuSeconds"] for p in pieces) / (run["audioSeconds"] or 1),
            })

    out["streams"] = []
    for path in sorted(glob.glob(os.path.join(results, "stream-*.json"))):
        run = json.load(open(path))
        reference = load_reference(sample, run["recording"])
        if not reference:
            continue
        pieces = run["pieces"]
        delays = []
        for turn in reference:
            if turn["handsOver"]:
                piece = covering(pieces, turn, run["layout"], 0.35)
                if piece is not None:
                    delays.append(piece["ready"] - turn["end"])
        text = " ".join(p["text"] for p in sorted(pieces, key=lambda p: (p["start"], p["track"])))
        out["streams"].append({
            "model": run["model"], "recording": run["recording"], "language": run["language"],
            "optimized": run["optimized"], "chunkMilliseconds": run["chunkMilliseconds"],
            "loadSeconds": run["loadSeconds"], "footprintMB": run["footprintMegabytes"],
            "pieces": len(pieces), "age": summary(run["tokenAges"]), "step": summary(run["stepSeconds"]),
            "flush": summary([p["decodeSeconds"] for p in pieces]), "delay": summary(delays),
            "wer": wer(" ".join(t["text"] for t in reference), text), "cyrillic": cyrillic_share(text),
            "cpuPerAudioMinute": 60 * sum(p["cpuSeconds"] for p in pieces) / (run["audioSeconds"] or 1),
        })

    out["replays"] = []
    for path in sorted(glob.glob(os.path.join(results, "replay-*.json"))):
        run = json.load(open(path))
        reference = load_reference(sample, run["recording"])
        if not reference:
            continue
        speakers = ["local", "them"]
        lines = [a for a in run["arrivals"] if not a["partial"]]
        delays, first, missing = [], [], 0
        for turn in reference:
            if turn["end"] > run["seconds"] - 0.5:
                continue
            mine = [a for a in run["arrivals"] if a["speaker"] == speakers[turn["track"]]]
            begun = [a["at"] for a in mine if turn["start"] - 0.5 <= a["time"] <= turn["end"]]
            if begun:
                first.append(min(begun) - turn["start"])
            if not turn["handsOver"]:
                continue
            said = [a for a in mine if not a["partial"] and a["time"] <= turn["end"]]
            last = max(said, key=lambda a: a["time"]) if said else None
            if last is None or last["at"] < turn["end"]:
                missing += 1
            else:
                delays.append(last["at"] - turn["end"])
        out["replays"].append({
            "model": run["model"], "recording": run["recording"], "language": run["language"],
            "optimized": run["optimized"], "seconds": run["seconds"], "lines": len(lines),
            "partials": len(run["arrivals"]) - len(lines), "delay": summary(delays), "missing": missing,
            "firstWords": summary(first),
        })

    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w") as file:
            json.dump(rounded(out), file, indent=1)
            file.write("\n")

    print("## Pause detection alone (no model)\n")
    print("| Recording | Layout | Rule | Pieces | Under 2 s | Cut by length | Hand-overs caught | "
          "Wait after the last word: median / p90 / max |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for c in out["cuts"]:
        w = c["wait"]
        print(f"| {c['recording']} | {c['layout']} | {c['rule']} | {c['pieces']} | {c['under2s']} | {c['forced']} | "
              f"{c['caught']} of {c['handovers']} | {w['median']:.2f} / {w['p90']:.2f} / {w['max']:.2f} s |")

    print("\n## With a model\n")
    print("| Model | Rec. | Layout | Pass | Pieces | Decode: median / max | Text after the pause: median / max | "
          "Text after a hand-over's last word: median / p90 / max | Mean age | WER | CPU s per audio min | Load / first | Memory |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for p in out["passes"]:
        d, t = p["decode"], p["delay"]
        name = p["model"] + ("" if p["optimized"] else " (unoptimized)")
        kind = "windows" if p["kind"] == "windows" else f"turns, {p['rule']}"
        after = "" if p["afterPause"] is None else f"{p['afterPause']['median']:.2f} / {p['afterPause']['max']:.2f} s"
        missing = f" ({p['missing']} never)" if p["missing"] else ""
        cyr = f" ({p['cyrillic'] * 100:.0f}% Cyrillic)" if p["cyrillic"] > 0.01 else ""
        recording = p["recording"] if p["language"] == p["recording"] else f"{p['recording']}, hint {p['language']}"
        print(f"| {name} | {recording} | {p['layout']} | {kind} | {p['pieces']} | {d['median']:.2f} / {d['max']:.2f} s | "
              f"{after} | {t['median']:.2f} / {t['p90']:.2f} / {t['max']:.2f} s{missing} | {p['age']:.1f} s | "
              f"{p['wer']:.1f}%{cyr} | {p['cpuPerAudioMinute']:.1f} | {p['loadSeconds']:.1f} / {p['firstDecodeSeconds']:.2f} s | "
              f"{p['footprintMB'] / 1024:.1f} GB |")

    if out["streams"]:
        print()
        print("## Streaming recognizer")
        print()
        print("| Model | Rec. | Chunk | Word shown after it is spoken: median / p90 / max | Text complete after a hand-over's "
              "last word: median / p90 / max | Slowest 160 ms step | WER | CPU s per audio min | Load | Memory |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for r in out["streams"]:
            a, d = r["age"], r["delay"]
            cyr = f" ({r['cyrillic'] * 100:.0f}% Cyrillic)" if r["cyrillic"] > 0.01 else ""
            print(f"| {r['model']} | {r['recording']}, hint {r['language']} | {r['chunkMilliseconds']} ms | "
                  f"{a['median']:.2f} / {a['p90']:.2f} / {a['max']:.2f} s | {d['median']:.2f} / {d['p90']:.2f} / {d['max']:.2f} s | "
                  f"{r['step']['max']:.2f} s | {r['wer']:.1f}%{cyr} | {r['cpuPerAudioMinute']:.1f} | {r['loadSeconds']:.1f} s | "
                  f"{r['footprintMB'] / 1024:.1f} GB |")

    if out["replays"]:
        print()
        print("## Through the app's live preview, in real time")
        print()
        print("| Model | Rec. | Played | Lines | Shown while speaking | Text after a hand-over's last word: median / p90 / max | "
              "First words after a turn begins: median / max |")
        print("| --- | --- | --- | --- | --- | --- | --- |")
        for r in out["replays"]:
            d, f = r["delay"], r["firstWords"]
            missing = f" ({r['missing']} never)" if r["missing"] else ""
            print(f"| {r['model']} | {r['recording']} | {r['seconds']:.0f} s | {r['lines']} | {r['partials']} | "
                  f"{d['median']:.2f} / {d['p90']:.2f} / {d['max']:.2f} s{missing} | {f['median']:.2f} / {f['max']:.2f} s |")


if __name__ == "__main__":
    main()