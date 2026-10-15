#!/bin/zsh
# Builds TheExplorer.app: release into build/, debug (CONFIG=debug) into build/debug/
# with a separate bundle identifier (com.gego.TheExplorer.debug).
#
# Signing: macOS keys privacy permissions (Full Disk Access, Desktop, Documents…) to the
# app's signature. Ad-hoc signatures change on every build, so permissions would reset each
# time. The script signs with SIGN_IDENTITY if set, otherwise with the local
# "TheExplorer Local Signing" certificate if it's in the keychain, and only falls back to
# ad-hoc signing when neither exists.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
LOCAL_IDENTITY="TheExplorer Local Signing"

if [[ "$CONFIG" == "release" ]]; then
    APP="build/TheExplorer.app"
else
    APP="build/$CONFIG/TheExplorer.app"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
        echo "warning: no signing certificate found; ad-hoc signing (permissions reset on every build)" >&2
    fi
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TheExplorer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TheExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$CONFIG" != "release" ]]; then
    # Debug builds get their own identity, so test runs never touch the installed app's settings,
    # saved tabs or privacy permissions.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gego.TheExplorer.debug" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName TheExplorer Debug" "$APP/Contents/Info.plist"
fi
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed: $([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
