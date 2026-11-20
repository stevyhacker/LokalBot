# 0025. Mac app: Email

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Email/`, `LokalBotTests/Services/Email/`.

## Decisions

### `LokalBot/Services/Email/EmailController.swift`

#### Mail checks are cheap history reads so run often; no model
`EmailSyncSchedule`: When mail is checked. Checking is cheap (Gmail's change history), so it
runs often; nothing here runs a model.

#### No two checks of one account within 15 minutes, failures included
`EmailSyncSchedule.minimumGap`: No two checks of one account closer than this, failures included.

#### First check after local 6am counts as the morning one
`EmailSyncSchedule.morningHour`: Local hour after which the first check of the day counts as the morning one.

#### launched until first check; nextMeetingStart read only when needed
`EmailSyncSchedule.due`: `launched` is true until the first check after the app starts.
`nextMeetingStart` is read only when it could matter.

#### Mail is read-only: no code path sends, deletes, labels or marks read
`EmailController`: Connected mail accounts for Settings and the background check. Mail is
read-only: there is no code path that sends, deletes, labels, or marks
anything read.

#### Revision bumps when mail changes so readers can cache
`EmailController.mailRevision`: Bumped whenever downloaded mail may have changed, so readers can cache.

#### Calendar attendee addresses around now make their threads qualify
`EmailController.attendeeAddresses`: Calendar attendee addresses around now; their threads qualify.

#### Next meeting with attendees drives the pre-meeting check
`EmailController.nextMeetingStart`: Start of the next meeting with attendees, for the pre-meeting check.

#### False until meeting library loaded, since its attendees count
`EmailController.canSync`: False until the meeting library has loaded, whose attendees count too.

#### Saving refused until list read so unreadable file never replaced
`EmailController.accountsLoaded`: Saving is refused until the saved list was read, so an unreadable
file is never replaced by a partial list.

#### Nothing touches Keychain until an account was connected once
`EmailController.start`: Loads saved accounts and starts the minute tick. Nothing touches the
Keychain until an account was connected once.

#### Accounts from imported client must sign in again next check
`EmailController.useBuiltInClient`: Forgets the imported client so new sign-ins use LokalBot's again.
Accounts signed in through it ask to sign in again on their next check.

#### Reconnecting same address renews existing account sign-in
`EmailController.connectGmail`: Signs in to Gmail and adds the account, or renews the sign-in of an
account already connected under the same address.

#### Local data removed first, then Google revoke; false if unconfirmed
`EmailController.disconnect`: Ends the account here first (tokens, downloaded mail, the account
itself), then asks Google to revoke the access. Returns false when
Google didn't confirm; nothing is left on this Mac either way.

#### Unreadable account list is never overwritten
`EmailController.disconnect`: An unreadable account list is never overwritten.

#### Decrypts files so callers read it off the main actor
`EmailController.mailbox`: Downloaded mail for features that read it, such as the meeting brief.
Nil when no account is connected. Reading it decrypts files, so callers
do it off the main actor.

#### Calendar read at most once per tick and only if needed
`EmailController.tick`: Read the calendar at most once a tick, and only if an account asks.

#### Disconnect during a pass wins over its result
`EmailController.finish`: A disconnect during the pass wins over its result, including any
thread it saved after the account's mail was deleted.

### `LokalBot/Services/Email/EmailMeetingContext.swift`

#### Built only from mail already stored on this Mac
`UpcomingMeetingEmailThread`: One email conversation with people in an upcoming meeting, as the brief
shows and cites it. Built only from mail already on this Mac.

#### Latest message asks something the user has not answered
`UpcomingMeetingEmailThread.awaitingReply`: Their latest message asks something you haven't answered.

#### Excerpt is latest new text without quoted history
`UpcomingMeetingEmailThread.excerpt`: The latest new text in the thread, without quoted history.

#### Recent messages for brief model, each tagged with author
`UpcomingMeetingEmailThread.promptText`: The thread's recent messages for the brief's model, each tagged with
who wrote it.

#### People matched by email address only; display names never link people
`EmailMeetingContext`: Finds the downloaded conversations that involve a meeting's attendees.
People are matched by email address only; a shared display name never
links two people.

#### Email's share of the brief prompt is 3,000 characters
`EmailMeetingContext.promptCharacters`: The share of the brief's prompt that email may take.

#### Bulk mail and secret-looking text kept out of excerpt and prompt
`EmailMeetingContext.build`: Mail from robots and mailing lists inside a thread stays out of the
excerpt and the prompt; so does text that looks like a secret.

#### Encode plus in address as %2B so it is not read as space
`EmailMeetingContext.gmailURL`: A "+" in an address would otherwise read as a space.

#### Mail quoted as evidence; model told never to follow it
`EmailMeetingContext.promptSection`: The email section of the brief's prompt. Mail is quoted evidence: the
system prompt tells the model never to follow instructions inside it.

### `LokalBot/Services/Email/EmailModels.swift`

#### Several mailboxes allowed; each keeps own sign-in, cursor and threads
`EmailAccount`: One connected mailbox. Several can be connected; each keeps its own
sign-in, cursor, and downloaded conversations.

#### Mailbox address stored lowercased
`EmailAccount.address`: The mailbox address, lowercased.

#### Aliases are Gmail send-as addresses, lowercased
`EmailAccount.aliases`: Other addresses this mailbox sends as (Gmail "Send mail as"), lowercased.

#### History cursor nil until first scan completes and after expiry
`EmailSyncState.historyID`: Gmail's `historyId` after the last complete pass. Nil until the first
window scan finishes, and again after Gmail expires the history.

#### People stay known after leaving calendar so outages delete nothing
`EmailSyncState.people`: Calendar people and the last time each was on the calendar. Their
threads keep qualifying for the window after that, so a calendar that
is briefly unavailable (at launch, or with calendar use paused) never
deletes mail or triggers new searches.

#### New calendar people get one search; capped-scan misses stay unsearched
`EmailSyncState.searchedAddresses`: People whose older threads were searched to the end. Someone who joins
the calendar later gets one search of their own; someone a capped scan
never reached stays unsearched until a pass reaches them.

#### Threads Gmail failed to return are rechecked next pass
`EmailSyncState.retryThreadIDs`: Threads Gmail couldn't return last time, checked again next pass.

#### Addresses stored lowercased
`EmailAddress.address`: Lowercased.

#### Attachment contents are never downloaded
`EmailMessage`: One message as LokalBot keeps it: who, when, and the text. Attachment
contents are never downloaded.

#### Message-ID header matches same message across accounts
`EmailMessage.internetMessageID`: The `Message-ID` header, which matches the same message in another
account.

#### Only SENT label proves authorship; From header can be forged
`EmailMessage.fromMe`: Sent by the account (Gmail's SENT label). A `From` header with the
person's address proves nothing; anyone can write it.

#### Body is plain text with quoted history, capped at maxBodyCharacters
`EmailMessage.body`: Plain text, HTML converted, quoted history kept, capped at
`EmailScope.maxBodyCharacters`.

#### Thread holds only messages inside window, oldest first
`EmailThread`: A conversation that qualified for download, with only its messages
inside the window, oldest first.

#### Participant addresses are lowercased
`EmailThread.participantAddresses`: Every address in the thread, lowercased.

#### Gmail tokens stored in Keychain only
`EmailCredentials`: One signed-in Gmail session. Stored in the Keychain only.

#### Refresh needs the same OAuth client that issued tokens
`EmailCredentials.clientID`: The OAuth client that issued these tokens; refreshing needs the same one.

#### Replaced tokens kept for Disconnect; reconnect revocation can kill new grant
`EmailCredentials.pendingRevocationTokens`: Replaced sign-ins, retained only so Disconnect can revoke grants from
previous clients too. Revoking during reconnect can revoke the new grant.

#### Keychain read failure throws and is not a sign-out
`EmailSecretStore.credentials`: Nil when the account was never signed in or signed out; throws when
the Keychain can't be read right now, which is not a sign-out.

### `LokalBot/Services/Email/EmailScope.swift`

#### Download conversations not inboxes; spam, trash, drafts never read
`EmailScope`: What LokalBot downloads: conversations, not inboxes. A thread qualifies
when the person wrote in it, or when someone on their calendar takes part
and the mail isn't bulk. Newsletters, receipts, and notifications never
qualify on the calendar rule. Spam, Trash, and Drafts are never read.

#### First scan stops at 2,000 threads and says so in Settings
`EmailScope.maxThreadsPerScan`: A first scan stops here and says so in Settings.

#### 15 addresses per search keeps Gmail queries short
`EmailScope.addressesPerQuery`: Addresses per participant search, keeping each Gmail query short.

#### Gmail search itself leaves out Spam and Trash
`EmailScope.sentQuery`: Threads the person wrote in. Gmail search leaves out Spam and Trash.

#### Participant searches exclude bulk tabs; braces group is Gmail OR
`EmailScope.participantSearches`: Threads with these people, outside Gmail's bulk tabs. The `{}` group
is Gmail's OR.

#### Addresses with query syntax skipped, not escaped
`EmailScope.isSearchable`: Only plain addresses go into a search; anything with Gmail query
syntax in it is skipped rather than escaped.

#### Automated includes no-reply, robots and calendar resources
`EmailScope.isAutomated`: Mailboxes no person reads: no-reply senders, notification robots, and
calendar resources (rooms, group calendars).

#### Only SENT label counts as the person's words; From is forgeable
`EmailScope.isFromOwner`: Only Gmail's SENT label proves the account wrote a message. A `From`
header with the person's own address can be forged by anyone, so a
spoofed message never counts as the person's words.

#### Kept messages inside window and outside never-read labels
`EmailScope.keptMessages`: Messages LokalBot may keep from a thread: inside the window and in
none of the never-read labels.

#### Qualification decided from metadata headers alone
`EmailScope.qualifies`: Decides from headers alone (a `metadata` fetch) whether a thread is
downloaded. `people` are the calendar people of the window.

#### Stored thread must still qualify after older messages age out
`EmailScope.stillQualifies`: The same rule for a stored thread, after older messages aged out of
it: what remains must still qualify on its own.

### `LokalBot/Services/Email/EmailStore.swift`

#### Mail sealed with AES-GCM; never in search DB, embeddings, reports or exports
`EmailStore`: Downloaded mail under `email/`, every file sealed with AES-GCM under the
per-install `email-key`. Mail never goes into the plaintext search
database, the embeddings, Dream reports, or exports.

email/accounts.json.enc                      connected accounts and cursors
email/\<account-id>/threads/\<thread-id>.json.enc

Writes are atomic and 0600. Tokens live in the Keychain, never here.

#### Key created lazily so no Keychain item without connected mail
`EmailStore.liveKey`: The sealing key, created on first use. Callers only ask for it once
an account exists, so an install that never connects mail never adds
a Keychain item.

#### Unreadable thread file skipped; next full scan replaces it
`EmailStore.threads`: Every stored thread of an account. An unreadable file is skipped
rather than failing the rest; the next full scan replaces it.

### `LokalBot/Services/Email/EmailText.swift`

#### Quoted names may contain commas; groups flattened; entries without @ dropped
`EmailText.addresses`: Parses an address-list header (`To`, `Cc`, `From`): display names in
quotes may contain commas, and groups (`team: a@x, b@y;`) are
flattened. Entries without an `@` are dropped.

#### Whitespace between adjacent encoded words dropped per RFC 2047
`EmailText.decodeEncodedWords`: Decodes `=?charset?B?…?=` and `=?charset?Q?…?=` words. Whitespace
between two adjacent encoded words is dropped, as the RFC requires.
Text without encoded words is returned unchanged.

#### Serbian mail still uses Windows-1250 or ISO-8859-2; fall back to UTF-8, Latin-1
`EmailText.decode`: Decodes body or header bytes in their declared charset (Serbian mail
still arrives as Windows-1250 or ISO-8859-2), then UTF-8, then Latin-1
so text is never lost.

#### Reply-header patterns cover Gmail, Apple Mail, Outlook in users' languages
`EmailText.replyHeaderPatterns`: Lines that start the quoted history of a reply: Gmail, Apple Mail and
Outlook headers in the languages LokalBot's users write in most.

#### Strip quotes and signatures for display only; full body kept on disk
`EmailText.conversationText`: What the sender wrote in this message: the text above the quoted
history, without `>` lines, the signature after `-- `, or mobile
sign-offs. The whole body is kept on disk; this is only for display
and prompts.

#### Gmail wraps long reply header onto a second line
`EmailText.conversationText`: Gmail wraps a long "On … wrote:" header onto a second line.

#### Tokenizer only; nothing fetched; blockquotes keep > prefix
`EmailText.plainText(fromHTML:)`: Readable text from an HTML body. It is a tokenizer, not a renderer:
nothing is fetched, no image or tracking pixel loads, and links keep
only their text. Quoted history inside `<blockquote>` keeps a `> `
prefix so later passes can tell it from new text.

### `LokalBot/Services/Email/GmailAuthorizer.swift`

#### Presents consent page and returns redirect in client's own scheme
`GmailAuthorizer.AppRedirectPresenter`: Shows Google's consent page and returns the URL Google redirected to
in the client's own scheme (`ASWebAuthenticationSession` in the app).

#### Token cache avoids Keychain reads and token-endpoint retries after write failure
`GmailAuthorizer.cache`: Tokens already read or written this launch. Gmail calls need no
Keychain read each, and a failed Keychain write after a refresh
doesn't send every later call back to Google's token endpoint.

#### New sign-ins prefer imported client over LokalBot's
`GmailAuthorizer.signInClient`: The client new sign-ins use: the person's own when they imported one,
otherwise LokalBot's.

#### Refresh needs issuing client; if gone, account signs in again
`GmailAuthorizer.issuingClient`: The client that issued an account's tokens. Refreshing needs that same
client; if it's gone (the imported file was removed or replaced), the
account signs in again.

#### Never follow redirects away from Google's fixed hosts
`GmailAuthorizer.liveTransport`: Google's fixed hosts; never follow a redirect away from them.

#### Own client returns to app sheet; imported client to loopback; address from Gmail
`GmailAuthorizer.signIn`: Shows Google's consent page and completes the code exchange when
Google returns. LokalBot's own client returns to the app's sign-in
sheet; an imported Desktop client returns to a loopback listener in
the browser. The account's address comes from Gmail itself, so the
token can't be filed under the wrong one.

#### Foreign-scheme redirect yields empty query, rejected by state check
`GmailAuthorizer.query`: The query of a redirect in the app's own scheme; anything else is empty,
which the state check then rejects.

#### Keep replaced tokens for Disconnect; revoking on reconnect kills new grant
`GmailAuthorizer.save`: Files a finished sign-in under its account. Google revocation affects
the whole project's grant, including a newly issued token. Keep replaced
tokens in the Keychain for Disconnect instead of revoking on reconnect.

#### Tokens read from Keychain once per launch
`GmailAuthorizer.credentials`: The account's tokens, read from the Keychain once per launch.

#### Keep tokens of older clients for Disconnect even when grant expired
`GmailAuthorizer.performRefresh`: Older clients may belong to another Cloud project. Keep
their tokens available for Disconnect even if this grant expired.

#### Client errors keep token so Disconnect can still revoke
`GmailAuthorizer.performRefresh`: The token is kept: Disconnect can still revoke it.

#### Disconnect or new sign-in during refresh wins over result
`GmailAuthorizer.performRefresh`: A disconnect or new sign-in during the refresh wins over its result.

#### Cache keeps session working even if Keychain write fails
`GmailAuthorizer.performRefresh`: The cache keeps the session working even if this write fails.

#### Client handed to sync is read-only
`GmailAuthorizer.client(for:)`: A read-only client for one account.

#### Stop using account at once; return all retained tokens for revocation
`GmailAuthorizer.forget`: Stops using the account at once and returns every retained refresh
token for revocation, including grants from previously used clients.

#### Revoke applies to token's whole Cloud project grant
`GmailAuthorizer.revoke`: Asks Google to revoke the account's grant for the token's Cloud project.
Returns false when Google didn't confirm.

#### HTTP 400 means token already revoked, treat as success
`GmailAuthorizer.revoke`: 400 means Google no longer knows the token: already revoked.

### `LokalBot/Services/Email/GmailClient.swift`

#### Only GET to Gmail host; gmail.readonly grant forbids changes anyway
`GmailClient`: Read-only Gmail API calls for one account. Every request is a `GET` to
`gmail.googleapis.com`; the client has no way to change mail, and Google
would refuse it under the `gmail.readonly` grant anyway.

#### Throws historyExpired when Gmail no longer keeps that history
`GmailClient.changes`: Threads changed since `historyID`. Throws `GmailError.historyExpired`
when Gmail no longer keeps history that old.

#### URLComponents leaves plus unescaped, which Google reads as space
`GmailClient.request`: URLComponents leaves "+" alone, which Google reads as a space.

#### Non-hex Gmail ids refused rather than escaped
`GmailClient.pathSafe`: Gmail ids are hex; anything else is refused rather than escaped.

#### Gmail reports per-user rate limits as 403 with a reason
`GmailClient.isRetryable`: Gmail reports per-user rate limits as 403 with a reason.

### `LokalBot/Services/Email/GmailOAuth.swift`

#### Read-only enforced by Google; iOS-type client for macOS, Desktop client imported
`GmailOAuth`: Google's OAuth 2.0 flow for the read-only Gmail scope, with PKCE. Google
refuses any change to mail made with this grant, so "read-only" does not
rest on LokalBot's own code.

Two kinds of client sign in (`GoogleOAuthClient`):
- LokalBot's own, registered as Google's "iOS" type, which Google requires
  for macOS apps (developers.google.com/identity/sign-in/ios/start-integrating,
  2026-10). It has no secret; the browser returns to LokalBot through the
  client's own URL scheme, caught by `ASWebAuthenticationSession`.
- A "Desktop app" client the person imports, for their own Google Cloud
  project. It has a secret Google treats as public and returns through a
  loopback listener (developers.google.com/identity/protocols/oauth2/native-app).

#### Desktop clients accept any loopback port and path
`GmailOAuth.callbackPath`: Desktop clients accept any loopback port and path.

#### Built-in client id is public, no secret, so lives in source
`GmailOAuth.builtInClientID`: LokalBot's own client: Google Cloud project `lokalbot-512410`, type iOS,
bundle `me.dotenv.LokalBot`. A client id is public and this type has no
secret, so it belongs in the source. See Docs/guides/google-oauth-verification.md.

#### Offline access with forced consent so re-sign-in never strands a refresh token
`GmailOAuth.AuthorizationRequest.url`: A refresh token, issued again on every consent, so a
second sign-in to the same account never strands one.

#### Validate state first so forged local requests cannot complete or cancel
`GmailOAuth.parseCallback`: Validates `state` before anything else, so a forged request from
another local process can neither complete nor cancel a sign-in.

#### Unticked Gmail box still returns a code; check granted scope
`GmailOAuth.parseCallback`: Google lists what the person actually granted; an unticked Gmail
box still returns a code.

#### Revocation kills whole Cloud project grant; use only on Disconnect
`GmailOAuth.revocationRequest`: Google revokes this account's grant for the entire Cloud project,
including tokens issued to its other clients. Use only on Disconnect.

#### Revoked grant refresh token is useless and forgotten
`GmailOAuth.revokedGrantErrors`: Google no longer honors the refresh token (revoked, expired, or the
password changed). It is useless and can be forgotten.

#### Client errors keep refresh token until Disconnect revokes it
`GmailOAuth.clientErrors`: The imported client was deleted, reset, or replaced. The refresh token
may still be live at Google, so it is kept until Disconnect revokes it.

#### Desktop secret not confidential but kept in Keychain, never repository
`GoogleOAuthClient`: A Google Cloud OAuth client of type "Desktop app", as Google's console
downloads it (`{"installed": {"client_id": …, "client_secret": …}}`).
Google states that an installed app's secret is not confidential; LokalBot
still keeps it in the Keychain and never in the repository.

#### Nil for built-in client; Google issues no secret to iOS clients
`GoogleOAuthClient.clientSecret`: Nil for LokalBot's own client: Google issues no secret to "iOS" clients.

#### iOS client scheme is reversed client id under com.googleusercontent.apps
`GoogleOAuthClient.appURLScheme`: Google's URL scheme for an "iOS" client: its id with the dot-separated
parts reversed, `com.googleusercontent.apps.<id>`.

### `LokalBot/Services/Email/GmailResources.swift`

#### Gmail resource types match Gmail REST reference as of 2026-10
The parts of Gmail API responses LokalBot reads
(developers.google.com/workspace/gmail/api/reference/rest, 2026-10).

#### Gmail omits verification status for primary address
`GmailSendAsList.addresses`: Verified "Send mail as" addresses, lowercased. Gmail leaves the
status out for the primary address.

#### Read, star, archive label changes don't refetch threads
`GmailHistory.Change.threadIDs`: Threads this change touched in a way that can change whether they
qualify. Reading, starring, or archiving mail changes labels too,
but never the answer, so those threads aren't fetched again.

#### internalDate is milliseconds since 1970 as decimal string
`GmailMessageResource.internalDate`: Milliseconds since 1970, as a decimal string.

#### Body data is base64url; attachments absent and served separately
`GmailMessagePart.Body.data`: base64url; absent for attachments, which Gmail serves separately.

### `LokalBot/Services/Email/GmailSync.swift`

#### Full scan vs history pass; cursor saved after storing so interruptions repeat work
`GmailSyncer`: One sync pass for one Gmail account.

- **First pass, or after Gmail expires the history:** search the window
  (threads you wrote in, plus threads with calendar people), keep what
  qualifies, and drop stored threads that no longer do.
- **Later passes:** read Gmail's change history since the saved cursor
  and recheck only the threads it names, then search once for any person
  who joined the calendar since the last pass.

The cursor is saved only after the threads it covers are stored, so an
interrupted pass repeats work instead of skipping it, and repeating it
rewrites the same files. A thread Gmail fails to return is left as it
was and checked again on the next pass, rather than holding back every
other one; a lost connection or an expired sign-in ends the pass.

#### Four parallel fetches stay under Gmail's 25 reads per second
`GmailSyncer.concurrency`: Parallel thread fetches. Gmail allows about 25 thread reads a second
per user; four in flight stays well under it.

#### People stay known for window so brief calendar outage changes nothing
`GmailSyncer.sync`: People stay known for the window after they were last on the
calendar, so a calendar that is briefly unreadable changes nothing.

#### Read cursor before searching so mail arriving mid-scan is replayed
`GmailSyncer.fullScan`: The cursor is read before searching, so mail that arrives during
the scan is replayed by the next pass rather than missed.

#### Full scan is whole truth for window except unreadable threads
`GmailSyncer.fullScan`: A full scan is the whole truth for the window, except for threads
it couldn't read this time.

#### Log counts only, never addresses, subjects or ids
`GmailSyncer.fullScan`: Counts only: never addresses, subjects, or ids.

#### Recheck stores qualifying threads, removes others, leaves unreadable ones
`GmailSyncer.recheck`: Rechecks threads Gmail says changed: store the ones that still
qualify, remove the ones that no longer do (trashed, deleted, spam).
Returns the ids that couldn't be read and were left as they were.

#### Full page may have stopped at limit, so mark cut
`GmailSyncer.search`: A full page may have stopped at the limit with more to come.

#### Threads the person wrote in skip headers-only check
`GmailSyncer.fetch`: Fetches candidates a few at a time and stores the ones that qualify.
Threads you wrote in skip the headers-only check.

#### Many failures mean Gmail trouble; end pass and keep cursor
`GmailSyncer.fetch`: Many failures at once mean Gmail is having trouble, not a few odd
threads: end the pass so the cursor stays and it runs again later.

#### Only 200 failed threads kept for retry; rest wait for change
`GmailSyncer.maxRetries`: Threads kept for the next pass to retry; the rest wait for a change.

#### Only per-thread errors skip; sign-in, connection, rate limits stop pass
`GmailSyncer.isThreadSpecific`: Errors that concern one thread only. Anything else (sign-in,
connection, rate limits that outlasted the retries, cancellation)
stops the pass.

#### Drop aged-out messages then threads that no longer qualify alone
`GmailSyncer.prune`: Drops messages that aged out of the window, then threads whose
remaining messages no longer qualify on their own (the reply that
qualified them aged out). Returns what remains.

### `LokalBot/Services/Email/GoogleSignInSheet.swift`

#### Auth sheet shares browser session; only own-scheme redirect returns code
`GoogleSignInSheet`: Google's consent page in Apple's authentication sheet
(`ASWebAuthenticationSession`), the way Google's own SDK signs macOS apps
in. The sheet shares the browser's Google session, shows the page's real
address, and hands back only a redirect in LokalBot's own client scheme,
so no other app or web page can receive the authorization code.

#### Throws CancellationError when the person closes the sheet
`GoogleSignInSheet.present`: Shows `url` and returns the redirect Google sends to `callbackScheme`.
Throws `CancellationError` when the person closes the sheet.

#### Non-ephemeral session reuses browser's signed-in Google account
`GoogleSignInSheet.run`: Reuse the Google account already signed in to the browser.

### `LokalBotTests/Services/Email/EmailControllerTests.swift`

#### Recent successes keep the background email check from starting
`testDisconnectRevokesAndDeletesOnlyThatAccountsMail`: Recent successes keep the background check from starting.

#### A different key simulates a Keychain item that can't be read as saved
`testAnUnreadableAccountListIsNeverOverwritten`: Another key, as when the Keychain item can't be read as saved.

### `LokalBotTests/Services/Email/EmailScopeTests.swift`

#### Anyone can spoof From with the owner's address; only SENT label counts
`testASpoofedFromHeaderIsNotTheOwner`: Anyone can put the person's own address in From; only SENT counts.

### `LokalBotTests/Services/Email/EmailTextTests.swift`

#### Adjacent encoded words join without the space between them
`EmailText.decodeEncodedWords`: Adjacent encoded words join without the space between them.

#### Unknown charset falls back to UTF-8, then Latin-1, never nothing
`EmailText.decode`: An unknown charset falls back to UTF-8, then Latin-1, never to nothing.

#### Gmail wraps a long 'On ... wrote:' header onto a second line
`EmailText.conversationText`: Gmail wraps a long header onto a second line.

### `LokalBotTests/Services/Email/GmailOAuthTests.swift`

#### Plus in login_hint must be percent-encoded, not read as a space
`GmailOAuth.AuthorizationRequest`: "+" must arrive as itself, not as a space.

#### Google consent lets the person untick Gmail yet still returns a code
`GmailOAuth.parseCallback`: Google's consent screen lets the person untick Gmail and still returns a code.

#### Google doesn't rotate the refresh token; the old one stays
`GmailAuthorizer refresh`: Google doesn't rotate the refresh token; the old one stays.

#### Pending revocations survive serialization and a fresh authorizer
`GmailAuthorizer.forget`: The pending revocations survive serialization and a fresh authorizer.

#### Loopback listener must tolerate a stray favicon request before the callback
`testSignInCompletesThroughLoopbackRedirect`: A stray request first, as a browser's favicon fetch would be.

### `LokalBotTests/Services/Email/GmailSyncTests.swift`

#### Bulk and stranger threads are never downloaded with bodies
`testFirstPassStoresConversationsAndSkipsEverythingElse`: The bulk and stranger threads were never downloaded with bodies.

#### Mail window is 90 days; at 89.5 days seeded messages fall outside
`testMailOlderThanTheWindowAgesOut`: 89.5 days later every seeded message is outside the window.

#### An unreadable calendar at launch or paused must not delete or search mail
`testABrieflyEmptyCalendarDeletesNothingAndSearchesNothing`: Ana replies while the calendar can't be read (launch, calendar use paused).

#### Threads you wrote in fill the scan limit before attendee searches run
`testACappedScanLeavesPeopleItNeverSearched`: The two threads you wrote in fill the limit; Ana's search never runs.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
