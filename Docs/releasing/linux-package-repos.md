# Linux package repositories

Part of the [release runbook](../../RELEASING.md).

The release's `.deb` and `.rpm` add LokalBot's own apt and dnf repositories,
the way Chrome's and VS Code's packages do, so installing the downloaded file
once means `sudo apt upgrade` or `sudo dnf upgrade` brings every later stable
version. The `.deb` installs `/etc/apt/sources.list.d/lokalbot.sources` and
`/usr/share/keyrings/lokalbot-archive-keyring.gpg`; the `.rpm` installs
`/etc/yum.repos.d/lokalbot.repo` (`gpgcheck=1`, `repo_gpgcheck=1`) and
`/etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot`. The repository files are config
files, so a user's edits (`Enabled: no`, `enabled=0`) survive upgrades.
`scripts/package-linux-distros.sh` adds these files only once
`LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc` exists. The Arch
package has no repository.

| URL | What it is |
| --- | --- |
| `https://pkg.lokalbot.com/apt` | apt repository: suite `stable`, component `main`, `amd64`; signed `InRelease` and `Release.gpg`, indexes also by hash |
| `https://pkg.lokalbot.com/rpm` | dnf repository: signed RPMs, `repodata/repomd.xml.asc` |
| `https://pkg.lokalbot.com/lokalbot.gpg`, `lokalbot.asc` | the public key, unarmored and armored |

`release.yml`'s `linux-repos` job calls `.github/workflows/linux-repos.yml`
for stable tags after the packages are attached; pre-release tags never reach
the repositories. On a GitHub-hosted runner (never a self-hosted one: this key
decides what every subscribed computer installs as root) it downloads the
release's `.deb` and `.rpm`, checks them against the SHA-256 GitHub reports,
copies the published packages from the R2 bucket `lokalbot-packages`, and runs
`LinuxWindows/scripts/linux-repos.sh`. That adds the release unless its
version is already published (a published version's bytes never change),
keeps the newest 3 versions, signs new RPMs with `rpmsign`, rebuilds and signs
the indexes, and checks every signature against the public key. The job then
uploads packages and hash-named indexes first, then the signed indexes (sent
with `Cache-Control: no-cache`), deletes the pruned packages, and compares
what `pkg.lokalbot.com` serves with what it uploaded. The workflow owns the
bucket: anything else in it is deleted, except older hash-named indexes, kept
so a client holding the previous index still finds its files. Without the
secrets the job skips with a notice; once the key is committed, a missing
secret fails it, because that release's packages point at the repositories.

To add a release that is already out (or to retry), run
`gh workflow run linux-repos.yml -f tag=vX.Y.Z`. Pull requests that change the
repositories or the packages run `scripts/ci/check-linux-repos.sh`: it
packages the latest release's binaries as four versions with a throwaway key,
serves the repositories as `pkg.lokalbot.com` on a private Docker network, and
checks that clean Ubuntu 24.04, Debian 13 and Fedora containers install the
first from the downloaded file, upgrade with `apt upgrade` and `dnf upgrade`,
keep an edited repository file, and refuse a tampered `InRelease`, `Release`
or `repomd.xml`, a swapped `.deb` or `.rpm`, and an unsigned `.rpm`. Run it on
any Linux machine with Docker:
`NFPM=/path/to/nfpm LinuxWindows/scripts/ci/check-linux-repos.sh LokalBot-X.Y.Z-linux-x86_64`.

## One-time setup

1. Generate the key on a trusted computer: RSA 4096 (every apt and rpm
   version verifies it; Ed25519 needs a recent rpm), signing only, expiring in
   3 years. CI has no passphrase prompt, so the key has none; the backup is
   what protects it.

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-generate-key \
     'LokalBot package signing <stevyhacker@users.noreply.github.com>' rsa4096 sign 3y
   FPR=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
   gpg --armor --export-options export-minimal --export "$FPR" \
     > LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc
   gpg --armor --export-secret-keys "$FPR" | gh secret set LINUX_REPO_GPG_PRIVATE_KEY --repo stevyhacker/lokalbot
   ```

   Keep `gpg --armor --export-secret-keys "$FPR"` and the revocation
   certificate `$GNUPGHOME/openpgp-revocs.d/$FPR.rev` in your password manager,
   not on disk, then `rm -rf "$GNUPGHOME"`. Don't commit the public key yet.
2. In Cloudflare: create the R2 bucket `lokalbot-packages`; under its
   Settings → Custom Domains, connect `pkg.lokalbot.com` (this adds the DNS
   record and serves the bucket publicly there; leave the `r2.dev` URL off);
   then create an R2 API token with **Object Read & Write** on that bucket
   only. Each object carries its own `Cache-Control`, so no cache rule is
   needed.
3. Add the token and account ID:

   ```sh
   gh secret set LINUX_REPO_R2_ACCOUNT_ID --repo stevyhacker/lokalbot
   gh secret set LINUX_REPO_R2_ACCESS_KEY_ID --repo stevyhacker/lokalbot
   gh secret set LINUX_REPO_R2_SECRET_ACCESS_KEY --repo stevyhacker/lokalbot
   ```

4. Publish the current release and check it is served:
   `gh workflow run linux-repos.yml -f tag=v0.11.0`, then
   `curl -fsS https://pkg.lokalbot.com/apt/dists/stable/InRelease`. Its
   packages don't add the repositories, so nobody uses them yet.
5. Commit `lokalbot-archive-keyring.asc`, with the README and website copy
   that tells users about the repositories (#339). The next release's `.deb`
   and `.rpm` add the repositories, and every release after it reaches them
   with `apt upgrade` and `dnf upgrade`.

## Key expiry and rotation

The job warns when the key expires within 180 days. After it expires, apt and
dnf refuse the repositories until the computer has the extended key, and the
only way to deliver it is a package update signed before the expiry. So extend
the key well ahead, with the backup imported into a temporary `GNUPGHOME`:

```sh
gpg --quick-set-expire "$FPR" 3y
gpg --armor --export-options export-minimal --export "$FPR" > LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc
gpg --armor --export-secret-keys "$FPR" | gh secret set LINUX_REPO_GPG_PRIVATE_KEY --repo stevyhacker/lokalbot
```

Commit the key, store the new backup and ship a release; the published
`lokalbot.gpg` updates with it. apt reads the keyring file, so the installed
release is enough. dnf keeps the key it imported in the rpm database
(`gpg-pubkey`); `sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot`
updates its expiry there (checked with rpm 6.0 on Fedora 44), which the
release notes should mention. A computer that missed
every update until the old expiry gets the key back with
`curl -fsSL https://pkg.lokalbot.com/lokalbot.gpg | sudo tee /usr/share/keyrings/lokalbot-archive-keyring.gpg > /dev/null`
(apt) or by installing the latest `.rpm` from the release page (dnf).

To move to a new key, generate it, commit both keys in one armored file
(`gpg --armor --export-options export-minimal --export OLD NEW`) and ship a
release, still signed with the old key. Once most installs have that release,
switch `LINUX_REPO_GPG_PRIVATE_KEY` to the new key; the next release's indexes
are signed with it. Drop the old key from the file a few releases later.

## If the key leaks

The key alone can't reach users: an attacker also needs to serve files as
`pkg.lokalbot.com`. Still, act at once:

1. Delete `LINUX_REPO_GPG_PRIVATE_KEY`, and revoke and replace the R2 token in
   Cloudflare.
2. Generate a new key. Import the old key's revocation certificate
   (`gpg --import OLD.rev`) and commit the new key and the revoked old key in
   one armored file.
3. Ship a release whose repositories are still signed with the old key (set
   it as the secret for this one run): installs trust only that key until
   they have the new keyring. Then set the new key as the secret and run
   `gh workflow run linux-repos.yml -f tag=<that release>`, which signs the
   same repositories again with it.
4. In the release notes, tell users who hadn't updated yet to install the
   latest package from the release page, and dnf users to remove the old key
   with `sudo rpm -e gpg-pubkey-<old key ID>` (dnf keeps keys it imported).

## Taking a version back

apt and dnf never downgrade, so the fix for a bad release is a newer one. To
stop more computers from upgrading in the meantime, delete the version's
`apt/pool/main/l/lokalbot/lokalbot_X.Y.Z-1_amd64.deb` and
`rpm/lokalbot-X.Y.Z-1.x86_64.rpm` from the bucket in the Cloudflare dashboard,
then run `gh workflow run linux-repos.yml -f tag=vPREVIOUS` with the previous
good tag: it rebuilds the indexes from what is left.

---
