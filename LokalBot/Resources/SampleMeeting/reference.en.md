# Sample: Orders API delivery window

Reference transcript of the LokalBot sample meeting: what each synthetic voice was asked to say, with the time each turn starts in the recording. The people and the company are fictional.

**[00:00] Maya:** This is the LokalBot sample meeting. The voices are synthetic, and the company and the people in it are made up.

**[00:07] Maya:** Hi Daniel. Can you hear me okay?

**[00:09] Daniel:** Loud and clear, Maya. Sorry I'm a minute late, my build was still running.

**[00:14] Maya:** No problem. Let's sort out the delivery window for the Orders API.

**[00:19] Daniel:** Sure. Quick context: support wants customers to see a delivery window, like between two and four in the afternoon, instead of the single ETA time we return today.

**[00:30] Maya:** Right. And Priya from partner success says three of our biggest partners asked for the same thing.

**[00:37] Maya:** So, the plan from last week: we replace the ETA field with a new delivery window object, and we ship it as version three of the API.

**[00:46] Daniel:** That was the plan. The window would be two timestamps, a start and an end, both in UTC. I can have version three ready by November eighteenth.

**[00:56] Maya:** Okay. Decision for now: version three, the delivery window replaces ETA, and we target November eighteenth.

**[01:05] Daniel:** Performance is fine either way. I measured it yesterday, and p95 latency stays at about a hundred and eighty milliseconds.

**[01:13] Maya:** Good. What about the mobile app?

**[01:16] Daniel:** Tomás says the mobile team can pick it up in release four point two, but not earlier.

**[01:21] Maya:** That's fine. And testing?

**[01:24] Daniel:** Lena will add contract tests. She needs two days once the schema is frozen.

**[01:29] Daniel:** Actually, before we lock this in. I went through the partner integrations last night. Forty-two partners call the orders endpoint, and nineteen of them use generated clients that fail when a field they expect is missing. If we remove ETA, those nineteen break the day we ship.

**[01:46] Maya:** Nineteen out of forty-two. That's almost half of them. And a version three means every single partner has to migrate.

**[01:54] Daniel:** Exactly. Fernhill alone took four months to move to version two.

**[01:59] Maya:** Then let's change the decision. No version three. The response stays backward-compatible: ETA stays exactly as it is, and the delivery window is added as a new, optional field. If we don't know the window, we leave the field out.

**[02:15] Daniel:** Optional, left out when it's unknown, ETA unchanged, and we stay on version two. That's less work, too. I can ship it by November eleventh instead of the eighteenth.

**[02:27] Maya:** Great. So, for the notes: this replaces what we said at the start. The response stays backward-compatible, the delivery window is optional, and we ship on November eleventh.

**[02:39] Daniel:** Should I tell Lena the schema is frozen, then?

**[02:42] Maya:** Yes, go ahead. And Priya will email the three partners who asked for it. Daniel, can you update the API spec and the changelog?

**[02:52] Daniel:** Yes, I'll have both done by Friday.

**[02:54] Daniel:** One thing we still haven't figured out: do we backfill delivery windows for orders that were created before the change, or only for new orders?

**[03:03] Maya:** Hm. A backfill means rerunning the estimator on about two million open orders. I honestly don't know if that's worth it.

**[03:12] Daniel:** Me neither. It depends on whether partners even look at old orders.

**[03:17] Maya:** Let's leave it open for now. I'll ask Priya whether partners need it for old orders.

**[03:22] Daniel:** Okay. So the backfill is still open.

**[03:26] Maya:** Yes. Thanks, Daniel. That's it for today.

