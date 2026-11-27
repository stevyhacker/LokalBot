# Store listing metadata

Versioned copy and screenshot shot lists for the Apple App Store and Google Play
listings of the LokalBot companion apps.

`Scripts/release/publish_app_store.py` and `Scripts/release/publish_google_play.py`
currently publish signed binaries and per-release What's New notes from
`Scripts/release/release-notes/<tag>.md`. The listing titles, subtitles,
keywords, descriptions, review notes, and screenshot plans here are the source
of truth to paste or sync into App Store Connect and Google Play Console.

## Layout

| Path | Store | Files |
| --- | --- | --- |
| [ios/en-US/](ios/en-US/) | App Store | `name.txt`, `subtitle.txt`, `promotional_text.txt`, `keywords.txt`, `description.txt`, `review_notes.txt`, `screenshots.md` |
| [android/en-US/](android/en-US/) | Google Play | `title.txt`, `short_description.txt`, `full_description.txt`, `review_notes.txt`, `screenshots.md` |

Field limits:
- App Store: Name <= 30 chars, Subtitle <= 30 chars, Promotional Text <= 170 chars, Keywords <= 100 chars, Description <= 4,000 chars.
- Google Play: Title <= 30 chars, Short Description <= 80 chars, Full Description <= 4,000 chars.

## Rules

- Keep Apple App Store files free of Android or Google Play references.
- Keep Google Play files free of iOS, iPhone, iPad, or App Store references.
- Keep iOS keywords comma-separated with no spaces and zero words duplicated
  from `name.txt` or `subtitle.txt`.
- Keep all copy plain, factual, and aligned with [PRIVACY.md](../../PRIVACY.md).
