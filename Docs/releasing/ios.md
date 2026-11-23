# iPhone and iPad

Part of the [release runbook](../../RELEASING.md).

The app is on the [App Store](https://apps.apple.com/app/id6836773709) as
`me.dotenv.LokalBot.companion`, team `3N8B4562P4`. The tag that releases macOS
also sends it to App Review, while the `APP_STORE_PUBLISH` repository variable is
`true`. Pre-release tags stay off the App Store.

`release.yml` calls `.github/workflows/app-store.yml` once the macOS job has
published the release (so its release gates passed). That workflow has two jobs,
both on GitHub's hosted macOS runners:

1. `archive` checks that `MARKETING_VERSION` in `Companion/ios/project.yml`
   names the tag's version, then builds the Release archive from the tag with
   `CODE_SIGNING_ALLOWED=NO`. It sees no secret. The archive, with the dSYMs
   that decode crash reports from that build, stays in the run's `release-ios`
   artifact for 90 days.
2. `publish` runs no build script. It signs that archive through
   `xcodebuild -exportArchive` (`Companion/ios/ExportOptions.plist`) with the
   App Store Connect API key, which uses Apple's cloud-managed distribution
   certificate, so no certificate or provisioning profile is stored in the
   repository or its secrets and none has to be renewed each year. Then
   `Scripts/release/publish_app_store.py` uploads the `.ipa` with `altool`,
   waits up to 45 minutes for App Store Connect to process it, attaches the build to the App Store version, writes What's New, and
   submits the version for review.

How far a release goes is the `APP_STORE_RELEASE` repository variable:

| Value | What happens |
| --- | --- |
| `review` (default) | Submitted for review, and released automatically once approved |
| `manual` | Submitted for review; the approved version waits for **Release This Version** in App Store Connect |
| `testflight` | Uploaded only; the processed build is in TestFlight and nothing is submitted |

## Version and build number

The app carries the release's version and the Mac build number, like the
Android app. `Scripts/release/bump-version.py` writes both to
`Companion/ios/project.yml`, and `release-preflight.py` fails when they
disagree with `LokalBot/Info.plist`. App Store Connect refuses a build number it
has already seen for a version, so a fix to a broken upload needs a new build
number, as a bad release does.

## What's New

The release notes cover every platform, and App Review rejects text that names
another mobile platform. So What's New keeps only the bullets of
`Scripts/release/release-notes/<tag>.md` whose platform tag names iPhone, iPad or
iOS, for example:

```markdown
- **Record from the lock screen (iPhone and iPad).** Start a recording from Control Center.
```

The tag itself, links, bold and code marks are removed. A tagged bullet that
still names Android or Google Play is left out. When no bullet qualifies, What's
New is "Bug fixes and improvements." Every store language gets the same English
text, capped at 4,000 characters.

## One-time setup

1. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api)
   → Users and Access → Integrations → App Store Connect API, create a **team**
   key with the **Admin** role. Cloud signing refuses any lower role with "Cloud
   signing permission error", and individual keys have no access to signing. Download the
   `.p8` file; Apple offers it once. Note the key ID and the issuer ID shown on
   that page.
2. Store the three values as repository secrets, without pasting them into
   source or shell history:

   ```bash
   gh secret set APP_STORE_CONNECT_KEY_ID --repo stevyhacker/LokalBot
   gh secret set APP_STORE_CONNECT_ISSUER_ID --repo stevyhacker/LokalBot
   gh secret set APP_STORE_CONNECT_API_KEY --repo stevyhacker/LokalBot < /path/to/AuthKey_XXXXXXXXXX.p8
   ```

   Keep the `.p8` in your password manager, not on disk. An Admin key can change
   anything in the developer account, so it must never reach the Windows PC, a
   shared machine or a self-hosted runner. Revoke it in App Store Connect if it
   leaks; a new key needs only the three secrets replaced.
3. Export compliance is answered in the app. It encrypts sync traffic with
   Noise (X25519, ChaChaPoly, BLAKE2s), and `ITSAppUsesNonExemptEncryption` is
   `false` under `info.properties` in `Companion/ios/project.yml`, the answer
   given for build 1 (0.1.0) in App Store Connect. Builds from v0.13.4 on carry
   it, so App Store Connect does not ask.
   - **A build uploaded without the key** (a tag before v0.13.4) can only be
     answered in App Store Connect. In `review` and `manual` mode the job stops
     after processing with "has no export compliance answer": answer it for
     that build, then use **Re-run failed jobs**.
   - **In `testflight` mode the job does not check this** and succeeds anyway.
     Such a build can still show Missing Compliance in App Store Connect and
     stay unavailable to testers until it is answered.
   - **If the answer changes to `true`**, the key is not enough: App Store
     Connect also needs the encryption declaration for the build, and when
     Apple asks for export compliance documentation, the code it issues goes in
     `ITSEncryptionExportComplianceCode`.
4. Run the [dry run](#dry-run) below and fix what it reports.
5. Switch on publishing for stable tags:

   ```bash
   gh variable set APP_STORE_PUBLISH --body true --repo stevyhacker/LokalBot
   # Optional (default: review):
   # gh variable set APP_STORE_RELEASE --body manual --repo stevyhacker/LokalBot
   ```

Without `APP_STORE_PUBLISH=true` the release skips the job and spends no macOS
runner time on it.

## Dry run

```bash
gh workflow run app-store.yml --ref master -f validate_only=true
```

archives `master`, signs it with the key, and has App Store Connect validate the
signed app (`altool --validate-app`) without uploading it. It proves the key, its
role, cloud signing and the app's metadata. Add `-f tag=vX.Y.Z` to check a tag
instead. The first run is the only test of the signing and upload steps: pull
requests exercise the `archive` job and the script's tests, never the key.

## Publishing an existing tag by hand

`app-store.yml` can be dispatched from `master` for any stable tag whose
`Companion/ios/project.yml` names that version (tags from v0.13.4 on):

```bash
gh workflow run app-store.yml --ref master -f tag=vX.Y.Z
gh workflow run app-store.yml --ref master -f tag=vX.Y.Z -f release=testflight
```

## When a run stops

Rerunning is safe: a build App Store Connect already holds is not uploaded
again, and a version that is waiting for review, in review or released is left
alone.

- **Processing timed out.** The build was uploaded. Use **Re-run failed jobs**
  once App Store Connect lists it.
- **A version is already in review.** App Store Connect allows one version in
  review at a time, so the next one cannot be created until that review ends.
  Rerun the job afterwards.
- **A version was prepared but never submitted.** The job renames that version
  to the new release instead of creating a second one.
- **Rejected.** Reply or resubmit in App Store Connect; the job does not answer
  App Review.
- **A bad release.** Take it back by releasing a new version with a higher build
  number, or remove the version from sale in App Store Connect.

## Checks after publishing

In App Store Connect, the app's page should show the version as Waiting for
Review with the tag's build attached. The public listing follows once approved:

```bash
curl -s 'https://itunes.apple.com/lookup?id=6836773709' | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["version"])'
```

## App Review notes

App Review cannot pair with a computer. Keep the review notes in App Store
Connect pointing to **Try It Without a Computer** on the welcome screen, which
opens the built-in sample library, and explaining that the app syncs with
LokalBot on the person's computer over the local network or Tailscale and that
recording needs a paired computer. The job does not write review notes; App
Store Connect carries them from one version to the next.
