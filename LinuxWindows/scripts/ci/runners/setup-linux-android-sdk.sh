#!/usr/bin/env bash
# Gives the Linux runner from setup-linux-runner.sh what the "Companion Android"
# workflow needs: an Android SDK of its own, because a job can't read anyone
# else's home. Run it as a user with sudo. Running it again installs only what's
# missing, and it never holds a key: release builds stay on GitHub's runners.
set -euo pipefail

RUNNER_USER=ghrunner
SDK=/home/$RUNNER_USER/android-sdk
# Command-line tools 20.0, the ones android-emulator-runner uses on GitHub's runners.
TOOLS_BUILD=14742923
TOOLS_SHA256=04453066b540409d975c676d781da1477479dde3761310f1a7eb92a1dfb15af7
# The same versions the job gets on GitHub's runners. The app's compileSdk picks
# the platform, and AGP downloads the build tools it wants on top of these.
PACKAGES=(
  platform-tools
  emulator
  "build-tools;37.0.0"
  "platforms;android-37.0"
  "ndk;27.3.13750724"
  "system-images;android-36;google_apis;x86_64"
)

echo "== packages the SDK tools need"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends --no-upgrade \
  openjdk-21-jre-headless unzip libx11-6

as_runner() { sudo -u "$RUNNER_USER" -H bash -c "cd; $1"; }

echo "== command-line tools $TOOLS_BUILD"
tools=$SDK/cmdline-tools/latest
as_runner "test -x '$tools/bin/sdkmanager' || {
  set -e
  work=\$(mktemp -d)
  trap 'rm -rf \"\$work\"' EXIT
  curl -fsSLo \"\$work/tools.zip\" https://dl.google.com/android/repository/commandlinetools-linux-${TOOLS_BUILD}_latest.zip
  echo '$TOOLS_SHA256  '\"\$work/tools.zip\" | sha256sum -c --quiet -
  unzip -q \"\$work/tools.zip\" -d \"\$work\"
  mkdir -p '$SDK/cmdline-tools'
  mv \"\$work/cmdline-tools\" '$tools'
}"

echo "== SDK packages"
as_runner "export ANDROID_HOME='$SDK'; yes 2>/dev/null | '$tools/bin/sdkmanager' --licenses >/dev/null || true"
for package in "${PACKAGES[@]}"; do
  echo "$package"
  as_runner "ANDROID_HOME='$SDK' '$tools/bin/sdkmanager' --install '$package' >/dev/null"
done

echo "== checks"
as_runner "du -sh '$SDK'; '$SDK/emulator/emulator' -version | head -n 1"
echo "The job also needs /dev/kvm. setup-linux-runner.sh gives its service the kvm group."
