# Public launch runbook

Building this project does not deploy the relay, register an OpenAI connection, publish a companion download, or submit a listing.

## Launch inputs

- Cloudflare account/profile, a stable HTTPS origin owned by the publisher, and authorization to deploy the Worker, KV namespace, Durable Objects, and rate-limit bindings, including their operating costs.
- A released LokalBot helper containing the interactive stdio fix. The installed 0.10.2 helper failed the live-pipe check; the source-built helper passes. Do not advertise compatibility with the installed version tested here.
- A stable companion download and update process. The first version needs Node and a foreground process; disclose this in the listing. It is not integrated into LokalBot's settings or login items.
- Publisher identity, support contact, applicable terms, and a published privacy notice covering Cloudflare transit and OAuth/device metadata. Replace the source manifest's privacy link if the service uses a separate notice. No terms or support endpoint is invented here.
- A synthetic reviewer Mac/library kept online and a repeatable reviewer pairing procedure. Supply review access through the submission portal, never a real user's library or production device credential.

## Deploy after approval

1. Select the intended `cf` profile/account using the installed CLI's help. Use `cf` for this project. `cloudflare.config.ts` declares the Worker, Durable Object class, managed KV, and rate-limit bindings.
2. Replace `PUBLIC_ORIGIN` in that config with the exact origin, without a trailing slash or path. Configure routing/custom domain in the chosen account to serve it. `.invalid` and unexpected hosts fail closed. Keep Cloudflare credentials outside source files and chat.
3. Run the README's source checks and native CLI fixture test, then:

   ```sh
   npm run build:relay
   npm exec -- cf deploy --dry-run
   ```

4. Review the account, generated resources, logging settings, and deployment output. With deployment authorization, run `npm exec -- cf deploy` under the same profile. Preserve KV/DO storage on updates; it holds active pairings and OAuth grants.
5. Run `npm run package:public -- --origin https://THE_DEPLOYED_ORIGIN`. It checks service health, protected-resource discovery, and the unauthenticated OAuth challenge. These checks establish discovery only, not successful pairing or rendering.
6. Distribute `dist/companion/` with its license notices and source/version reference using the approved release workflow. Keep the folder together. Node runs the bundled code directly; no runtime npm download is needed.

The Worker does not persist meeting payloads. KV contains OAuth registrations, consent transactions and grants. Durable Objects store device credential hashes, identities, and expiring pairing mappings. In-flight payloads exist in memory. Application observability is disabled; account-level logs, retention, access controls, cost limits, and support procedures need review before describing the deployed service's policy.

## Validate the deployed connection

Use two distinct synthetic Mac configurations and OAuth clients. Verify that colliding request ids and caller-provided device headers cannot cross libraries. Revoke one Mac: its old and refreshed OAuth tokens must stop reaching the library while the other remains available. Retain the source revision, Worker deployment identifier, helper version, configured origin, and results with review evidence.

The repository prohibits local UI tests. Use a remote runner or hosted environment for these ChatGPT/desktop checks:

- Fresh OAuth pairing, cancel, expired/repeated codes, and reauthorization.
- Sidebar and thread panels, light/dark styling, narrow layouts, keyboard navigation, and an empty library.
- Search, summaries, commitments, People, source selection, and desktop composer mentions resolving after reconnection.
- Disable meeting access while the panel is open, refresh, and confirm old rows disappear and reads fail. The plugin must not enable the setting itself.
- Stop the companion or sleep the Mac. Requests must fail explicitly; reconnection must not replay calls or switch devices.
- Include HTML/script-like titles and prompt-injection text in fixtures. Display them as source text and preserve tool/permission boundaries.
- Run setup in a fresh chat and during installation in an existing chat. Pairing codes must never be requested in conversation.

## Prompt evaluation cases

| Prompt | Expected behavior |
| --- | --- |
| Find the meeting where we chose Redis. | Search excerpts, read the matching summary, cite the meeting and available timestamp. |
| What decisions did we make in yesterday's design review? | Match title/date, fetch its summary, separate decisions from suggestions. |
| What do I owe Mira from our recent meetings? | Resolve the person and list saved commitments with source meetings; do not send messages. |
| Show my open meeting commitments. | Read active action items with saved status, owner, and due date. |
| Use this selected meeting to prepare a follow-up draft. | Resolve the selected source and draft from supported facts in chat. |
| What is the weather today? | Do not invoke LokalBot. |
| Read my screen history or screenshots. | Explain that this plugin has no screen-memory access. |
| Mark every action done and email the attendees. | Explain the read-only boundary; do not invoke write/send capabilities. |

Also test explicit transcript excerpts and ambiguous meetings/people. Read a bounded excerpt only when needed; clarify ambiguity rather than selecting unrelated evidence.

## Register, submit, and publish

Use OpenAI's [connection workflow](https://developers.openai.com/plugins/build/plugins) for a test registration at the deployed `/mcp` endpoint with OAuth. Pair a synthetic reviewer device, validate tools/UI, then use the actual registered id if building a desktop package with `--app-id`.

Follow [public submission](https://developers.openai.com/plugins/deploy/submission) using the remote MCP path. Include skills, accurate capabilities, screenshots, review evidence, real privacy/support/terms details, and the companion requirement. A build, private tunnel, or local marketplace installation does not establish public eligibility or publication. Complete review/publication in the publisher's account and record the live listing URL.

## Operations and rollback

Disabling the Worker stops remote access globally. Users can stop their companion, disable meeting-library permission, or revoke pairing. These controls cannot erase content already shared with a client.

Roll back through `cf` under the approved account while preserving KV/DO data. Changes to stored authorization formats need compatible migrations. Never log codes, tokens, redirect query strings, or tool contents; diagnose with synthetic data and status categories.

There is no public self-service OAuth metadata deletion page in this version. Revocation immediately removes the device record and denies access; OAuth records age out under the provider's TTLs. Publisher support must cover deletion requests for remaining metadata before launch.
