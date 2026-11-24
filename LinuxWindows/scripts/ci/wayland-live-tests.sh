#!/usr/bin/env bash
set -euo pipefail

lw_root="$(cd "$(dirname "$0")/../.." && pwd)"
repo_root="$(cd "$lw_root/.." && pwd)"
cd "$lw_root"

image="${WAYLAND_IMAGE:-ubuntu:26.04}"
sysroot="$(rustc --print sysroot)"
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
target_dir="${CARGO_TARGET_DIR:-$lw_root/target}"
host_uid="$(id -u)"
host_gid="$(id -g)"

mkdir -p "$cargo_home" "$target_dir"
cargo fetch --locked

docker run --rm -i \
  -v "$repo_root:/work" \
  -v "$sysroot:/opt/toolchain:ro" \
  -v "$cargo_home:/opt/cargo" \
  -v "$target_dir:/work-target" \
  -e DEBIAN_FRONTEND=noninteractive \
  -e HOST_UID="$host_uid" \
  -e HOST_GID="$host_gid" \
  "$image" bash -s <<'EOF'
set -euo pipefail

apt-get update -qq
apt-get install -y --no-install-recommends \
  gcc libc6-dev pkg-config libxkbcommon-dev libwayland-dev libfontconfig-dev \
  sway foot wtype wl-clipboard \
  kwin-wayland kwin-common libei1 \
  dbus-daemon python3 python3-gi gir1.2-gtk-3.0 fonts-dejavu-core

setcap -r /usr/bin/kwin_wayland

run_user="$(getent passwd "$HOST_UID" | cut -d: -f1 || true)"
if [ -z "$run_user" ]; then
  run_group="$(getent group "$HOST_GID" | cut -d: -f1 || true)"
  if [ -z "$run_group" ]; then
    groupadd -g "$HOST_GID" ci
    run_group=ci
  fi
  useradd -m -u "$HOST_UID" -g "$run_group" -s /bin/bash ci
  run_user=ci
fi
run_home="$(getent passwd "$run_user" | cut -d: -f6)"
mkdir -p "$run_home"
chown "$HOST_UID:$HOST_GID" "$run_home"

export LANG=C.UTF-8 LC_ALL=C.UTF-8
sway --version
kwin_wayland --version
/opt/toolchain/bin/rustc --version

runuser -u "$run_user" -- env \
  HOME="$run_home" \
  PATH="/opt/toolchain/bin:$PATH" \
  CARGO_HOME=/opt/cargo \
  CARGO_TARGET_DIR=/work-target \
  CARGO_NET_OFFLINE=true \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  bash -euo pipefail -c '
    bash /work/LinuxWindows/crates/lokalbot-platform/scripts/live-kwin.sh
    bash /work/LinuxWindows/crates/lokalbot-platform/scripts/live-sway.sh
  '
EOF
