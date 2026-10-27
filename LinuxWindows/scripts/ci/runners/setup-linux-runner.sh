#!/usr/bin/env bash
# Sets up a self-hosted GitHub Actions runner for the "Linux & Windows"
# workflow on an Ubuntu 24.04 host. Run it as a user with sudo, with a runner
# registration token on stdin:
#
#   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
#     ssh HOST 'bash setup-linux-runner.sh https://github.com/OWNER/REPO'
#
# The runner runs as its own unprivileged user (no sudo, no docker) under a
# systemd unit that cannot reach the Tailscale network, uses a private /tmp,
# and gets a lower CPU weight and a memory cap. See README.md.
set -euo pipefail

URL=${1:?usage: setup-linux-runner.sh <repository-url> [runner-name]}
NAME=${2:-lokalbot-linux}
LABEL=lokalbot-linux
RUNNER_USER=ghrunner
RUNNER_VERSION=2.338.0
RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
TOOLCHAIN=1.99.1
# capture-linux.sh starts its own Xvfb on this display.
CAPTURE_DISPLAY=:240

read -r TOKEN || true
[ -n "${TOKEN:-}" ] || { echo "Pass a runner registration token on stdin." >&2; exit 1; }

HOME_DIR=/home/$RUNNER_USER
RUNNER_DIR=$HOME_DIR/actions-runner
if sudo test -f "$RUNNER_DIR/.runner"; then
  echo "A runner is already configured in $RUNNER_DIR; remove it first (README.md)." >&2
  exit 1
fi

as_runner() { sudo -u "$RUNNER_USER" -H bash -c "$1"; }

echo "== packages the workflow installs on GitHub's runners"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  libxkbcommon-x11-dev libwayland-dev libvulkan1 mesa-vulkan-drivers libfontconfig-dev \
  libasound2-dev libxcb1-dev libx11-xcb-dev libssl-dev pkg-config clang \
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
as_runner "mkdir -p '$RUNNER_DIR' '$HOME_DIR/target' && cd '$RUNNER_DIR' &&
  curl -fsSLo runner.tar.gz https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz &&
  echo '$RUNNER_SHA256  runner.tar.gz' | sha256sum -c --quiet - && tar xzf runner.tar.gz && rm runner.tar.gz"

# The token goes through a file the runner user owns, so it never shows up in
# a process list.
token_file=$(sudo -u "$RUNNER_USER" mktemp)
printf '%s' "$TOKEN" | sudo -u "$RUNNER_USER" tee "$token_file" >/dev/null
as_runner "cd '$RUNNER_DIR' && ACTIONS_RUNNER_INPUT_TOKEN=\$(cat '$token_file') ./config.sh --unattended \
  --url '$URL' --name '$NAME' --labels '$LABEL' --work _work --replace; rc=\$?; rm -f '$token_file'; exit \$rc"

# Jobs keep a warm target directory instead of restoring a cache. Written
# after config.sh, which rewrites .path.
as_runner "cd '$RUNNER_DIR' && printf '%s\n' LANG=C.UTF-8 CARGO_TARGET_DIR=$HOME_DIR/target CAPTURE_DISPLAY=$CAPTURE_DISPLAY > .env &&
  echo '$HOME_DIR/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > .path"

echo "== systemd service"
sudo bash -c "cd '$RUNNER_DIR' && ./svc.sh install '$RUNNER_USER'"
UNIT=$(sudo cat "$RUNNER_DIR/.service")
sudo mkdir -p "/etc/systemd/system/$UNIT.d"
sudo tee "/etc/systemd/system/$UNIT.d/lokalbot.conf" >/dev/null <<'EOF'
[Service]
# CI jobs run code from pull requests. Keep them off the Tailscale network
# (IPv4 CGNAT range and Tailscale's IPv6 prefix), out of other users' /tmp and
# X displays, and from crowding out interactive work on the host.
IPAddressDeny=100.64.0.0/10 fd7a:115c:a1e0::/48
PrivateTmp=true
NoNewPrivileges=true
CPUWeight=50
MemoryMax=32G
EOF
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
sudo systemctl is-active "$UNIT"
echo "Runner $NAME ($LABEL) is installed as $UNIT."
