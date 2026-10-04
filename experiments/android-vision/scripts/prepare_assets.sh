#!/usr/bin/env bash
# Fetch + verify MediaPipe models and build the photo set, then stage both as assets of the
# `all` flavour (VisionEval/app/src/all/assets, git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$HERE/models"
ASSETS="$HERE/VisionEval/app/src/all/assets"

tail -n +2 "$MODELS/MODELS.csv" | while IFS=, read -r file url sha _rest; do
  if [[ ! -f "$MODELS/$file" ]]; then curl -sSfL -o "$MODELS/$file" "$url"; fi
  actual="$(shasum -a 256 "$MODELS/$file" | cut -d' ' -f1)"
  [[ "$actual" == "$sha" ]] || { echo "sha256 mismatch for $file: $actual" >&2; exit 1; }
done

[[ -x "$HERE/.venv/bin/python" ]] || { python3 -m venv "$HERE/.venv" && "$HERE/.venv/bin/pip" install -q pillow numpy; }
"$HERE/.venv/bin/python" "$HERE/scripts/make_test_set.py"

rm -rf "$ASSETS" && mkdir -p "$ASSETS/models" "$ASSETS/photos"
cp "$MODELS"/*.tflite "$MODELS"/*.task "$ASSETS/models/"
cp "$HERE/work/photos/"*.jpg "$ASSETS/photos/"
echo "assets staged: $(ls "$ASSETS/photos" | wc -l | tr -d ' ') photos, $(ls "$ASSETS/models" | wc -l | tr -d ' ') models"
