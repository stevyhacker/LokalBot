# Replay — November 21, 2026 at 8:41 PM
**Duration:** in progress · **App:** Benchmark · **Words:** 533 words · **Template:** Meeting · **Language:** English · **Model:** qwen3.5-4b · on this PC

## TL;DR

- **Them 1:** The backfill decision is left open pending Priya's inquiry about partner needs for old orders. — [00:03:17]
- **Them 2:** Support requests customers see a delivery window (start and end times) instead of a single ETA. — [00:00:19]
- **Them 2:** Lena will add contract tests requiring two days once the schema is frozen. — [00:01:24]

## Key points

- **Them 2:** Support requests customers see a delivery window (start and end times) instead of a single ETA. — [00:00:19]
- **Them 1:** Three of the biggest partners requested the delivery window feature. — [00:00:30]
- **Them 2:** Nineteen out of forty-two partners use generated clients that break if the ETA field is removed. — [00:01:29]
- **Them 1:** The response remains backward-compatible by keeping ETA unchanged and adding the delivery window as an optional field. — [00:01:59]
- **Them 2:** The delivery window field is omitted when the window is unknown. — [00:02:15]
- **Them 2:** The project will ship on November eleventh instead of the originally planned November eighteenth. — [00:02:15]
- **Them 2:** Lena will add contract tests requiring two days once the schema is frozen. — [00:01:24]
- **Them 2:** The mobile team can integrate the delivery window in release four point two but not earlier. — [00:01:16]
- **Them 2:** It is unresolved whether to backfill delivery windows for orders created before the change or only for new orders. — [00:02:54]
- **Them 1:** Backfilling would require rerunning the estimator on approximately two million open orders. — [00:03:03]
- **Them 2:** It is uncertain whether partners review old orders to determine the value of backfilling. — [00:03:12]
- **Them 1:** The backfill decision is left open pending Priya's inquiry about partner needs for old orders. — [00:03:17]

## Decisions

None

## Action items

### Me
None

### Others
- [ ] Them 2: Update the API spec and changelog to reflect the backward-compatible delivery window change. — due Friday — [00:02:27]
- [ ] Them 1: Contact Priya to determine if partners require delivery window backfill for pre-change orders. — [00:03:17]

### Owner unclear
- [ ] Inform Lena that the schema is frozen so she can begin adding contract tests. — [00:02:27]

## Open questions

None
