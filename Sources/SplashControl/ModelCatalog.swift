import CoreServices
import Foundation
import os

/// The models this machine can serve, discovered from the filesystem rather
/// than hardcoded — the list goes stale the moment a third model exists, which
/// is exactly what happened when Prism ML Ternary-Bonsai-2 was installed.
///
/// `splash` itself offers no listing command: `splash --help` exposes only
/// `serve` plus the agent connectors, `install/models.py` has just
/// `prepare`/`verify`/`link`, and the official catalogue
/// (`incoai/splash-6aac69afeba907af0511ec14`) lists only the two `incoai`
/// packages — it would never surface an upstream model like Bonsai.
enum ModelCatalog {

  /// `splash serve` writes one selection symlink per model under
  /// `~/Library/Application Support/Splash/models/<owner>/<repo>[:VARIANT]`,
  /// which is the exact shape `--model` accepts. The dot-prefixed siblings
  /// (`.install.lock`, `.metadata`, `.resolved`) are bookkeeping, not models.
  /// Path casing matches `install/paths.py:DATA`; the volume is
  /// case-insensitive, so either spelling resolves.
  static var modelsRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Splash", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
  }

  /// Installed model IDs, sorted, from an in-memory cache invalidated by an
  /// FSEvents watch on `modelsRoot`.
  ///
  /// The cache replaces a directory scan on every menu open. The scan is only
  /// ~0.03 ms, but it runs on the main thread while an AppKit menu tracks, and
  /// every `stat` is a disk round trip that can queue behind Metal cache paging.
  /// Watching means the menu opens from memory and a newly installed model still
  /// appears with no refresh step and nothing to announce.
  ///
  /// A model appears here once its first `splash serve` has prepared it.
  /// `configured` is unioned in by callers so an ID that is set but not yet
  /// installed still renders instead of leaving a picker with no selection.
  static func installed() -> [String] {
    let hit = cache.withLock { $0 }
    if let ids = hit.ids, Date().timeIntervalSince(hit.at) < ttl { return ids }
    let ids = scan()
    cache.withLock { $0 = Cache(ids: ids, at: Date()) }
    return ids
  }

  /// Backstop so a stale list is impossible even where the watch cannot run
  /// (no models directory yet, watch creation refused).
  nonisolated static let ttl: TimeInterval = 5

  private struct Cache {
    var ids: [String]?
    var at: Date
  }

  /// Async-safe: the FSEvents callback runs on its own queue, not the main one.
  private static let cache = OSAllocatedUnfairLock<Cache>(
    initialState: Cache(ids: nil, at: .distantPast))

  /// The live streams. Held for the process lifetime; a stream that nothing
  /// retains is stopped and released immediately.
  nonisolated(unsafe) private static var streams: [FSEventStreamRef] = []

  private static func scan() -> [String] {
    let fm = FileManager.default
    guard
      let owners = try? fm.contentsOfDirectory(
        at: modelsRoot, includingPropertiesForKeys: nil
      )
    else { return [] }
    var ids: [String] = []
    for owner in owners {
      guard owner.lastPathComponent.hasPrefix(".") == false,
        let models = try? fm.contentsOfDirectory(
          at: owner, includingPropertiesForKeys: nil)
      else { continue }
      for model in models where !model.lastPathComponent.hasPrefix(".") {
        ids.append("\(owner.lastPathComponent)/\(model.lastPathComponent)")
      }
    }
    return ids.sorted()
  }

  // MARK: - Filesystem watch

  /// Starts a recursive watch on `modelsRoot`. Idempotent: a second call while
  /// a stream is live does nothing.
  ///
  /// `FSEventStream`, not `DispatchSource.makeFileSystemObjectSource`: a
  /// dispatch source on a directory reports changes to its *immediate* entries
  /// only, and a model is installed as `<modelsRoot>/<owner>/<repo>` — two
  /// levels down — so a non-recursive watch would never fire.
  @discardableResult
  static func startWatching() -> Bool {
    let root = modelsRoot
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      SplashLog.shared.log("model_watch_skipped reason=missing_dir path=\(root.path)")
      return false
    }
    guard streams.isEmpty else { return true }
    // One event kind is enough: the cache is refreshed as a whole, so there is
    // nothing to distinguish. No context pointer — the callback reaches the
    // cache statically, which is also why no retain cycle is possible here.
    let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
      ModelCatalog.cache.withLock { $0.ids = nil }
    }
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        callback,
        nil,
        [root.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        // Coalesce the burst of writes a model install produces into one
        // rescan instead of one per file.
        0.5,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents)
      )
    else {
      SplashLog.shared.log("model_watch_failed reason=create")
      return false
    }
    // A dispatch queue, not the main run loop: the callback only drops a
    // cached list, so it must never contend with menu tracking.
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
    guard FSEventStreamStart(stream) else {
      SplashLog.shared.log("model_watch_failed reason=start")
      return false
    }
    streams.append(stream)
    SplashLog.shared.log("model_watch_started path=\(root.path) models=\(scan().count)")
    return true
  }

  /// Menu/Picker label for a model ID: drop the owner, drop a packaging
  /// suffix the two `incoai` releases and Prism's GGUF repo both carry, and
  /// surface a GGUF variant separately since it selects a different file.
  ///
  ///     incoai/Qwen3.8-27B-Splash                 -> "Qwen 3.8 27B"
  ///     prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0  -> "Ternary Bonsai 2 27B · PQ2_0"
  ///
  /// Deliberately derived, not a lookup table: a table is what silently
  /// titled an unrecognised model "Qwen 3.6 35B A3B".
  static func displayName(for id: String) -> String {
    var name = id.split(separator: "/").last.map(String.init) ?? id
    var variant: String?
    if let colon = name.firstIndex(of: ":") {
      variant = String(name[name.index(after: colon)...])
      name = String(name[..<colon])
    }
    for suffix in ["-gguf", "-mlx", "-Splash"] where name.hasSuffix(suffix) {
      name = String(name.dropLast(suffix.count))
      break
    }
    let label = name.replacingOccurrences(of: "-", with: " ")
    return variant.map { "\(label) · \($0)" } ?? label
  }
}
