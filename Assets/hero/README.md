# README hero

The root [README](../../README.md) opens with [lokalbot-hero-light.png](lokalbot-hero-light.png)
or [lokalbot-hero-dark.png](lokalbot-hero-dark.png), whichever matches the
viewer's appearance. Each is a composite: two unedited captures of the native
SwiftUI views on a drawn background, under the tagline, with "saw" and "said"
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
