#!/usr/bin/env bash
# Build the release binary and assemble dist/Splash.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/Splash.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SplashControl "$APP/Contents/MacOS/SplashControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then bash Scripts/make-icon.sh; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.png ]; then cp Resources/AppIcon.png "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"

echo "Built $APP"
