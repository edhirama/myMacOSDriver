#!/bin/bash
# Wraps a built MacDriverHost executable into build/MacDriver.app and signs it.
#
#   scripts/package_app.sh <path/to/MacDriverHost> [path/to/driverctl]
#
# Used by scripts/bundle.sh (command-line builds) and by the Xcode "MacDriver (app)" scheme's
# post-build action, so both produce the same bundle identity: dev.macdriver.host signed with the
# local "MacDriver Dev" certificate when present. macOS attaches Accessibility and Screen
# Recording grants to that identity, so they survive rebuilds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="$1"
CTL_BIN="${2:-}"
APP="$ROOT/build/MacDriver.app"

[ -f "$HOST_BIN" ] || { echo "error: no executable at $HOST_BIN" >&2; exit 1; }

# Replacing the executable of a running app can crash it; quit it gracefully first (its
# shutdown returns windows from the virtual display).
if pgrep -f "$APP/Contents/MacOS/MacDriverHost" >/dev/null; then
  osascript -e 'tell application id "dev.macdriver.host" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "$APP/Contents/MacOS/MacDriverHost" >/dev/null || break; sleep 0.1; done
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HOST_BIN" "$APP/Contents/MacOS/MacDriverHost"
[ -n "$CTL_BIN" ] && [ -f "$CTL_BIN" ] && cp "$CTL_BIN" "$ROOT/build/driverctl"

IDENTITY="${MACDRIVER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"MacDriver Dev"/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier dev.macdriver.host "$APP"
[ -f "$ROOT/build/driverctl" ] && codesign --force --sign "$IDENTITY" "$ROOT/build/driverctl"
if [ "$IDENTITY" = "-" ]; then
  echo "warning: signed ad-hoc; macOS permission grants will reset on every build (create a 'MacDriver Dev' code-signing certificate)"
fi
echo "Packaged $APP (signed with: $IDENTITY)"
