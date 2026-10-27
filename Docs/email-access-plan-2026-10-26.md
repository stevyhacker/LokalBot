# Email in LokalBot: plan

Date: 2026-10-26. Status: in progress.

**Progress.** The first PR (branch `claude/gmail-read-only`) delivers the Gmail half of step 2. It covers:

- Gmail sign-in with LokalBot's own Google client, or optionally your own, for several accounts. Setup and verification are in [google-oauth-verification.md](google-oauth-verification.md);
- the conversations-only filter;
- Gmail's change history and the check schedule (morning, every three hours, and before meetings);
- the sealed thread store;
- Settings → Personal Context → Email, and PRIVACY.md.

Nothing reads the stored mail yet. The "From email" section of the brief is the next PR.

**Goal.** LokalBot reads several email accounts the user owns, read-only, and refreshes them every morning. It uses the mail for two things:

- briefing the user before each of the day's meetings;
- telling Personal Context (About You) more about the user.

## The bet

Before a meeting, the useful part of email is the unfinished business with the people you're about to see: what they asked you, what you promised, what you're waiting on, and when you last talked. A searchable copy of the mailbox is not what helps. Four choices follow:

- **Read conversations, not inboxes.** Download a thread only if you wrote in it, or if someone in it is on your calendar. Newsletters, receipts, and notifications never enter.
- **Match on email address.** Calendar attendees already carry their addresses, so linking a meeting to its threads is an exact match, with no fuzzy name matching.
- **Summarize only what is needed.** Summarize threads for meetings coming up and sent mail for About You. Don't run a model over every message every night.
- **No search index in the first version.** Briefs and About You need only the address map and a list of sent messages. Search in Ask comes later and brings its index with it.

Plumbing is not the risk here. The risk is whether email-based briefs turn out useful or just noise. So the first milestone is a thin slice that runs on the user's own mail for a week, before settings, polish, and other providers.

## How to connect

| Account type | Recommended access | Read-only guaranteed by |
| --- | --- | --- |
| Gmail and Google Workspace | Gmail API with the `gmail.readonly` scope, signed in through the browser | Google: the token cannot change mail |
| iCloud, Fastmail, Yahoo, custom-domain hosts, Proton Bridge | IMAP with an app-specific password | LokalBot: mailboxes opened with `EXAMINE`, bodies read with `BODY.PEEK`, and a command allowlist checked by tests |
| Outlook.com and Microsoft 365 | Microsoft Graph with delegated `Mail.Read` | Microsoft: the token cannot change mail |

**Start with the Gmail API.**

- **It is truly read-only.** Google itself refuses writes; with IMAP, the stored password could delete mail even though LokalBot never would.
- **Sync is cheap.** Gmail's history API returns only what changed since the last check.
- **Bulk mail is easy to drop.** Gmail already labels Promotions, Social, Updates, and Forums.
- **It is less code.** It needs plain HTTPS calls plus the existing browser sign-in pieces: [LoopbackRedirectListener](../LokalBot/Engines/Subscription/LoopbackRedirectListener.swift) and the PKCE helpers in [ChatGPTPlanOAuth.swift](../LokalBot/Engines/Subscription/ChatGPTPlanOAuth.swift).

**For personal use,** a Google Cloud project with a Desktop OAuth client set to *In Production* works without Google's review. Google allows [personal use](https://support.google.com/cloud/answer/13464323) by fewer than 100 users, after clicking past an "unverified app" warning. Keep it out of *Testing* status, where refresh tokens for Gmail scopes expire after 7 days.

**Shipping to every user is a separate decision.** Unverified clients stop at 100 users, and `gmail.readonly` is a restricted scope. [Verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification) takes weeks, is redone every year, and may include a security assessment. Optional remote models make that harder to argue away. The public route that needs no Google approval is IMAP with app passwords, so IMAP is the second adapter. A Workspace admin can also trust the client for their own domain.

**Not chosen:**

- **Apple Mail's local store:** it needs Full Disk Access, its format is undocumented and changes between macOS versions, and it only sees accounts set up in Mail.
- **IMAP for Gmail:** with OAuth it needs the full `https://mail.google.com/` scope, which allows deletion.
- **Any relay server:** it would break local-first.

The adapter interface has no write operations. It has only sign in, list changes since a cursor, fetch headers, fetch a raw message, and revoke. Both adapters return raw RFC 822 messages, so one MIME parser serves both. It handles charsets including Windows-1250 and ISO-8859-2 for Serbian mail, quoted-printable, multipart/alternative, and HTML converted to text without fetching anything remote.

## What LokalBot reads

**Your addresses.** Every connected account's address, the aliases the provider lists, and any addresses the user adds. Together they define "me" across accounts. A message that reached two of your accounts is stored once, matched by `Message-ID`.

**Headers come first.** LokalBot downloads a thread's bodies only if the thread qualifies:

- **You wrote in it,** from any of your addresses.
- **Someone in it is on your calendar,** in the last 90 days or the next 14.
- **It isn't bulk mail.** Bulk signals are `List-Unsubscribe`, `List-Id`, `Precedence: bulk`, `Auto-Submitted`, no-reply senders, and Gmail's non-Primary categories.

**Never read:**

- Spam, Trash, and Drafts.
- Senders, domains, labels, and threads the user excludes. An exclusion is remembered, so the next sync doesn't bring the thread back.

**Window.** On connect, LokalBot reads the last 90 days, adjustable to 30 or 365. Older threads age out together with everything made from them.

**Attachments.** LokalBot keeps the file name, type, and size, but not the contents.

**Calendar invitations.** The thread for an invitation carries the event's `UID` in its `.ics` part. That ties the "Invitation: …" thread, with its replies and agenda edits, to the exact calendar event.

Before anything downloads, each account shows counts only: threads found, how many qualify, and how many were skipped as bulk.

## Daily rhythm

Checking for new mail takes seconds, so it can run often. Model work is what costs, and it runs only where it pays off.

| When | What happens |
| --- | --- |
| First wake after 06:00, or 60 minutes before the first meeting if that is earlier | Check for new mail on every account, then prepare the morning brief for every meeting today |
| Every 3 hours while the app runs, and on wake | Check for new mail |
| 30 minutes before each meeting | Check for new mail again; refresh that meeting's brief if its threads changed |
| Nightly, after the Dream review | About You pass over the day's sent mail |
| Sync now | Check for new mail |

- **Scheduler:** add an `EmailSyncScheduler` modeled on the durable run log in [MemoryRoutines.swift](../LokalBot/Services/MemoryRoutines.swift). Like LokalBot's other schedulers it runs inside the app, which already launches at login.
- **Gates:** model work uses the gates the brief already has: a local model, already downloaded, with no surprise downloads ([UpcomingMeetingPreparation.swift:504](../LokalBot/Services/Calendar/UpcomingMeetingPreparation.swift)). The nightly pass also uses the Dream gates: AC power, and nothing recording.
- **Cursors:** each account keeps a cursor, the Gmail `historyId` or the IMAP `UIDVALIDITY` and last UID. It moves forward in the same write that stores the messages, so an interrupted sync resumes without duplicates. If Gmail reports that a history ID has expired, LokalBot rescans the window.
- **Deletions:** mail deleted on the server is deleted locally. A failed check never counts as a deletion.
- **Background refresh is new.** Today the brief refreshes only while the Today tab is on screen ([TodayView.swift:53-69](../LokalBot/Views/TodayView.swift)), so the morning and pre-meeting work needs an app-level watcher.

## Briefs

**Fix matching first.** Calendar attendees carry addresses ([EventKitCalendarEventProvider.swift:157-168](../LokalBot/Services/Calendar/EventKitCalendarEventProvider.swift)). The brief still matches earlier meetings by attendee name ([UpcomingMeetingPreparation.swift:340](../LokalBot/Services/Calendar/UpcomingMeetingPreparation.swift)). Matching by address helps briefs even without email, so ship it on its own first.

**Email adds open items, not summaries.** For each attendee, LokalBot takes the qualifying threads and works out:

- **Without a model:** who sent the last message, and how long ago; questions to you with no reply from you; and the last time you exchanged mail.
- **With one short model call per thread:** you owe, they owe, agreed (with dates), and a one-line "where it stands". Every item is tagged with who said it, so "Ana asked me to ship Friday" never becomes "I agreed to ship Friday". The result is sealed and cached until the thread gets a new message.

**Ranking.** Threads are ranked by how many attendees they include, how recent they are, open questions to you, the invitation-thread link, and how much the subject overlaps the event title. The top 5 go into the brief, using about 3,000 of its 12,000 characters.

**On the Today page:**

- **The card for the next meeting** ([UpcomingMeetingView.swift](../LokalBot/Views/UpcomingMeetingView.swift)) gains a "From email" section. Each source card shows subject, sender, date, the quoted line, and Open in mail.
- **The "Later today" rows,** prepared in the morning, expand to show their own briefs.
- **First meetings with outside people** gain the most, because email is often the only history.

**Notifications** are optional and off by default:

- a morning one: "4 meetings today, 2 with open items";
- one 10 minutes before each meeting.

They show only meeting titles and counts, never email text on the lock screen.

## About You

- **Your own words only.** Learn from sent mail, with quoted replies, forwards, and signatures removed. Mail others write about you never becomes a claim about you.
- **Your signature, without a model.** It gives your role, company, and website, offered as suggestions.
- **A one-time backfill.** The existing nightly cap of 3 items ([PersonalLearning.swift:62-69](../LokalBot/Services/PersonalModel/PersonalLearning.swift)) would take months to get through 90 days of sent mail. So when the setting is first turned on, one pass over the window offers up to 20 suggestions to review at once. After that, the nightly pass reads only the day's sent mail, with its own small budget (about 10 excerpts and 2,000 characters), so meetings keep their share.
- **Worth learning:** preferences and constraints you state ("no calls before 10"), what you work on and with whom, which language you use with whom, and goals you mention. Promises you make belong to the open-items list, not About You.
- **Always reviewed.** Every email suggestion waits for review, like other typed sources, and "Learn from my sent email" is off by default.
- **Code changes:**
  - Add `TypedSource.email(accountID:messageID:)` ([PersonalClaim.swift:28](../LokalBot/Services/PersonalModel/PersonalClaim.swift)), and handle it in each place that switches on a claim's origin: the agent projection, the CLI labels, and the Settings rows in [PersonalContextSettings.swift](../LokalBot/Views/PersonalContextSettings.swift).
  - Add `.email` to `DreamEvidenceSource.Kind` ([DreamModels.swift:81](../LokalBot/Services/Dreaming/DreamModels.swift)) and track it per message, so that deleting or excluding the message retracts the claim. Today, every kind other than meeting is tracked per day.
- **Later, opt-in:** receipts, bookings, and subscriptions are facts about your life, such as services you use or trips coming up. They fit the whole-person direction, but they need sensitivity filters, so they stay out of the first version.

## Storage and safety

- **Keychain:** tokens and app passwords, one item per account. `email/accounts.json` holds addresses, scope, cursors, and status, with no secrets.
- **Threads:** one sealed file per thread (`AES.GCM`, `KeychainSecrets.symmetricKey(account: "email-key")`, [AppIdentifiers.swift:244](../LokalBot/Models/AppIdentifiers.swift)), written atomically with 0600 permissions like [PersonalModelStore](../LokalBot/Services/PersonalModel/PersonalModelStore.swift). A sealed manifest of participants, dates, and subjects becomes the in-memory address map at launch.
- **Where email never goes:** the plaintext search database (`lokalbotv3.sqlite`), the embeddings, Dream reports, or exports.
- **Untrusted text.** The brief, thread, and learning prompts have no tools. Email text goes in as quoted evidence through `PromptContextSanitizer`. Agent Mode never receives raw email.
- **Fix the agent leak first.** Before anything made from email can reach agents, fix [Briefing.swift:213-214](../LokalBot/CLISupport/Briefing.swift). Today it treats every source other than meetings as screen evidence, so an agent holding only the screen grant would also see email-derived memory. Email for agents is its own grant, and comes later.
- **Remote models:** email-derived text goes only to local models unless the user separately allows remote ones.
- **Logs:** no message text, addresses, or tokens in logs or diagnostics. Test fixtures are synthetic.
- **Account controls:** Pause; Disconnect (revoke the token, delete it, and offer to delete the account's mail and everything made from it); per-thread "Forget".
- **[PRIVACY.md](../PRIVACY.md):** add the stored data, the network hosts, the new Personal Context source, and the permissions.

## Build order

| Step | What ships | Done when | Size |
| --- | --- | --- | --- |
| 0. Address matching | Briefs find earlier meetings by attendee address | Fixture: a renamed attendee still matches | ½ day |
| 1. Spike | Google client; a throwaway harness that signs in to each of your accounts and prints counts only | Providers and volumes known; IMAP needed or not | 1 day |
| 2. Thin slice | Gmail adapter, MIME parser, sealed thread store, address map, morning sync, and the "From email" section on the next meeting's card, behind a developer flag | You use it for a week and judge whether the email items were worth reading | ~1.5 weeks |
| 3. Daily briefs | Morning brief for every meeting, pre-meeting refresh, invitation-thread link, notifications, Settings → Email (accounts, preview counts, exclusions, status, disconnect), PRIVACY.md | Fixture scenarios pass; a full week without missed or stale briefs | ~1 week |
| 4. About You | Learning from sent mail, signature suggestions, backfill review, email evidence and retraction | Every suggestion quotes your own sent text; deleting the message retracts it | ~1 week |
| 5. IMAP | IMAP adapter with the command allowlist; the route to ship to everyone without Google review | Same checks on an iCloud or custom-domain account | ~1 week |
| Later | Search in Ask, People details from signatures, email for agents, Outlook, life facts from receipts, Windows/Linux, Google verification | — | — |

Steps 0–4 take about 3½ weeks for one engineer. Step 2 is the decision point: if a week of real briefs isn't useful, change the open-items design before building the rest.

## Tests

- **Read-only:** a Gmail client test fails on any request other than a GET to `gmail.googleapis.com`, or the token POST. An IMAP transcript test fails on any command outside the allowlist (`SELECT`, `STORE`, `COPY`, `MOVE`, `EXPUNGE`, `APPEND`, `DELETE`).
- **Recorded provider responses:** pagination, expired history ID, 429 rate limits, mail deleted on the server, revoked tokens.
- **Scope fixtures:** bulk detection, aliases across accounts, the same message in two accounts, exclusions that survive the next sync, mail ageing out of the window.
- **Brief scenarios:**
  - a first meeting where email is the only history;
  - an email that moves a date agreed in a meeting;
  - a thread where they asked and you didn't promise;
  - an email carrying instructions to the model;
  - a thread excluded after it appeared, which then disappears.
- **Upgrade:** libraries without email keep working, and older builds ignore `.email` evidence rather than treating it as a meeting.
- **Repository rules:** UI tests run only on hosted CI or the remote runner. Run `xcodegen generate` after adding files.

## Decisions for you

1. **Which providers are your accounts on?** If they are all Google, IMAP waits until step 5.
2. **Just you for now, or every LokalBot user?** For everyone, either start Google verification now or lead with IMAP.
3. **Morning brief time:** first wake after 06:00?
4. **Notifications:** morning summary, pre-meeting, both, or neither?
5. **Remote models:** may email-derived text ever go to one?
