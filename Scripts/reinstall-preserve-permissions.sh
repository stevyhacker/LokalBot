#!/usr/bin/env bash
# Rebuild and reinstall LokalBot without changing the permission-bearing app
# identity. This intentionally updates the existing /Applications bundle in
# place instead of deleting it first, so macOS TCC grants keep pointing at the
# same signed app identity.
#
# Xcode's Developer ID export writes its own form of the designated
# requirement. When that text differs from the installed app's but the build
# still satisfies the installed requirement, the outer bundle is re-signed with
# the installed requirement so the identity TCC checks stays the same.
#
# Usage:
#   Scripts/reinstall-preserve-permissions.sh
#   Scripts/reinstall-preserve-permissions.sh --no-relaunch
#   CONFIGURATION=Release Scripts/reinstall-preserve-permissions.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LokalBot"
PROJECT="LokalBot.xcodeproj"
SCHEME="LokalBot"
CONFIGURATION="${CONFIGURATION:-Debug}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
INSTALLED_APP="${LOKALBOT_APP:-/Applications/LokalBot.app}"

TMP_ROOT="/private/tmp"
DERIVED_DATA="$TMP_ROOT/lokalbot-preserve-permissions-DerivedData"
SPM_CACHE="$TMP_ROOT/lokalbot-preserve-permissions-SPM"
BUILD_LOG="$TMP_ROOT/lokalbot-preserve-permissions-xcodebuild.log"
LOCK_DIR="$TMP_ROOT/lokalbot-preserve-permissions.lock"
ARCHIVE_PATH="$DERIVED_DATA/$APP_NAME.xcarchive"
EXPORT_PATH="$DERIVED_DATA/export"
EXPORT_OPTIONS="$DERIVED_DATA/ExportOptions.plist"

RELAUNCH=1

usage() {
  cat <<EOF
Usage: Scripts/reinstall-preserve-permissions.sh [--no-relaunch] [--help]

Environment:
  CONFIGURATION        Xcode configuration to build. Default: Debug
  LOKALBOT_APP         Installed app path. Default: /Applications/LokalBot.app
  EXPECTED_BUNDLE_ID   Expected bundle id. Default: installed app's bundle id
  EXPECTED_TEAM_ID     Expected Apple Team ID. Default: installed app's team
  SIGNING_IDENTITY     Xcode signing selector. Default: installed app's authority
EOF
}

log() {
  printf '== %s\n' "$*"
}

note() {
  printf '   %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-relaunch)
      RELAUNCH=0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

plist_raw() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

codesign_display() {
  /usr/bin/codesign -dv --verbose=4 -r- "$1" 2>&1
}

codesign_field() {
  local path="$1"
  local field="$2"
  codesign_display "$path" | /usr/bin/awk -F= -v field="$field" '
    $1 == field && value == "" { value = $2 }
    END { if (value != "") print value }
  '
}

codesign_authority() {
  codesign_display "$1" | /usr/bin/awk '
    /^Authority=/ && value == "" {
      sub(/^Authority=/, "")
      value = $0
    }
    END { if (value != "") print value }
  '
}

designated_requirement() {
  codesign_display "$1" | /usr/bin/awk '
    /^designated => / && value == "" {
      sub(/^designated => /, "")
      value = $0
    }
    END { if (value != "") print value }
  '
}

verify_app_identity() {
  local app_path="$1"
  local label="$2"
  local bundle_id
  local team_id
  local requirement

  [ -d "$app_path" ] || fail "$label app is missing: $app_path"
  [ -f "$app_path/Contents/Info.plist" ] || fail "$label app has no Info.plist: $app_path"

  bundle_id="$(plist_raw "$app_path/Contents/Info.plist" CFBundleIdentifier)"
  [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || fail "$label bundle id is '$bundle_id', expected '$EXPECTED_BUNDLE_ID'"

  /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || fail "$label app fails codesign verification: $app_path"

  team_id="$(codesign_field "$app_path" TeamIdentifier)"
  [ "$team_id" = "$EXPECTED_TEAM_ID" ] || fail "$label TeamIdentifier is '$team_id', expected '$EXPECTED_TEAM_ID'"

  requirement="$(designated_requirement "$app_path")"
  [ -n "$requirement" ] || fail "$label app has no designated signing requirement"

  printf '%s\n' "$requirement"
}

satisfies_requirement() {
  /usr/bin/codesign --verify --test-requirement="=$2" "$1" >/dev/null 2>&1
}

# Re-signs only the outer bundle; nested code keeps the export's signatures.
resign_with_requirement() {
  local app_path="$1"
  local requirement="$2"
  local timestamp="--timestamp=none"

  [ -n "$(codesign_field "$app_path" Timestamp)" ] && timestamp="--timestamp"
  /usr/bin/codesign --force \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    --requirements="=designated => $requirement" \
    "$timestamp" \
    --sign "$SIGNING_IDENTITY" \
    "$app_path"
}

# Only the installed copy: Release replays and benchmarks run other copies
# under the same process name and must keep running.
installed_app_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v exe="$INSTALLED_EXECUTABLE" '
    { pid = $1; sub(/^ *[0-9]+ +/, "") }
    $0 == exe || index($0, exe " ") == 1 { print pid }
  '
}

cleanup_old_temp_dirs() {
  local removed=0
  local path

  shopt -s nullglob
  for path in \
    "$TMP_ROOT"/lokalbot-reinstall-DerivedData \
    "$TMP_ROOT"/lokalbotfable-DerivedData-* \
    "$TMP_ROOT"/lokalbot-preserve-permissions-DerivedData.old.*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ "$path" = "$DERIVED_DATA" ] && continue
    log "Removing old temp dir: $path"
    rm -rf "$path"
    removed=$((removed + 1))
  done
  shopt -u nullglob

  if [ "$removed" -eq 0 ]; then
    note "no old LokalBot reinstall temp dirs found"
  else
    note "removed $removed old temp dir(s)"
  fi
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "another reinstall appears to be running: $LOCK_DIR"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

need_cmd xcodegen
need_cmd xcodebuild

log "Prechecking installed app identity"
note "installed app: $INSTALLED_APP"
[ -d "$INSTALLED_APP" ] || fail "installed app is missing: $INSTALLED_APP"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-$(plist_raw "$INSTALLED_APP/Contents/Info.plist" CFBundleIdentifier)}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-$(codesign_field "$INSTALLED_APP" TeamIdentifier)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(codesign_authority "$INSTALLED_APP")}"
[ -n "$EXPECTED_BUNDLE_ID" ] || fail "could not derive the installed bundle id"
[ -n "$EXPECTED_TEAM_ID" ] || fail "could not derive the installed TeamIdentifier"
[ -n "$SIGNING_IDENTITY" ] || fail "could not derive the installed signing authority"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/$(plist_raw "$INSTALLED_APP/Contents/Info.plist" CFBundleExecutable)"
installed_requirement="$(verify_app_identity "$INSTALLED_APP" installed)"
installed_signed_time="$(codesign_field "$INSTALLED_APP" Timestamp)"
note "bundle id: $EXPECTED_BUNDLE_ID"
note "team id: $EXPECTED_TEAM_ID"
note "signing identity: $SIGNING_IDENTITY"
note "installed signed time: ${installed_signed_time:-unknown}"

log "Regenerating Xcode project"
Scripts/build-sync-xcframework.sh
xcodegen generate >/dev/null

log "Building signed $CONFIGURATION app"
note "derived data: $DERIVED_DATA"
note "package cache: $SPM_CACHE"
note "build log: $BUILD_LOG"
rm -rf "$DERIVED_DATA"
mkdir -p "$SPM_CACHE"

if [[ "$SIGNING_IDENTITY" == "Developer ID Application"* ]]; then
  log "Archiving with Developer ID and Hardened Runtime"
  if ! xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    -destination 'generic/platform=macOS' \
    ENABLE_HARDENED_RUNTIME=YES \
    ARCHS=arm64 \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    -quiet >"$BUILD_LOG" 2>&1; then
    /usr/bin/tail -80 "$BUILD_LOG" >&2 || true
    fail "xcodebuild archive failed; full log: $BUILD_LOG"
  fi

  /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert teamID -string "$EXPECTED_TEAM_ID" "$EXPORT_OPTIONS"
  /usr/bin/plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS"
  if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet >>"$BUILD_LOG" 2>&1; then
    /usr/bin/tail -80 "$BUILD_LOG" >&2 || true
    fail "xcodebuild export failed; full log: $BUILD_LOG"
  fi
  BUILT_APP="$EXPORT_PATH/$APP_NAME.app"
else
  if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SPM_CACHE" \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    -quiet \
    build >"$BUILD_LOG" 2>&1; then
    /usr/bin/tail -80 "$BUILD_LOG" >&2 || true
    fail "xcodebuild failed; full log: $BUILD_LOG"
  fi
  BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
fi

log "Checking built app identity"
note "built app: $BUILT_APP"
built_requirement="$(verify_app_identity "$BUILT_APP" built)"
built_signed_time="$(codesign_field "$BUILT_APP" Timestamp)"
note "built signed time: ${built_signed_time:-unknown}"

if [ "$built_requirement" != "$installed_requirement" ]; then
  note "installed requirement: $installed_requirement"
  note "built requirement:     $built_requirement"
  satisfies_requirement "$BUILT_APP" "$installed_requirement" \
    || fail "built app does not satisfy the installed app's signing requirement; refusing to replace because TCC permissions would not survive"

  log "Re-signing built app with the installed signing requirement"
  resign_with_requirement "$BUILT_APP" "$installed_requirement" >>"$BUILD_LOG" 2>&1 \
    || fail "re-signing failed; full log: $BUILD_LOG"
  built_requirement="$(verify_app_identity "$BUILT_APP" built)"
  [ "$built_requirement" = "$installed_requirement" ] \
    || fail "re-signed app signing requirement still differs from installed app"
  note "re-signed time: $(codesign_field "$BUILT_APP" Timestamp)"
fi

log "Stopping running app"
running_pids="$(installed_app_pids)"
if [ -n "$running_pids" ]; then
  note "stopping pid(s): $(printf '%s ' $running_pids)"
  kill $running_pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -z "$(installed_app_pids)" ] && break
    /bin/sleep 0.5
  done
  [ -z "$(installed_app_pids)" ] || fail "$APP_NAME is still running from $INSTALLED_APP; quit it and rerun"
else
  note "not running"
fi
/usr/bin/pkill -x "LokalBotV3" 2>/dev/null || true

log "Syncing app bundle in place"
note "source: $BUILT_APP/"
note "dest:   $INSTALLED_APP/"
/usr/bin/rsync -a --delete "$BUILT_APP/" "$INSTALLED_APP/"

log "Verifying installed app after copy"
post_requirement="$(verify_app_identity "$INSTALLED_APP" installed)"
[ "$post_requirement" = "$installed_requirement" ] || fail "post-copy signing requirement changed unexpectedly"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"

if [ "$RELAUNCH" -eq 1 ]; then
  log "Relaunching $INSTALLED_APP"
  /usr/bin/open -n "$INSTALLED_APP"

  app_pid=""
  for _ in $(seq 1 20); do
    app_pid="$(installed_app_pids | /usr/bin/head -1)"
    [ -n "$app_pid" ] && break
    /bin/sleep 0.5
  done

  [ -n "$app_pid" ] || fail "$APP_NAME did not appear to launch"
  note "running pid: $app_pid"
else
  note "relaunch skipped"
fi

log "Cleaning old reinstall temp dirs"
cleanup_old_temp_dirs

log "Done"
note "installed app: $INSTALLED_APP"
note "bundle id: $EXPECTED_BUNDLE_ID"
note "team id: $EXPECTED_TEAM_ID"
note "signed time: $(codesign_field "$INSTALLED_APP" Timestamp)"
note "kept current derived data: $DERIVED_DATA"
note "kept package cache: $SPM_CACHE"
note "build log: $BUILD_LOG"
