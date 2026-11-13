# One-time setup

Part of the [release runbook](../../RELEASING.md).

## 1. Point the project at a GitHub repo

The canonical remote is `https://github.com/stevyhacker/lokalbot.git`. If you
are starting from a fresh clone or fork, set the real `owner/repo` slug anywhere
the examples below still use `OWNER/REPO`.

Create a new remote only for a fresh repository:

```sh
git remote add origin git@github.com:OWNER/REPO.git
git push -u origin main
```

## 2. Generate the Sparkle key pair (ONCE, ever)

Sparkle ships the key tools as binaries inside its SwiftPM artifact. After an
Xcode build that resolves the Sparkle package, symlink them onto your PATH:

```sh
mkdir -p ~/bin
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys    -type f | head -n 1)" ~/bin/sparkle-generate-keys
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update       -type f | head -n 1)" ~/bin/sparkle-sign-update
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

> No Sparkle package resolved yet? Download a Sparkle release tarball from
> <https://github.com/sparkle-project/Sparkle/releases>; the tools are under
> its `bin/` directory (`bin/generate_keys`, `bin/sign_update`).

Generate the key and print the public half:

```sh
sparkle-generate-keys           # creates the private key in the login Keychain
sparkle-generate-keys -p        # prints the base64 SUPublicEDKey
```

Back the private key up somewhere safe (you can never regenerate a matching one):

```sh
sparkle-generate-keys -x ~/secure/LokalBot-sparkle-key.txt
```

## 3. Publish the public key in the app

Add the Sparkle Info.plist keys via `project.yml` (so xcodegen writes them into
`LokalBot.app/Contents/Info.plist`). Under `targets.LokalBot.info.properties`:

```yaml
        SUFeedURL: https://github.com/stevyhacker/lokalbot/releases/latest/download/appcast.xml
        SUPublicEDKey: R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=
        SUEnableAutomaticChecks: true        # default on for new installs
```

`SUPublicEDKey` must match the private key used by `sign_update` at release time.
A mismatch makes every installed copy reject the update silently.

> Adding the Sparkle **framework** to the app (the `SPUStandardUpdaterController`
> wiring) is separate from this runbook; this document covers building, signing,
> and publishing the release artifacts.

## 4. Create the Developer ID Application certificate

For direct distribution outside the Mac App Store, create a **Developer ID
Application** certificate for team `3N8B4562P4`. The simplest route is Xcode:

1. Open Xcode → Settings → Accounts.
2. Select the Apple ID and the `Stevan Bogosavljevic` team.
3. Open **Manage Certificates…**, click `+`, and choose
   **Developer ID Application**.

Verify that the certificate and its private key are available locally:

```sh
security find-identity -p codesigning -v
```

The output must include `Developer ID Application` with team `3N8B4562P4`.
`Apple Development`, `Apple Distribution`, and `Developer ID Installer` are
different certificate types and do not replace it for this DMG flow.

For GitHub Actions, export the Developer ID Application certificate **with its
private key** from Keychain Access as a password-protected `.p12`. Never commit
the `.p12` or its password.

An App Store Connect app record and a Mac App Store provisioning profile are
not required for this direct-distribution path.

## 5. Store notarization credentials

Create an app-specific password at <https://appleid.apple.com>, then cache it as
a notarytool keychain profile so the release commands stay credential-free:

```sh
xcrun notarytool store-credentials "LokalBot-notary" \
  --apple-id "you@example.com" \
  --team-id "3N8B4562P4" \
  --password "<app-specific-password>"
```

---
