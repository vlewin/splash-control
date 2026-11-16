import Foundation
import Testing

@testable import SplashControl

@Test("version parser handles plain semver and v-prefixed versions")
func testVersionParsing() {
  #expect(UpdateManager.parseVersionComponents("1.11.0") == [1, 11, 0])
  #expect(UpdateManager.parseVersionComponents("v1.11.0") == [1, 11, 0])
  #expect(UpdateManager.parseVersionComponents("v2.0.1-beta") == [2, 0, 1])
  #expect(UpdateManager.parseVersionComponents("dev") == [])
}

@Test("version comparison correctly identifies newer versions")
func testVersionComparison() {
  #expect(UpdateManager.isVersionNewer(candidate: "1.12.0", than: "1.11.0"))
  #expect(UpdateManager.isVersionNewer(candidate: "v1.11.1", than: "1.11.0"))
  #expect(UpdateManager.isVersionNewer(candidate: "2.0.0", than: "1.11.0"))
  #expect(!UpdateManager.isVersionNewer(candidate: "1.11.0", than: "1.11.0"))
  #expect(!UpdateManager.isVersionNewer(candidate: "1.10.9", than: "1.11.0"))
  #expect(!UpdateManager.isVersionNewer(candidate: "1.9.0", than: "1.11.0"))
  // Under dev or empty, any standard version is newer
  #expect(UpdateManager.isVersionNewer(candidate: "1.0.0", than: "dev"))
}

@Test("parse GitHub release JSON payload extracting zip and sha256 assets")
func testParseRelease() {
  let jsonString = """
  {
    "tag_name": "v1.12.0",
    "name": "Splash Control 1.12.0",
    "body": "Bug fixes and performance improvements",
    "html_url": "https://github.com/vlewin/splash-control/releases/tag/v1.12.0",
    "assets": [
      {
        "name": "SplashControl-v1.12.0.zip",
        "browser_download_url": "https://github.com/vlewin/splash-control/releases/download/v1.12.0/SplashControl-v1.12.0.zip"
      },
      {
        "name": "SplashControl-v1.12.0.zip.sha256",
        "browser_download_url": "https://github.com/vlewin/splash-control/releases/download/v1.12.0/SplashControl-v1.12.0.zip.sha256"
      }
    ]
  }
  """

  let release = UpdateManager.parseRelease(data: Data(jsonString.utf8))
  #expect(release != nil)
  #expect(release?.tagName == "v1.12.0")
  #expect(release?.version == "1.12.0")
  #expect(release?.name == "Splash Control 1.12.0")
  #expect(release?.body == "Bug fixes and performance improvements")
  #expect(release?.zipURL.absoluteString == "https://github.com/vlewin/splash-control/releases/download/v1.12.0/SplashControl-v1.12.0.zip")
  #expect(release?.sha256URL.absoluteString == "https://github.com/vlewin/splash-control/releases/download/v1.12.0/SplashControl-v1.12.0.zip.sha256")
}

@Test("cask install detection handles regular and Caskroom paths")
func testCaskDetection() {
  #expect(!UpdateManager.detectCaskInstall(bundlePath: "/Applications/Splash.app"))
  #expect(UpdateManager.detectCaskInstall(bundlePath: "/opt/homebrew/Caskroom/splash-control/1.11.0/Splash.app"))
}

@Test("installed-tag breaker never masks a newer release")
func testResolveUpdateState() {
  let release = UpdateManager.ReleaseInfo(
    tagName: "v1.18.0",
    version: "1.18.0",
    name: "Release v1.18.0",
    body: "",
    htmlURL: URL(string: "https://example.com/v1.18.0")!,
    zipURL: URL(string: "https://example.com/v1.18.0.zip")!,
    sha256URL: URL(string: "https://example.com/v1.18.0.zip.sha256")!
  )

  // The bug: a stale key must not hide a genuinely newer release.
  #expect(
    UpdateManager.resolve(candidate: release, current: "1.17.1", lastInstalledTag: "v1.18.0")
      == .updateAvailable(release))
  // The loop the breaker exists to stop: release already installed and running.
  #expect(
    UpdateManager.resolve(candidate: release, current: "1.18.0", lastInstalledTag: "v1.18.0")
      == .upToDate(currentVersion: "1.18.0"))
  // Same release, no key recorded (fresh install): version compare still wins.
  #expect(
    UpdateManager.resolve(candidate: release, current: "1.18.0", lastInstalledTag: nil)
      == .upToDate(currentVersion: "1.18.0"))
  // Local `git describe` build five commits past the tag: same base version.
  #expect(
    UpdateManager.resolve(
      candidate: release, current: "1.18.0-5-gabc1234", lastInstalledTag: "v1.18.0")
      == .upToDate(currentVersion: "1.18.0"))
  // Older release than what is running: never offer a downgrade.
  #expect(
    UpdateManager.resolve(candidate: release, current: "1.19.0", lastInstalledTag: nil)
      == .upToDate(currentVersion: "1.19.0"))
}
