import Foundation

/// File-based logging, split into two channels so the tray's own lifecycle
/// events and the server's output can be read independently:
///
/// - `.tray`  → `splash-control.log`   what the app did: launch, adopt, restart,
///   exit. 24 h age-compacted on launch, as before.
/// - `.server` → `splash-server.log` everything `splash serve` printed. This was
///   previously written **only while the process was `.starting`**
///   (`SplashProcess.appendConsole`), so per-request output was never persisted;
///   it now is. Size-rotated rather than age-compacted, because a low-traffic
///   server should keep a long history rather than lose it to a daily sweep.
///
/// Both channels are pinned to **Europe/Berlin**, which is the machine's own
/// zone and the one `splash serve` uses for its line prefixes, so tray and
/// server timestamps finally agree instead of one being UTC and the other local.
final class SplashLog {

  enum Channel: String, CaseIterable {
    case tray
    case server

    var filename: String {
      self == .tray ? "splash-control.log" : "splash-server.log"
    }
  }

  /// Roll a channel once it passes 1 MB. A roll **deletes** the old log rather
  /// than archiving it as `.1`, `.2`, …: the generations accumulated into ~10 MB
  /// of unread files from October 1–2, and a `.log.10` is not something any view
  /// in this app can reach. What history exists is the current run, and a server
  /// start resets it deliberately (`SplashProcess.start`).
  static let rotationBytes = 1_048_576

  static let shared = SplashLog()

  /// App version: CFBundleShortVersionString from Info.plist ("dev" under `swift run`).
  static var version: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
  }

  static var logDirectory: URL {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs")
      .appendingPathComponent("SplashControl", isDirectory: true)
  }

  /// The tray log — unchanged name, so existing links and habits keep working.
  static var logURL: URL { url(for: .tray) }

  static func url(for channel: Channel) -> URL {
    logDirectory.appendingPathComponent(channel.filename)
  }

  /// One formatter for both writing and parsing. `TimeZone(identifier:)`
  /// resolves CET/CEST per call, so a hardcoded `+02:00` would be wrong for
  /// the five winter months.
  ///
  /// The same formatter also parses the older `…Z` lines: ISO8601 parsing
  /// honours the offset present in the string, so the 24 h compaction keeps
  /// working across the switch instead of silently keeping every legacy line.
  static let stamp: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = .withInternetDateTime
    f.timeZone = TimeZone(identifier: "Europe/Berlin")
    return f
  }()

  private static var unavailableSet: Set<Channel> = []
  private static let unavailableLock = NSLock()

  /// Channels whose file could not be opened and which are therefore writing
  /// to `/dev/null`. Surfaced in the UI: a silently discarded server log would
  /// look identical to a quiet server.
  ///
  /// Lock-guarded rather than a bare `static var`: the writes happen under the
  /// instance lock from pipe-handler threads, while the reads are on the main
  /// actor from a view — exactly the cross-thread access that is a data race
  /// even when the value almost never changes.
  static var unavailable: Set<Channel> {
    unavailableLock.lock()
    defer { unavailableLock.unlock() }
    return unavailableSet
  }

  private let dir: URL
  private var handles: [Channel: FileHandle] = [:]
  /// Bytes per channel, tracked in memory so rotation does not need a `stat`
  /// on every line. Re-seeded from disk whenever the file is (re)opened.
  private var written: [Channel: Int] = [:]

  /// Guards every access to `handles`, `written` and `unavailable`.
  ///
  /// This type is written from at least four threads: the server pipe's
  /// `readabilityHandler`, the poll loop, `SplashProcess`'s launch/kill
  /// routines, and the benchmark's worker tasks. Those dicts are not
  /// thread-safe, so concurrent mutation is a real data race — not a
  /// theoretical one — and it lands as `EXC_BAD_ACCESS` or a half-rotated
  /// file rather than as a diagnosable error.
  ///
  /// Deliberately a plain `NSLock` and not a serial queue: the critical
  /// section is a handful of syscalls on a 1 MB-rotated file, so queue
  /// hopping would cost more than the contention.
  ///
  /// Contract for the lock-free internals below: `open` and `rotate` assume
  /// the lock is **already held** by their caller (`init`, `log`, `rotateNow`).
  private let lock = NSLock()

  /// `directory` exists so the checks can exercise rotation in a temp folder.
  init(directory: URL? = nil) {
    dir = directory ?? Self.logDirectory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    lock.lock()
    for channel in Channel.allCases { open(channel) }
    lock.unlock()
  }

  private func path(_ channel: Channel) -> URL {
    dir.appendingPathComponent(channel.filename)
  }

  private func open(_ channel: Channel) {
    let file = path(channel)
    // Auto-compact on launch: keep only the last 24 h so the tray log does
    // not grow unbounded across app launches. The server log is left alone —
    // it is rotated by size instead, and a daily sweep would throw away
    // exactly the long-tail history a quiet server accumulates.
    if channel == .tray, FileManager.default.fileExists(atPath: file.path) {
      Self.compactOldEntries(at: file, olderThan: 24 * 3600)
    } else if !FileManager.default.fileExists(atPath: file.path) {
      // FileHandle(forWritingTo:) does NOT create the file — touch it first.
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    written[channel] = (attributes?[.size] as? NSNumber)?.intValue ?? 0

    do {
      let handle = try FileHandle(forWritingTo: file)
      handle.seekToEndOfFile()
      handles[channel] = handle
      Self.markAvailable(channel, true)
    } catch {
      // Worst case: a handle to /dev/null that silently discards. Recorded
      // so a view can say so — a log that vanishes without a trace is
      // worse than one that is loudly missing.
      handles[channel] = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
      Self.markAvailable(channel, false)
    }
  }

  private static func markAvailable(_ channel: Channel, _ ok: Bool) {
    unavailableLock.lock()
    defer { unavailableLock.unlock() }
    if ok { unavailableSet.remove(channel) } else { unavailableSet.insert(channel) }
  }

  /// Rewrites the log keeping only timestamped entries newer than `maxAgeSec`
  /// ago (non-timestamped lines are preserved). Runs once per app launch.
  static func compactOldEntries(at url: URL, olderThan maxAgeSec: TimeInterval) {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
    let cutoff = Date().addingTimeInterval(-maxAgeSec)
    var kept: [String] = []
    for line in content.components(separatedBy: "\n") where !line.isEmpty {
      var keep = true
      if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
        let tsRange = line.index(after: line.startIndex)..<close
        if let ts = stamp.date(from: String(line[tsRange])) {
          keep = ts >= cutoff
        }
      }
      if keep { kept.append(line) }
    }
    try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n"))
      .write(to: url, atomically: true, encoding: .utf8)
  }

  /// `splash serve` prefixes every line it prints with `HH:MM:SS `
  /// (`server/diagnostics.py`), so stamping the `.server` channel as well gave
  /// one event two timestamps and burned ~30 columns on every row:
  /// `[2026-10-02T23:01:06+02:00] 23:01:06 Loading · …`. Only the lines that
  /// carry no clock of their own — the model-download notice, the `$ splash
  /// serve …` echo — still get the ISO stamp, so nothing loses its place in
  /// the file.
  private static let clockPrefix = try! NSRegularExpression(pattern: "^\\d{2}:\\d{2}:\\d{2} ")

  private static func hasOwnClock(_ line: String) -> Bool {
    clockPrefix.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
  }

  func log(_ message: String, _ channel: Channel = .tray) {
    let stamp =
      channel == .server && Self.hasOwnClock(message)
      ? "" : "[\(Self.stamp.string(from: Date()))] "
    let line = "\(stamp)\(message)\n"
    let data = Data(line.utf8)
    lock.lock()
    defer { lock.unlock() }
    handles[channel]?.write(data)
    written[channel, default: 0] += data.count
    if written[channel, default: 0] >= Self.rotationBytes { rotate(channel) }
  }

  /// Delete this channel's log and start an empty one.
  ///
  /// Lock-free: every caller already holds `lock` (`log` may call it mid-line,
  /// which is exactly why a second acquisition here would deadlock).
  private func rotate(_ channel: Channel) {
    let fm = FileManager.default
    let file = path(channel)
    handles[channel]?.closeFile()
    handles[channel] = nil
    // Enumerated by prefix rather than by generation index, so archives left
    // by the old ten-generation scheme (`.1` … `.10`) are purged too instead
    // of sitting on disk forever, unreachable by any view.
    let prefix = file.lastPathComponent + "."
    for stale in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    where stale.lastPathComponent.hasPrefix(prefix) {
      try? fm.removeItem(at: stale)
    }
    try? fm.removeItem(at: file)
    open(channel)  // recreates empty and re-seeds the counter
  }

  /// Manual rotation, for the Logs tab. Reuses the size-triggered path exactly
  /// so there is only ever one rotation scheme.
  ///
  /// No server restart is involved or needed: the tray spawns splash with
  /// `standardOutput` on a `Pipe` and writes the log itself, so the server holds
  /// no handle on the file. Rotating is a few unlinks plus reopening the
  /// handle, and the next line the server emits lands in the new file.
  func rotateNow(_ channel: Channel) {
    lock.lock()
    defer { lock.unlock() }
    rotate(channel)
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    for (_, handle) in handles { handle.closeFile() }
    handles.removeAll()
  }

  /// Reads the full log file back as a string (convenience for UI/debugging).
  func readLog() -> String? {
    try? String(contentsOf: path(.tray), encoding: .utf8)
  }
}
