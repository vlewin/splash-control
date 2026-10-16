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

# If a version is passed (e.g. from CI release or make-app.sh 1.12.0), stamp Info.plist
if [ -n "${1:-}" ]; then
  VERSION="${1#v}"
  BUILD="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
  echo "Stamped Info.plist with version $VERSION (build $BUILD)"
fi

if [ ! -f Resources/AppIcon.icns ]; then bash Scripts/make-icon.sh; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.png ]; then cp Resources/AppIcon.png "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"

echo "Built $APP"
