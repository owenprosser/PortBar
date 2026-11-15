#!/bin/zsh
# Rebuilds the hero icon end to end: compile the renderer, render every layer, assemble both .icon
# documents and export previews with Icon Composer's own renderer (ictool).
#   ./make.sh            (override the look with env vars, e.g. KEY=1.3 SHEEN=2 ./make.sh)
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
OUT=..; TMP=$(mktemp -d)

swiftc -swift-version 5 -O render.swift -o "$TMP/render"
SAMPLES=${SAMPLES:-4}
"$TMP/render" "$TMP/full" 1024 $SAMPLES                    >/dev/null    # everything
LAYERMAX=0 "$TMP/render" "$TMP/top" 1024 $SAMPLES          >/dev/null    # top unit only
LAYERMAX=1 "$TMP/render" "$TMP/mid" 1024 $SAMPLES          >/dev/null    # top + middle

mkdir -p $OUT/layers $OUT/layers-split $OUT/preview
for f in object shadow glow streaks backlight vignette; do cp "$TMP/full/$f.png" $OUT/layers/$f.png; done
cp "$TMP/top/object.png"  $OUT/layers-split/unit-1-top.png
cp "$TMP/mid/object.png"  $OUT/layers-split/unit-2-middle.png
cp "$TMP/full/object.png" $OUT/layers-split/unit-3-bottom.png

python3 build_icon.py "$TMP/full" $OUT/PortBar.icon
python3 build_icon.py "$TMP/full" $OUT/PortBar-split.icon --split "$TMP/top" "$TMP/mid" --group-shadow 0.30

for n in PortBar PortBar-split; do
  "$IC" $OUT/$n.icon --export-image --output-file $OUT/preview/$n.png        --platform macOS --rendition Default    --width 1024 --height 1024 --scale 1 --design-generation 27 >/dev/null
  "$IC" $OUT/$n.icon --export-image --output-file $OUT/preview/$n-dark.png   --platform macOS --rendition Dark       --width 1024 --height 1024 --scale 1 --design-generation 27 >/dev/null
  "$IC" $OUT/$n.icon --export-image --output-file $OUT/preview/$n-tinted.png --platform macOS --rendition TintedDark --width 1024 --height 1024 --scale 1 --tint-color 0.6 --tint-strength 0.7 --design-generation 27 >/dev/null
done
rm -rf "$TMP"; echo "done: $(cd $OUT && pwd)"
