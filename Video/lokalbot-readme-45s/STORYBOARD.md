---
duration: 45
format: 1920x1080
fps: 30
music: none
---

# Storyboard

## Part 1: motion graphics (0–15 s)

| # | Time (s) | Picture | Type |
| - | --- | --- | --- |
| A | 0.0–5.0 | A four-person call card with the speaking tile ringed and a speech bubble ("Let's lock the caching layer. I propose Redis."); it slides left as a team-chat window arrives and a highlight sweeps "booked for Thursday". On "gone", the bubble's words scatter, the tiles grey out to "Call ended", and the chat window minimises. The first frame is the README poster, so line one, the call and the bubble are already on screen. | "You heard it in a meeting." / "You saw it on your screen." / "Then it was gone." |
| B | 4.9–10.25 | The app icon pops with a ring pulse. A Meetings card (waveform, three timestamped lines) and a Screen text card (the "Save screen text" toggle switches on, a scan beam passes over a window, two lines are extracted; the toggle pulses on "turn it on") feed it along dotted paths, then fly into it. The icon moves onto the next beat's laptop screen. | "LokalBot keeps both." / "Your calls, and what you saw on screen, if you turn it on." |
| C | 10.1–15.15 | Laptop line art draws around the icon. Five model rows slide in (role, model, format and size), each fills a load bar and reports "On this Mac": Qwen3-ASR 1.7B, Qwen3.5 4B, Nemotron 3, Harrier 0.6B, LFM2.5 1.2B. The Qwen rows glow on "Qwen", Nemotron on "Nemotron". On "do the work", dotted links run from the rows into the laptop and an activity meter pulses on its screen; chips No cloud / No account / No meeting bot land under it. | "Local AI models," … "on your Mac." |
| D | 14.45–16.05 | The Quick Recall panel rises with an empty field and a blinking caret, drawn to match the real panel; the recorded take fades in over it at 15.6, just as "Redis" is typed. | "When you need it, just search." |

## Part 2: the real app (15.6–45 s)

A chip after each headline names the local model behind that feature (see README, Models).

| # | Time (s) | Picture | Headline (model chip) | Source |
| - | --- | --- | --- | --- |
| 3 | 15.6–21.4 | Quick Recall: "Redis" typed live; results for screens and meetings; ↓ ↓ moves the selection (keycap overlay); slow push-in | One search: meetings + saved screen text (Harrier 0.6B) | take `t-recall` 0.30–6.10 s |
| 4 | 21.4–25.0 | Meeting summary; cursor clicks the 00:00:26 citation; app jumps to the highlighted transcript line | Every decision, cited (Qwen3.5 4B) | `t-meeting` 0.90–4.50 s |
| 5a | 25.0–28.6 | "failover" typed into transcript search, matches highlighted | Search every word (Qwen3-ASR 1.7B) | `t-transcript` 1.40–5.00 s |
| 5b | 28.6–31.7 | Ask answer with evidence; cursor opens a citation, lands on the source line | Ask, then check the source (Qwen3.5 4B) | `t-ask` 0.20–3.30 s |
| 6a | 31.7–34.0 | Today: action checked off, Undo toast | Clear what needs you | `t-today` 0.20–2.50 s |
| 6b | 34.0–36.8 | Timeline: two work sessions opened, evidence panel | Retrace your day | `t-timeline` 0.50–3.30 s |
| 7 | 36.8–40.8 | Writing preview: Insert suggestion accepts the ghost text; hold on the last frame under a push-in | Autocomplete that runs on your Mac (LFM2.5 1.2B) | `t-writing` 0.20–3.60 s + 0.6 s hold |
| 8 | 40.8–45.0 | End card: icon, wordmark, tagline, four fact chips, install line, lokalbot.com | — | type + icon |

Every take plays at its recorded speed. Cursor and click ripples are editorial overlays placed at the click positions and times logged by the recorder (`*.events.json`); screen pixels are unchanged. Scenes 4–7 share one window frame so cuts read as in-app navigation. The filming environment per take is listed in `../lokalbot-readme-30s/README.md`.
