# 0016. Email and calendar access

- Status: Accepted
- Date: 2026-11-20

## Context

On the Mac, LokalBot signs in to Gmail with read-only access, downloads the conversations that involve the person or the people on their calendar, and quotes that mail in meeting briefs. The Windows and Linux app reads the person's calendars (Evolution Data Server on Linux, or private iCalendar links) for calendar-assisted meeting detection and for People's upcoming meetings. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Reading calendars (Windows and Linux)

### People's next meetings come only from a consented calendar and are never stored

People reads the coming week only while calendar use is on and the calendar has been read, matches its meetings to people by the directory's keys (as macOS `refreshUpcoming` does), and never reads a personal appointment. Otherwise there are no readable events and nobody has a next meeting. Nothing is stored.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/people.rs` (`PeoplePage.refresh_upcoming`), `LinuxWindows/crates/lokalbot-core/src/people/upcoming.rs` (`readable_events`).

### On Linux, read calendars from Evolution Data Server's synced copy

LokalBot reads every enabled, selected calendar the desktop knows through Evolution Data Server over D-Bus, including those GNOME Online Accounts adds (Google, Microsoft 365, Nextcloud). EDS keeps its own synced copy, so reading it makes no network request of LokalBot's own. `CalendarFactory.OpenCalendar` starts or reuses a backend whose object lives only while the D-Bus connection does, so one connection serves a whole refresh.

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/eds.rs`.

### Parse iCalendar with `calcard` and apply recurrence overrides by instant

Parsing, time zone names (IANA, Windows, Outlook's "(UTC+01:00) …" labels, `X-LIC-LOCATION`) and RRULE iteration come from `calcard`. Each series is grouped with its `RECURRENCE-ID` overrides, which apply by instant: a moved or cancelled occurrence replaces the original whatever its `SEQUENCE`. Each occurrence then goes through the same filter as macOS (`EventKitCalendarEventProvider.candidate(from:)`).

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/ics.rs`.

### Give unplaceable time zones a location from their offsets

A `VTIMEZONE` whose name `calcard` cannot place (Outlook's "Customized Time Zone") gets an `X-LIC-LOCATION`: this computer's zone when its standard and daylight offsets match, else the fixed standard offset. Without it, its times would be read in this computer's zone regardless.

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/ics.rs` (`name_unknown_zones`).

### Expand starts without a TZID in their own offset

`calcard` iterates a start without a TZID in the default zone, even a UTC one ("…T150000Z"), so those series are expanded in their own offset instead.

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/ics.rs` (`Context::expand_series`).

## Calendar links

### Calendar links are secrets kept in the credential store and shown only by host

The private calendar links calendar-assisted detection reads live in the system credential store, never in settings, and the Calendar settings page shows them only by host.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/calendar.rs`, `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings.calendar_detection_enabled`).

### Links to another computer must stay encrypted, redirects included

An `http://` link to another computer is refused: it is fetched every few minutes, and it and any password in it would cross the network in the clear. Encryption is judged on the address the request goes to, without the credentials. An encrypted link never follows a redirect to an unencrypted address.

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/feed.rs` (`LinkRefused::NotEncrypted`, `normalize`, `agent`).

### Transport errors never repeat the link

A failed fetch is described in words that never repeat the link, because some `ureq` errors carry the whole URL and a calendar link is a secret.

Where: `LinuxWindows/crates/lokalbot-platform/src/calendar/feed.rs` (`describe`).

## Gmail sign-in

### Use the read-only Gmail scope with PKCE, enforced by Google

Sign-in is Google's OAuth 2.0 flow for the read-only Gmail scope, with PKCE. Google refuses any change to mail made with this grant, so "read-only" does not rest on LokalBot's own code.

Where: `LokalBot/Services/Email/GmailOAuth.swift` (`GmailOAuth`).

### Sign in with LokalBot's iOS-type client or an imported Desktop client

LokalBot's own client is registered as Google's "iOS" type, which Google requires for macOS apps (developers.google.com/identity/sign-in/ios/start-integrating, 2026-10); it has no secret, and the browser returns through the client's URL scheme, caught by `ASWebAuthenticationSession`. A person can instead import a "Desktop app" client from their own Google Cloud project; its secret is one Google treats as public, and it returns through a loopback listener (developers.google.com/identity/protocols/oauth2/native-app).

Where: `LokalBot/Services/Email/GmailOAuth.swift` (`GmailOAuth`, `GoogleOAuthClient`).

### Validate `state` before anything else in the callback

The callback checks `state` first, so a forged request from another local process can neither complete nor cancel a sign-in.

Where: `LokalBot/Services/Email/GmailOAuth.swift` (`GmailOAuth.parseCallback`).

### Check the scopes actually granted

Google's consent screen lets the person untick Gmail and still returns a code, so the callback checks the scopes Google lists as granted.

Where: `LokalBot/Services/Email/GmailOAuth.swift` (`GmailOAuth.parseCallback`), `LokalBotTests/Services/Email/GmailOAuthTests.swift`.

### Never follow a redirect off Google's fixed hosts

The authorizer's transport talks only to Google's fixed hosts and never follows a redirect away from them.

Where: `LokalBot/Services/Email/GmailAuthorizer.swift` (`GmailAuthorizer.liveTransport`).

### Keep the refresh token across refreshes

Google doesn't rotate the refresh token, so a refresh keeps the old one.

Where: `LokalBotTests/Services/Email/GmailOAuthTests.swift` (`GmailAuthorizer` refresh).

## Accounts and credentials

### A read failure is never treated as signed out or empty

`EmailSecretStore.credentials` returns nil only when the account was never signed in or was signed out, and throws when the Keychain can't be read right now. Saving the account list is refused until the saved list was read, so an unreadable list (as when the Keychain item can't be read as saved) is never replaced by a partial one.

Where: `LokalBot/Services/Email/EmailModels.swift` (`EmailSecretStore.credentials`), `LokalBot/Services/Email/EmailController.swift` (`EmailController.accountsLoaded`), `LokalBotTests/Services/Email/EmailControllerTests.swift` (`testAnUnreadableAccountListIsNeverOverwritten`).

### Disconnect clears this Mac first, then revokes at Google

Disconnect removes the tokens, downloaded mail and the account itself first, then asks Google to revoke the access. It returns false when Google didn't confirm; nothing is left on the Mac either way.

Where: `LokalBot/Services/Email/EmailController.swift` (`EmailController.disconnect`).

### Keep replaced sign-ins for Disconnect, not reconnect

Tokens replaced by a new sign-in are kept only so Disconnect can revoke grants from previous clients too. They are not revoked during reconnect, because that can revoke the new grant.

Where: `LokalBot/Services/Email/EmailModels.swift` (`EmailCredentials.pendingRevocationTokens`).

## What LokalBot downloads

### Download conversations, not inboxes

A thread qualifies when the person wrote in it, or when someone on their calendar takes part and the mail isn't bulk. Newsletters, receipts and notifications never qualify on the calendar rule. Spam, Trash and Drafts are never read.

Where: `LokalBot/Services/Email/EmailScope.swift` (`EmailScope`).

### Calendar people keep qualifying for the window after they leave the calendar

Sync state records each calendar person and the last time they were on the calendar, and their threads keep qualifying for the window after that. A calendar that is briefly unavailable (at launch, or with calendar use paused) then never deletes mail or triggers new searches.

Where: `LokalBot/Services/Email/EmailModels.swift` (`EmailSyncState.people`).

### Only Gmail's SENT label proves the person wrote a message

A `From` header with the person's address proves nothing, since anyone can write it; a message counts as the person's only with Gmail's SENT label.

Where: `LokalBot/Services/Email/EmailModels.swift` (`EmailMessage.fromMe`), `LokalBotTests/Services/Email/EmailScopeTests.swift` (`testASpoofedFromHeaderIsNotTheOwner`).

### The person's addresses are their verified send-as addresses

The person's addresses are Gmail's verified "Send mail as" addresses, lowercased. Gmail leaves the verification status out for the primary address, so its absence there does not exclude it.

Where: `LokalBot/Services/Email/GmailResources.swift` (`GmailSendAsList.addresses`).

## Gmail sync

### Search on the first pass, then follow Gmail's change history

The first pass, or one after Gmail expires the history, searches the window (threads the person wrote in, plus threads with calendar people), keeps what qualifies and drops stored threads that no longer do. Later passes read Gmail's change history since the saved cursor, recheck only the threads it names, then search once for anyone who joined the calendar since the last pass. A thread Gmail fails to return is left as it was and checked on the next pass instead of holding back the others; a lost connection or an expired sign-in ends the pass.

Where: `LokalBot/Services/Email/GmailSync.swift` (`GmailSyncer`).

### Read the history cursor before searching and save it only after storing

The cursor is read before a full search, so mail that arrives during the scan is replayed by the next pass rather than missed. It is saved only after the threads it covers are stored, so an interrupted pass repeats work instead of skipping it, and the repeat rewrites the same files.

Where: `LokalBot/Services/Email/GmailSync.swift` (`GmailSyncer`, `GmailSyncer.fullScan`).

### Fetch four threads in parallel

Gmail allows about 25 thread reads a second per user; four fetches in flight stay well under it.

Where: `LokalBot/Services/Email/GmailSync.swift` (`GmailSyncer.concurrency`).

### Retry Gmail's per-user rate limits

Gmail reports per-user rate limits as 403 with a reason, so those 403s are retryable.

Where: `LokalBot/Services/Email/GmailClient.swift` (`GmailClient.isRetryable`).

### Percent-encode "+" in Google requests

`URLComponents` leaves "+" alone and Google reads it as a space, so Gmail queries and OAuth requests encode it to arrive as itself.

Where: `LokalBot/Services/Email/GmailClient.swift` (`GmailClient.request`), `LokalBotTests/Services/Email/GmailOAuthTests.swift` (`GmailOAuth.AuthorizationRequest`).

## Mail text

### Decode in the declared charset, then UTF-8, then Latin-1

Body and header bytes are decoded in their declared charset (Serbian mail still arrives as Windows-1250 or ISO-8859-2), then as UTF-8, then as Latin-1, so text is never lost.

Where: `LokalBot/Services/Email/EmailText.swift` (`EmailText.decode`).

### Turn HTML into text with a tokenizer, not a renderer

Nothing is fetched, so no image or tracking pixel loads, and links keep only their text. Quoted history inside `<blockquote>` keeps a `> ` prefix so later passes can tell it from new text.

Where: `LokalBot/Services/Email/EmailText.swift` (`EmailText.plainText(fromHTML:)`).

### Mail in a prompt is quoted evidence

The email section of a brief's prompt quotes mail as evidence, and the system prompt tells the model never to follow instructions inside it.

Where: `LokalBot/Services/Email/EmailMeetingContext.swift` (`EmailMeetingContext.promptSection`).

## Consequences

- Calendar links and Gmail tokens are secrets: keep them in the credential store or Keychain, out of settings, errors and logs, and never send them unencrypted or let a redirect take them off their host.
- An unreadable store, a calendar outage or a failed thread fetch must never look like "empty": nothing is deleted, overwritten or signed out because a read failed.
- Gmail sync correctness rests on cursor ordering (read before searching, save after storing); a change to the sync passes has to keep both.
