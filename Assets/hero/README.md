# README hero

The root [README](../../README.md) opens with [lokalbot-demo-light.gif](lokalbot-demo-light.gif),
a 28-second loop of one fictional story: a team set launch pricing on a call,
and the decision turns up wherever it is needed. Five scenes: a Quick Recall
search for "pricing" that finds screen text and the meeting, a summary decision
that opens the transcript at its source line, an Ask answer with its sources,
autocomplete in TextEdit finishing "the Team plan will be $15" with "per seat,
billed annually.", and a dictated request ("Write a one-line team update with
the launch pricing.") written into TextEdit with that price. There is one
light version for both appearances.

Each scene is a recording of a real window driven by real keyboard and
pointer events; the window's pixels are unchanged apart from cropping and
scaling. The caption above each scene, the footer, and the ring drawn where a
click landed were added afterwards. The library is the fictional one in
`Scripts/readme-gif/seed_library.py`. All recordings were made on
**October 22, 2026** from the `v0.11.2` release commit
[`749987d`](https://github.com/stevyhacker/lokalbot/tree/749987d60be964dcbf154707e225ae3fcc95d0cf),
with a temporary library and settings suite. The installed app's library and
settings were not used, and no UI tests were run.

- **First three scenes:** the LokalBot UI Test Host, built with
  `CODE_SIGNING_ALLOWED=NO`. It suppresses capture and inference, so the
  transcript, summary, decisions and the Ask answer are fixtures; the search
  results are the app's own search over the library.
- **Autocomplete and dictation:** a filming copy of the same release whose
  only change makes the suggestion panel visible to screen capture
  (`build_filming_app.sh`). These are live: the suggestion comes from Gemma 4
  E2B with meeting memory, and dictation is Parakeet TDT 0.6B v3 transcribing
  a macOS voice (Samantha) through the built-in microphone, then Compose with
  Qwen3.5 4B. TextEdit types plain text in its default monospace font.

[Scripts/readme-gif/README.md](../../Scripts/readme-gif/README.md) explains how
to record and rebuild it.

| File | Dimensions | Length | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `lokalbot-demo-light.gif` | 1840 × 1344 | 28.4 s at 20 fps | 1,345,291 | `0e1f8286db8bb0fb1126e6225d6d438661da7b3ccb1bf6b50521e29d7229e35a` |

## Still composite

The earlier README hero, [lokalbot-hero-light.png](lokalbot-hero-light.png)
and [lokalbot-hero-dark.png](lokalbot-hero-dark.png), stays for the social
preview card (`Assets/social-preview/social-preview.html`). Each is a composite:
two unedited captures of the native SwiftUI views on a drawn background, under
the tagline, with "saw" and "said"
labels beside Quick Recall's Screens and Meetings groups. Nothing inside the
captures was retouched. All content is fictional demo data from
`Scripts/seed_demo_library.py --profile studio`. Both images pair the holiday
shoot planning call with a search on a different topic, "demo presentation";
the headline already says "Mac", so the search avoids it.

All four captures came from one seeded library on **October 9, 2026**, so the
times they show agree. The LokalBot UI Test Host was built from the `v0.10.2`
release commit
[`1ade074`](https://github.com/stevyhacker/lokalbot/tree/1ade074a90510866d8909dc17e2e1dde372831b7)
(build 46) and ran with a temporary storage root and UserDefaults suite. The
installed app and user library were not used, and no UI tests were run.

| Capture | Settings |
| --- | --- |
| Meeting window | `LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary`, `LOKALBOT_CAPTURE_SIZE=1400x880` at 2× |
| Quick Recall | `LOKALBOT_UI_TEST_WINDOW=quick-recall LOKALBOT_QUICK_RECALL_QUERY="demo presentation"`, `LOKALBOT_CAPTURE_SIZE=660x512` with `LOKALBOT_CAPTURE_SCALE=4` |

Each was captured with `LOKALBOT_CAPTURE_APPEARANCE=light` and `dark`, plus
`LOKALBOT_DISMISS_ONBOARDING=1` and the rest of the environment from
`capture()` in `Scripts/capture-screenshots.sh`.

Compose a hero from two captures (requires Google Chrome):

```bash
python3 Scripts/render_readme_hero.py --theme light --meetings meetings.png --recall quick-recall.png --out Assets/hero/lokalbot-hero-light.png
```

Both published files are that script's output for the captures above.

| File | Dimensions | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `lokalbot-hero-light.png` | 3200 × 1800 | 3,926,159 | `9505bfdf22359ab1503a353bc8b5d82e93b65c71814854d7f579e2c3b073c465` |
| `lokalbot-hero-dark.png` | 3200 × 1800 | 2,905,569 | `3b7c554d264c66bea2831b7e56b5bffb85f0cb9f2b33ed1c75d1e0b59ae4e5c3` |
