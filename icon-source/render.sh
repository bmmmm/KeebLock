#!/usr/bin/env bash
# Rasterize an AppIcon SVG into all sizes the macOS AppIcon.appiconset expects.
#
# Usage:
#   ./render.sh                # default (Day) → AppIcon.svg
#   ./render.sh dark           # Sleepy night
#   ./render.sh bath           # Bubble bath with rubber duck
#   ./render.sh sakura         # Hanami / cherry blossom
#   ./render.sh coffee         # Coffee rescue
#
# Edit any AppIcon-*.svg, then run this script with the matching variant
# name to push it into Assets.xcassets/AppIcon.appiconset/.
# Requires: inkscape (brew install inkscape).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEST="$ROOT/KeebLock/Assets.xcassets/AppIcon.appiconset"

VARIANT="${1:-day}"
case "$VARIANT" in
  day|"")    SRC="$HERE/AppIcon.svg" ;;
  dark)      SRC="$HERE/AppIcon-Dark.svg" ;;
  bath)      SRC="$HERE/AppIcon-Bath.svg" ;;
  sakura)    SRC="$HERE/AppIcon-Sakura.svg" ;;
  coffee)    SRC="$HERE/AppIcon-Coffee.svg" ;;
  *)
    echo "error: unknown variant '$VARIANT'" >&2
    echo "valid: day | dark | bath | sakura | coffee" >&2
    exit 2
    ;;
esac

if ! command -v inkscape >/dev/null 2>&1; then
  echo "error: inkscape not found — brew install inkscape" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "error: $SRC not found" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Rendering variant '$VARIANT' from $(basename "$SRC")..."
for size in 16 32 64 128 256 512 1024; do
  inkscape "$SRC" \
    --export-type=png \
    --export-filename="$TMP/icon_${size}.png" \
    -w "$size" -h "$size" 2>/dev/null
done

echo "Copying into $DEST"
cp "$TMP/icon_16.png"   "$DEST/icon_16x16.png"
cp "$TMP/icon_32.png"   "$DEST/icon_16x16@2x.png"
cp "$TMP/icon_32.png"   "$DEST/icon_32x32.png"
cp "$TMP/icon_64.png"   "$DEST/icon_32x32@2x.png"
cp "$TMP/icon_128.png"  "$DEST/icon_128x128.png"
cp "$TMP/icon_256.png"  "$DEST/icon_128x128@2x.png"
cp "$TMP/icon_256.png"  "$DEST/icon_256x256.png"
cp "$TMP/icon_512.png"  "$DEST/icon_256x256@2x.png"
cp "$TMP/icon_512.png"  "$DEST/icon_512x512.png"
cp "$TMP/icon_1024.png" "$DEST/icon_512x512@2x.png"

echo "Done. Rebuild the app to pick up '$VARIANT'."
