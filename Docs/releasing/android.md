# Android

Part of the [release runbook](../../RELEASING.md).

The tag that releases macOS also attaches the Android app, as
`LokalBot-<version>-android.apk`, for people to install directly. It holds
arm64-v8a and x86_64, and installs on Android 10 or later.

`release.yml` calls `companion-android.yml`, the same workflow CI uses, with the
tag, without secrets or a compiled-output cache, while the macOS job runs. Its
tag check fails when `versionName` does not name the tag's version. It builds the
shrunk release APK and runs the unit, screenshot and lint checks. It then signs
the APK with a throwaway key through `Scripts/release/sign-android-release.sh` and runs
the end-to-end test on that copy against the stand-in computer, on an emulator.
The tag keeps this job on GitHub's runners; CI's other runs may use the self-hosted
Android runner on the Linux machine.

After the macOS job has published the release (so its release gates passed),
`android-publish` signs the same unsigned APK with `ANDROID_KEYSTORE_BASE64` and
attaches it. The script refuses a key whose certificate differs from
`Companion/android/release-certificate.sha256`. Signing is not part of the Gradle
build, so no build script runs beside the key. Pre-release tags get an APK too.

The build's R8 mapping, which decodes a stack trace from that release, stays with
the unsigned APK in the run's `release-android` artifact for 90 days.

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
would not install for anyone.

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

`release.yml` doesn't upload to Play. Play takes an app bundle
(`./gradlew :app:bundleRelease`), not the APK, signed with the upload key. Build
it from the release tag and upload it in Play Console; until then, Play users stay
on the version they have. Play refuses a `versionCode` it has already seen, so a
fix to an upload needs a new build number, as a bad release does.
