#!/bin/sh
# Render and atomically promote the canonical 16:9, 30-second product promo.
# Run only after the HyperFrames Studio preview has been reviewed.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_DIR="$REPO_ROOT/Video/lokalbot-promo"
MASTER="$PROJECT_DIR/renders/video.mp4"
FINAL_TMP="$REPO_ROOT/web/assets/hero-demo.production.mp4"
FINAL="$REPO_ROOT/web/assets/hero-demo.mp4"
POSTER_TMP="$REPO_ROOT/web/assets/hero-poster.production.jpg"
POSTER="$REPO_ROOT/web/assets/hero-poster.jpg"
MODE=${1:-}

case "$MODE" in
  ""|--postprocess-only) ;;
  *)
    echo "usage: $0 [--postprocess-only]" >&2
    exit 2
    ;;
esac

for command in ffmpeg ffprobe jq shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: $command is required" >&2
    exit 1
  fi
done

HYPERFRAMES_VERSION=$(jq -r '
  [.scripts.check, .scripts.render]
  | map(capture("hyperframes@(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)").version)
  | unique
  | if length == 1 then .[0] else empty end
' "$PROJECT_DIR/package.json")
if [ -z "$HYPERFRAMES_VERSION" ]; then
  echo "error: HyperFrames check and render scripts must use one exact version" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/renders" "$REPO_ROOT/web/assets"

if [ "$MODE" != "--postprocess-only" ]; then
  for asset in \
    assets/bgm/track.wav \
    assets/voice/01.wav \
    assets/voice/02.wav \
    assets/voice/03.wav \
    assets/voice/04.wav \
    assets/voice/05.wav \
    assets/voice/06.wav; do
    if [ ! -s "$PROJECT_DIR/$asset" ]; then
      echo "error: missing generated promo asset: $PROJECT_DIR/$asset" >&2
      echo "prepare the local media assets and preview the project before rendering" >&2
      exit 1
    fi
  done

  for caption_asset in caption_groups.json compositions/captions.html; do
    if grep -qi 'localbot\.com' "$PROJECT_DIR/$caption_asset"; then
      echo "error: incorrect CTA domain in $PROJECT_DIR/$caption_asset" >&2
      echo "replace localbot.com with lokalbot.com before rendering" >&2
      exit 1
    fi
  done

  (
    cd "$PROJECT_DIR"
    npm run check
    npm run render -- \
      --skill=product-launch-video \
      --output "$MASTER" --fps 30 --quality high --strict
  )
fi

if [ ! -s "$MASTER" ]; then
  echo "error: missing rendered master: $MASTER" >&2
  exit 1
fi

# Measure first, then apply a linear second pass. A single loudnorm pass can
# miss both integrated loudness and true-peak targets on a short, dynamic mix.
LOUDNESS_LOG=$(mktemp "${TMPDIR:-/tmp}/lokalbot-loudnorm.XXXXXX")
trap 'rm -f "$LOUDNESS_LOG"' EXIT HUP INT TERM

ffmpeg -hide_banner -nostats -v info -i "$MASTER" -map 0:a:0 \
  -af 'loudnorm=I=-16:TP=-1.5:LRA=7:print_format=json' \
  -f null - 2> "$LOUDNESS_LOG"

MEASURED_I=$(sed -n '/^{/,/^}/p' "$LOUDNESS_LOG" | jq -r '.input_i')
MEASURED_TP=$(sed -n '/^{/,/^}/p' "$LOUDNESS_LOG" | jq -r '.input_tp')
MEASURED_LRA=$(sed -n '/^{/,/^}/p' "$LOUDNESS_LOG" | jq -r '.input_lra')
MEASURED_THRESH=$(sed -n '/^{/,/^}/p' "$LOUDNESS_LOG" | jq -r '.input_thresh')
TARGET_OFFSET=$(sed -n '/^{/,/^}/p' "$LOUDNESS_LOG" | jq -r '.target_offset')

for measurement in \
  "$MEASURED_I" \
  "$MEASURED_TP" \
  "$MEASURED_LRA" \
  "$MEASURED_THRESH" \
  "$TARGET_OFFSET"; do
  if [ -z "$measurement" ] || [ "$measurement" = "null" ]; then
    echo "error: unable to parse loudnorm analysis" >&2
    exit 1
  fi
done

LOUDNORM_FILTER="loudnorm=I=-16:TP=-1.5:LRA=7:measured_I=$MEASURED_I:measured_TP=$MEASURED_TP:measured_LRA=$MEASURED_LRA:measured_thresh=$MEASURED_THRESH:offset=$TARGET_OFFSET:linear=true:print_format=summary"

ffmpeg -y -v error -i "$MASTER" -map 0:v:0 -map 0:a:0 \
  -filter:a "$LOUDNORM_FILTER" \
  -c:v libx264 -preset slow -crf 19 -profile:v high -level 4.2 \
  -pix_fmt yuv420p -colorspace bt709 -color_primaries bt709 \
  -color_trc bt709 -color_range tv \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$FINAL_TMP"
mv "$FINAL_TMP" "$FINAL"

# The complete cited-answer frame reads clearly before playback and at social-card size.
ffmpeg -y -v error -ss 10.8 -i "$FINAL" -frames:v 1 \
  -q:v 2 -pix_fmt yuvj444p "$POSTER_TMP"
mv "$POSTER_TMP" "$POSTER"

write_manifest() {
  output=$1
  manifest=$2
  output_name=$(basename "$output")
  sha256=$(shasum -a 256 "$output" | awk '{print $1}')
  duration=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$output")
  bytes=$(stat -f %z "$output")
  temp="$manifest.production"

  jq -n \
    --arg output "$output_name" \
    --arg sha256 "$sha256" \
    --arg duration "$duration" \
    --arg engine_version "$HYPERFRAMES_VERSION" \
    --argjson bytes "$bytes" \
    '{
      version: 2,
      output: $output,
      sha256: $sha256,
      production: {
        engine: "HyperFrames",
        engineVersion: $engine_version,
        source: "Video/lokalbot-promo/index.html",
        canvas: [1920, 1080],
        fps: 30,
        durationSeconds: ($duration | tonumber)
      },
      audio: {
        narration: {engine: "Kokoro-82M", voice: "am_michael", local: true},
        music: "local production bed",
        effects: "scene-aligned local sound design",
        deliveryLoudness: {integratedTargetLufs: -16, truePeakTargetDbtp: -1.5}
      },
      captions: {language: "en", burnedIn: true, source: "local narration timings"},
      scenes: [
        {id: "pop-quiz", start: 0, end: 3.904},
        {id: "cited-recall", start: 3.904, end: 11.008},
        {id: "bot-free-capture", start: 11.008, end: 14.976},
        {id: "dictation-and-autocomplete", start: 14.976, end: 20.288},
        {id: "scoped-network-check", start: 20.288, end: 26.325},
        {id: "cta", start: 26.325, end: 29.973}
      ],
      delivery: {bytes: $bytes}
    }' > "$temp"
  mv "$temp" "$manifest"
}

write_manifest "$FINAL" "$REPO_ROOT/web/assets/hero-demo.manifest.json"

# Keep the previous public aliases aligned with the canonical website cut.
for alias in hero-demo-short feature-demo; do
  alias_tmp="$REPO_ROOT/web/assets/$alias.production.mp4"
  alias_final="$REPO_ROOT/web/assets/$alias.mp4"
  cp "$FINAL" "$alias_tmp"
  mv "$alias_tmp" "$alias_final"
done

cp "$POSTER" "$REPO_ROOT/web/assets/hero-poster-short.production.jpg"
mv "$REPO_ROOT/web/assets/hero-poster-short.production.jpg" \
  "$REPO_ROOT/web/assets/hero-poster-short.jpg"
write_manifest "$REPO_ROOT/web/assets/hero-demo-short.mp4" \
  "$REPO_ROOT/web/assets/hero-demo-short.manifest.json"

echo "Rendered  $FINAL"
echo "Poster    $POSTER"
echo "Manifest  $REPO_ROOT/web/assets/hero-demo.manifest.json"
echo "Aliases   web/assets/hero-demo-short.mp4, web/assets/feature-demo.mp4"
