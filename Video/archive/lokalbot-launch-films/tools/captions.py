#!/usr/bin/env python3
"""Captions from a film's timeline: <film>/captions.srt and captions.vtt, each narration line split at its
punctuation into chunks of at most 48 characters, timed from the word times; the meeting line is labelled.

    python3 tools/captions.py <film>
"""
import json, os, re, sys

film = sys.argv[1]
tl = json.load(open(os.path.join(film, "timeline.json")))
MAX = 48


def dedupe(words):
    """whisper sometimes repeats a line's opening words at the end with near-zero durations; drop that tail"""
    for i in range(1, len(words)):
        tail = [w[0] for w in words[i:]]
        if len(tail) >= 3 and tail == [w[0] for w in words[:len(tail)]]:
            return words[:i]
    return words


def norm(w):
    return re.sub(r"[^a-z0-9]", "", w.lower())


def align(toks, words):
    """the time each script token starts: matched to whisper's words by text, in order; proportional where it misses"""
    out, j, n, m = [], 0, len(toks), len(words)
    for i, tok in enumerate(toks):
        head = norm(tok.split("-")[0]) or norm(tok)
        hit = next((k for k in range(j, min(m, j + 4)) if norm(words[k][0]).startswith(head[:4]) or head.startswith(norm(words[k][0])[:4] or "\0")), None)
        if hit is None:
            out.append(words[min(m - 1, round(i * m / n))][1])
        else:
            out.append(words[hit][1]); j = hit + 1
    return out


def chunks(text, words):
    """clauses at punctuation; a clause longer than MAX splits into balanced halves at a word boundary"""
    toks = text.split(); starts = align(toks, words)
    clauses, cur = [], []
    for i, w in enumerate(toks):
        cur.append(i)
        if re.search(r"[.,:;?!]$", w): clauses.append(cur); cur = []
    if cur: clauses.append(cur)
    merged = []
    for c in clauses:                       # rejoin a short clause ("LokalBot.") with the next when it fits
        if merged and len(" ".join(toks[j] for j in merged[-1] + c)) <= MAX and len(" ".join(toks[j] for j in merged[-1])) < 14:
            merged[-1] = merged[-1] + c
        else:
            merged.append(c)
    out = []
    for c in merged:
        text_c = " ".join(toks[j] for j in c)
        if len(text_c) <= MAX:
            out.append(c); continue
        best = min(range(1, len(c)), key=lambda k: abs(len(" ".join(toks[j] for j in c[:k])) - len(" ".join(toks[j] for j in c[k:]))))
        out += [c[:best], c[best:]]
    return [[starts[c[0]], " ".join(toks[j] for j in c)] for c in out]


cues = []
for v in tl["vo"]:
    cs = chunks(v["text"], dedupe(v["words"]))
    for k, (t0, s) in enumerate(cs):
        t1 = cs[k + 1][0] if k + 1 < len(cs) else v["end"] + 0.15
        cues.append([t0, t1, s])
if "meet" in tl:
    m = tl["meet"]; cues.append([m["t"], m["end"] + 0.15, "[Meeting] " + m["text"]])
cues.sort()
for a, b in zip(cues, cues[1:]):
    a[1] = min(a[1], b[0] - 0.02)


def ts(t, sep):
    h, r = divmod(t, 3600); mi, s = divmod(r, 60)
    return f"{int(h):02d}:{int(mi):02d}:{int(s):02d}{sep}{int(round((s - int(s)) * 1000)):03d}"


srt = [f"{i}\n{ts(a, ',')} --> {ts(b, ',')}\n{s}" for i, (a, b, s) in enumerate(cues, 1)]
open(os.path.join(film, "captions.srt"), "w").write("\n\n".join(srt) + "\n")
vtt = [f"{ts(a, '.')} --> {ts(b, '.')}\n{s}" for a, b, s in cues]
open(os.path.join(film, "captions.vtt"), "w").write("WEBVTT\n\n" + "\n\n".join(vtt) + "\n")
print(f"{film}: {len(cues)} cues")
for a, b, s in cues:
    print(f"{a:6.2f}–{b:6.2f}  {s}")
