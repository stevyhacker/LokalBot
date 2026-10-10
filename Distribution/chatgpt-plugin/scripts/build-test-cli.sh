#!/bin/bash
# Build the actual CLI target without the app, its model runtimes, or signing.
# Sources and the ArgumentParser pin come from the repository's source of truth.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
BUILD_ROOT="$PLUGIN_ROOT/.test-cli"
CLI_CONFIGURATION="${LOKALBOT_CLI_CONFIGURATION:-Debug}"
case "$CLI_CONFIGURATION" in Debug|Release) ;; *) exit 2 ;; esac
mkdir -p "$BUILD_ROOT"
ruby -rjson -ryaml - "$REPO_ROOT" "$BUILD_ROOT" <<'RUBY'
root, output = ARGV
project = YAML.load_file(File.join(root, 'project.yml'))
target = project.fetch('targets').fetch('lokalbot-cli')
target['sources'] = target.fetch('sources').map do |source|
  source = { 'path' => source } if source.is_a?(String)
  source.merge('path' => File.join(root, source.fetch('path')))
end
pin = JSON.parse(File.read(File.join(root, 'LokalBot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))).fetch('pins')
  .find { |item| item.fetch('identity') == 'swift-argument-parser' }
spec = {
  'name' => 'LokalBotCLIProbe',
  'packages' => { 'ArgumentParser' => {
    'url' => pin.fetch('location'), 'revision' => pin.fetch('state').fetch('revision')
  } },
  'targets' => { 'lokalbot-cli' => target },
  'schemes' => { 'CLI' => { 'build' => { 'targets' => { 'lokalbot-cli' => 'all' } } } }
}
File.write(File.join(output, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$BUILD_ROOT/project.json" --project "$BUILD_ROOT"
xcodebuild -quiet -project "$BUILD_ROOT/LokalBotCLIProbe.xcodeproj" \
  -scheme CLI -configuration "$CLI_CONFIGURATION" -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_ROOT/DerivedData" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
printf '%s\n' "Test helper: $BUILD_ROOT/DerivedData/Build/Products/$CLI_CONFIGURATION/lokalbot-cli"
