#!/bin/zsh
# Builds PortBar with xcodebuild and wraps it in build/PortBar.app (no sandbox, LSUIElement=YES).
#
#   ./build.sh           build build/PortBar.app (Release)
#   ./build.sh Debug     build a Debug build instead
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${1:-Release}"
mkdir -p build
LOG=build/xcodebuild.log
if ! xcodebuild -scheme PortBar -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath build/DerivedData build > "$LOG" 2>&1; then
  grep -E '\.swift:[0-9]+:[0-9]+: error' "$LOG" | sort -u || true
  echo "BUILD FAILED (full log: $LOG)"; exit 1
fi
# Always show warnings; never hide them behind a truncated tail.
grep -E '\.swift:[0-9]+:[0-9]+: warning' "$LOG" | sort -u || true
echo "BUILD SUCCEEDED"

BIN="build/DerivedData/Build/Products/$CONFIG/PortBar"
APP="build/PortBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PortBar"
# SwiftPM stamps the binary with SDK 13.0 (its deployment target), and macOS decides between the
# current system look (Liquid Glass, large traffic lights, current corner radii) and the legacy one
# from the SDK a binary was linked against. Re-stamp it with the real SDK; the deployment target
# (minos) stays 13.0.
SDKVER="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos 13.0 "$SDKVER" -replace \
  -output "$APP/Contents/MacOS/PortBar" "$APP/Contents/MacOS/PortBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# --- App icon -------------------------------------------------------------------------------
# Resources/AppIcon.icon is an Icon Composer document. actool compiles it into Assets.car (the
# layered icon macOS 26+ uses, with its dark and tinted variants). actool's own fallback .icns
# lacks the large sizes, so build a complete one by rendering every standard size with
# Icon Composer's renderer.
RES="$APP/Contents/Resources"; mkdir -p "$RES"
xcrun actool Resources/AppIcon.icon --compile "$RES" --platform macosx --target-device mac \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist build/icon-info.plist >/dev/null
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px=${spec%%:*}; name=${spec#*:}
  "$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$SET/$name.png" --platform macOS \
    --rendition Default --width $px --height $px --scale 1 --design-generation 27 >/dev/null
done
iconutil --convert icns "$SET" -o "$RES/AppIcon.icns"
# Ad-hoc sign with NO entitlements file => App Sandbox stays off.
codesign --force --sign - "$APP"
echo "Built $APP"
