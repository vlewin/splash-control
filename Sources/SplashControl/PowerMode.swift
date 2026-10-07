import Foundation
import os

/// Reads the user-selected macOS power mode (`pmset -g` → "powermode N").
enum PowerMode {
  static func name(_ mode: Int?) -> String {
    switch mode {
    case 0: return "Auto"  // Automatisch
    case 1: return "Efficiency"  // Leistung reduzieren
    case 2: return "Performance"  // Hohe Leistung
    case nil: return "unknown"
    default: return "mode \(mode!)"
    }
  }

  /// How long a `pmset` answer is reused. The poll loop calls `current()` every
  /// 1–2 s, and each call forked a child process: 43 200 spawns per day, each
  /// paying kernel process-table allocation, Mach port setup, address-space
  /// mapping, binary parsing and a security audit. A power mode is a manual
  /// System Settings switch (or a battery-threshold event) — it changes a few
  /// times a day at most, so a minute of staleness is invisible. The chart
  /// annotates mode changes; that annotation now lands up to 60 s late.
  static let ttl: TimeInterval = 60

  /// `os_unfair_lock` via `OSAllocatedUnfairLock` rather than `NSLock`:
  /// `current()` is `async`, and taking an `NSLock` across an async function is
  /// a Swift 6 error ("use async-safe scoped locking"). The critical section
  /// here is two field reads.
  private static let cache = OSAllocatedUnfairLock<Cached>(
    initialState: Cached(mode: nil, at: .distantPast))
  private struct Cached {
    var mode: Int?
    var at: Date
  }

  /// Runs `pmset -g` off the main thread, at most once per `ttl`.
  /// Returns the parsed mode, or nil when pmset failed or said nothing.
  static func current() async -> Int? {
    let hit = cache.withLock { $0 }
    if Date().timeIntervalSince(hit.at) < ttl { return hit.mode }

    let probed = await Task.detached(priority: .utility) { probe() }.value

    return cache.withLock { state in
      // Keep the last good value if the probe failed: `nil` here would blank
      // the power chip and its chart annotation, so a single transient
      // failure would erase a fact we already know.
      let mode = probed ?? state.mode
      state = Cached(mode: mode, at: Date())
      return mode
    }
  }

  /// Drops the cache so the next call re-reads. Used when the user opens
  /// Settings, where a stale minute-old value is visible without explanation.
  static func invalidate() {
    cache.withLock { $0.at = .distantPast }
  }

  private static func probe() -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let text = String(data: data, encoding: .utf8) ?? ""
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ").filter { !$0.isEmpty }
      if parts.count == 2, parts[0] == "powermode", let value = Int(parts[1]) {
        return value
      }
    }
    return nil
  }
}
