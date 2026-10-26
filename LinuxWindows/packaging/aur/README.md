# AUR package: lokalbot-bin

`lokalbot-bin/` holds the `PKGBUILD` and `.SRCINFO` published to the AUR as
[lokalbot-bin](https://aur.archlinux.org/packages/lokalbot-bin), so Arch and
Omarchy users can run `yay -S lokalbot-bin`. It repackages the release's
`LokalBot-<version>-linux-x86_64.tar.gz` (checksum from its `.sha256` asset)
with the files and dependencies of the release's own Arch package
(`scripts/package-linux-distros.sh`):

- `/usr/bin/lokalbot` and `/usr/bin/lokalbot-cli`;
- `/usr/share/applications/com.lokalbot.LokalBot.desktop` and the hicolor icons;
- `LICENSE` (GPL-3.0), `THIRD_PARTY_NOTICES.md` and the `LICENSES/` folder
  of license texts it names (AGPL-3.0 for the Autocomplete code ported from
  Cotabby and, in releases after 0.11.0, the Rust crates' licenses) in
  `/usr/share/licenses/lokalbot-bin`, at the paths the notices give.

It provides and conflicts with `lokalbot`, the name of the release's own Arch
package. Keep the two packages' `depends` the same.

Like the release packages, it installs into `/usr/bin`, so LokalBot never
replaces its own files. It finds that `lokalbot-bin` owns them (`pacman -Qo`)
and, when a new version is out, tells the user to update with `yay -Syu`, which
picks it up once the AUR has the new version.

## Checks

`scripts/ci/check-aur-package.sh` builds and installs the package with
`makepkg -si` in a clean `archlinux:latest` container and fails when
`.SRCINFO` does not match the `PKGBUILD`, namcap reports an error, a library
is missing, or `lokalbot-cli` reports another version. The **AUR package**
workflow (`.github/workflows/aur.yml`) runs it on pull requests that change
these files. namcap's remaining warnings on the built package are expected:

| Warning | Why it stays |
| --- | --- |
| `Unused shared library '/usr/lib64/ld-linux-x86-64.so.2'` | Both binaries import `__tls_get_addr` from the loader; namcap misses it. |
| `Dependency included, but may not be needed ('vulkan-icd-loader')`, `('wayland')` | The app loads `libvulkan.so.1` and `libwayland-client.so.0` with `dlopen`, so they are not in its `NEEDED` list. |
| `Dependency included, but may not be needed ('libgomp')` | The llama.cpp runtime the app downloads links `libgomp.so.1`; the app itself doesn't. |

## Updating

The release workflow does this for every stable tag: its `aur` job
(`aur.yml`) runs `scripts/update-aur.sh <version>`, checks the result as
above, and pushes `PKGBUILD` and `.SRCINFO` to the AUR with the
`AUR_SSH_PRIVATE_KEY` secret. It pushes only while the `AUR_PUBLISH`
repository variable is `true`; without the variable or the secret it checks
and stops. Pre-releases are skipped.

The release job sets `pkgver`, `pkgrel` and the checksum and takes everything
else from this folder, so the copy here may name an older version. To bring
it up to date:

```bash
cd LinuxWindows
scripts/update-aur.sh 0.11.1        # pkgver, pkgrel=1, sha256, .SRCINFO
scripts/ci/check-aur-package.sh
```

`update-aur.sh` needs `makepkg`, or `docker`/`podman` to run it in an Arch
container. For a packaging-only change to a published version (a new
dependency, say), edit the `PKGBUILD`, run
`scripts/update-aur.sh <same version> <pkgrel + 1>`, merge it, and publish it
from master with `gh workflow run aur.yml -f tag=v<same version>`.

## One-time setup

These need the maintainer's own accounts, so CI cannot do them:

1. Create an AUR account at <https://aur.archlinux.org/register>. New
   registrations were closed in October 2026 after a wave of malicious
   uploads; check the page by hand rather than scripting retries.
2. Make a key for the AUR without a passphrase (CI cannot type one) and add
   its public half under **My Account → SSH Public Key**:

   ```bash
   ssh-keygen -t ed25519 -N '' -C 'lokalbot-bin AUR' -f ~/.ssh/aur_lokalbot
   cat ~/.ssh/aur_lokalbot.pub
   ```

3. Check the host key fingerprint against the one on the AUR home page
   (Ed25519 `SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4`), then push
   the first version, which creates the package:

   ```bash
   git -c core.sshCommand='ssh -i ~/.ssh/aur_lokalbot -o IdentitiesOnly=yes' \
     clone ssh://aur@aur.archlinux.org/lokalbot-bin.git /tmp/lokalbot-bin
   cp LinuxWindows/packaging/aur/lokalbot-bin/{PKGBUILD,.SRCINFO} /tmp/lokalbot-bin/
   cd /tmp/lokalbot-bin
   git config core.sshCommand 'ssh -i ~/.ssh/aur_lokalbot -o IdentitiesOnly=yes'
   git add PKGBUILD .SRCINFO
   git commit -m 'Initial import: lokalbot-bin 0.11.0-1'
   git push origin master
   ```

4. Let releases publish it:

   ```bash
   gh secret set AUR_SSH_PRIVATE_KEY --repo stevyhacker/LokalBot < ~/.ssh/aur_lokalbot
   gh variable set AUR_PUBLISH --repo stevyhacker/LokalBot --body true
   ```

5. Check <https://aur.archlinux.org/packages/lokalbot-bin> and
   `yay -S lokalbot-bin` on an Arch machine. Then make `yay -S lokalbot-bin`
   the first install option in the Omarchy section of `LinuxWindows/README.md`
   (it now says the AUR package is on its way) and on the website.
