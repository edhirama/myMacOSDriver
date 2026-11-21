#!/bin/bash
# Builds the test fixture app into build/DriverFixture.app (see Sources/DriverFixture).
#
#   scripts/package_fixture.sh
#
# It needs no permissions, so an ad-hoc signature is enough.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product DriverFixture
APP="$ROOT/build/DriverFixture.app"
pkill -f "$APP/Contents/MacOS/DriverFixture" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build --show-bin-path)/DriverFixture" "$APP/Contents/MacOS/DriverFixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.macdriver.fixture</string>
  <key>CFBundleName</key><string>DriverFixture</string>
  <key>CFBundleExecutable</key><string>DriverFixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.macdriver.fixture "$APP"
echo "Packaged $APP"
