# Replay — November 21, 2026 at 8:44 PM
**Duration:** in progress · **App:** Benchmark · **Words:** 533 words · **Template:** Meeting · **Language:** English · **Model:** inkling-2-mini · on this PC

## TL;DR

- **Them 1:** Delivery window for the Orders API changed from a version-3 ETA replacement to a backward-compatible optional field on version 2, shipping November 11. — [00:01:59]
- **Them 2:** 19 of 42 partners use generated clients that break if ETA is removed; Fernhill alone took four months to migrate to version 2. — [00:01:29]

## Key points

- **Them 2:** Support wants customers to see a delivery window (e.g., between two and four in the afternoon) instead of the single ETA time returned today. — [00:00:19]
- **Them 1:** Priya from partner success says three of the biggest partners asked for the same thing. — [00:00:30]
- **Them 1:** The plan from last week: replace the ETA field with a new delivery window object and ship it as version three of the API. — [00:00:37]
- **Them 2:** The window would be two timestamps, a start and an end, both in UTC; version three could be ready by November eighteenth. — [00:00:46]
- **Them 2:** Performance is fine either way; p95 latency stays at about a hundred and eighty milliseconds. — [00:01:05]
- **Them 2:** Tomás says the mobile team can pick it up in release four point two, but not earlier. — [00:01:16]
- **Them 2:** Lena will add contract tests; she needs two days once the schema is frozen. — [00:01:24]
- **Them 2:** Forty-two partners call the orders endpoint; nineteen use generated clients that fail when a field they expect is missing, so removing ETA breaks them on ship day. — [00:01:29]
- **Them 2:** Fernhill alone took four months to move to version two. — [00:01:54]

## Decisions

None

## Action items

### Me
None

### Others
- [ ] Them 2: Update the API spec and the changelog by Friday. — due Friday — [00:02:42]
- [ ] Them 1: Ask Priya whether partners need the delivery window backfill for old orders. — [00:03:17]

### Owner unclear
- [ ] Add contract tests once the schema is frozen (needs two days). — [00:01:24]
- [ ] Email the three partners who asked for the delivery window. — [00:02:42]
- [ ] Tell Lena the schema is frozen. — [00:02:39]

## Open questions

- **Them 2:** Whether to backfill delivery windows for orders created before the change or only for new orders is unresolved. — [00:02:54]
