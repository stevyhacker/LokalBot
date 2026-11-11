#!/usr/bin/env bash
# Sets up a self-hosted GitHub Actions runner on an Ubuntu 24.04 host. Run it
# as a user with sudo, with a runner registration token on stdin:
#
#   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
#     ssh HOST 'bash setup-linux-runner.sh https://github.com/OWNER/REPO [linux|android]'
#
# "linux" (the default) is the runner for the Linux job of "Linux & Windows";
# "android" is a second one beside it, for "Companion Android", so the two can
# run at the same time. Give that one an SDK with setup-linux-android-sdk.sh.
#
# The runner is named after its label (lokalbot-linux, lokalbot-android). To
# add a machine beside one that already has that runner, give it a name of its
# own; the label stays the same, so the picker uses whichever one is idle:
#
#   ... | ssh HOST 'RUNNER_NAME=lokalbot-linux-pc bash setup-linux-runner.sh https://github.com/OWNER/REPO'
#
# Registering with a name that is already taken replaces that runner.
#
# Both run as one unprivileged user (no sudo, no docker), each under a systemd
# unit that cannot reach the Tailscale network or private networks (a home LAN,
# Docker bridges) and uses a private /tmp. The two units share a slice that gets
# a lower CPU weight and a memory cap. See README.md.
set -euo pipefail

URL=${1:?usage: setup-linux-runner.sh <repository-url> [linux|android]}
KIND=${2:-linux}
RUNNER_USER=ghrunner
RUNNER_VERSION=2.338.0
RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
TOOLCHAIN=1.99.1
# capture-linux.sh starts its own Xvfb on this display.
CAPTURE_DISPLAY=:240

read -r TOKEN || true
[ -n "${TOKEN:-}" ] || { echo "Pass a runner registration token on stdin." >&2; exit 1; }

HOME_DIR=/home/$RUNNER_USER
case $KIND in
  linux) LABEL=lokalbot-linux RUNNER_DIR=$HOME_DIR/actions-runner TARGET=$HOME_DIR/target ;;
  android) LABEL=lokalbot-android RUNNER_DIR=$HOME_DIR/actions-runner-android TARGET=$HOME_DIR/target-android ;;
  *) echo "usage: setup-linux-runner.sh <repository-url> [linux|android]" >&2; exit 1 ;;
esac
NAME=${RUNNER_NAME:-$LABEL}
if ! [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "RUNNER_NAME must be 1-64 letters, digits, '.', '_' or '-'." >&2
  exit 1
fi
SLICE=system-ghrunner.slice
# CI jobs run code from pull requests. Keep them off the Tailscale network
# (IPv4 CGNAT range and Tailscale's IPv6 prefix) and private networks (a home
# LAN, a hypervisor's NAT, Docker bridges, link-local).
DENY="100.64.0.0/10 fd7a:115c:a1e0::/48 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 fc00::/7 fe80::/10"
if sudo test -f "$RUNNER_DIR/.runner"; then
  echo "A runner is already configured in $RUNNER_DIR; remove it first (README.md)." >&2
  exit 1
fi

# The block also stops DNS when /etc/resolv.conf names a private resolver
# (WSL's 10.255.255.254, a home router), and the runner would never connect.
# A local stub such as systemd-resolved (127.0.0.53) works.
if ! sudo systemd-run --quiet --wait --pipe --property=IPAddressDeny="$DENY" \
    timeout 8 getent hosts github.com >/dev/null; then
  echo "Name lookups fail behind the runner's network block: /etc/resolv.conf uses" >&2
  grep -E '^nameserver' /etc/resolv.conf >&2 || true
  echo "Point it at a local stub resolver (systemd-resolved: 127.0.0.53) and run this again." >&2
  exit 1
fi

as_runner() { sudo -u "$RUNNER_USER" -H bash -c "$1"; }

echo "== packages the workflow installs on GitHub's runners"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  libxkbcommon-x11-dev libwayland-dev libvulkan1 mesa-vulkan-drivers libfontconfig-dev \
  libasound2-dev libxcb1-dev libx11-xcb-dev pkg-config clang \
  xvfb xfwm4 x11-xserver-utils xdotool ffmpeg hsetroot xfce4-panel x11-utils dbus-daemon \
  python3 git curl ca-certificates

echo "== runner user"
id "$RUNNER_USER" >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash "$RUNNER_USER"
sudo chmod 750 "$HOME_DIR"

echo "== Rust $TOOLCHAIN"
as_runner "test -x $HOME_DIR/.cargo/bin/rustup || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --profile minimal --default-toolchain none --no-modify-path"
as_runner "$HOME_DIR/.cargo/bin/rustup toolchain install $TOOLCHAIN --profile minimal -c rustfmt -c clippy"

echo "== runner $RUNNER_VERSION"
as_runner "mkdir -p '$RUNNER_DIR' '$TARGET' && cd '$RUNNER_DIR' &&
  curl -fsSLo runner.tar.gz https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz &&
  echo '$RUNNER_SHA256  runner.tar.gz' | sha256sum -c --quiet - && tar xzf runner.tar.gz && rm runner.tar.gz"

# The token goes through a file the runner user owns, so it never shows up in
# a process list.
token_file=$(sudo -u "$RUNNER_USER" mktemp)
printf '%s' "$TOKEN" | sudo -u "$RUNNER_USER" tee "$token_file" >/dev/null
as_runner "cd '$RUNNER_DIR' && ACTIONS_RUNNER_INPUT_TOKEN=\$(cat '$token_file') ./config.sh --unattended \
  --url '$URL' --name '$NAME' --labels '$LABEL' --work _work --replace; rc=\$?; rm -f '$token_file'; exit \$rc"

# Jobs keep a warm target directory of their runner's own instead of restoring
# a cache. Written after config.sh, which rewrites .path.
env_lines="LANG=C.UTF-8 CARGO_TARGET_DIR=$TARGET"
[ "$KIND" = linux ] && env_lines="$env_lines CAPTURE_DISPLAY=$CAPTURE_DISPLAY"
as_runner "cd '$RUNNER_DIR' && printf '%s\n' $env_lines > .env &&
  echo '$HOME_DIR/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > .path"

echo "== systemd service"
# Both runners together get the CPU weight one runner had alone, and a memory cap.
sudo tee "/etc/systemd/system/$SLICE" >/dev/null <<'EOF'
[Unit]
Description=Self-hosted GitHub Actions runners

[Slice]
CPUWeight=50
MemoryMax=40G
EOF
sudo bash -c "cd '$RUNNER_DIR' && ./svc.sh install '$RUNNER_USER'"
UNIT=$(sudo cat "$RUNNER_DIR/.service")
sudo mkdir -p "/etc/systemd/system/$UNIT.d"
{
  cat <<EOF
[Service]
Slice=$SLICE
# CI jobs run code from pull requests. Keep them off the Tailscale network and
# private networks, out of other users' /tmp and X displays, and from crowding
# out interactive work on the host. Loopback stays open: the emulator, the
# capture display and the local DNS stub use it.
IPAddressDeny=$DENY
PrivateTmp=true
NoNewPrivileges=true
CPUWeight=50
MemoryMax=32G
EOF
  if [ "$KIND" = android ]; then
    echo "# The emulator needs KVM."
    echo "SupplementaryGroups=kvm"
  fi
} | sudo tee "/etc/systemd/system/$UNIT.d/lokalbot.conf" >/dev/null
sudo systemctl daemon-reload
sudo bash -c "cd '$RUNNER_DIR' && ./svc.sh start"

echo "== checks"
# The same block, applied to a throwaway unit, must stop a tailnet connection.
if sudo systemd-run --quiet --wait --pipe --uid="$RUNNER_USER" \
    --property=IPAddressDeny="100.64.0.0/10 fd7a:115c:a1e0::/48" \
    bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/100.100.100.100/53"' 2>/dev/null; then
  echo "IPAddressDeny did not block the tailnet on this host." >&2
  exit 1
fi
# And a private network: when the default gateway is a private address (a home
# router, a hypervisor's NAT) that answers on port 53 or 80, the block must stop it.
gateway=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
# shellcheck disable=SC2016 # $0 is expanded by the inner bash
probe='timeout 3 bash -c "exec 3<>/dev/tcp/$0/53" 2>/dev/null || timeout 3 bash -c "exec 3<>/dev/tcp/$0/80" 2>/dev/null'
if [[ ${gateway:-} =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] &&
  sudo -u "$RUNNER_USER" bash -c "$probe" "$gateway" &&
  sudo systemd-run --quiet --wait --pipe --uid="$RUNNER_USER" \
    --property=IPAddressDeny="$DENY" \
    bash -c "$probe" "$gateway"; then
  echo "IPAddressDeny did not block the private network ($gateway) on this host." >&2
  exit 1
fi
sudo systemctl is-active "$UNIT"
echo "Runner $NAME ($LABEL) is installed as $UNIT."
