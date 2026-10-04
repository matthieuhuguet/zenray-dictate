#!/bin/bash
set -euo pipefail

SRC_SVG="${1:-AppIcon.svg}"
OUTPUT_ICNS="${2:-AppIcon.icns}"

if [[ ! -f "$SRC_SVG" ]]; then
    echo "Source SVG not found: $SRC_SVG"
    exit 1
fi

TMP_ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$TMP_ICONSET"

echo "Generating iconset from $SRC_SVG..."
rsvg-convert -w 16 -h 16 "$SRC_SVG" -o "$TMP_ICONSET/icon_16x16.png"
rsvg-convert -w 32 -h 32 "$SRC_SVG" -o "$TMP_ICONSET/icon_16x16@2x.png"
rsvg-convert -w 32 -h 32 "$SRC_SVG" -o "$TMP_ICONSET/icon_32x32.png"
rsvg-convert -w 64 -h 64 "$SRC_SVG" -o "$TMP_ICONSET/icon_32x32@2x.png"
rsvg-convert -w 128 -h 128 "$SRC_SVG" -o "$TMP_ICONSET/icon_128x128.png"
rsvg-convert -w 256 -h 256 "$SRC_SVG" -o "$TMP_ICONSET/icon_128x128@2x.png"
rsvg-convert -w 256 -h 256 "$SRC_SVG" -o "$TMP_ICONSET/icon_256x256.png"
rsvg-convert -w 512 -h 512 "$SRC_SVG" -o "$TMP_ICONSET/icon_256x256@2x.png"
rsvg-convert -w 512 -h 512 "$SRC_SVG" -o "$TMP_ICONSET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$SRC_SVG" -o "$TMP_ICONSET/icon_512x512@2x.png"

echo "Compiling $OUTPUT_ICNS with iconutil..."
iconutil -c icns "$TMP_ICONSET" -o "$OUTPUT_ICNS"

rm -rf "$(dirname "$TMP_ICONSET")"
echo "Successfully generated $OUTPUT_ICNS ($(ls -lh "$OUTPUT_ICNS" | awk '{print $5}'))"
