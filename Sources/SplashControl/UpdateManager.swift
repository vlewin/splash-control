import AppKit
import CryptoKit
import Foundation

/// Update check and installation manager for Splash Control.
///
/// Communicates with GitHub Releases API for `vlewin/splash-control` to check for updates,
/// download release zip assets and SHA256 checksums, verify cryptographic integrity,
/// and perform an in-place atomic application swap without external dependencies.
@MainActor
final class UpdateManager: ObservableObject {
  static let shared = UpdateManager()

  static let repo = "vlewin/splash-control"

  struct ReleaseInfo: Equatable {
    let tagName: String
    let version: String
    let name: String
    let body: String
    let htmlURL: URL
    let zipURL: URL
    let sha256URL: URL
  }

  enum State: Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(ReleaseInfo)
    case downloading(progress: Double)
    case readyToRestart(ReleaseInfo)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var isInstalledViaCask: Bool = false

  private var downloadTask: Task<Void, Never>?

  init() {
    isInstalledViaCask = Self.detectCaskInstall()
  }

  /// Detects whether the running bundle was installed via Homebrew Cask.
  nonisolated static func detectCaskInstall(bundlePath: String = Bundle.main.bundlePath) -> Bool {
    let homebrewCaskDir = "/opt/homebrew/Caskroom/splash-control"
    let intelCaskDir = "/usr/local/Caskroom/splash-control"
    if FileManager.default.fileExists(atPath: homebrewCaskDir)
      || FileManager.default.fileExists(atPath: intelCaskDir)
    {
      return true
    }
    // Check if the bundle or its contents resolve to a Homebrew path
    let resolved = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
    return resolved.contains("/Caskroom/splash-control/")
  }

  /// Parses semantic version string ("1.11.0" or "v1.11.0") into [Int].
  nonisolated static func parseVersionComponents(_ string: String) -> [Int] {
    let clean = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
    let parts = clean.split(separator: "-").first ?? ""
    return parts.split(separator: ".").compactMap { Int($0) }
  }

  /// Compares two semver strings. Returns true if candidate is newer than current.
  nonisolated static func isVersionNewer(candidate: String, than current: String) -> Bool {
    let c = parseVersionComponents(candidate)
    let cur = parseVersionComponents(current)
    let count = max(c.count, cur.count)
    for i in 0..<count {
      let cVal = i < c.count ? c[i] : 0
      let curVal = i < cur.count ? cur[i] : 0
      if cVal > curVal { return true }
      if cVal < curVal { return false }
    }
    return false
  }

  /// Checks for available updates from GitHub Releases API.
  func checkForUpdates(silent: Bool = false) async {
    if case .downloading = state { return }
    if !silent {
      state = .checking
    }

    guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
      state = .failed("Invalid release API URL")
      return
    }

    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("SplashControl/\(SplashLog.version)", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        state = .failed("GitHub API returned status \(code)")
        return
      }

      guard let release = Self.parseRelease(data: data) else {
        state = .failed("Release payload missing required assets")
        return
      }

      let current = SplashLog.version
      let lastInstalledTag = UserDefaults.standard.string(forKey: "LastInstalledReleaseTag")
      if release.tagName == lastInstalledTag {
        // Circuit breaker: This exact release was already installed on this machine
        state = .upToDate(currentVersion: release.version)
        SplashLog.shared.log("updater up_to_date_circuit_breaker tag=\(release.tagName)")
      } else if Self.isVersionNewer(candidate: release.version, than: current) {
        state = .updateAvailable(release)
        SplashLog.shared.log(
          "updater update_available version=\(release.version) current=\(current)")
      } else {
        state = .upToDate(currentVersion: current)
        SplashLog.shared.log("updater up_to_date version=\(current)")
      }
    } catch {
      state = .failed(error.localizedDescription)
      SplashLog.shared.log("updater check_failed error=\(error)")
    }
  }

  /// Parses GitHub release JSON data into `ReleaseInfo`.
  nonisolated static func parseRelease(data: Data) -> ReleaseInfo? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tagName = json["tag_name"] as? String,
      let htmlURLString = json["html_url"] as? String,
      let htmlURL = URL(string: htmlURLString),
      let assets = json["assets"] as? [[String: Any]]
    else {
      return nil
    }

    let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    let name = (json["name"] as? String) ?? tagName
    let body = (json["body"] as? String) ?? ""

    var zipURL: URL?
    var shaURL: URL?

    for asset in assets {
      guard let assetName = asset["name"] as? String,
        let downloadURLString = asset["browser_download_url"] as? String,
        let downloadURL = URL(string: downloadURLString)
      else {
        continue
      }

      if assetName.hasSuffix(".zip") {
        zipURL = downloadURL
      } else if assetName.hasSuffix(".zip.sha256") || assetName.hasSuffix(".sha256") {
        shaURL = downloadURL
      }
    }

    guard let finalZip = zipURL, let finalSha = shaURL else { return nil }
    return ReleaseInfo(
      tagName: tagName,
      version: version,
      name: name,
      body: body,
      htmlURL: htmlURL,
      zipURL: finalZip,
      sha256URL: finalSha
    )
  }

  /// Downloads the release zip, verifies its SHA256 checksum, extracts it, and triggers atomic restart swap.
  func downloadAndInstall(release: ReleaseInfo) {
    guard downloadTask == nil else { return }
    state = .downloading(progress: 0.0)

    downloadTask = Task {
      do {
        let session = URLSession.shared

        // 1. Download SHA256 checksum
        state = .downloading(progress: 0.1)
        let (shaData, shaResp) = try await session.data(from: release.sha256URL)
        guard let httpSha = shaResp as? HTTPURLResponse, (200...299).contains(httpSha.statusCode),
          let shaString = String(data: shaData, encoding: .utf8)
        else {
          throw NSError(
            domain: "UpdateManager", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to download SHA256 checksum"])
        }
        let expectedHash =
          shaString.split(separator: " ").first.map(String.init)?.trimmingCharacters(
            in: .whitespacesAndNewlines
          ).lowercased() ?? ""
        guard !expectedHash.isEmpty else {
          throw NSError(
            domain: "UpdateManager", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid SHA256 checksum format"])
        }

        // 2. Download release zip
        state = .downloading(progress: 0.3)
        let (tempZipURL, zipResp) = try await session.download(from: release.zipURL)
        guard let httpZip = zipResp as? HTTPURLResponse, (200...299).contains(httpZip.statusCode)
        else {
          throw NSError(
            domain: "UpdateManager", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to download update archive"])
        }

        state = .downloading(progress: 0.7)

        // 3. Verify SHA256 checksum
        let zipData = try Data(contentsOf: tempZipURL)
        let digest = SHA256.hash(data: zipData)
        let actualHash = digest.compactMap { String(format: "%02x", $0) }.joined().lowercased()

        guard actualHash == expectedHash else {
          throw NSError(
            domain: "UpdateManager",
            code: 4,
            userInfo: [
              NSLocalizedDescriptionKey:
                "SHA256 checksum mismatch (expected \(expectedHash.prefix(8))..., got \(actualHash.prefix(8))...)"
            ]
          )
        }

        // 4. Extract into temporary staging directory using native ditto (preserves macOS code signatures & permissions)
        state = .downloading(progress: 0.9)
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          "SplashControlUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tempZipURL.path, stagingDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
          throw NSError(
            domain: "UpdateManager", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Failed to extract update zip archive"])
        }

        let stagedApp = stagingDir.appendingPathComponent("Splash.app")
        guard FileManager.default.fileExists(atPath: stagedApp.path) else {
          throw NSError(
            domain: "UpdateManager", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Extracted archive missing Splash.app bundle"])
        }

        // Verify target bundle is user-writable before attempting swap
        let targetBundle = Bundle.main.bundlePath
        let parentDir = URL(fileURLWithPath: targetBundle).deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: targetBundle)
          && !FileManager.default.isWritableFile(atPath: parentDir)
        {
          let isCask = Self.detectCaskInstall(bundlePath: targetBundle)
          let errorMsg =
            isCask
            ? "Cannot update: bundle not writable. Please run 'brew upgrade --cask splash-control'."
            : "Cannot update: '\(targetBundle)' is not writable by current user."
          throw NSError(
            domain: "UpdateManager", code: 7, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        // 5. Record installed release tag to prevent loop, then prepare relaunch swap
        UserDefaults.standard.set(release.tagName, forKey: "LastInstalledReleaseTag")
        state = .readyToRestart(release)
        SplashLog.shared.log(
          "updater ready_to_restart version=\(release.version) staged=\(stagedApp.path)")

        // Execute relaunch swap
        try Self.performSwapAndRestart(
          stagedAppPath: stagedApp.path, targetBundlePath: targetBundle)
      } catch {
        state = .failed(error.localizedDescription)
        SplashLog.shared.log("updater install_failed error=\(error)")
      }
      downloadTask = nil
    }
  }

  /// Spawns detached bash helper script to swap bundle in place with rollback and relaunch.
  static func performSwapAndRestart(
    stagedAppPath: String, targetBundlePath: String = Bundle.main.bundlePath
  ) throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "splash_update_\(pid).sh")
    let stagedDir = URL(fileURLWithPath: stagedAppPath).deletingLastPathComponent().path
    let backupPath = "\(targetBundlePath).old"
    let scriptPath = scriptURL.path
    let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("splash_update.log")
      .path

    let scriptContent = """
      #!/usr/bin/env bash
      exec > "\(logPath)" 2>&1
      set -e

      # Wait for the running application to exit (timeout 30s)
      count=0
      while kill -0 \(pid) 2>/dev/null; do
        sleep 0.2
        count=$((count + 1))
        if [ $count -gt 150 ]; then
          echo "Timeout waiting for PID \(pid) to exit"
          exit 1
        fi
      done

      # Remove quarantine attribute from downloaded bundle
      xattr -dr com.apple.quarantine "\(stagedAppPath)" 2>/dev/null || true

      # Atomic backup of existing bundle if present
      rm -rf "\(backupPath)"
      if [ -d "\(targetBundlePath)" ]; then
        mv "\(targetBundlePath)" "\(backupPath)"
      fi

      # Copy staged app to destination
      if ditto "\(stagedAppPath)" "\(targetBundlePath)"; then
        # Remove quarantine from target destination
        xattr -dr com.apple.quarantine "\(targetBundlePath)" 2>/dev/null || true
        # Clean up backup on success
        rm -rf "\(backupPath)"
      else
        echo "Ditto failed; rolling back"
        if [ -d "\(backupPath)" ]; then
          rm -rf "\(targetBundlePath)"
          mv "\(backupPath)" "\(targetBundlePath)"
        fi
        exit 1
      fi

      # Clean up staged temporary directory and script
      rm -rf "\(stagedDir)"
      rm -f "\(scriptPath)"

      # Relaunch the upgraded application
      open -n "\(targetBundlePath)"
      """

    try scriptContent.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)

    // Make executable
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+x", scriptURL.path]
    try chmod.run()
    chmod.waitUntilExit()

    // Spawn detached process
    let runner = Process()
    runner.executableURL = URL(fileURLWithPath: "/bin/bash")
    runner.arguments = [scriptURL.path]
    try runner.run()

    // Exit current app gracefully
    SplashLog.shared.log("updater relaunching pid=\(pid) target=\(targetBundlePath)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NSApp.terminate(nil)
    }
  }
}
