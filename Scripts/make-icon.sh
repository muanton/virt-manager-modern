#!/bin/zsh
# Renders the master icon and assembles Resources/AppIcon.icns.
set -euo pipefail
cd "${0:A:h:h}"
tmp=$(mktemp -d)
swift Scripts/make-icon.swift "$tmp/icon_1024.png"
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon_1024.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$tmp/icon_1024.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
rm -rf "$tmp"
echo "wrote Resources/AppIcon.icns"
