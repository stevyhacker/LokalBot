# Live answers: questions answered from the work, 29 October 2026

Live answers look up a question the radar catches: first what LokalBot remembers (projects, open actions, memory), then meetings, screen text, documents, code, commits, and GitHub. Two replays ran on synthetic fixtures with Muse Wonder 1.0 at low reasoning, and Muse Spark 1.3 ran the radar passes. Folders were read for real: a pricing sheet and a launch brief made for the demo ([demo-files](../../../../Docs/meta-hackathon/demo-files/)), and this repository with `git` and `gh`.

## Questions about the work

- **Run.** `--radar-replay fixtures/synthetic-live-answers.json --answers --folders <this checkout>`. The fixture's `memory` holds a tracked project's "Where it stands" note and two open actions ([output](synthetic-live-answers-wonder.jsonl)).

| Question | Answer, from | Turns | Time | Cost |
|---|---|---:|---:|---:|
| Is the radar panel hidden when I share my screen? | Yes, by default (`AppSettings.swift:176`, `SettingDescriptor.swift:161`) | 5 | 18.2 s | $0.074 |
| What did we put as the Team plan price in the pricing sheet? | $12 per seat (the sheet's Team row) | 4 | 10.9 s | $0.026 |
| What's the target for paying teams by the end of Q1 in the launch brief? | 400 paying teams (the brief's PDF) | 4 | 8.4 s | $0.017 |
| Who's reviewing the onboarding emails again? | Marko (open actions, no lookup) | 1 | 2.5 s | $0.006 |
| Did the fix for the speaker labels in the desktop app get merged yet? | No answer: two merged and two open pull requests matched, so it didn't pick one | 6 | 26.2 s | $0.063 |

## The demo call

- **Run.** `--radar-replay fixtures/synthetic-demo-call.json --screens fixtures/screens --answers --folders <Northwind>,<LokalBot>`: the demo video's call with the pricing-sheet and code questions, the two synthetic captures for screen answers, and the folders `Scripts/meta-hackathon-demo.sh answers` makes ([output](synthetic-demo-call-answers.jsonl)).
- **Radar.** Nine items: two commitments, the two contradictions with "Launch planning", the decision, and four questions, one of them the opening line's "I just need the final numbers". 6 passes, $0.019, none rejected.
- **Answers.**

  | Question | Screen answer | Live answer, from | Turns | Time | Cost |
  |---|---|---|---:|---:|---:|
  | What are the final numbers for the pricing page? | none | Free $0, Team $12, Business $24 per seat; the annual discount is still open (the sheet's rows and the project's note) | 5 | 12.9 s | $0.026 |
  | What did we put as the Team plan price in the pricing sheet? | none | $12 per seat (the sheet's Team row) | 4 | 6.6 s | $0.014 |
  | What was trial-to-paid conversion last month? | 4.1% (the dashboard crop) | No answer: nothing in meetings or folders | 6 | 11.7 s | $0.027 |
  | Is the radar panel hidden when I share my screen? | none | Yes, by default (`AppSettings.swift:176`, `LiveRadarFloatingPanel.swift:59`, linked to GitHub at the checked-out commit) | 3 | 8.0 s | $0.036 |

## What changed because of these runs

- **The demo reads a clean copy of the repository.** With this checkout as a folder, the conversion answer cited `Docs/meta-hackathon/demo-script.md`, which describes the expected answer. The demo now reads a clone without the demo notes, fixtures, tests, and scripted film replies.
- **Document search ranks file names.** Spotlight doesn't index `~/Library`, where the demo library keeps its folders. File names were matched only when they held every query word, so Wonder needed three searches to find the sheet. Names are now ranked by the query's words, and "price" finds "pricing".
- **The call script leaves questions open.** A reply like "I'm pretty sure it is" made the radar treat the panel question as answered and skip it, so the script's reply is now "Hm, good question."

## Limits

- **Small sample.** Nine questions on synthetic fixtures; Wonder's lookups vary from run to run.
- **Stand-in memory.** The fixtures' `memory` stands in for what LokalBot would remember, and their earlier passages for meeting search. Screen search isn't available to live answers in replays.
- **Time.** Measured from the question being caught to the answer, not from the question being said. The radar catches a question about 3 s after it ends with fast live text.
