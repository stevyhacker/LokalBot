---
duration: 30
format: 1920x1080
fps: 30
music: none
---

# Storyboard

| # | Time (s) | Picture | Headline | Source |
| - | --- | --- | --- | --- |
| 1 | 0.0–2.9 | Kinetic hook, two lines land word by word | — | type only |
| 2 | 2.9–5.1 | App icon pops, wordmark, "finds it in seconds." | — | `assets/lokalbot-icon.svg` |
| 3 | 5.0–10.1 | Quick Recall window rises; "Redis" typed live; results for screens and meetings; ↓ ↓ moves the selection (keycap overlay) | One search: meetings + saved screen text | take `t-recall` 0.40–5.91 s at 1.08× |
| 4 | 10.1–13.6 | Meeting summary; cursor clicks the 00:00:26 citation; app jumps to the highlighted transcript line; push-in | Every decision, cited | `t-meeting` 0.90–4.61 s at 1.06× |
| 5a | 13.6–16.0 | "failover" typed into transcript search, 1 of 2 matches highlighted | Search every word | `t-transcript` 1.55–3.95 s |
| 5b | 16.0–18.1 | Ask answer with evidence; cursor opens citation 1, lands on the source line | Ask, then check the source | `t-ask` 0.55–2.65 s |
| 6a | 18.1–20.0 | Today: action checked off, Undo toast | Clear what needs you | `t-today` 0.10–2.00 s |
| 6b | 20.0–21.5 | Timeline: work session opened, evidence panel | Retrace your day | `t-timeline` 2.10–3.60 s |
| 7 | 21.5–24.7 | Writing preview: Insert suggestion accepts the ghost text; hold on the accepted frame under a push-in | Autocomplete that runs on your Mac | `t-writing` 0.00–1.40 s + 1.8 s hold |
| 8 | 24.7–30.0 | End card: icon, wordmark, tagline, four fact chips, install line, lokalbot.com | — | type + icon |

Cursor and click ripples are editorial overlays placed at the click positions and times logged by the recorder (`*.events.json`); screen pixels are unchanged. Scenes 4–7 share one window frame so cuts read as in-app navigation.
