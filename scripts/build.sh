#!/usr/bin/env bash
# Builds SignType.app from the Swift package and ad-hoc signs it.
#
#   scripts/build.sh            # release build → build/SignType.app
#   CONFIG=debug scripts/build.sh
#   CODESIGN_IDENTITY="Apple Development: You (TEAMID)" scripts/build.sh
#
# Using a real signing identity keeps your Camera / Accessibility / Input Monitoring
# grants across rebuilds. With ad-hoc signing ("-") macOS treats every build as a
# new app and asks again.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/SignType.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SignType"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SignType"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo
echo "Built $APP"
echo "Run it with:  open $APP"
echo "Logs:         log stream --predicate 'process == \"SignType\"' --level info"
