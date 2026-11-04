#!/bin/sh
# Render the narrated, animated long showcase from the canonical screenshots.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_DIR="$REPO_ROOT/Video/hero-demo"
VENV_DIR="$PROJECT_DIR/.venv"
HYPERFRAMES_VERSION="0.7.42"
NARRATION_PROVIDER=${NARRATION_PROVIDER:-elevenlabs}
MASTER="$PROJECT_DIR/renders/lokalbot-hero-demo-master.mp4"
FINAL_TMP="$REPO_ROOT/web/assets/hero-demo-long.production.mp4"
FINAL="$REPO_ROOT/web/assets/hero-demo-long.mp4"
POSTER="$REPO_ROOT/web/assets/hero-poster-long.jpg"
MANIFEST="$REPO_ROOT/web/assets/hero-demo-long.manifest.json"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required to prepare the local narration environment" >&2
  exit 1
fi

if [ ! -x "$VENV_DIR/bin/python" ]; then
  uv venv --python 3.12 "$VENV_DIR"
fi
uv pip install --python "$VENV_DIR/bin/python" kokoro-onnx soundfile

mkdir -p "$PROJECT_DIR/assets" "$PROJECT_DIR/renders"
if [ ! -f "$PROJECT_DIR/assets/narration.wav" ] || [ "$PROJECT_DIR/script.txt" -nt "$PROJECT_DIR/assets/narration.wav" ]; then
  case "$NARRATION_PROVIDER" in
    elevenlabs)
      if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
        echo "error: ELEVENLABS_API_KEY is required to regenerate the Bella narration" >&2
        exit 1
      fi
      "$VENV_DIR/bin/python" "$PROJECT_DIR/generate_elevenlabs_narration.py"
      ;;
    kokoro)
      PATH="$VENV_DIR/bin:$PATH" VIRTUAL_ENV="$VENV_DIR" \
        npx --yes "hyperframes@$HYPERFRAMES_VERSION" tts "$PROJECT_DIR/script.txt" \
          --voice af_nova --speed 1.00 --output "$PROJECT_DIR/assets/narration.wav"
      ;;
    *)
      echo "error: unsupported NARRATION_PROVIDER=$NARRATION_PROVIDER" >&2
      exit 1
      ;;
  esac
fi

"$PROJECT_DIR/prepare_assets.sh"

(
  cd "$PROJECT_DIR"
  npm run check
  npx --yes "hyperframes@$HYPERFRAMES_VERSION" render \
    --output "$MASTER" --fps 30 --quality high --strict
)

ffmpeg -y -v error -i "$MASTER" \
  -filter:a 'loudnorm=I=-16:TP=-1.5:LRA=7' \
  -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.2 -pix_fmt yuv420p \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$FINAL_TMP"
mv "$FINAL_TMP" "$FINAL"

ffmpeg -y -v error -ss 4.80 -i "$FINAL" -frames:v 1 -q:v 2 -pix_fmt yuvj444p "$POSTER"
"$VENV_DIR/bin/python" "$PROJECT_DIR/write_manifest.py" "$FINAL" "$MANIFEST"

echo "Rendered $FINAL"
echo "Poster   $POSTER"
echo "Manifest $MANIFEST"
