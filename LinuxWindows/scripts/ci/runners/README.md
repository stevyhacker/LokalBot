# Self-hosted runners

The "Linux & Windows" workflow (`.github/workflows/linux-windows.yml`) runs
its Linux and Windows jobs on the maintainer's own machines when they are
online and idle, and on GitHub's runners otherwise. "Companion Android"
(`.github/workflows/companion-android.yml`) does the same on a second runner on
the Linux machine, so the two can run side by side.
A self-hosted runner keeps a warm cargo target directory between jobs, so a run
there rebuilds only what changed instead of restoring a cache.

## How a run picks its runners

The first job, **Pick runners**, runs on GitHub. It lists the repository's
runners and sends each job to a self-hosted runner that is online, idle and
carries the right label (`lokalbot-linux`, `lokalbot-windows`,
`lokalbot-android`). Everything else goes to GitHub's runners:

- pull requests from forks, always;
- runs where the `SELF_HOSTED_RUNNERS` repository variable is `off`;
- runs without the `RUNNER_STATUS_TOKEN` secret, or when listing fails;
- for Companion Android, every run with a `tag` input: `release.yml` and manual
  dry runs. That job builds the APK the release signs with the real key, so it
  always runs on `ubuntu-latest`, and it fails if it ever lands anywhere else.

Most Android changes also start "Linux & Windows", because they touch the sync
core. Each of the two jobs has a runner of its own on the Linux machine, so they
run at the same time instead of one waiting or going to GitHub.

Listing runners needs more than the workflow's own token can do:
`RUNNER_STATUS_TOKEN` is a fine-grained personal access token with access to
this repository only and one permission, Administration: read-only. Only the
Pick runners job, on GitHub's machine, ever sees it. When it expires, runs
fall back to GitHub's runners.

The Windows desktop checks (page captures, the autocomplete probe in
Notepad, screen capture and OCR) take over the screen, so they never run on
the maintainer's PC. When the Windows job runs there, it uploads
`lokalbot.exe` and the three check programs, and the **Windows desktop
checks** job runs them on GitHub's Windows runner. On GitHub's runner, the
Windows job runs the checks itself (`.github/actions/windows-desktop-checks`).

On the Linux machine, Companion Android keeps its own warm target,
`~/.gradle` and `~/.m2` between runs, and never writes to GitHub's caches, so
nothing from that machine reaches a hosted run. Other people run emulators on it, so its emulator test goes
through `Companion/e2e/own_emulator.py` instead of `android-emulator-runner`:
the action only takes the ports every adb server scans. Its own adb server and
emulator ports stay out of everyone else's way, and `android_trip.py` picks a
free port for the stand-in computer.

## Isolation

Runner jobs run code from the repository's branches and pull requests. The
repository requires approval before a workflow runs for any outside
contributor, and the picker never sends fork pull requests to these machines.
The machines are set up so a bad job can do little:

| | Linux (`setup-linux-runner.sh`) | Windows (`setup-windows-runner.ps1`) |
|---|---|---|
| Account | `ghrunner` for both runners: no sudo, no docker, private home; the `kvm` group only in the Android runner's service | NETWORK SERVICE; `C:\gh` limited to SYSTEM, Administrators and that account |
| Tailscale network | Blocked by `IPAddressDeny` on the systemd unit | Blocked by an outbound firewall rule for the runner service (unrestricted service SID) |
| Sharing the host | Both runners in `system-ghrunner.slice`: `CPUWeight=50` and `MemoryMax=40G` together, `MemoryMax=32G` each; private `/tmp`; the Linux job's own X display (`:240`) | Steps run at below-normal priority, on the CPU's performance cores |
| State between jobs | Warm targets in `~ghrunner/target` and `~ghrunner/target-android`; XDG folders per job | Warm target in `C:\gh\t`; workspace synced per job (`sync-sources.ps1`); when the manifests change, programs with unhashed names are removed so no job tests or packages another branch's build (`check-runner.ps1`) |
| Secrets | None: these jobs use no repository secrets | None; release builds and signing stay on GitHub's runners |

Every self-hosted job starts with `check-runner.sh` or `check-runner.ps1`. It
fails the job if the runner can reach Tailscale's DNS address
(100.100.100.100), and clears the warm target when the disk runs low.

## Setting a runner up

Each script installs a pinned, checksum-verified runner and a Rust toolchain,
registers the runner and starts it as a service. Pass a registration token on
stdin. It's valid for an hour, and the scripts keep it out of process lists.

```bash
gh api -X POST repos/stevyhacker/LokalBot/actions/runners/registration-token --jq .token |
  ssh LINUX_HOST 'bash setup-linux-runner.sh https://github.com/stevyhacker/LokalBot'

gh api -X POST repos/stevyhacker/LokalBot/actions/runners/registration-token --jq .token |
  ssh LINUX_HOST 'bash setup-linux-runner.sh https://github.com/stevyhacker/LokalBot android'

gh api -X POST repos/stevyhacker/LokalBot/actions/runners/registration-token --jq .token |
  ssh WINDOWS_HOST 'powershell -NoProfile -ExecutionPolicy Bypass -File setup-windows-runner.ps1 -Url https://github.com/stevyhacker/LokalBot'
```

The Android runner also needs an Android SDK. Run this again to update what it
installs:

```bash
ssh LINUX_HOST 'bash setup-linux-android-sdk.sh'
```

The Linux scripts need Ubuntu 24.04 and a user with sudo. The Windows script
needs an elevated shell, Visual Studio Build Tools with the C++ workload, Git
for Windows, 7-Zip and CMake. It installs PowerShell 7 machine-wide if it's
missing.

## Removing a runner

Take a removal token from
`gh api -X POST repos/stevyhacker/LokalBot/actions/runners/remove-token --jq .token`, then:

- Linux, for each of `~ghrunner/actions-runner` and `~ghrunner/actions-runner-android`:
  `cd` there, `sudo ./svc.sh stop && sudo ./svc.sh uninstall`, then as `ghrunner`
  run `./config.sh remove --token TOKEN`. Delete `/etc/systemd/system/actions.runner.*.d/`,
  `/etc/systemd/system/system-ghrunner.slice` and, if wanted, the user.
- Windows (elevated): `cd C:\gh\runner; .\config.cmd remove --token TOKEN`, then
  `Remove-NetFirewallRule -DisplayName 'GitHub Actions runner: no Tailscale network'`
  and delete `C:\gh`.

To stop using the machines without removing anything, set the
`SELF_HOSTED_RUNNERS` repository variable to `off`.
