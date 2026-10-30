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

# Stamp the build so the menu bar can show which binary is actually running.
HASH="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
STAMP="$HASH $(date '+%H:%M')"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STAMP" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $STAMP" "$APP/Contents/Info.plist"

# `open` would just re-activate an already-running copy, so quit it first.
if pgrep -x SignType >/dev/null; then
  echo "▸ quitting running SignType"
  osascript -e 'tell application "SignType" to quit' >/dev/null 2>&1 || pkill -x SignType || true
  sleep 1
fi

echo "▸ codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo
echo "Built $APP  (build $STAMP)"
echo "Run it with:  open $APP"
echo "Live logs:    log stream --predicate 'subsystem == \"dev.loran.signtype\"' --level debug"
echo "Recent logs:  log show --last 3m --predicate 'subsystem == \"dev.loran.signtype\"' --level debug"
