# README hero

The root [README](../../README.md) opens with [lokalbot-demo-light.gif](lokalbot-demo-light.gif),
a 30-second loop of seven features and an end card, each with its own fictional
example: a Quick Recall search for "demo presentation" that finds Keynote and
Mail screen text and two meetings; a meeting summary whose action-item citation
opens the transcript at that line; an Ask answer whose citation does the same;
autocomplete in TextEdit finishing "the Team plan will be $15" with "per seat,
billed annually." from a meeting; a dictated request written into TextEdit as
a team update; a Timeline work session opening with its evidence; and the
People page switching from Maya to Leo. The end card names the features not
shown. There is one light version for both appearances.

Every scene is a recording of a real window driven by real keyboard and
pointer events. Window pixels are only cropped, scaled, or retimed by whole
frames: Quick Recall's typing plays at 2.5× and the dictation scene's Compose
wait at 2×. The caption band, step dots, cursor, click ripple and keycaps were
drawn afterwards at the recorded times and positions. The installed app's
library and settings were not used, and no UI tests were run.

- **Search, meeting, Ask, Timeline and People:** the LokalBot UI Test Host
  built from `master` at
  [`5a53f66`](https://github.com/stevyhacker/lokalbot/tree/5a53f6668650703dd63e890810ad0065bc868e8c)
  with `CODE_SIGNING_ALLOWED=NO` and the filming-only patch in
  `Video/lokalbot-readme-hero/filming/`, recorded on **October 26, 2026**. It
  suppresses capture and inference, so transcripts, summaries and the Ask
  answer are fixtures; the search results are the app's own search over the
  library. The library is `Scripts/seed_demo_library.py --profile studio`,
  seeded with every meeting on the local clock.
- **Autocomplete and dictation:** cut from the previous version of this file
  (at `43d72b9`), recorded on **October 22, 2026** by `Scripts/readme-gif/`
  from a filming copy of the `v0.11.2` release commit
  [`749987d`](https://github.com/stevyhacker/lokalbot/tree/749987d60be964dcbf154707e225ae3fcc95d0cf)
  whose only change makes the suggestion panel visible to screen capture.
  These are live: the suggestion comes from Gemma 4 E2B with meeting memory,
  and dictation is Parakeet TDT 0.6B v3 transcribing a macOS voice (Samantha)
  through the built-in microphone, then Compose with Qwen3.5 4B. The partial
  transcript shown while dictating is the model's unedited live output.

[Video/lokalbot-readme-hero/README.md](../../Video/lokalbot-readme-hero/README.md)
explains how to film and rebuild it.

| File | Dimensions | Length | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `lokalbot-demo-light.gif` | 1412 × 1020 | 30.0 s at 15 fps | 1,639,980 | `8f8cb7b7bc0fd882be560a80b5ad17ebc5b051164026d26153854069dbf48f6a` |

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
