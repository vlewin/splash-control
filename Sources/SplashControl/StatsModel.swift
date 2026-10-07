import Combine
import Foundation
import SplashControlKit

/// One poll tick of derived, chart-ready values.
struct Sample: Identifiable {
  let id = UUID()
  let date: Date
  /// Engine decode rate for a newly observed batch or counter interval. Nil when no new decode event.
  var decodeTps: Double?
  /// Sustained decode throughput: Δ`decode_output_tokens` / Δ`decode_wall_ms`
  /// over the poll interval, the same construction as `prefillTps`.
  ///
  /// This — not `decodeTps` — is the number that means "throughput". The
  /// server's own per-request log line is a near-identical construction
  /// (`server/metrics.py`: `(completion − first_token_batch_tokens) × 1000 /
  /// first_token_to_done_ms`); the only difference is that the log excludes
  /// the first emission batch, worth under 1% on a long generation.
  ///
  /// `decodeTps` cannot stand in for it. One engine batch decodes ~2 tokens in
  /// ~27 ms, but how many depends on speculative-draft acceptance: a batch
  /// whose whole draft lands reports ~300 tok/s, a batch that accepted 1 of 7
  /// reports ~37. Measured spread on one model inside one request: 36.7 to
  /// 323.7 tok/s. It is a per-batch reading, not a rate — see ARCHITECTURE.md § 4.3.
  var sustainedTps: Double?
  /// Engine prefill rate over the interval: Δprefill_tokens / Δprefill_wall. Nil when idle.
  var prefillTps: Double?
  /// Server-side rolling-window percentiles (last 4096 samples).
  var ttftP50Ms: Double?
  var ttftP95Ms: Double?
  var itlP50Ms: Double?
  var itlP95Ms: Double?
  var metalBytes: UInt64?
  var metalBudgetBytes: UInt64?
  /// The model's fixed weight cost. Constant per model, so this is a floor and
  /// is drawn as a reference line, never as a plotted series.
  /// `physical − host_available`: everything on the machine that the governor
  /// does not consider available. `host_available` deliberately adds the file
  /// cache, purgeable pages and compression headroom, so this is a **lower
  /// bound** on macOS's "Speicher (belegt)" and always ≤ it. The gap is the
  /// reclaimable pool — verified at 14,7 GiB on a 64 GiB machine, of which the
  /// file cache was 6,8 GiB and the rest headroom macOS holds compressed for
  /// the price of 0,9 GiB.
  ///
  /// The two series `totalLoadBytes + hostAvailableBytes` sum to physical
  /// exactly, which is the property that makes the chart reconcilable with the
  /// machine it is describing.
  var totalLoadBytes: UInt64?
  var kvPagesActive: Int?
  var kvBlockTokens: Int?
  var hostAvailableBytes: UInt64?
  var ttftSamples: Int?
  var pressure: String?
  var draftAcceptance: Double?
  var requestsPerMin: Double?
  var activeRequests: Int?
  var powerMode: Int?
  var deviceName: String?
  /// splash's resolved architecture family ("Qwen3.8-27B"), not the repo id.
  var familyName: String?
  /// The context limit the server actually enforces.
  var maxContextTokens: Int?
  /// The model's native window (its ceiling). Usually larger than
  /// `maxContextTokens`; equal when nothing is capping it.
  var nativeContextTokens: Int?
  /// Tokens in the resident KV pool (pages_resident × tokens/page).
  /// This is the *retained cache pool*, not one request's logical context:
  /// it can exceed the context cap (retained prefixes from past requests)
  /// and shrinks only under eviction pressure.
  var kvPoolTokens: Int?
  /// True when the previous tick was >30 s ago — charts plot a break here.
  var gap: Bool = false
}

/// A vertical annotation on the charts (power-mode switches, manual notes).
struct Marker: Identifiable, Codable, Equatable {
  var id = UUID()
  var date: Date
  var label: String
  var automatic: Bool
}

/// Engine state read off `GET /status`.
///
/// The server exposes no client, session, or agent identity on any endpoint —
/// `instance.id` identifies the *process*, not the caller. So this is aggregate
/// engine state ("is the GPU working, and on what"), never "which agent".
enum AgentStatus: Equatable {
  case stopped  // no live server
  case starting  // process up, engine not ready yet
  case loading  // prefill: reading the prompt
  case decoding  // generating tokens
  case masked  // blocked on a grammar/JSON-schema mask (tool call)
  case queued  // held at admission (concurrency / memory / queue)
  case suspended  // cache resource reclaimed while the request waited
  case draining  // shutdown started with work still in flight
  case recovering  // transport restarted after a crash
  case stale  // last snapshot, refresh blocked by GPU work
  /// The engine's own `--max-memory` budget is exhausted: growth is being
  /// refused. Actionable, and the state auto-restart can act on.
  case budgetCapped
  /// The OS reports memory pressure, but the engine's budget may be fine.
  /// Not actionable by restarting splash: the engine budget may be fine.
  case memoryPressure
  case idle
  case error

  var label: String {
    switch self {
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .loading: return "loading"
    case .decoding: return "decoding"
    case .masked: return "masked"
    case .queued: return "queued"
    case .suspended: return "suspended"
    case .draining: return "draining"
    case .recovering: return "recovering"
    case .stale: return "stale"
    case .budgetCapped: return "memory-capped"
    case .memoryPressure: return "memory-pressure"
    case .idle: return "idle"
    case .error: return "error"
    }
  }

  /// User-facing capitalized title (e.g. "Decoding", "Memory Pressure").
  var displayName: String {
    switch self {
    case .stopped: return "Stopped"
    case .starting: return "Starting"
    case .loading: return "Loading"
    case .decoding: return "Decoding"
    case .masked: return "Masked"
    case .queued: return "Queued"
    case .suspended: return "Suspended"
    case .draining: return "Draining"
    case .recovering: return "Recovering"
    case .stale: return "Stale"
    case .budgetCapped: return "Memory Capped"
    case .memoryPressure: return "Memory Pressure"
    case .idle: return "Idle"
    case .error: return "Error"
    }
  }

  enum Severity { case ok, busy, warn, bad }

  var severity: Severity {
    switch self {
    case .idle, .decoding: return .ok
    case .loading, .masked, .starting: return .busy
    case .queued, .suspended, .draining, .recovering, .stale,
      .budgetCapped, .memoryPressure:
      return .warn
    case .stopped, .error: return .bad
    }
  }

  /// Precedence chain over one `/status` snapshot. Nil = the server has never
  /// answered, which is distinct from `idle`.
  static func derive(from s: StatusDTO?) -> AgentStatus? {
    guard let s else { return nil }
    // Stale outranks everything: the snapshot itself is untrustworthy, and
    // ARCHITECTURE.md § 4.4 is explicit that it must never read as "down".
    if s.transport?.statusStale == true { return .stale }
    if s.transport?.recovering == true || s.metal?.healthy == false { return .recovering }
    if s.admission?.draining == true { return .draining }
    if s.ready != true { return .starting }
    if (s.admission?.suspended ?? 0) > 0 { return .suspended }
    // Memory constraint outranks the phase gauges. It used to sit below them,
    // so a green "decoding" dot hid an active memory warning: the phase is a
    // transient fact about this instant, the constraint is a condition that
    // persists, and it is the one a restart can act on. Losing the phase
    // costs nothing — `detail` reports it alongside the constraint.
    if s.memoryGovernor?.growthAllowed == false { return .budgetCapped }
    if let pressure = s.memoryPressure ?? s.memoryGovernor?.systemPressure,
      pressure != "normal"
    {
      return .memoryPressure
    }
    // Prefill next: it dominates wall time in this workload (629k prefill
    // vs 68k decode tokens on the reference run) and is the phase an agent
    // experiences as "waiting for the model".
    if (s.scheduler?.prefilling ?? 0) > 0 { return .loading }
    if (s.scheduler?.decoding ?? 0) > 0 { return .decoding }
    if (s.scheduler?.waitingMask ?? 0) > 0 { return .masked }
    if (s.admission?.waiting ?? 0) > 0 || (s.scheduler?.queued ?? 0) > 0 { return .queued }
    return .idle
  }

  /// The phase the engine is in *while* constrained, so reporting the
  /// constraint instead of the phase does not lose the fact that work is
  /// running. Nil when nothing is in flight.
  static func activePhase(_ s: StatusDTO) -> String? {
    var parts: [String] = []
    if let p = s.scheduler?.prefilling, p > 0 { parts.append("prefill \(p)") }
    if let d = s.scheduler?.decoding, d > 0 { parts.append("decode \(d)") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Secondary facts behind a status, e.g. "2 queued · oldest 1.5 s" — the
  /// counts the single status word has to drop. Nil when there is nothing to add.
  static func detail(from s: StatusDTO, for status: AgentStatus) -> String? {
    func n(_ v: Int?) -> String { v.map(String.init) ?? "0" }
    switch status {
    case .loading, .decoding:
      // `frontend.active` reads 0 even mid-generation (verified live), so
      // only the scheduler gauges are trustworthy here.
      var parts = [
        "prefill \(n(s.scheduler?.prefilling))",
        "decode \(n(s.scheduler?.decoding))",
      ]
      if let w = s.scheduler?.decoding, w > 1 { parts.append("batched ×\(w)") }
      return parts.joined(separator: " · ")
    case .masked:
      return "\(n(s.scheduler?.waitingMask)) on mask"
    case .queued:
      var parts = ["\(n(s.admission?.waiting)) waiting"]
      if let m = s.admission?.waitingMemory, m > 0 { parts.append("\(m) memory") }
      if let c = s.admission?.waitingConcurrency, c > 0 { parts.append("\(c) concurrency") }
      if let ms = s.admission?.oldestWaitMs, ms > 0 {
        parts.append(String(format: "oldest %.1fs", ms / 1000))
      }
      return parts.joined(separator: " · ")
    case .stale:
      guard let ms = s.transport?.statusAgeMs, ms > 0 else { return "last snapshot" }
      return String(format: "snapshot %.1fs old", ms / 1000)
    case .budgetCapped:
      // Name the ENGINE budget, not the host: these are different limits
      // and conflating them is what made this read wrong.
      var parts: [String] = []
      if let h = s.memoryGovernor?.headroomBytes {
        parts.append(String(format: "engine %.1f GiB headroom", Double(h) / 1_073_741_824))
      }
      if let d = s.memoryGovernor?.deniedReservations, d > 0 {
        parts.append("\(d) denied")
      }
      if let phase = activePhase(s) { parts.append(phase) }
      if parts.isEmpty { return "engine budget exhausted" }
      return parts.joined(separator: " · ")
    case .memoryPressure:
      // Host/OS pressure. splash may be fine; restarting it will not help.
      var parts: [String] = []
      if let p = s.memoryPressure ?? s.memoryGovernor?.systemPressure, !p.isEmpty {
        parts.append(p)
      }
      if let h = s.memoryGovernor?.hostHeadroomBytes {
        parts.append(String(format: "host %.1f GiB headroom", Double(h) / 1_073_741_824))
      }
      if let phase = activePhase(s) { parts.append(phase) }
      if parts.isEmpty { return "host memory pressure" }
      return parts.joined(separator: " · ")
    case .recovering:
      if let reason = s.metal?.failureReason, !reason.isEmpty { return reason }
      if let r = s.transport?.restarts, r > 0 { return "\(r) restart\(r == 1 ? "" : "s")" }
      return nil
    case .suspended:
      return "\(n(s.admission?.suspended)) suspended"
    case .draining:
      return "\(n(s.admission?.waiting)) still waiting"
    case .starting, .stopped, .idle, .error:
      return nil
    }
  }
}

@MainActor
final class StatsModel: ObservableObject {
  @Published private(set) var samples: [Sample] = []
  @Published private(set) var markers: [Marker] = []
  @Published private(set) var latest: StatusDTO?
  /// Live probe of the running server: true only when it serves the WebUI.
  @Published private(set) var webUIAvailable = false

  /// The model actually serving when it is **not** the one configured, else
  /// `nil`. The tray holds two independent facts — `config.model` (what it
  /// would launch) and `/status` `instance.model` (what is serving) — and it
  /// happily adopts a server it did not start. Every later `start()` still
  /// uses the configured model, so a mismatch is how a hand-started model
  /// gets silently replaced. Pure, so it is assertable.
  static func modelMismatch(configured: String?, serving: String?) -> String? {
    guard let configured, !configured.isEmpty,
      let serving, !serving.isEmpty, configured != serving
    else { return nil }
    return serving
  }

  // MARK: - Per-model history (long-term, persisted)
  //
  // Injected by the owner so there is exactly one ModelStats and one file on
  // disk. `nil` disables recording entirely.
  var history: ModelStats?
  /// Server settings that make two runs comparable. Kept in sync with config
  /// by the owner; `reasoning_effort` is deliberately excluded because it was
  /// measured not to affect throughput.
  var conditions = ModelStats.Key.conditions(
    kvFormat: "", maxContext: "",
    maxMemory: "", maxCacheDisk: "")
  /// Used only when `/status` reports no model (server not up yet).
  var fallbackModel: String?

  func setWebUIAvailable(_ available: Bool) {
    guard webUIAvailable != available else { return }
    webUIAvailable = available
  }
  @Published private(set) var powerMode: Int?

  /// Retention covers the largest selectable chart window (5 h); the chart
  /// itself only displays the configured window on top of this buffer.
  static let retentionSeconds: TimeInterval = 5 * 3600
  static let maxSamples = 18_000  // backstop: 5 h at 1 s poll (~8 MiB)

  /// Index of the first sample at or after `cutoff` in a date-ascending
  /// buffer, or `endIndex` when all of them predate it. Binary search because
  /// these buffers reach `maxSamples` and are scanned on every poll — a linear
  /// `firstIndex(where:)` here cost 18 000 comparisons per tick to trim a
  /// window that is almost always empty.
  static func lowerBound(_ cutoff: Date, in samples: [Sample]) -> Int {
    var lo = samples.startIndex
    var hi = samples.endIndex
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if samples[mid].date >= cutoff { hi = mid } else { lo = mid + 1 }
    }
    return lo
  }

  private var lastStatus: StatusDTO?
  private var lastSampleDate: Date?
  private var lastPowerMode: Int?
  private var markersURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SplashControl", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("markers.json")
  }

  init() {
    if let data = try? Data(contentsOf: markersURL),
      let saved = try? JSONDecoder().decode([Marker].self, from: data)
    {
      markers = saved
    }
  }

  // MARK: - Ingest

  func ingest(_ status: StatusDTO, powerMode: Int?) {
    let now = Date()
    self.powerMode = powerMode
    if let pm = powerMode {
      if let previous = lastPowerMode, pm != previous {
        let label = "Power: \(PowerMode.name(pm))"
        // Suppress flapping: don't stack identical markers within 60 s.
        if let last = markers.last, last.label == label, now.timeIntervalSince(last.date) < 60 {
          // same mode re-detected immediately — skip
        } else {
          addMarker(label: label, automatic: true)
        }
      }
      lastPowerMode = pm
    }

    var sample = Sample(date: now)
    let prev = lastStatus
    let m = status.metrics

    let currentBatch = m?.currentDecodeBatch
    let previousBatch = prev?.metrics?.currentDecodeBatch
    let batchChanged = currentBatch != previousBatch
    var decodeTokenDelta: Double?
    var decodeCountersAdvanced = false
    if let pt = m?.decodeOutputTokens, let pw = m?.decodeWallMs,
      let qpt = prev?.metrics?.decodeOutputTokens, let qdw = prev?.metrics?.decodeWallMs,
      pt > qpt, pw > qdw
    {
      decodeTokenDelta = Double(pt - qpt) / (pw - qdw) * 1000
      decodeCountersAdvanced = true
    }

    let newDecodeBatch: Bool
    if let batches = status.scheduler?.decodeBatches {
      if let previousBatches = prev?.scheduler?.decodeBatches {
        newDecodeBatch = batches != previousBatches
      } else {
        newDecodeBatch = true
      }
    } else {
      newDecodeBatch = prev == nil || batchChanged || decodeCountersAdvanced
    }

    if newDecodeBatch, let batch = currentBatch,
      batch.valid == true, let rate = batch.tokensPerSecond, rate > 0
    {
      sample.decodeTps = rate
    } else if newDecodeBatch, let rate = decodeTokenDelta {
      sample.decodeTps = rate
    }

    if let pt = m?.prefillInputTokens, let pw = m?.prefillWallMs,
      let qpt = prev?.metrics?.prefillInputTokens, let qpw = prev?.metrics?.prefillWallMs,
      pt > qpt, pw > qpw
    {
      sample.prefillTps = Double(pt - qpt) / (pw - qpw) * 1000
    }

    // Sustained decode, by the same delta-of-cumulative-counters construction as
    // prefill above. Independent of the batch reading, so it stays smooth
    // while `decodeTps` swings on draft acceptance.
    sample.sustainedTps = decodeTokenDelta

    sample.ttftP50Ms = m?.ttftMs?.p50
    sample.ttftP95Ms = m?.ttftMs?.p95
    sample.ttftSamples = m?.ttftMs?.samples
    sample.itlP50Ms = m?.itlMs?.p50
    sample.itlP95Ms = m?.itlMs?.p95
    sample.metalBytes = status.memoryActual?.currentBytes
    // Only `available <= physical` is a real invariant. It is tempting to
    // also require `observed <= physical - available`, but that is wrong:
    // `host_available` adds back reclaimable pages, so `physical − available`
    // is a *lower bound* on system load and can sit below a single process's
    // RSS. Measured 2026-09-29 on the 35B: RSS 35.36 GiB against a computed
    // load of 25.64 GiB, which failed the check and silently nil'd both this
    // series and the memory statistics. Do not re-add that condition.
    if let physical = status.memoryPlan?.device?.physicalMemoryBytes,
      let available = status.memoryGovernor?.hostAvailableBytes,
      status.memoryGovernor?.hostMeasurementValid == true,
      available <= physical
    {
      sample.totalLoadBytes = physical - available
    } else {
      sample.totalLoadBytes = nil
    }
    sample.metalBudgetBytes = status.memoryGovernor?.limitBytes
    sample.kvPagesActive = status.kv?.pagesActive
    sample.kvBlockTokens = status.kv?.blockTokens
    sample.hostAvailableBytes = status.memoryGovernor?.hostAvailableBytes
    sample.pressure = status.memoryPressure ?? status.memoryGovernor?.systemPressure
    sample.draftAcceptance = m?.draftAcceptanceRate
    sample.activeRequests = status.scheduler?.decoding
    sample.deviceName = status.memoryPlan?.device?.deviceName
    sample.familyName = status.memoryPlan?.model?.modelName
    sample.maxContextTokens = status.maximumContextTokens
    sample.nativeContextTokens = status.memoryPlan?.maximumContextTokens
    if let p = status.kv?.pagesResident, let bt = status.kv?.blockTokens {
      sample.kvPoolTokens = p * bt
    }

    if let ct = status.requests?.completed, let cpt = prev?.requests?.completed, ct > cpt,
      let dt = lastSampleDate
    {
      let delta = now.timeIntervalSince(dt)
      if delta > 0.5 {
        sample.requestsPerMin = Double(ct - cpt) / delta * 60
      }
    }
    sample.powerMode = powerMode

    if let last = lastSampleDate {
      sample.gap = now.timeIntervalSince(last) > 30
    }
    lastSampleDate = now

    samples.append(sample)
    // Per-model history is fed here rather than from a second poller, so
    // the long-term aggregates and the live window can never disagree.
    // Keyed on the **live** model from /status, not on config, so an
    // adopted external server is recorded under what it actually serves.
    if let store = history, let model = status.instance?.model ?? fallbackModel, !model.isEmpty {
      store.record(sample, key: conditions.withModel(model))
    }
    // Time-based retention (covers the 5 h max window); the count cap is
    // only a backstop for abnormally fast poll cadences.
    let keepFrom = Self.lowerBound(now.addingTimeInterval(-Self.retentionSeconds), in: samples)
    if keepFrom > samples.startIndex {
      samples.removeSubrange(samples.startIndex..<keepFrom)
    }
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
    markers = markers.filter { $0.date >= now.addingTimeInterval(-3 * 3600) }
    latest = status
    lastStatus = status
  }

  // MARK: - Markers

  func addMarker(label: String, automatic: Bool = false) {
    markers.append(Marker(date: Date(), label: label, automatic: automatic))
    persistMarkers()
  }

  func removeMarker(_ marker: Marker) {
    markers.removeAll { $0.id == marker.id }
    persistMarkers()
  }

  func clearMarkers() {
    markers.removeAll()
    persistMarkers()
  }

  func clearHistory() {
    samples = []
    lastStatus = nil
    lastSampleDate = nil
  }

  private func persistMarkers() {
    if let data = try? JSONEncoder().encode(markers) {
      try? data.write(to: markersURL, options: .atomic)
    }
  }

  // MARK: - Convenience for the hero panels

  var latestDecodeTps: Double? {
    latestDecodeSample?.decodeTps
  }

  private var latestDecodeSample: Sample? {
    samples.last(where: { $0.decodeTps != nil })
  }

  /// Last observed **windowed** prefill rate, held rather than blanked — the
  /// same trick as `latestDecodeTps`, and for the same reason: prefill only
  /// runs on a cache miss, and this engine serves ~97% of prompt tokens from
  /// cache, so a hero demanding a live sample would read "—" almost always.
  ///
  /// The server's own `prefill_tokens_per_second` is NOT usable here. It is
  /// `prefillTokens_ * 1000 / prefillWallMilliseconds_` over lifetime counters
  /// (Status.hpp:206), i.e. a mean that only converges — it drifted 1120 →
  /// 1044 tok/s over twenty minutes with the engine doing nothing but its job,
  /// which reads as "the engine is slowing down" when nothing had changed.
  var latestPrefillTps: Double? {
    latestPrefillSample?.prefillTps
  }

  private var latestPrefillSample: Sample? {
    samples.last(where: { $0.prefillTps != nil })
  }

  /// How stale `latestPrefillTps` is. A held value with no age is
  /// indistinguishable from a live one, which is the same defect as the
  /// lifetime average, so the hero states it rather than implying currency.
  var latestPrefillTpsAge: TimeInterval? {
    guard let s = latestPrefillSample else { return nil }
    return Date().timeIntervalSince(s.date)
  }

  /// Sustained decode throughput, held rather than blanked. This is the hero
  /// figure because it is the one that means "how fast is this model
  /// generating" and the one comparable to the server's own log line.
  var displayTps: Double? {
    if let s = samples.last(where: { $0.sustainedTps != nil })?.sustainedTps { return s }
    return latestDecodeTps
  }

  /// The most recent engine batch, for the hero caption. Not a rate — the
  /// spread comes from speculative-draft acceptance, not engine speed.
  var latestBatchTps: Double? {
    latestDecodeTps
  }

  /// The last observed batch, for its draft-acceptance detail.
  var latestDecodeBatch: StatusDTO.Batch? {
    latest?.metrics?.currentDecodeBatch
  }

  var latestTTFTp95Ms: Double? {
    latest?.metrics?.ttftMs?.p95
  }

  /// Resident KV pool in tokens (matches the pi status line only while idle
  /// right after a request; diverges after compaction as old pages stay retained).
  var kvPoolTokens: Int? {
    guard let p = latest?.kv?.pagesResident, let bt = latest?.kv?.blockTokens else { return nil }
    return p * bt
  }

  /// The limit the server enforces — the denominator for the KV-pool gauge.
  var contextCap: Int? { latest?.maximumContextTokens }

  /// True when splash 1.2.0+ has paged the model weights out and is holding
  /// only the small always-resident buffers.
  ///
  /// Since 1.2.0 the engine unwires every buffer and frees the weights ten
  /// minutes after the last request, restoring them on the next one (measured
  /// 600 s exactly, and a sub-2 s restore on this host). While that state
  /// holds, `memory_actual.current_bytes` sits near the KV/state floor instead
  /// of near `peak_bytes`, so every "x% of budget" figure derived from it
  /// reads as *empty* when the truth is *paged out*. Measured released:
  /// 1.19 GiB against a 21.18 GiB peak — the hero claimed "2% of 51 GiB".
  ///
  /// 1.2.1 publishes `weights.released`, which is the real signal and is used
  /// whenever it is present. Before that the state has to be inferred, and the
  /// test is a comparison against the weight cost — which the DTO already
  /// documents as "a floor, not a time series", so it is the one figure that
  /// cannot itself be paged away.
  ///
  /// The fallback requires an idle engine on purpose: a request in flight is
  /// restoring the weights right now, and calling that "released" would be its
  /// own lie.
  var weightsReleased: Bool {
    guard let s = latest, s.ready == true, s.transport?.statusStale != true else { return false }
    if let authoritative = s.weights?.released { return authoritative }
    guard let weights = s.memoryPlan?.model?.memory?.totalWeightsBytes, weights > 0,
      let current = s.memoryActual?.currentBytes
    else { return false }
    let busy =
      (s.scheduler?.decoding ?? 0) + (s.scheduler?.prefilling ?? 0) > 0
      || (s.scheduler?.queued ?? 0) > 0
    guard !busy else { return false }
    return current < weights
  }

  /// splash's resolved family for the loaded model, e.g. "Qwen3.8-27B".
  /// Prefer this over `instance.model` (the repo id) when keying per-model
  /// constants: `prism-ml/Ternary-Bonsai-2-27B-gguf` reports family
  /// `Qwen3.8-27B`.
  var modelFamily: String? { latest?.memoryPlan?.model?.modelName }

  /// The model's native context window, or nil when the server does not
  /// report one. Equal to `contextCap` when nothing is capping it.
  var contextNative: Int? { latest?.memoryPlan?.maximumContextTokens }

  // MARK: - Menu-bar dot colour
  //
  // The menu bar shows the rate only; the centre dot is the sole carrier of
  // engine state there, so the mapping is kept here where it is assertable.
  // Six distinct hues, so nothing is ambiguous:
  //
  //   green  ok      idle or decoding
  //   blue   busy    prefilling, mask-blocked, or still starting
  //   orange warn    queued, suspended, draining, recovering, stale,
  //                  memory-capped, memory-pressure
  //   red    error   the engine reported a failure
  //   purple —       SplashControl's own start/stop/restart, in flight. An
  //                  *action* rather than a health signal, which is why it
  //                  does not share orange with warn.
  //   grey   —       no server, or nothing heard yet. Absence, not a fault:
  //                  a deliberately stopped server must not read as an error.
  enum DotHue: String, CaseIterable, Equatable {
    case green, blue, orange, red, purple, grey, white, none
  }

  /// Dot diameter as a fraction of the symbol, per hue. **This, not hue, is now
  /// the primary separator between ok and warn** — the colours are bright
  /// enough to see on a coloured menu bar, which they could not be while also
  /// being 3:1 apart. So ok and warn differ by a clear step in size, with a
  /// contrasting outline behind both.
  static func dotWeight(_ hue: DotHue) -> Double {
    switch hue {
    case .none: return 0  // no server: the ring is drawn empty
    case .grey: return 0.34  // up but idle / not known yet
    case .green, .blue, .white: return 0.36  // the resting look
    case .purple: return 0.40
    case .orange: return 0.46  // needs attention: clearly larger than ok
    case .red: return 0.50  // failed: larger still
    }
  }

  /// The dot's calibrated sRGB, 0…1. Kept beside the semantics — rather than
  /// in the AppKit drawing code — so the palette's guarantees are measured
  /// facts about what is actually rendered, and cannot drift away from a
  /// hand-written table.
  ///
  /// These are **presence** colours, chosen to be legible against a coloured
  /// menu bar. An earlier revision deliberately darkened green to reach 3:1
  /// against orange and the dot became nearly invisible on a blue bar:
  /// dot-vs-dot separation was bought at the cost of dot-vs-background. A
  /// contrasting outline (see `dotStrokeFraction`) now carries background
  /// legibility, and dot-vs-dot separation is carried mainly by **size**, so
  /// the hues are free to be bright.
  static func dotRGB(_ hue: DotHue) -> (r: Double, g: Double, b: Double) {
    switch hue {
    case .green: return (0.18, 0.66, 0.31)  // #2EA84F, legible on blue and light
    case .blue: return (0.20, 0.50, 0.95)
    case .orange: return (1.00, 0.72, 0.05)
    case .red: return (0.97, 0.28, 0.26)
    case .purple: return (0.66, 0.42, 0.95)
    case .grey: return (0.55, 0.55, 0.55)
    case .white: return (0.98, 0.98, 0.98)  // prefill: the pre-2026-09-25 look
    case .none: return (0, 0, 0)  // never drawn; kept exhaustive
    }
  }

  /// Outline thickness around the dot, as a fraction of the dot's diameter.
  /// White on a dark/colourful bar, black on a light one, so the dot keeps an
  /// edge on *any* menu bar — including a tinted one, which is the case that
  /// made a dark green dot vanish.
  static let dotStrokeFraction = 0.34

  /// Scale of the dot, which is **always a full filled circle**. Only the
  /// *size* moves, and only on the dim half of a pulse.
  ///
  /// Two channels are now retired for the dim half, both because they removed
  /// the state colour from the screen:
  /// - **alpha** — at 0.30 the grey dim half blended into the larger white
  ///   stroke behind it, so the pulse read as the dot *disappearing*. Low
  ///   alpha is indistinguishable from absent on a dark bar.
  /// - **a hollow ring** — it put a bare coloured ring on screen for the first
  ///   time in the app's life, which is the app's "no server" look. A green
  ///   ring therefore read as a *dead* server, not a working one.
  ///
  /// Shrinking keeps a complete, fully opaque, correctly coloured circle in
  /// every frame, so no state is ever confusable with "no server" and colour
  /// keeps carrying the state while motion carries "working".
  static func dotScale(animating: Bool, phaseBright: Bool) -> Double {
    guard animating else { return 1 }
    return phaseBright ? 1 : 0.6
  }

  /// WCAG relative luminance of `dotRGB`.
  static func dotLuminance(_ hue: DotHue) -> Double {
    let (r, g, b) = dotRGB(hue)
    func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  }

  /// WCAG contrast ratio between two hues, 1…21.
  static func dotContrast(_ a: DotHue, _ b: DotHue) -> Double {
    let (x, y) = (dotLuminance(a), dotLuminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// The SERVER axis. Deliberately distinct from `AgentStatus`, which is the
  /// AGENT axis: "is splash up" and "is the model working" are different
  /// questions, and conflating them is what made `running` swallow the agent
  /// state — a service that was `.running` but not the exact enum case the
  /// icon code expected produced a *dotless* ring while the model was happily
  /// decoding.
  enum ServiceState: Equatable {
    case down  // stopped, or never answered
    case starting
    case restarting
    case up  // serving, whatever the agent is doing
    case failed(String)
  }

  /// What the menu-bar dot renders. One value, produced in one place, so the
  /// icon, the pulse timer and the title cannot disagree about what the state
  /// is — they used to each re-derive it, which is how a fix landed in one
  /// copy and not the others.
  struct TrayLook: Equatable {
    var hue: DotHue
    var blinks: Bool
  }

  /// Service state wins only when the service is not healthy. When it *is*
  /// healthy the agent decides the colour — including "no snapshot yet", which
  /// is a grey "up, don't know yet" and never an empty ring.
  ///
  /// This is the ONLY status→appearance mapping in the app. It used to have two
  /// rivals, `dotHue(status:lifecycleBusy:)` and `dotAnimates(_:snapshot:)`,
  /// neither of which production ever called — but both of which the test suite
  /// exercised, so they stayed green while contradicting this:
  /// `dotHue` sent `.loading` to blue instead of white, and mapped a *missing*
  /// status to the empty ring, which is the exact "no data yet looks like no
  /// server" confusion the grey case exists to prevent. `dotAnimates` argued at
  /// length that the dot must not blink through a decode; this blinks, because
  /// blinking green is what "producing" should look like.
  static func trayLook(service: ServiceState, agent: AgentStatus?) -> TrayLook {
    switch service {
    case .down: return TrayLook(hue: .none, blinks: false)
    case .failed: return TrayLook(hue: .red, blinks: false)
    case .starting, .restarting: return TrayLook(hue: .purple, blinks: false)
    case .up:
      guard let agent else { return TrayLook(hue: .grey, blinks: false) }
      switch agent {
      case .idle: return TrayLook(hue: .grey, blinks: false)
      // The only two blinking states: the model is working on tokens right
      // now. Everything else is a steady fact about the engine, so motion
      // keeps meaning "busy" instead of decorating half the palette.
      case .decoding: return TrayLook(hue: .green, blinks: true)
      case .loading: return TrayLook(hue: .white, blinks: true)
      // `starting` is the *server* axis speaking (ready:false), and a start
      // is an action, not engine pressure — so it takes the service's
      // purple, never a status colour. It used to be blue, a colour the
      // documented palette does not contain.
      case .starting: return TrayLook(hue: .purple, blinks: false)
      // A masked request is waiting its turn, same as a queued one, so it
      // joins the orange group rather than inventing its own.
      case .masked, .queued, .suspended, .draining, .recovering, .stale,
        .budgetCapped, .memoryPressure:
        return TrayLook(hue: .orange, blinks: false)
      case .error, .stopped: return TrayLook(hue: .red, blinks: false)
      }
    }
  }

  // MARK: - Chart scaling policy
  //
  // Display-model constants live here, not in the SwiftUI views, so they are
  // reachable from Scripts/check_core.sh (same reason AgentStatus lives here).

  /// Y-axis ceiling for a chart with no natural upper bound.
  ///
  /// There is deliberately **no per-model decode ceiling**. This used to
  /// return a hardcoded 150 for `Qwen3.8-27B` and 250 for `Qwen3.6-35B`,
  /// taken from eyeballed charts rather than measurement. Both sat 5-6x above
  /// the rates those models actually sustain (~24 and ~97 tok/s), so bars
  /// filled 16-39% of the plot and headroom was invisible — the same symptom
  /// as the bug that put the lookup there in the first place (axis pinned to
  /// something that is not the data), just inverted. Every newly accepted
  /// model would have needed its own constant too. Auto-scaling is the honest
  /// default for a live dashboard: the axis tracks the data.
  ///
  /// Charts with a *physically* meaningful bound still pass one — the memory
  /// chart uses physical RAM in GiB, which is a real limit, not a guess.
  ///
  /// Headroom factor when no fixed ceiling applies. Without it the axis top
  /// would be pinned to the best sample ever seen, so every chart reads as
  /// "running at its maximum" by construction and headroom is never visible.
  static let autoScaleHeadroom = 1.25

  /// Sustained decode throughput in tok/s, from the delta of the server's
  /// cumulative counters. Nil when there is nothing to compare against, so an
  /// idle engine records nothing rather than a zero that drags averages down.
  ///
  /// Static and pure so `check_core.sh` can assert it — the arithmetic is the
  /// hero number, and it must survive a server restart's counter reset without
  /// reporting an absurd rate, which the `>` guards give for free.
  static func sustainedDecode(current: StatusDTO?, previous: StatusDTO?) -> Double? {
    guard let ct = current?.metrics?.decodeOutputTokens,
      let cw = current?.metrics?.decodeWallMs,
      let pt = previous?.metrics?.decodeOutputTokens,
      let pw = previous?.metrics?.decodeWallMs,
      ct > pt, cw > pw
    else { return nil }
    return Double(ct - pt) / (cw - pw) * 1000
  }

  static func autoScaleCeiling(observed: Double) -> Double {
    max(observed, 0.001) * autoScaleHeadroom
  }

  // MARK: - Chart bucketing
  //
  // Moved out of the SwiftUI view because it was **view logic doing per-render
  // work**: `SeriesChart.points` bucketed the whole window on every body
  // evaluation, and SwiftUI re-evaluates a body for any published change.
  // Here it is a pure function, so it is also assertable from
  // Scripts/check_core.sh — which matters because the bucket boundaries decide
  // what the bars mean.

  /// One plotted point. The `id` is **derived, not random**: a fresh `UUID()`
  /// per render makes every mark a brand-new identity, so SwiftUI Charts threw
  /// away all mark geometry and re-ran layout on every poll — the visible cost
  /// was a full chart rebuild every 2 s. `series@bucketStart` is stable across
  /// renders for the same bucket, so an unchanged bucket keeps its mark.
  struct ChartPoint: Identifiable, Equatable {
    var id: String { "\(series)@\(Int(date.timeIntervalSinceReferenceDate))" }
    let date: Date
    let value: Double?
    let series: String
  }

  /// Start of the bucket a sample belongs to. Buckets are aligned to absolute
  /// time, not to the first sample, so a bar's x position means the same thing
  /// whatever the window is.
  static func bucketStart(for date: Date, duration: TimeInterval) -> Date {
    let seconds = date.timeIntervalSinceReferenceDate
    return Date(timeIntervalSinceReferenceDate: (seconds / duration).rounded(.down) * duration)
  }

  /// Mean of one series over the samples sharing a bucket. Nil-valued samples
  /// are skipped (a `gap` is not an average of nothing).
  private struct Accumulator {
    var sum = 0.0
    var count = 0
    mutating func push(_ v: Double?) {
      guard let v else { return }
      sum += v
      count += 1
    }
    var mean: Double? { count > 0 ? sum / Double(count) : nil }
  }

  /// Bucketed series for one chart.
  ///
  /// - Parameters:
  ///   - samples: date-ascending window, already trimmed by the caller.
  ///   - series: one name per plotted series, in the order bars are drawn.
  ///   - extract: pulls a sample's value for the series at the same index.
  ///   - duration: bucket width; 1 (i.e. `window / 60`) yields one bucket per
  ///     minute regardless of how many samples landed in it.
  static func chartPoints(
    samples: ArraySlice<Sample>,
    series: [String],
    duration: TimeInterval,
    extract: (Sample, Int) -> Double?
  ) -> [ChartPoint] {
    guard duration > 0, let first = samples.first?.date, let last = samples.last?.date else {
      return []
    }
    var buckets: [Date: [Accumulator]] = [:]
    for sample in samples where !sample.gap {
      let start = bucketStart(for: sample.date, duration: duration)
      var row = buckets[start] ?? [Accumulator](repeating: Accumulator(), count: series.count)
      for (i, _) in series.enumerated() { row[i].push(extract(sample, i)) }
      buckets[start] = row
    }
    let centre = duration / 2
    // Walk EVERY bucket between the first and last one that has data, not
    // only the ones that do. Skipping empty buckets is what made bars minutes
    // apart render as adjacent: nothing occupied the time between them. A nil
    // value is what makes Charts leave a real gap, so idle reads as idle.
    var out: [ChartPoint] = []
    var start = bucketStart(for: first, duration: duration)
    let end = bucketStart(for: last, duration: duration)
    while start <= end {
      let date = start.addingTimeInterval(centre)
      let row = buckets[start]
      for (i, name) in series.enumerated() {
        out.append(ChartPoint(date: date, value: row?[i].mean, series: name))
      }
      start = start.addingTimeInterval(duration)
    }
    return out
  }

  // MARK: - Agent status

  /// Engine state from the last poll. Nil when the server has never answered,
  /// so callers can tell "no data yet" from "idle".
  var agentStatus: AgentStatus? { AgentStatus.derive(from: latest) }

  /// Secondary facts behind `agentStatus`, e.g. "2 queued · 1.5 s" — the counts
  /// the single status word has to drop. Nil when there is nothing to add.
  var agentStatusDetail: String? {
    guard let s = latest, let status = agentStatus else { return nil }
    return AgentStatus.detail(from: s, for: status)
  }
}
