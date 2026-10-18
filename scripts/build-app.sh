#!/bin/zsh
# Builds TheExplorer.app: release into build/, debug (CONFIG=debug) into build/debug/
# with a separate bundle identifier (com.gego.TheExplorer.debug).
#
# Signing: macOS keys privacy permissions (Full Disk Access, Desktop, Documents…) and
# Keychain access to the app's signature. Ad-hoc signatures change on every build, so
# permissions would reset each time. Without a Team ID, Keychain access is keyed to each
# build's hash, so the Keychain asks again after every build; an Apple Development
# certificate (free, from Xcode › Settings › Accounts) has one and avoids that. The script
# signs with SIGN_IDENTITY if set, otherwise with an Apple Development certificate, then the
# local "TheExplorer Local Signing" certificate, and only falls back to ad-hoc signing when
# none exists.
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
    # By its hash, which stays unambiguous if several certificates share a name.
    DEVELOPMENT_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / && !found { print $2; found = 1 }')"
    if [[ -n "$DEVELOPMENT_IDENTITY" ]]; then
        SIGN_IDENTITY="$DEVELOPMENT_IDENTITY"
    elif security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
        SIGN_IDENTITY="$LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="-"
        echo "warning: no signing certificate found; ad-hoc signing (permissions reset on every build)" >&2
    fi
fi

# SWIFT_FLAGS passes extra flags, e.g. SWIFT_FLAGS="-Xswiftc -O" for an optimized debug build
# when measuring performance with the debug scenes.
swift build -c "$CONFIG" ${=SWIFT_FLAGS:-}
BIN="$(swift build -c "$CONFIG" ${=SWIFT_FLAGS:-} --show-bin-path)/TheExplorer"

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
SIGNED_BY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !found { print $2; found = 1 }')"
echo "Built $APP (signed: ${SIGNED_BY:-ad-hoc})"
