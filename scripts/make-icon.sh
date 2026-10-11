#!/bin/bash
# Generates the .icns with built-in tools only (swift, sips, iconutil). Usage: scripts/make-icon.sh out.icns
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

swift scripts/make-icon.swift "$WORK/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "Icon written to $OUT"
