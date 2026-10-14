#!/bin/zsh
# Builds TheExplorer.app into ./build.
# Set SIGN_IDENTITY to a code signing identity to keep privacy permissions
# (like Full Disk Access) across rebuilds; ad-hoc signatures change every build.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/TheExplorer.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TheExplorer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TheExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
