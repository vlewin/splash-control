#!/usr/bin/env bash
# Render a Homebrew cask for Splash Control from release artifacts.
#
# Usage (CI):  Scripts/render-cask.sh <tag> <sha256>
#   tag    — the release tag with its "v" prefix (e.g. v1.4.0). The cask's
#            version strips it (v1.4.0 -> 1.4.0); the release zip keeps it.
#   sha256 — the SHA-256 of dist/SplashControl-<tag>.zip
#
# Usage (local review):  Scripts/render-cask.sh test
#   Writes dist/SplashControl-v0.0.0.cask with a placeholder sha256.
#
set -euo pipefail

REPO="vlewin/splash-control"

if [[ "${1:-}" == "test" ]]; then
    TAG="v0.0.0"
    SHA256="0000000000000000000000000000000000000000000000000000000000000000"
else
    TAG="${1:?Usage: render-cask.sh <tag> <sha256>}"
    SHA256="${2:?Usage: render-cask.sh <tag> <sha256>}"
fi

# Cask version without the tag prefix; the zip filename in the URL keeps it.
VERSION="${TAG#v}"

mkdir -p dist

cat > "dist/SplashControl-${TAG}.cask" <<EOF
cask "splash-control" do
  version "${VERSION}"
  sha256 "${SHA256}"

  name "Splash Control"
  desc "Menu bar controller for the splash LLM server"
  homepage "https://github.com/${REPO}"

  url "https://github.com/${REPO}/releases/download/v#{version}/SplashControl-v#{version}.zip"

  auto_updates true

  depends_on arch: :arm64
  # 26.4 floor per Resources/Info.plist; brew symbols are major-series only.
  depends_on macos: :tahoe
  depends_on formula: "incoai/tap/splash"

  app "Splash.app"

  # App state only. Never touch the engine's trees:
  # Application Support/Splash (models) and Caches/Splash (prefix/weights cache).
  uninstall delete: [
      "~/Library/Application Support/SplashControl",
      "~/Library/Saved Application State/com.vlewin.splash-control.savedState",
  ]

  zap trash: [
      "~/Library/Logs/SplashControl",
  ]

  caveats <<~CAVEATS
    Splash Control is ad-hoc signed and not notarized. macOS will block the
    first open; dismiss it via:

      System Settings -> Privacy & Security -> "Open Anyway"

    If you had "Start at login" enabled, also remove the login item in
    System Settings -> General -> Login Items after uninstalling.
  CAVEATS
end
EOF

echo "Rendered cask: dist/SplashControl-${TAG}.cask"
