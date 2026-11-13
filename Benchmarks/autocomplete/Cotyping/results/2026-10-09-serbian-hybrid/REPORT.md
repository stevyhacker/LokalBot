# Serbian check of the local + cloud hybrid — 2026-10-09

The hybrid from the 2026-10-06 proposal does not clear its bar in Serbian. The
bar was at least 3 points more keystrokes saved than gated local E2B inside
the top-up and pause slots. The best case, cloud at every top-up and pause
with no typing deadline, saved **+1.0 point** with visible text and **+0.6**
without, and roughly doubled wrong suggestions. Cloud at top-ups only added
0.1–0.2 points. The cloud alone saved fewer keystrokes than local.

## Setup

- 60 Latin-script Serbian/Montenegrin messages (48 labelled Serbian), 15 words
  on average, rebuilt with the eval-v2 builder from the VarDial 2024 BCMS
  dataset (Zenodo 10998042, CC BY-SA 4.0). Not the same 60 as the 2026-10-06
  eval. 1,500 checkpoints per variant: every word boundary after the first,
  and after the first letter of every word of three or more letters.
- Variants: the three previous messages as visible text above the field (the
  default for new installs), and no visible text (existing installs).
- Engines: local Gemma 4 E2B Base Q6 and Gemma 4 E4B Base (UD Q5_K_XL), both
  with the shipped confidence gate, on master 32381e9 (llama.cpp b11474); and
  Qwen3.8 27B on Cerebras through chat with thinking off, direct API.
- Scoring (eval v2): a simulated writer Tabs while the suggested word is right
  and types otherwise. A suggestion counts only if model or request time plus
  80 ms of app overhead beats the next keystroke, except right after an
  accepted word. Hybrid "top-ups" uses the cloud only right after an accepted
  word; "top-ups + pauses" uses it at every word boundary where it lands in
  time, with mid-word always local. 95% intervals resample whole messages.

## Keystrokes saved, with visible text

| Engine | No deadline | 300 ms per key | 200 ms per key | Wrong per 100 words (no deadline) |
| --- | ---: | ---: | ---: | ---: |
| Local E2B, gated | 14.7% | 14.7% | 14.3% | 55 |
| Local E4B, gated | 14.7% (−0.0) | 8.9% (−5.9) | 4.7% (−9.6) | 57 |
| Cloud alone | 10.1% (−4.7) | 3.8% (−11.0) | 0.0% (−14.3) | 103 |
| Hybrid, top-ups | 14.9% (+0.2, n.s.) | 14.9% (+0.2) | 14.5% (+0.2) | 66 |
| Hybrid, top-ups + pauses | 15.7% (**+1.0**, +0.6 to +1.5) | 15.2% (+0.4) | 14.5% (+0.2) | 104 |

## Keystrokes saved, without visible text

| Engine | No deadline | 300 ms per key | 200 ms per key | Wrong per 100 words (no deadline) |
| --- | ---: | ---: | ---: | ---: |
| Local E2B, gated | 11.6% | 10.3% | 5.7% | 60 |
| Local E4B, gated | 12.0% (+0.4, n.s.) | 7.3% (−3.0) | 2.1% (−3.7) | 61 |
| Cloud alone | 7.3% (−4.3) | 2.8% (−7.5) | 0.0% (−5.7) | 116 |
| Hybrid, top-ups | 11.6% (+0.1) | 10.3% (+0.0) | 5.8% (+0.0) | 70 |
| Hybrid, top-ups + pauses | 12.2% (+0.6, +0.3 to +1.0) | 10.5% (+0.2) | 5.8% (+0.0) | 116 |

## Why

- The cloud predicts the next whole word better (11.9% vs 5.6% of word
  boundaries right, with visible text), but it is much worse at finishing a
  word after its first letter (9.4% vs 22.7%), and it has no confidence gate,
  so it shows about twice as many wrong suggestions.
- Top-ups are a small slot: about 15–17 cloud calls per 100 words, and they
  replace suggestions local mostly gets right already.
- Serbian requests were slower than English from this Mac: p50 249–264 ms,
  p95 687–868 ms, so at a 200 ms typing pace the cloud is never in time outside
  top-ups.

## Side finding: E4B

With the confidence gate on, E4B saved no more keystrokes than E2B on this
sample (−0.0 with visible text, +0.4 n.s. without) and loses 3–10 points once
typing speed matters. The 2026-10-06 gain (+1.4 to +2.3) was measured before
the gate and on a different 60 messages, so treat the E4B-for-Serbian opt-in
as unproven.

Scorer: `score_hybrid.py` (session scratchpad, beside the eval-v2 scripts in
`LokalBot-cotyping-reliability/Benchmarks/Cotyping/eval2/`). Cost about $0.40.
