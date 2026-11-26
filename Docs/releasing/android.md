# Android

Part of the [release runbook](../../RELEASING.md).

The tag that releases macOS also attaches the Android app, as
`LokalBot-<version>-android.apk`, for people to install directly. It holds
arm64-v8a and x86_64, and installs on Android 10 or later.

`release.yml` calls `companion-android.yml`, the same workflow CI uses, with the
tag, without secrets or a compiled-output cache, while the macOS job runs. Its
tag check fails when `versionName` does not name the tag's version. It builds the
shrunk release APK (`:app:assembleRelease`) and Android App Bundle
(`:app:bundleRelease`), and runs the unit, screenshot and lint checks. It signs
both with a throwaway key through `Scripts/release/sign-android-release.sh` and
`Scripts/release/sign-android-bundle.sh` and runs the end-to-end test on the APK
against the stand-in computer, on an emulator. The tag keeps this job on GitHub's
runners; CI's other runs may use the self-hosted Android runner on the Linux
machine.

After the macOS job has published the release (so its release gates passed),
`android-publish` signs the same unsigned APK with `ANDROID_KEYSTORE_BASE64` and
attaches it. The script refuses a key whose certificate differs from
`Companion/android/release-certificate.sha256`. Signing is not part of the Gradle
build, so no build script runs beside the key. Pre-release tags get an APK too.

The build's R8 mapping (which decodes stack traces from that release) and the
unsigned App Bundle stay with the unsigned APK in the run's `release-android`
artifact for 90 days.

If the macOS release succeeded but an Android job failed, fix the cause and use
**Re-run failed jobs**: the publish job uploads with `--clobber`.

The app has no update check, so people who use the APK install each new one over
the old one; Google Play users get updates from Play. Android keeps their
pairing and library only if the new APK has the same signing key and a higher
`versionCode` (the Mac build number):

- Taking a bad version back means releasing a new version with a higher build
  number. Android refuses to install a lower one over it.
- Replacing the key forces everyone to uninstall, which erases the phone's copy
  and its pairing. Never rotate it casually, and never lose it.
- Google Play signs the app with a different key ([Google Play](#google-play)),
  so moving between the APK and Play means uninstalling, with the same loss.

The iPhone and iPad app is not attached. iOS installs apps only through the App
Store, TestFlight or a provisioned device list, so an `.ipa` on the release page
would not install for anyone. The same tag sends it to the App Store instead
([iPhone and iPad](ios.md)).

## One-time setup

Generate the key on a trusted computer, not the Windows PC or a shared machine.
PKCS12 has one password, which CI reads from the secret; the backup is what
protects it. The certificate lasts 50 years because Google Play requires one
that runs past 2033, and it can't be renewed without changing the key.

```bash
dir=$(mktemp -d)
pass=$(openssl rand -hex 32)
keytool -genkeypair -keystore "$dir/lokalbot-android.p12" -storetype PKCS12 \
  -storepass "$pass" -alias lokalbot -keyalg RSA -keysize 4096 -validity 18250 \
  -dname "CN=LokalBot, O=LokalBot"
base64 -i "$dir/lokalbot-android.p12" | gh secret set ANDROID_KEYSTORE_BASE64 --repo stevyhacker/lokalbot
printf '%s' "$pass" | gh secret set ANDROID_KEYSTORE_PASSWORD --repo stevyhacker/lokalbot
keytool -list -v -keystore "$dir/lokalbot-android.p12" -storepass "$pass" \
  | awk '/SHA256:/ {print $2}' | tr -d : | tr 'A-F' 'a-f' > Companion/android/release-certificate.sha256
```

Keep `$dir/lokalbot-android.p12` and the password in your password manager, not
on disk, then `rm -rf "$dir"`. Commit `release-certificate.sha256`: from then on
every release attaches an APK, and a missing or different key fails the job.

## Dry run

```sh
gh workflow run companion-android.yml --ref BRANCH -f tag=v<current version>
```

builds as a release would, without caches, and keeps the unsigned APK as the
`release-android` artifact. It never reads the release key and publishes nothing.
Every run of the workflow signs with a throwaway key and tests that copy.

## Checks after publishing

```sh
gh release download vX.Y.Z --repo stevyhacker/lokalbot --pattern '*-android.apk'
apksigner verify --print-certs LokalBot-X.Y.Z-android.apk
```

The `SHA-256` line must match `Companion/android/release-certificate.sha256`.

## Google Play

The app is on [Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion) as `me.dotenv.lokalbot.companion`.
Play App Signing signs it with a key Google holds, not the release key above:

| Key | Certificate SHA-256 |
| --- | --- |
| Play app signing key (in use) | `8F:2B:EC:EE:17:39:4E:BD:C4:55:AF:8F:F5:3A:68:C7:DB:50:41:FA:B0:DB:B2:FC:B8:85:B9:E0:56:6E:73:5E` |
| Play upload key | `68:50:C1:30:C8:9D:1D:4B:61:0F:2E:1F:4B:1A:6F:91:E5:31:3F:AC:99:B5:C3:B7:43:D7:FD:14:50:E8:A0:EB` |
| Release key (the APK on GitHub) | `4f89301c866531db57b6a6f44fcf0e79ea6bbf5d0a8faff6066e406a07309d89` |

So Android won't install the APK over a Play install or the other way round:
switching means uninstalling, which erases the phone's copy and its pairing.
Play lets the app signing key be upgraded once a year, next from 3 November 2027.

For stable tags, `release.yml` calls `.github/workflows/google-play.yml` once
the macOS release gates and the `android` job succeed (pre-release tags stay off
Google Play). A called workflow sees its caller's event name, so the call is
recognised by its `from_release` input, never by `github.event_name`. While the
`PLAY_PUBLISH` repository variable is `true`, that job
runs on GitHub's hosted runner, signs the unsigned `app-release.aab` from the
`release-android` artifact with `Scripts/release/sign-android-bundle.sh`
(refusing any keystore whose certificate differs from
`Companion/android/play-upload-certificate.sha256`), and uploads the signed
`.aab`, the R8 `mapping.txt` deobfuscation file, and trimmed `en-US` release
notes from `Scripts/release/release-notes/<tag>.md` through
`Scripts/release/publish_google_play.py`. Without `PLAY_PUBLISH=true`, it prints
a notice and succeeds.

Play refuses a `versionCode` it has already seen, so `publish_google_play.py`
checks the target track first and exits cleanly when that `versionCode` is
already published; a fix to a broken upload still needs a new build number, as a
bad release does.

### One-time Google Play CI setup

1. In Google Cloud, enable the **Google Play Android Developer API** and create
   a service account (for example `lokalbot-play-release@<project>.iam.gserviceaccount.com`).
2. In **Google Play Console → Users and permissions**, invite that service
   account and grant **Release to production, exclude devices, and use Play App
   Signing** (and **Release apps to testing tracks** if using `internal`/`beta`)
   scoped to `me.dotenv.lokalbot.companion`.
3. Upload the Play upload keystore secrets (without pasting them into source or
   shell history):

```bash
base64 -i /path/to/play-upload.keystore | \
  gh secret set PLAY_UPLOAD_KEYSTORE_BASE64 --repo stevyhacker/LokalBot
gh secret set PLAY_UPLOAD_KEYSTORE_PASSWORD --repo stevyhacker/LokalBot
# Only needed if the keystore has multiple entries or a separate key password:
# gh secret set PLAY_UPLOAD_KEY_ALIAS --repo stevyhacker/LokalBot
# gh secret set PLAY_UPLOAD_KEY_PASSWORD --repo stevyhacker/LokalBot
```

4. Configure Google Play API authentication using **either** option:
   - **Service account JSON key (quickest):**
     ```bash
     gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo stevyhacker/LokalBot < /path/to/service-account.json
     ```
   - **Keyless GitHub OIDC (Workload Identity Federation), in use since
     2026-11-23:** project `lokalbot-512410` has the service account
     `lokalbot-play-release`, the pool `github` and its provider `lokalbot`,
     which accepts only this repository's `master` and `v*` tags
     (`assertion.repository == 'stevyhacker/LokalBot' && (assertion.ref ==
     'refs/heads/master' || assertion.ref.startsWith('refs/tags/v'))`), so a
     pull request branch cannot mint a Play token. The pool's
     `attribute.repository/stevyhacker/LokalBot` principal set has
     `roles/iam.workloadIdentityUser` on the service account. To recreate it,
     do the same and set:
     ```bash
     gh secret set PLAY_WORKLOAD_IDENTITY_PROVIDER --repo stevyhacker/LokalBot
     gh secret set PLAY_SERVICE_ACCOUNT_EMAIL --repo stevyhacker/LokalBot
     ```
5. Enable automatic publishing on stable tags:

```bash
gh variable set PLAY_PUBLISH --body true --repo stevyhacker/LokalBot
# Optional overrides (defaults: track=production, status=completed):
# gh variable set PLAY_TRACK --body production --repo stevyhacker/LokalBot
# gh variable set PLAY_RELEASE_STATUS --body completed --repo stevyhacker/LokalBot
```

### Publishing or validating an existing tag by hand

`google-play.yml` can also be dispatched from `master` for any stable tag (it
builds a clean unsigned `.aab` from that tag in a secret-free job first, then
signs and uploads it in the separate `publish` job):

```bash
# Dry-run validation against Google Play (uploads, validates edit, then deletes it):
gh workflow run google-play.yml --ref master -f tag=v0.13.3 -f validate_only=true

# Publish to production (or pass -f track=internal / -f status=draft):
gh workflow run google-play.yml --ref master -f tag=v0.13.3
```

### Store listing metadata, screenshots, and Play review

`Scripts/release/publish_google_play.py` uploads the `.aab`, R8 mapping, and
per-release What's New notes, while the versioned store listing copy lives in
[Companion/store-metadata/android/en-US/](../../Companion/store-metadata/android/en-US/):

| Field | Limit | Current value / file |
| --- | --- | --- |
| Title | 30 chars | `LokalBot: Private Meeting AI` (`title.txt`, 28 chars) |
| Short Description | 80 chars | `short_description.txt` (75 chars) |
| Full Description | 4,000 chars | `full_description.txt` (Mac, Windows, Linux pairing + offline recording) |
| Review & FGS notes | Console form | [review_notes.txt](../../Companion/store-metadata/android/en-US/review_notes.txt) |
| Screenshot plan | 8 to 10 shots | [screenshots.md](../../Companion/store-metadata/android/en-US/screenshots.md) |

Keep Google Play metadata free of iOS, iPhone, iPad, or App Store mentions.
Reviewers can test `FOREGROUND_SERVICE_MICROPHONE` right from the welcome
screen by tapping **Record a meeting** (saved strictly in private on-device
storage until paired with LokalBot on Mac, Windows, or Linux over Wi-Fi or
Tailscale) and can tap **Try it without a computer** to explore the built-in
sample library.
