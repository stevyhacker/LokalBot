# Replay — November 21, 2026 at 8:42 PM
**Duration:** in progress · **App:** Benchmark · **Words:** 533 words · **Template:** Meeting · **Language:** English · **Model:** qwen3.5-4b · on this PC

## TL;DR

- **Them 1:** This is the LokalBot sample meeting. The voices are synthetic, and the company and the people in it are made up. — [00:00:00]
- **Them 2:** Tomás says the mobile team can pick it up in release four point two, but not earlier. — [00:01:16]
- **Them 1:** So, for the notes: this replaces what we said at the start. The response stays backward-compatible, the delivery window is optional, and we ship on November eleventh. — [00:02:27]

## Key points

- **Them 1:** This is the LokalBot sample meeting. The voices are synthetic, and the company and the people in it are made up. — [00:00:00]
- **Them 2:** Loud and clear, Maya. Sorry I'm a minute late, my build was still running. — [00:00:09]
- **Them 2:** Quick context: support wants customers to see a delivery window, like between two and four in the afternoon, instead of the single ETA time we return today. — [00:00:19]
- **Them 1:** So, the plan from last week: we replace the ETA field with a new delivery window object, and we ship it as version three of the API. — [00:00:37]
- **Them 2:** That was the plan. The window would be two timestamps, a start and an end, both in UTC. I can have version three ready by November eighteenth. — [00:00:46]
- **Them 2:** Performance is fine either way. I measured it yesterday, and p95 latency stays at about a hundred and eighty milliseconds. — [00:01:05]
- **Them 2:** Tomás says the mobile team can pick it up in release four point two, but not earlier. — [00:01:16]
- **Them 2:** Lena will add contract tests. She needs two days once the schema is frozen. — [00:01:24]
- **Them 2:** Forty-two partners call the orders endpoint, and nineteen of them use generated clients that fail when a field they expect is missing. If we remove ETA, those nineteen break the day we ship. — [00:01:29]
- **Them 1:** Then let's change the decision. No version three. The response stays backward-compatible: ETA stays exactly as it is, and the delivery window is added as a new, optional field. If we don't know the window, we leave the field out. — [00:01:59]
- **Them 2:** Optional, left out when it's unknown, ETA unchanged, and we stay on version two. That's less work, too. I can ship it by November eleventh instead of the eighteenth. — [00:02:15]
- **Them 1:** So, for the notes: this replaces what we said at the start. The response stays backward-compatible, the delivery window is optional, and we ship on November eleventh. — [00:02:27]

## Decisions

None

## Action items

### Me
None

### Others
- [ ] Them 2: Update the API spec and the changelog by Friday. — due Friday — [00:02:39]
- [ ] Them 1: Ask Priya whether partners need delivery windows for old orders. — [00:02:54]

## Open questions

None
