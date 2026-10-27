# Plan comparison CSV — notes for Sales and for you

*Prepared 2026-10-27 for the action item "Create a plan comparison as a CSV table Sales can paste into the deck" (Launch follow-up, Tue 2026-10-27 15:17, [00:00:36]).*

## The deliverable

`plan-comparison.csv` — one row per feature, columns for the two plans. Sales can open it, select all, and paste straight into the deck; the first row becomes the column headers.

## What is confirmed (with sources)

| Fact | Source |
|---|---|
| Paid plan is **$15 per seat, billed annually** | "Launch planning", Oct 27, 2026, [00:00:14]; confirmed in "Launch follow-up", Oct 27, 2026, [00:00:11] ("Pricing is locked") |
| **Free plan for teams of up to three** people | "Launch planning", Oct 27, 2026, [00:00:24]; confirmed in "Launch follow-up", [00:00:11] |
| **Onboarding is free for every paid team** | "Sales sync", Oct 26, 2026, [00:00:09] |
| Example math in the CSV (5 seats = $75/year) | derived from $15 × 5 — simple arithmetic, no new decision |

## What is NOT decided — left as [TBD] on purpose

Nothing in any recorded meeting covers these, so I did not invent them:

- **Plan names** — the meetings only ever say "free plan" and "paid plan". I used those neutral labels; if official product names exist, rename the column headers before the deck ships.
- **Seat cap / team size on the paid plan** — only the free plan's 3-person limit was decided.
- **Onboarding on the free plan** — the Sales sync decision ("every *paid* team") doesn't cover it.
- **Support, storage, integrations, admin/SSO** — never discussed.
- Also worth knowing for related drafts: monthly billing, refund terms, and proration were never decided (already flagged in the pricing FAQ draft from task 2).

**Ask whoever owns the pricing sheet (it was open during the "Launch follow-up" call, [00:00:05]) to fill the [TBD] cells, or raise them at the Tuesday check-in.**

## How Sales should paste it

1. Open `plan-comparison.csv` in any spreadsheet app.
2. Select the whole table and copy.
3. In the deck, paste as a table (Keynote/PowerPoint: Paste Special → keep as table/text) so the columns stay aligned.
4. The values contain no commas, so nothing will split wrongly.

## Internal-only context (do not put in the customer deck)

- Competitor reference: customers compare the product to **Cobalt at $18/seat**; the $15 price was set to come in under them ("Launch planning", Oct 27, 2026, [00:00:06]–[00:00:14]). Useful for Sales talk tracks, not for the plan table.
