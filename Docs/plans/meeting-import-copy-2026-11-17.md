# Meeting import — user-facing copy (draft)

_Status: draft for review, 2026-11-17. Nothing here is published. The README, website, and release notes change only when the person approves this copy._

## Pitch

> Import two years of Granola or Otter notes onto your disk in a minute, then delete your cloud account.

Short form for buttons and listings: **Bring your meetings with you.**

## README — a line under Features → "Remember what was agreed"

> **Already use another app?** Bring your history with you: **Recording → Import Meetings From** reads exports from Granola, Otter, Fireflies, Fathom, and Zoom, Screenpipe's database, Voice Memos, and MacWhisper. Notes, transcripts, and action items land in your library on your computer, the original files stay untouched, and importing the same export twice adds nothing twice.

## Website — section for the home page and the comparison pages

**Leave the cloud, keep your history.**
Export from Otter, Fireflies, Fathom, or Granola, choose the file in LokalBot, and every meeting is searchable here in seconds — transcripts with speakers, notes, and action items. Screenpipe, Zoom recordings, Voice Memos, and MacWhisper are read straight from your computer. Nothing is uploaded, nothing signs in, and LokalBot never changes the files it reads.

Per-comparison line (append to each `lokalbot-vs-<app>` page's "Switching" paragraph):
> Switching from <App>? Export your <App> conversations, then choose **Recording → Import Meetings From → <App>** in LokalBot. <How to export, from `exportHint`.>

## Release notes

- **Import meetings from other apps.** Recording → Import Meetings From brings in notes, transcripts, and action items from Granola, Otter, Fireflies, Fathom, Screenpipe, Zoom, Voice Memos, and MacWhisper. Re-importing skips what's already there. Agents can ask with `lokalbot-cli import`, and you approve it in LokalBot.

## Approval card (shipped in the app)

> **lokalbot-cli via claude** wants to import another app's meetings into LokalBot.
> **Import from Otter** — Copies notes, transcripts, and recordings into your library. The original files aren't changed.
> /Users/…/otter-export.zip · 214 new meetings, 12 already in your library · From 2024-11-02 to 2026-11-15

## Open questions for the person

- Lead the README hero with the import pitch, or keep it as a Features line?
- The approval card and import panel guidance are English-only in this version; the menu item and card line are translated.
