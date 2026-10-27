# Google sign-in and verification for Gmail

Date: 2026-10-26. Owner: the LokalBot Google Cloud project's owner.

LokalBot signs in to Gmail with its own Google OAuth client and the read-only Gmail scope, `gmail.readonly`. Google classifies that scope as restricted.

- **Before Google verifies the app:** the client works for at most 100 users, and each of them first sees an "unverified app" screen.
- **After verification:** anyone can sign in without that screen.
- **Renewal:** Google repeats the review every 12 months.

This document covers the one-time setup, the answers to give in Google's submission, and what the app must keep true to stay verified.

## Client choice

Google requires the **iOS** client type for macOS apps ([Google Sign-In for iOS and macOS](https://developers.google.com/identity/sign-in/ios/start-integrating)). That client type has no client secret. Its sign-in returns through the client's own URL scheme, `com.googleusercontent.apps.<id>`.

LokalBot shows Google's page in `ASWebAuthenticationSession`, Apple's sign-in sheet, which is what Google's own SDK uses on macOS. The sheet returns only redirects in that scheme (`GoogleSignInSheet`). A client ID is public, so it lives in the source as `GmailOAuth.builtInClientID`.

People who want their own Google Cloud project can still import a Desktop-app client under Settings → Day Memory → Email → Use your own Google OAuth client. That path uses the loopback redirect.

## One-time setup in Google Cloud

Use a Google account that will own LokalBot for the long term, and add a second owner so the project never depends on one person.

1. **Find the project before creating one.** LokalBot's existing project is `lokalbot-512410` (number `158325362655`), confirmed on October 27, 2026. Select it in [console.cloud.google.com](https://console.cloud.google.com). Check its existing OAuth clients before adding one. Only create a new project if the intended owner cannot use this project.
2. **Enable Gmail.** Open **APIs & Services → Library**, choose **Gmail API**, and click **Enable**.
3. **Fill in Branding** (under **Google Auth Platform**):
   - App name `LokalBot`, the user support email, and the 120×120 app icon (`AppIcon.icns`, exported as PNG).
   - Home page `https://www.lokalbot.com`, privacy policy `https://www.lokalbot.com/privacy`, terms `https://www.lokalbot.com/terms`.
   - Authorized domain `lokalbot.com`, and the developer contact email.

   A project owner must verify `lokalbot.com` in Google Search Console with the same Google account.
4. **Set the Audience.** Choose **External**, then **Publish app**. While the project is in Testing, Google expires every sign-in after 7 days.
5. **Set Data access.** **Add or remove scopes** → add `https://www.googleapis.com/auth/gmail.readonly`, and nothing else.
6. **Create the client.** Go to **Clients → Create client → iOS**:
   - name `LokalBot for Mac`;
   - bundle ID `me.dotenv.LokalBot`;
   - leave App Store ID and Team ID empty.
7. **Put the client ID in the source.** Copy the client ID (`…apps.googleusercontent.com`) into `GmailOAuth.builtInClientID`.
   - The Dev build (`me.dotenv.LokalBot.dev`) signs in with the same client, because Google checks the bundle only with App Check, which LokalBot doesn't use.
   - If Google ever refuses it, register a second iOS client for the Dev bundle.

From then on, a release with the client ID gives one-click Gmail sign-in to the first 100 users, each behind the unverified-app screen.

## Setup and integration check: October 27, 2026

- **Confirmed against Google Cloud:** the existing project above is active, the signed-in account is its owner, and Gmail API was enabled successfully. Before setup, the Credentials page listed no OAuth clients and asked for consent-screen configuration.
- **Still required:** finish Branding, External audience and Data access; verify `lokalbot.com` ownership with the project's owner; create the iOS client; and add its public ID to `GmailOAuth.builtInClientID`. Never commit tokens, a Desktop client's secret, or downloaded credential JSON.
- **Live policy:** the public privacy page still lacks the draft PR's **Email from Gmail** disclosure. Deploy that disclosure before shipping Gmail integration or submitting verification.
- **Automated checks:** 78 focused email tests passed in an isolated Swift package containing the unchanged production email sources and their existing dependencies (only logging replaced). They use synthetic mail, an in-memory secret store, and temporary encrypted files. This is a focused subsystem check, not an app build or a live Google sign-in.
- **Reconnect correction:** Google [revokes the account's grant across the entire Cloud project](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke), including newly issued tokens. Reconnect therefore saves the new tokens without revoking the old ones. Replaced refresh tokens remain in the Keychain solely for Disconnect, which deletes local credentials and mail before attempting every retained revocation. The regression fails with the old save behavior restored, then passes with the fix.
- **Not tested against Google yet:** the native authorization-sheet redirect, actual refresh-token issuance and reuse, limited mailbox synchronization, and removal of the grant on Disconnect. Keep this PR in draft until setup and these checks are complete.

For live integration testing, use a willing test account and an isolated library, keep the scope exactly `gmail.readonly`, limit the first scan, and record only request status/counts. Do not record tokens, authorization codes, message bodies, or private attendee addresses in PR evidence. Check the native callback, force one refresh, repeat sign-in, run a small first sync followed by history replay, then Disconnect and confirm local deletion and Google grant removal. This testing does not submit restricted-scope verification.

## When to submit

Submit after the first feature that reads mail, the "From email" section of the meeting brief, has shipped. Google's reviewers need to see the scope used by a feature people can see. Until then LokalBot only counts conversations, and that would not justify the scope.

Before submitting:

- Check that the live privacy page at `https://www.lokalbot.com/privacy` shows the **Email from Gmail** section and the Limited Use statement. Google reads the deployed page.
- Make sure the home page still links to the privacy page.
- Record the demo video from a release build that contains the client ID.

## Submission answers

**How LokalBot uses the scope:**

> LokalBot is a local-first macOS app that prepares people for their meetings. When a person connects a Gmail account, LokalBot downloads, onto their own Mac, the conversations they wrote in and the conversations that involve the people on their calendar. It uses those conversations to show, before each meeting, what is still open with those people: questions they were asked, promises made, and dates agreed. With the person's approval, it also suggests facts for their Personal Context page from mail they sent themselves. All processing happens on the person's Mac. LokalBot has no server; mail and tokens never leave the device, and mail is not sent to any AI provider.

**Why `gmail.readonly` and not a narrower scope:**

> The briefs need the text of messages, which `gmail.metadata` doesn't return; metadata alone can't tell what was asked or agreed. LokalBot never changes mail, so it doesn't request `gmail.modify`, `gmail.compose`, `gmail.send`, or the full `https://mail.google.com/` scope. `gmail.readonly` is the narrowest scope that returns message bodies.

**Data handling answers:**

- **Stored on servers?** No. Data is stored only on the user's device, encrypted with AES-GCM under a key in the macOS Keychain. Tokens are in the Keychain.
- **Shared with third parties?** No. There are no transfers, no advertising, no human access, and no AI or machine-learning training.
- **Retention:** a rolling 90-day window. Disconnect deletes the account's mail and tokens immediately and revokes the grant at Google.

## Demo video

Record in English, at 1080p or higher, as one continuous take, and upload it to YouTube as unlisted. The shots:

1. **The client.** Open the Google Cloud console's **Clients** page with the `LokalBot for Mac` client ID visible. Then show the same ID in the source (`GmailOAuth.builtInClientID` on GitHub). The macOS sign-in sheet shows the page's host but not the full URL, so this proves which client is being reviewed.
2. **The app's home page and privacy page.** Scroll to **Email from Gmail**.
3. **The notice.** In LokalBot, open **Settings → Day Memory → Email → Add Gmail Account…** and show the notice that explains what is read.
4. **The consent screen.** Click **Continue**. Google's consent screen appears in the sign-in sheet. Show all of it, with the language set to English at the bottom left and the read-only Gmail permission listed.
5. **The first check.** After sign-in, show the account in Settings and the "Checked … · N conversations" line.
6. **The feature.** Open **Today** before a meeting with someone you have emailed, and show the brief's email section citing those threads. This shot can only be filmed once that feature exists.
7. **Disconnect.** Click **Disconnect…** and confirm, then show the account and its mail gone. Then show **myaccount.google.com/permissions**, where LokalBot no longer has access.

## Security assessment

Google's restricted-scope pages say a security assessment (CASA) is the final step of the review. The assessment is at assurance level AL1 or AL2 and is renewed every year ([Security Assessment](https://support.google.com/cloud/answer/13465431)). Google's pages describe the requirement for apps that can reach restricted data "from or through a third-party server".

LokalBot has no server, so it may be exempt. Google decides during the review, so plan for an assessment anyway.

Keep these true; they are also what an assessment looks for:

- tokens and mail encrypted at rest, in the Keychain and as sealed files;
- TLS-only requests to Google's hosts, with no cross-origin redirects followed;
- no credentials or message text in logs;
- deletion on Disconnect.

## What the app must keep true

These come from Google's [User Data Policy](https://developers.google.com/terms/api-services-user-data-policy) and [Workspace API policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy). Later email work must preserve them.

| Requirement | How LokalBot meets it |
| --- | --- |
| Request the narrowest scope | `gmail.readonly` only (`GmailOAuth.scope`). The client sends only `GET` requests (`GmailSyncTests.testEveryRequestIsAReadOnlyGetToGmail`). |
| Disclose use in the privacy policy, linked from the consent screen | PRIVACY.md and `web/privacy.html`, section **Email from Gmail**, with the Limited Use statement. |
| Show a timely disclosure in the product | The **Connect a Gmail account?** notice before Google's page opens (`EmailSettingsSection`). |
| Use data only for features people can see | Today: the Settings account list. Every new use updates the privacy policy first and asks the person. |
| No transfers, no ads, no human reading | Mail never leaves the Mac. Nothing sends it anywhere. |
| No AI or ML model training | LokalBot trains no models. Personal Context suggestions are the user's own, kept on their Mac, and wait for their review. |
| Encrypt data and tokens at rest | `EmailStore` (AES-GCM, `email-key` in the Keychain); tokens in the Keychain (`KeychainEmailSecretStore`). |
| Honor deletion | Disconnect deletes locally first, then revokes (`EmailController.disconnect`). Mail older than 90 days ages out. |
| Protect against prompt injection | Required once mail reaches a model (the brief). Prompts built from mail have no tools, quote mail as untrusted evidence through `PromptContextSanitizer`, and never reach Agent Mode. |
| Keep contact details current and act on Google's notices | The project owner's email in Branding; respond within Google's deadlines or API access is lost. |

Remote AI models are the one open question. Google allows a transfer that provides a feature the person can see, if they consent. LokalBot's current position is simpler: mail-derived text goes only to local models. Changing that needs a privacy-policy update, a per-feature opt-in, and a note in the next re-verification.

## Timeline

1. Now: create the project and client, then add the client ID to `GmailOAuth.builtInClientID`. Releases sign in with LokalBot's client, up to 100 users.
2. When the brief's email section ships: record the video and submit. Restricted-scope review "can take several weeks" ([restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)), plus any security assessment.
3. Every year: Google's re-verification and assessment. Update this document if scopes, data use, or storage change.
