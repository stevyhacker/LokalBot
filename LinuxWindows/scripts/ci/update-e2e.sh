#!/usr/bin/env bash
# End-to-end update from a dry-run feed on this computer. Installs the packaged
# archive the way a user does (install.sh into a scratch home), serves an
# update over plain HTTP on 127.0.0.1 signed with a throwaway key, and has the
# installed LokalBot check, download, verify, install and relaunch itself.
#
#   update-e2e.sh <installed-archive> <update-archive> <lokalbot-update-feed> <work-dir>
#
# The two archives may be the same file: the installed copy then pretends to
# be 0.0.1 (LOKALBOT_UPDATE_CURRENT_VERSION), which the relaunched copy does
# not inherit. Needs python3, openssl, and DISPLAY or Xvfb (on a free display
# number). Never touches the real home folder or library, and stops only the
# LokalBot it installed.
set -euo pipefail
trap 'echo "update-e2e.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR

INSTALLED_ARCHIVE="$(realpath "$1")"
UPDATE_ARCHIVE="$(realpath "$2")"
TOOL="$(realpath "$3")"
WORK="$4"
name_of() { basename "$1" .tar.gz; }
version_of() { name_of "$1" | sed -n 's/^LokalBot-\(.*\)-linux-x86_64$/\1/p'; }
OLD_VERSION="$(version_of "$INSTALLED_ARCHIVE")"
NEW_VERSION="$(version_of "$UPDATE_ARCHIVE")"
[ -n "$OLD_VERSION" ] && [ -n "$NEW_VERSION" ]

rm -rf "$WORK"
mkdir -p "$WORK/home" "$WORK/serve" "$WORK/library"
WORK="$(realpath "$WORK")"
export HOME="$WORK/home"
unset XDG_DATA_HOME XDG_BIN_HOME XDG_CONFIG_HOME
BIN="$HOME/.local/bin"
DATA="$HOME/.local/share"
ICON="$DATA/icons/hicolor/48x48/apps/com.lokalbot.LokalBot.png"
LOG="$WORK/library/logs/lokalbot.log"

tar -xzf "$INSTALLED_ARCHIVE" -C "$WORK"
"$WORK/$(name_of "$INSTALLED_ARCHIVE")/install.sh" >/dev/null

# The update, signed with a key made for this run only.
cp "$UPDATE_ARCHIVE" "$WORK/serve/"
(umask 077 && openssl rand -base64 32 > "$WORK/key")
PUBLIC="$("$TOOL" public-key --key-file "$WORK/key")"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
"$TOOL" sign --archive "$WORK/serve/$(basename "$UPDATE_ARCHIVE")" --platform linux-x86_64 \
  --version "$NEW_VERSION" --tag "v$NEW_VERSION" --key-file "$WORK/key" \
  --download-base "http://127.0.0.1:$PORT" --notes-url "http://127.0.0.1:$PORT/notes" \
  --output "$WORK/serve/linux-x86_64.json"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/serve" >"$WORK/http.log" 2>&1 &
HTTP=$!
# LokalBot reads the feed as soon as it starts; wait until the server answers.
FEED="http://127.0.0.1:$PORT/linux-x86_64.json"
for attempt in $(seq 120); do
  if python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' "$FEED" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$HTTP" 2>/dev/null || [ "$attempt" = 120 ]; then
    echo "The feed server did not answer at $FEED" >&2
    cat "$WORK/http.log" >&2
    exit 1
  fi
  sleep 0.5
done
XVFB=""
cleanup() {
  pkill -f "$BIN/lokalbot" 2>/dev/null || true
  kill "$HTTP" 2>/dev/null || true
  if [ -n "$XVFB" ]; then kill "$XVFB" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Marks that tell the copies apart: the binary's inode and a missing icon.
OLD_INODE="$(stat -c %i "$BIN/lokalbot")"
rm "$ICON"
printf '{"onboardingCompleted": true, "checkForUpdates": true}\n' > "$WORK/library/settings.json"

if [ -z "${DISPLAY:-}" ]; then
  # A display number nobody else on this machine uses.
  for number in $(seq 160 199); do
    if [ ! -e "/tmp/.X11-unix/X$number" ] && [ ! -e "/tmp/.X$number-lock" ]; then
      break
    fi
  done
  Xvfb ":$number" -screen 0 1280x800x24 -nolisten tcp >"$WORK/xvfb.log" 2>&1 &
  XVFB=$!
  export DISPLAY=":$number"
  sleep 1
fi

wait_for() { # pattern seconds
  local deadline=$((SECONDS + $2))
  until grep -q -- "$1" "$LOG" 2>/dev/null; do
    if ((SECONDS > deadline)); then
      echo "Timed out waiting for: $1" >&2
      tail -n 60 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
}

export LOKALBOT_STORAGE_ROOT="$WORK/library"
export LOKALBOT_UPDATE_FEED_URL="http://127.0.0.1:$PORT/linux-x86_64.json"
export LOKALBOT_UPDATE_PUBLIC_KEY="$PUBLIC"
if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
  export LOKALBOT_UPDATE_CURRENT_VERSION=0.0.1
fi
# `install-update` is the command form of Install and Relaunch.
"$BIN/lokalbot" install-update >"$WORK/first.out" 2>&1 &
FIRST=$!
wait_for "updates: installed LokalBot $NEW_VERSION" 240
wait_for "LokalBot $NEW_VERSION started after an update" 120
for _ in $(seq 60); do kill -0 "$FIRST" 2>/dev/null || break; sleep 1; done
if kill -0 "$FIRST" 2>/dev/null; then
  echo "The old copy did not quit" >&2
  exit 1
fi
# The relaunched copy checks the same feed and finds nothing newer.
wait_for "updates: up to date at $NEW_VERSION" 120

NEW_INODE="$(stat -c %i "$BIN/lokalbot")"
[ "$NEW_INODE" != "$OLD_INODE" ] || { echo "lokalbot was not replaced" >&2; exit 1; }
mkdir -p "$WORK/expected"
tar -xzf "$UPDATE_ARCHIVE" -C "$WORK/expected"
for binary in lokalbot lokalbot-cli; do
  cmp "$BIN/$binary" "$WORK/expected/$(name_of "$UPDATE_ARCHIVE")/$binary"
done
[ -f "$ICON" ] || { echo "the desktop icons were not refreshed" >&2; exit 1; }
grep -q "^Exec=$BIN/lokalbot" "$DATA/applications/com.lokalbot.LokalBot.desktop"
for leftover in "$BIN"/*.old "$BIN"/*.new; do
  if [ -e "$leftover" ]; then
    echo "update leftover remains: $leftover" >&2
    exit 1
  fi
done
pgrep -f "$BIN/lokalbot --after-update" >/dev/null || { echo "the relaunched LokalBot is not running" >&2; exit 1; }
grep "updates:\|after an update" "$LOG"
echo "Updated $OLD_VERSION → $NEW_VERSION and relaunched."
