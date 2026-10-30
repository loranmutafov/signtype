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
APP="build/SignType.app"

# Pick a signing identity. macOS ties Accessibility/Camera grants to the code signature, so an
# ad-hoc signature ("-") means re-granting after EVERY build. Any stable identity fixes that:
# an Apple Development certificate, or a free self-signed one named "SignType Dev"
# (Keychain Access ▸ Certificate Assistant ▸ Create a Certificate ▸ type: Code Signing).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  IDENTITY="$CODESIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(SignType Dev|Apple Development: [^"]+|Developer ID Application: [^"]+)"' \
    | head -1 | tr -d '"' || true)"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "⚠ No signing identity found: using ad-hoc signing. macOS will forget Accessibility"
    echo "  and Camera grants on every rebuild. Create a free one (takes a minute):"
    echo "  Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…"
    echo "  Name: SignType Dev · Identity Type: Self Signed Root · Certificate Type: Code Signing"
    echo "  Then rebuild; this script picks it up automatically."
  fi
fi

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
codesign -dv "$APP" 2>&1 | grep -E "^(Signature|Authority)=" | head -2 | sed 's/^/  /'

echo
echo "Built $APP  (build $STAMP)"
echo "Run it with:  open $APP"
echo "Live logs:    log stream --predicate 'subsystem == \"dev.loran.signtype\"' --level debug"
echo "Recent logs:  log show --last 3m --predicate 'subsystem == \"dev.loran.signtype\"' --level debug"
