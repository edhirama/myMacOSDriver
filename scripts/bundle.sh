#!/bin/bash
# Builds MacDriver.app, driverctl and drivertasks into ./build from the command line.
#
#   scripts/bundle.sh            # debug build
#   scripts/bundle.sh release    # optimized build
#
# Signing: see scripts/package_app.sh. From Xcode, use the "MacDriver (app)" scheme instead
# (install it with scripts/install_xcode_scheme.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product MacDriverHost
swift build -c "$CONFIG" --product driverctl
swift build -c "$CONFIG" --product drivertasks
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
scripts/package_app.sh "$BIN/MacDriverHost" "$BIN/driverctl"
cp "$BIN/drivertasks" build/drivertasks
echo "Run:   open build/MacDriver.app"
echo "Then:  build/driverctl status"
