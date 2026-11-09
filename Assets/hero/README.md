# README hero

The root [README](../../README.md) opens with
[lokalbot-demo-light.gif](lokalbot-demo-light.gif) or
[lokalbot-demo-dark.gif](lokalbot-demo-dark.gif), whichever matches the reader's
appearance: a loop of about 48 seconds at 12 fps through the six clips at the top of the
home page, each under a caption. In order, a call recorded with no bot, its live
transcript, its notes and a citation; a search across screens and meetings; autocomplete
finishing a sentence from a meeting; a dictated request written at the cursor; an Ask
answer and its source; and Claude Code asking LokalBot about a meeting.

The [Chinese README](../../README.zh-CN.md) keeps its Mandarin meeting screenshot as the
lead image and shows this loop below it.

Each scene is cut from `web/assets/demos/<clip>-wide-<appearance>.mp4`, so what those
clips are, and what is real in them, is in
[Video/lokalbot-landing-demos/README.md](../../Video/lokalbot-landing-demos/README.md).
[readme_gifs.py](../../Video/lokalbot-landing-demos/readme_gifs.py) builds these files and
everything in [Assets/readme](../readme). It trims scenes, plays the autocomplete typing at
1.6× and the dictation wait at 2×, and draws the caption band. Nothing inside a frame
changes.

The sections further down the README use the other loops and stills in `Assets/readme`,
cut the same way. The stills are single frames of the `meetings` and `search` clips.

| File | Dimensions | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `lokalbot-demo-light.gif` | 1120 × 784 | 8,362,342 | `6720727dfb4b42c803f21923ff56a188a3592bbdec4b2764262e4cb152eefaee` |
| `lokalbot-demo-dark.gif` | 1120 × 784 | 8,943,293 | `0307ef9fd54934c6154df1a172527203b2970c77793bda99f32fd3d57e316301` |
| `agents-dark.gif` | 960 × 600 | 130,299 | `16f7e0090f8f25675bc162690799f1c9406cf6a7216120e5fdd1eb5181f4ac95` |
| `agents-light.gif` | 960 × 600 | 115,498 | `6ce9b5ec490b7d28d79a04c6cd2226330b6c585bf6cf5a20be876a476607ddf0` |
| `ask-dark.gif` | 960 × 600 | 3,413,254 | `c4cb6c10d4cb7a3f9308eed794af55f004f251ceda5a681cf23da4559095c44d` |
| `ask-light.gif` | 960 × 600 | 3,230,989 | `d6b31ba60baa85b54928a8008c33039ae7561ffd4b1beaf8acaa802c4b676158` |
| `dictation-dark.gif` | 960 × 600 | 173,025 | `11d3836eb7bf448f401b02e561d4b6789e790800cc94b2e4658617d2406c0a04` |
| `dictation-light.gif` | 960 × 600 | 167,589 | `b8c7123dedac2a5fbfc2e17075060b93c9b4edc44d7617445b9f11fbf21cdf55` |
| `files-dark.gif` | 960 × 600 | 349,124 | `38e058400033b7ca3a3689988554ced9e2e9d57922aeef97667e7e27c0da3b08` |
| `files-light.gif` | 960 × 600 | 333,089 | `29a23605ef4694b0a1e2f20bcd61cf624d11d6b33a0f8d9fe77bf524d973a74e` |
| `meetings-dark.png` | 1600 × 940 | 333,004 | `e7495b49cfdb12dada6214c0107dd9691adc0f2cc359668d31a403e4e5d43c08` |
| `meetings-light.png` | 1600 × 940 | 305,206 | `55fce58942ddacee8ae3c3028465ea381381893686a827acab9dc0f9e96b15a0` |
| `people-dark.gif` | 960 × 600 | 649,774 | `828b303fe867d14b102612df5a228d7e36dbbcf6a59b58f795005ece7860aa8a` |
| `people-light.gif` | 960 × 600 | 584,335 | `a7c718dddeffd13d77418c33dc1d79abda6df7d9db18ede80fbf3477e01d39ff` |
| `projects-dark.gif` | 960 × 600 | 1,249,066 | `a1daae1fa643267511790be721d741ef0dfb50a7cff0665dcabacc293b7621b6` |
| `projects-light.gif` | 960 × 600 | 1,097,758 | `78319d639295da4d12f5961afc2573b3e53190880c8fb997385677423a177f0c` |
| `search-dark.png` | 1600 × 1000 | 282,720 | `2fed1c9402b631fc5c1417bc171a13f28d08326a0b2bf045421570a778690fa6` |
| `search-light.png` | 1600 × 1000 | 258,956 | `270906ecc0dc16f774a092076781d3e10737d9dd3065ecf0404059dec49e401c` |
| `timeline-dark.gif` | 960 × 600 | 1,062,290 | `0e94ff4274c49de61efd57b97efd2711ef535ee675c6537ac3a9e36de0e4e810` |
| `timeline-light.gif` | 960 × 600 | 978,863 | `a355d1ca6672cfc699a606ccd83540384cc5e7f21a293caf61bf4942ea034e22` |
| `today-dark.gif` | 960 × 600 | 1,696,725 | `f87871471ed2ea61d585d95e9e74d27a4ad27bb85bb2ba7d5b0db9942cc088aa` |
| `today-light.gif` | 960 × 600 | 1,625,028 | `b4f63d998956575f73be411fba4a4ddea381b7be306d1627deb64f7b20a149a9` |

The hero before this one is in git at
[`8378415`](https://github.com/stevyhacker/lokalbot/blob/8378415/Assets/hero/lokalbot-demo-light.gif),
and [Video/lokalbot-readme-hero](../../Video/lokalbot-readme-hero/README.md) explains how it
was filmed.

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
