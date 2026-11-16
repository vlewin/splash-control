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

# The version is written here and nowhere else: CI passes the minted tag, a
# local build reports `git describe` (e.g. 1.18.0-5-gabc) so it can never
# masquerade as a shipped release. The repo plist holds a placeholder only.
VERSION="${1#v}"
if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --always 2>/dev/null | sed 's/^v//' || true)"
  [ -n "$VERSION" ] || VERSION="0.0.0-dev"
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
echo "Stamped Info.plist with version $VERSION (build $BUILD)"

if [ ! -f Resources/AppIcon.icns ]; then bash Scripts/make-icon.sh; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.png ]; then cp Resources/AppIcon.png "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"

echo "Built $APP"
