import Foundation
import SwiftUI

/// Per-model performance history, kept across restarts so two models can be
/// compared on the same machine.
///
/// Two design decisions worth knowing before reading the numbers:
///
/// **What is aggregated exactly, and what is sampled.** `min`/`max`/`avg` need
/// only four numbers, so they are tracked *unbounded* and never truncated —
/// history does not decay. Only percentiles need a distribution, so those come
/// from a bounded reservoir. Storing raw samples for everything (the first
/// attempt) would have thrown away history at the ring boundary while paying
/// disk cost for values the aggregates already summarised exactly.
///
/// **What is a valid comparison key.** Rates depend on `kvFormat` (BF16 reads
/// twice the KV bytes per token), `maxMemory`/`maxCacheDisk` (governor denials
/// and SSD paging stall decode) and `maxContext` (planned KV). Measured
/// 2026-09-29: `reasoning_effort` does **not** move the rates — decode stayed
/// 94–101 tok/s across `medium` and `xhigh` — so it is deliberately *not* part
/// of the key. It changes output *length*, not throughput.
///
/// One confound the key cannot remove: prefill rate is bimodal by cache state.
/// Measured 219 tok/s cold (`cache_n` 0) against 61 tok/s warm (`cache_n` 32)
/// on the same prompt. `/status` exposes only cumulative `cache.hit_rate`, not
/// per-request, so samples cannot be labelled — the distribution is shown
/// honestly instead of being collapsed into one misleading percentile. The same
/// reasoning is why memory keeps its percentiles: the wide range is the truth,
/// and a dash would only hide it.
final class ModelStats: ObservableObject {

  /// One row: a model under one set of conditions.
  struct Key: Codable, Hashable, Identifiable {
    var model: String
    /// Empty when unset, so a default run and an explicit one compare.
    var kvFormat: String
    var maxContext: String
    var maxMemory: String
    var maxCacheDisk: String

    var id: String { "\(model)|\(kvFormat)|\(maxContext)|\(maxMemory)|\(maxCacheDisk)" }

    /// The condition half of the key, before a model is known.
    static func conditions(
      kvFormat: String, maxContext: String,
      maxMemory: String, maxCacheDisk: String
    ) -> Key {
      Key(
        model: "", kvFormat: kvFormat, maxContext: maxContext,
        maxMemory: maxMemory, maxCacheDisk: maxCacheDisk)
    }

    func withModel(_ m: String) -> Key {
      var k = self
      k.model = m
      return k
    }

    /// Human-readable condition summary, shown in the view so two rows are
    /// never silently compared across different setups.
    var conditions: String {
      [
        kvFormat.isEmpty ? nil : "kv \(kvFormat)",
        maxContext.isEmpty ? nil : "ctx \(maxContext)",
        maxMemory.isEmpty ? nil : "mem \(maxMemory)",
        maxCacheDisk.isEmpty ? nil : "disk \(maxCacheDisk)",
      ]
      .compactMap { $0 }
      .joined(separator: " · ")
    }
  }

  /// Exact running aggregate. `min`/`max` survive unbounded history because
  /// they are just the extremes seen so far.
  struct Aggregate: Codable {
    var count: Int = 0
    var sum: Double = 0
    var min: Double?
    var max: Double?

    mutating func add(_ v: Double) {
      count += 1
      sum += v
      min = min == nil ? v : Swift.min(min!, v)
      max = max == nil ? v : Swift.max(max!, v)
    }

    /// Merging on load keeps periodic flushing idempotent and lossless.
    mutating func merge(_ o: Aggregate) {
      guard o.count > 0 else { return }
      count += o.count
      sum += o.sum
      if let v = o.min { min = min == nil ? v : Swift.min(min!, v) }
      if let v = o.max { max = max == nil ? v : Swift.max(max!, v) }
    }

    var avg: Double? { count > 0 ? sum / Double(count) : nil }
  }

  /// Bounded reservoir for percentiles only. Replaces the oldest entry once
  /// full, which keeps the estimate stable without unbounded growth.
  struct Reservoir: Codable {
    var values: [Double] = []
    var limit: Int = 1024

    mutating func add(_ v: Double) {
      guard v.isFinite else { return }
      if values.count < limit {
        values.append(v)
      } else {
        values[values.count - 1] = v  // cheap bounded rotation
      }
    }

    mutating func merge(_ o: Reservoir) {
      for v in o.values { add(v) }
    }

    /// Linear-interpolation percentile; `nil` below one sample.
    func percentile(_ p: Double) -> Double? {
      guard !values.isEmpty else { return nil }
      let s = values.sorted()
      if s.count == 1 { return s[0] }
      let rank = p * Double(s.count - 1)
      let lo = Int(rank)
      let hi = Swift.min(lo + 1, s.count - 1)
      return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }
  }

  struct Row: Codable, Identifiable {
    var key: Key
    var decode = Aggregate()
    var decodeReservoir = Reservoir()
    var prefill = Aggregate()
    var prefillReservoir = Reservoir()
    /// Memory is a level, not a rate: it grows with KV and the state cache.
    /// Its percentiles answer "what was the footprint for most of the
    /// session" against a peak, which is a real question — worth more than
    /// the empty cells it replaces, since a dash cannot be distinguished
    /// from data that simply has not arrived yet.
    var memory = Aggregate()
    var memoryReservoir = Reservoir()
    var firstSeen: Double = Date().timeIntervalSince1970
    var lastSeen: Double = Date().timeIntervalSince1970
    var id: String { key.id }

    /// Hand-written so a `stats.json` written by an earlier build still
    /// loads. The synthesised decoder would throw `keyNotFound` on a missing
    /// non-optional field, and property defaults are *not* honoured there —
    /// so adding `decodeReservoir` would have silently discarded all
    /// existing history on upgrade.
    init(key: Key) {
      self.key = key
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      key = try c.decode(Key.self, forKey: .key)
      decode = (try? c.decode(Aggregate.self, forKey: .decode)) ?? Aggregate()
      decodeReservoir = (try? c.decode(Reservoir.self, forKey: .decodeReservoir)) ?? Reservoir()
      prefill = (try? c.decode(Aggregate.self, forKey: .prefill)) ?? Aggregate()
      prefillReservoir = (try? c.decode(Reservoir.self, forKey: .prefillReservoir)) ?? Reservoir()
      memory = (try? c.decode(Aggregate.self, forKey: .memory)) ?? Aggregate()
      memoryReservoir = (try? c.decode(Reservoir.self, forKey: .memoryReservoir)) ?? Reservoir()
      firstSeen = (try? c.decode(Double.self, forKey: .firstSeen)) ?? Date().timeIntervalSince1970
      lastSeen = (try? c.decode(Double.self, forKey: .lastSeen)) ?? Date().timeIntervalSince1970
    }
  }

  @Published private(set) var rows: [Row] = []
  /// Flushed periodically rather than per poll: rewriting JSON every second
  /// is wasteful and risks a torn write.
  private var lastFlush = Date.distantPast

  static let flushInterval: TimeInterval = 60
  /// Shared so the bench report lands beside `stats.json` in one folder.
  static let directory: URL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("SplashControl", isDirectory: true)

  private static let file: URL = directory.appendingPathComponent("stats.json")

  // MARK: - Recording

  /// Feed one poll's sample. Rates are nil when idle and are skipped rather
  /// than recorded as zero — an idle engine must not drag an average down.
  /// Set by the benchmark for the duration of a run. See `record`.
  var isSuppressed = false

  func record(_ sample: Sample, key: Key) {
    // A benchmark run generates real traffic against the same model and the
    // same conditions, so it would land in these very rows and blend five
    // synthetic prompts into hours of actual serving. Suppressed rather than
    // reset: the pollution is the problem, throwing away the history is not.
    guard !isSuppressed else { return }
    guard let i = index(for: key) else { return }
    if let v = sample.decodeTps, v > 0 {
      rows[i].decode.add(v)
      rows[i].decodeReservoir.add(v)
    }
    if let v = sample.prefillTps, v > 0 {
      rows[i].prefill.add(v)
      rows[i].prefillReservoir.add(v)
    }
    if let v = sample.totalLoadBytes, v > 0 {
      let gib = Double(v) / 1_073_741_824
      rows[i].memory.add(gib)
      rows[i].memoryReservoir.add(gib)
    }
    rows[i].lastSeen = Date().timeIntervalSince1970
    if Date().timeIntervalSince(lastFlush) >= Self.flushInterval { flush() }
  }

  private func index(for key: Key) -> Int? {
    if let i = rows.firstIndex(where: { $0.key == key }) { return i }
    rows.append(Row(key: key))
    rows.sort { $0.lastSeen > $1.lastSeen }
    return rows.firstIndex(where: { $0.key == key })
  }

  private let isEphemeral: Bool
  private let fileURL: URL?

  init(fileURL: URL? = nil, ephemeral: Bool = false) {
    self.fileURL = fileURL
    self.isEphemeral = ephemeral
    if !ephemeral { load() }
  }

  // MARK: - Persistence

  func load() {
    guard !isEphemeral else { return }
    let target = fileURL ?? Self.file
    guard let data = try? Data(contentsOf: target),
      let decoded = try? JSONDecoder().decode([Row].self, from: data)
    else { return }
    // Merge rather than replace, so a stats.json written by an older build
    // (or a duplicate row) cannot silently drop history.
    var merged: [String: Row] = [:]
    for row in decoded {
      if var existing = merged[row.id] {
        existing.decode.merge(row.decode)
        existing.decodeReservoir.merge(row.decodeReservoir)
        existing.prefill.merge(row.prefill)
        existing.prefillReservoir.merge(row.prefillReservoir)
        existing.memory.merge(row.memory)
        existing.memoryReservoir.merge(row.memoryReservoir)
        existing.firstSeen = Swift.min(existing.firstSeen, row.firstSeen)
        existing.lastSeen = Swift.max(existing.lastSeen, row.lastSeen)
        merged[row.id] = existing
      } else {
        merged[row.id] = row
      }
    }
    rows = merged.values.sorted { $0.lastSeen > $1.lastSeen }
  }

  func flush() {
    guard !isEphemeral else { return }
    lastFlush = Date()
    let target = fileURL ?? Self.file
    let dir = target.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(rows) else { return }
    // Atomic: a torn stats.json would be read back as garbage.
    try? data.write(to: target, options: .atomic)
  }

  // MARK: - Reset

  func reset(_ rowID: String) {
    rows.removeAll { $0.id == rowID }
    flush()
  }

  func resetAll() {
    rows.removeAll()
    flush()
  }
}
