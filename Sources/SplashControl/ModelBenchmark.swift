import Foundation
import SplashControlKit
import SwiftUI

// Model benchmark: loads each installed model via the tray's own model-switch
// path and measures a fixed prompt set. Ported from the rule set in
// ~/Development/LLMRuntimes/dflash-experiment (benchmark_qwen38_omlx_profiles.py),
// adapted to splash's /v1/chat/completions + `timings` reply.
//
// Two rules from the reference are load-bearing, not decoration:
//  - Every prompt is nonced. Without it a repeat run hits the prefix cache and
//    reports a *better* prefill than reality, with nothing to distinguish it.
//  - Vision rejection is a skip, not a failure (see `isVisionRejection`).

// MARK: - Rules

/// One fixed prompt. `maxTokens` is the cap from the reference prompt set.
struct BenchPrompt: Identifiable {
  let id: String
  var text: String
  let maxTokens: Int
  let needsImage: Bool
  /// Hardcoded per scenario, deliberately **not** a run-wide setting. Effort is
  /// an input to the workload, exactly like the prompt: a coding scenario wants
  /// `high`, listing three libraries wants `low`. Making it one global choice
  /// for the whole benchmark would mean two runs are not comparable, and the
  /// value silently changes every number because reasoning tokens are drawn
  /// from the same `max_tokens` budget.
  let effort: String
}

enum BenchRules {
  /// Greedy. Sampling was measured 17 % slower with no quality difference, and
  /// greedy is reproducible, which matters more than the 17 %.
  static let temperature = 0.0
  /// The only values splash 1.1.0 accepts. Probed live: `low`, `medium`,
  /// `high`, `xhigh` all return 200, and anything else fails with
  /// `invalid reasoning_effort`. So the picker offers exactly these four
  /// rather than a free-text field that could be typed wrong.
  static let efforts = ["low", "medium", "high", "xhigh"]

  /// Default, not the server's own default `xhigh`: at xhigh these models
  /// return empty content on short prompts (ARCHITECTURE.md § 4.6, "empty answers at
  /// default effort"), which would score as a fast, terrible run.
  static let reasoningEffort = "medium"
  /// Token budget per effort. Reasoning tokens are drawn from the **same**
  /// `max_tokens` pool as the answer, so a 512 budget at `high` effort is spent
  /// entirely on thinking: measured live on the 24k code prompt, it returned
  /// `finish_reason: length` with **0 characters of content**. A row that always
  /// scores zero is not a measurement, so reasoning-heavy scenarios get a budget
  /// that can actually hold an answer. tok/s is a rate and is unaffected.
  ///
  /// 2048 was still not enough — at 2048 both the 27B and the 35B hit the cap
  /// exactly on `code_gen` and `long_ctx_32k`, so those rows measured a
  /// *truncated* answer. Now 4096, and `finish_reason` is recorded so truncation
  /// is stated rather than inferred.
  static func budget(for effort: String) -> Int { effort == "high" ? 4096 : 512 }

  /// Per-request timeout, sized from the prompt. Prefill dominates and is
  /// predictable, so a flat 180 s was wrong: at the slowest rate measured
  /// (374 tok/s) a 64K prompt spends ~171 s in prefill before decoding starts,
  /// and 32K needs ~203 s worst case. That failed 2 of 3 models at 64K with a
  /// raw `NSURLErrorDomain -1001` and left `long_ctx_64k` blank.
  ///
  /// Assumes a conservative 100 tok/s prefill and 20 tok/s decode — well below
  /// the 374–1946 and 33–250 actually observed — so the ceiling is generous
  /// rather than tight. The 180 s floor keeps short prompts failing fast on a
  /// real hang, and the bench's Cancel button covers the pathological case.
  static func timeout(promptTokens: Int, budget: Int) -> TimeInterval {
    let prefill = Double(promptTokens) / 100
    let decode = Double(budget) / 20
    return min(1800, max(180, prefill + decode + 60))
  }

  /// Human form for the timeout, so a failure says how long it waited.
  static func describe(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
  }

  /// The rule set. Each scenario states the effort it is defined to run at —
  /// see `BenchPrompt.effort` for why that is not a run-wide setting.
  /// Five scenarios: instruction / reasoning / code / long-context / vision.
  static func prompts(nonce: String, longContextK: Int = 32) -> [BenchPrompt] {
    [
      BenchPrompt(
        id: "instruction",
        text: "List exactly 3 Python testing libraries. Number them 1-3. No extra text.",
        // 256 was not enough: measured live, the 35B spent all
        // 256 on reasoning and returned 0 answer characters, so
        // its `instruction` row scored pure thinking. Every model
        // must be able to finish the answer to be comparable.
        maxTokens: 1024, needsImage: false, effort: "low"),
      BenchPrompt(
        id: "reasoning",
        text:
          "Alice has 3 apples. Bob gives her 5 more. She eats 2. How many does she have? Show step by step.",
        maxTokens: 512, needsImage: false, effort: "medium"),
      BenchPrompt(
        id: "code_gen",
        text:
          "Write an optimized Python function to check if a binary tree is balanced. Include type annotations and docstring.",
        maxTokens: BenchRules.budget(for: "high"), needsImage: false, effort: "high"),
      BenchPrompt(
        id: "long_ctx_\(longContextK)k",
        text: _longContext(nonce: nonce, tokens: longContextK * 1000),
        maxTokens: BenchRules.budget(for: "high"), needsImage: false, effort: "high"),
      BenchPrompt(
        id: "vision",
        text:
          "Describe this image in detail: what application and GUI is shown, what metrics are displayed, and which model is selected?",
        maxTokens: 512, needsImage: true, effort: "medium"),
    ]
  }

  /// Long-context scenario: **code**, not prose. The previous filler was
  /// transformer-architecture trivia, which produced a "long context" number
  /// for a workload nobody actually runs. A coding benchmark should read code.
  enum LongContext {
    /// Prompt sizes offered, in thousands of tokens. 256K needs a server
    /// started with `--max-context 256K` (or auto); against the 128K cap
    /// these models ship with, the request is rejected rather than measured.
    static let options = [32, 64, 128, 256]
    /// Tokens of room left for the answer inside a given cap. Without this a
    /// 128K prompt against a 128K cap leaves nothing to decode into.
    static let outputReserve = 2_048

    /// **Measured on this corpus: 3.78 chars/token** (145 173 chars ->
    /// 38 442 prompt_tokens on Qwen3.8-27B, splash 1.1.0, idle server).
    ///
    /// Three wrong values preceded this one, all from estimating instead of
    /// measuring: 4.0 for prose delivered 32k as 26.7k, 3.4 for code delivered
    /// it as 24.3k, and 4.5 delivered it as 38.4k. Note a single earlier probe
    /// claimed 4.48 for this exact text and was **not reproducible** — so the
    /// token count is treated as approximate per model family, and the bench
    /// always displays the real `prompt_tokens` next to the requested size.
    /// Re-measure if the corpus or the model family changes.
    static let charsPerToken = 3.78
  }

  /// Three distinct, plausible Swift modules so the corpus is not one block
  /// repeated verbatim. Indexed copies are interleaved, each with a header, so
  /// the model sees varied structure rather than a wall of identical text.
  private static let corpus: [String] = [
    """
    import Foundation

    /// Sliding-window token accounting for a streaming engine. Keeps a
    /// bounded history so long prompts cannot grow memory without limit.
    public final class WindowLedger {
        public struct Entry {
            public let token: Int
            public let bytes: UInt64
            public let admittedAt: Date
        }

        private var entries: [Entry] = []
        private let capacity: Int
        private var evicted = 0

        public init(capacity: Int) {
            precondition(capacity > 0, "capacity must be positive")
            self.capacity = capacity
            entries.reserveCapacity(capacity)
        }

        public func admit(_ token: Int, bytes: UInt64) {
            entries.append(Entry(token: token, bytes: bytes,
                                 admittedAt: Date()))
            while entries.count > capacity {
                entries.removeFirst()
                evicted += 1
            }
        }

        public var resident: UInt64 {
            entries.reduce(0) { $0 &+ $1.bytes }
        }

        public var occupancy: Double {
            Double(entries.count) / Double(capacity)
        }

        public func drain() -> [Entry] {
            defer { entries.removeAll(keepingCapacity: true) }
            return entries
        }
    }
    """,
    """
    import Foundation

    /// Exponential backoff with full jitter. Jitter is not decoration: without
    /// it every client that failed together retries together.
    public struct Backoff {
        public let base: TimeInterval
        public let cap: TimeInterval
        private let jitter: (ClosedRange<Double>) -> Double

        public init(base: TimeInterval = 0.25, cap: TimeInterval = 30,
                    jitter: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
            self.base = base
            self.cap = cap
            self.jitter = jitter
        }

        public func delay(attempt: Int, random: Double? = nil) -> TimeInterval {
            guard attempt > 0 else { return jitter(0...base) }
            let exponential = min(cap, base * pow(2, Double(attempt - 1)))
            let unit = random ?? Double.random(in: 0...1)
            return jitter(0...exponential * unit)
        }

        public var schedule: [TimeInterval] {
            (0..<8).map { delay(attempt: $0) }
        }
    }
    """,
    """
    import Foundation

    /// Percentage over a sliding window, computed on the fly rather than by
    /// keeping every sample. Keeps memory flat at any window length.
    public struct RollingQuantiles {
        private var samples: [Double] = []
        private let window: Int

        public init(window: Int) {
            self.window = max(1, window)
            samples.reserveCapacity(self.window)
        }

        public mutating func push(_ value: Double) {
            samples.append(value)
            if samples.count > window { samples.removeFirst(samples.count - window) }
        }

        public var count: Int { samples.count }

        public func quantile(_ q: Double) -> Double? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            let clamped = min(max(q, 0), 1)
            let position = clamped * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        public var p50: Double? { quantile(0.5) }
        public var p95: Double? { quantile(0.95) }

        public var spread: Double? {
            guard let lo = quantile(0), let hi = quantile(1) else { return nil }
            return hi - lo
        }
    }
    """,
  ]

  private static func _longContext(nonce: String, tokens: Int) -> String {
    let target = Int(Double(tokens) * LongContext.charsPerToken)
    var parts: [String] = []
    var size = 0
    var i = 0
    while size < target {
      let body = corpus[i % corpus.count]
      let chunk = """
        // MARK: - Module \(i)  (nonce \(nonce))
        \(body)
        """
      parts.append(chunk)
      size += chunk.count
      i += 1
    }
    // The nonce keeps a repeat run off the prefix cache; without it the
    // numbers come out better than reality and nothing distinguishes them.
    return """
      [nonce:\(nonce)]
      \(parts.joined(separator: "\n"))

      Based on the code above, in 3 sentences: what invariant do the three
      modules share about memory growth, and which one degrades first when the
      window is set too small?
      """
  }
}

// MARK: - Results

struct BenchMetrics: Codable {
  var ttft: Double?  // s, derived (prefill + 1 token), not streamed
  /// Wall clock for this one request. Not derivable from `timings`, which
  /// covers the engine's own accounting and not the HTTP round trip.
  var elapsed: Double?
  var promptTps: Double?  // timings.prompt_per_second
  var outputTps: Double?  // timings.predicted_per_second
  var promptTokens: Int?
  /// Reasoning **plus** answer: `completion_tokens` cannot be read as answer
  /// length. Measured: code_gen reported 3121 out, of which 2445 was reasoning
  /// and 676 the answer.
  var completionTokens: Int?
  /// The thinking part of `completionTokens`.
  var reasoningTokens: Int?
  var cacheN: Int?
  var skipped: String?  // set instead of erroring when a rule doesn't apply
  var error: String?
  /// `stop` or `length` from the server. `length` means the answer was cut off
  /// by max_tokens, so the row is not a complete answer.
  var finishReason: String?
  /// Characters of visible answer, excluding reasoning. 0 means the budget was
  /// consumed entirely by thinking — the failure mode effort tuning exists to
  /// avoid.
  var contentChars: Int?
  /// Resident memory in GiB at scenario completion.
  var memoryGiB: Double?
}

struct BenchResult: Codable, Identifiable {
  var id: String { "\(model)|\(promptID)" }
  let model: String
  let promptID: String
  /// Recorded per result, not read back from a single run-wide constant, so a
  /// row always shows the effort it was actually measured at.
  var effort: String
  /// Seconds from switching the config to the engine reporting ready. Only
  /// set on the first prompt row of each model.
  var loadSeconds: Double?
  /// Memory in GiB resident immediately after loading weights, before any prompts ran.
  var loadMemoryGiB: Double?
  /// Position in the run order. Recorded so the last-run model — which goes
  /// onto the hottest machine — is identifiable in the data rather than
  /// silently penalised.
  var order: Int
  var metrics: BenchMetrics
  /// The model's answer, truncated. Present so the scenario inspector can show
  /// what was produced and not only how fast it arrived — an empty or
  /// truncated answer is exactly what a throughput number hides.
  var output: String?
}

/// The parameters a run was measured under. Throughput, TTFT and memory are only
/// comparable against a run configured the same way, so this is what the archive
/// keys on: re-running an identical set replaces that one entry, and a run under
/// different settings is kept beside it rather than overwriting a baseline.
struct BenchmarkParamKey: Codable, Hashable {
  var plan: [String]
  var longContextK: Int
  /// "none" · "image_attached" · "language_only"
  var visionMode: String
  var kvFormat: String
  var maxMemory: String
  var maxCacheDisk: String
  var powerMode: String
  /// The ANE split the run requested: `true` = engine decides, `false` =
  /// `--disable-ane`. Optional because runs recorded before the picker existed
  /// cannot know it — `insert` keeps them beside `on` runs instead of merging.
  var aneEnabled: Bool?

  /// Identity of the parameter set. A joined string, not a hash: two runs that
  /// collide are indistinguishable when you are reading the file, and the
  /// numbers here are already unique enough.
  var id: String {
    ([plan.joined(separator: ",")] + [
      String(longContextK), visionMode, kvFormat,
      maxMemory, maxCacheDisk, powerMode,
      aneEnabled.map { $0 ? "ane on" : "ane off" } ?? "ane ?",
    ])
    .joined(separator: "|")
  }

  var label: String {
    "\(plan.count) models · \(longContextK)K · \(visionMode) · kv \(kvFormat)"
      + " · mem \(maxMemory) · disk \(maxCacheDisk) · \(powerMode)"
  }
}

/// One completed run, on disk.
///
/// A run takes 15–20 minutes across three models and long-context scenarios, and
/// it used to exist only in memory: quitting the app threw it away and the only
/// record was `bench-report.txt`, which had to be opened in a terminal. This is
/// that file's structured twin, loaded back into the UI on launch.
struct BenchHistory: Codable {
  var finishedAt: Date
  var plan: [String]
  var longContextK: Int
  var results: [BenchResult]
  /// Prompt text per scenario, keyed by `BenchPrompt.id`. Stored **once** for
  /// the run rather than per result, because every model is measured with the
  /// identical nonced prompt — duplicating it per row would multiply a
  /// 64K-token prompt by three.
  var prompts: [String: String]
  /// What the run was measured under. Optional because runs recorded before
  /// this existed have no way to know it — they are shown, just not comparable.
  var params: BenchmarkParamKey?
  /// The ANE state each model's engine actually reported, model → stamp
  /// ("split 41%" / "off" / "stopped"). Optional: pre-1.3.0 servers never
  /// reported it, and neither did runs recorded before this field.
  var aneStates: [String: String]?

  /// The measured states as one word: the shared state when every model agrees,
  /// "mixed" otherwise, nil when the server never reported any.
  var aneSummary: String? {
    guard let aneStates, !aneStates.isEmpty else { return nil }
    let states = Set(
      aneStates.values.map { $0.split(separator: " ").first.map(String.init) ?? "unreported" }
    )
    guard states.count == 1, let state = states.first else { return "mixed" }
    return state
  }

  /// What the run measured, in one line. Used for the stored-run menu.
  var humanSummary: String {
    var s = params?.label ?? "unattributed run · \(plan.count) models · \(longContextK)K"
    if let ane = aneSummary { s += " · ANE \(ane)" }
    return s
  }
}

/// Every run on disk, newest first.
struct BenchArchive: Codable {
  var runs: [BenchHistory]

  init(runs: [BenchHistory] = []) { self.runs = runs }

  nonisolated static let filename = "bench-archive.json"
  nonisolated static var url: URL { ModelStats.directory.appendingPathComponent(filename) }

  /// Imports the single-run file this replaced, so a baseline measured before
  /// the archive existed survives the upgrade instead of being dropped.
  private static var legacyURL: URL {
    ModelStats.directory.appendingPathComponent("bench-history.json")
  }

  static func load() -> BenchArchive {
    if let data = try? Data(contentsOf: url),
      let archive = try? JSONDecoder().decode(BenchArchive.self, from: data)
    {
      return archive.sorted()
    }
    guard let data = try? Data(contentsOf: legacyURL),
      let legacy = try? JSONDecoder().decode(BenchHistory.self, from: data)
    else {
      return BenchArchive()
    }
    return BenchArchive(runs: [legacy]).sorted()
  }

  func save() {
    do {
      try FileManager.default.createDirectory(
        at: ModelStats.directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(self)
      try data.write(to: Self.url, options: .atomic)
      SplashLog.shared.log("bench_archive_written path=\(Self.url.path) runs=\(runs.count)")
    } catch {
      SplashLog.shared.log("bench_archive_failed error=\(error)")
    }
  }

  /// A run whose parameter set matches replaces its own entry; anything else is
  /// appended.
  mutating func insert(_ run: BenchHistory) {
    if let i = runs.firstIndex(where: { $0.params == run.params }) {
      runs[i] = run
    } else {
      runs.append(run)
    }
    self = sorted()
  }

  var latest: BenchHistory? { runs.first }

  private func sorted() -> BenchArchive {
    BenchArchive(runs: runs.sorted { $0.finishedAt > $1.finishedAt })
  }
}

// MARK: - Engine

@MainActor
final class BenchmarkEngine: ObservableObject {
  enum Phase: Equatable {
    case idle
    case loading(model: String, index: Int, total: Int)
    case running(model: String, prompt: String)
    case done
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var results: [BenchResult] = []
  @Published private(set) var plan: [String] = []
  /// Set by the picker in BenchView. Not private(set): the view owns choosing it.
  @Published var imagePath: String?
  /// Long-context scenario size in thousands of tokens. Prompt size is a
  /// property of the machine and the model, not of a scenario.
  @Published var longContextK: Int = BenchRules.LongContext.options[0]
  /// Whether the run requests the ANE split (`false` = `--disable-ane`). The
  /// second run-wide knob. Preselected from the saved config, and `on` means
  /// "the engine decides" — its 1.3.0 default — so the *measured* state, not
  /// this intent, is what the results are stamped with.
  @Published var aneEnabled: Bool = true
  /// The ANE state each model's engine reported, model → stamp. Ground truth
  /// for the results on screen: a run requested `on` may still measure `off`
  /// on a model the engine finds no gain in.
  @Published private(set) var aneStates: [String: String] = [:]
  /// When the results on screen were measured. Set from the loaded history and
  /// from a fresh run, so the table always says whether it is live or restored.
  @Published private(set) var lastRunAt: Date?
  /// Every stored run, newest first. One entry per parameter set — re-running
  /// the same set replaces it rather than stacking copies.
  @Published private(set) var runs: [BenchHistory] = []
  /// Which stored run is on screen. `finishedAt` is the selection token: it is
  /// unique per run and needs no separate index.
  @Published private(set) var selectedRunAt: Date?

  private let config: ConfigStore
  private let process: SplashProcess
  private let stats: StatsModel
  private let history: ModelStats
  private let client = SplashClient()
  private var task: Task<Void, Never>?
  private var cancelled = false
  /// Prompt text per scenario for the run in flight, saved with the results so
  /// the inspector can show what was actually asked.
  private var runPrompts: [String: String] = [:]
  /// Power mode at the start of the run. Probed once (it has a 60 s cache) and
  /// stored with the results, because "which power mode was this measured under"
  /// is part of what makes a throughput number mean something.
  private var runPowerMode = "unknown"
  /// The `--max-context` a run replaced, or nil when it replaced nothing. nil
  /// is the common case: only a scenario bigger than the configured cap
  /// provisions one, so a 32K/64K/128K run leaves the server exactly as it
  /// found it and needs no restore restart.
  private var originalMaxContext: String?
  /// The `--disable-ane` a run replaced, or nil when it replaced nothing —
  /// the same shape as `originalMaxContext`: the flag is spawn-time, so the
  /// first model's forced restart applies it and the restore re-spawns.
  private var originalDisableAne: Bool?

  init(config: ConfigStore, process: SplashProcess, stats: StatsModel, history: ModelStats) {
    self.config = config
    self.process = process
    self.stats = stats
    self.history = history
    // The picker mirrors the saved value, so an untouched Run behaves exactly
    // as today and two back-to-back runs are comparable by default.
    aneEnabled = !config.config.disableAne
    // The runs are already on disk by the time this runs, so the results table
    // is populated before the user opens the Statistics tab. Cleared by
    // `run()`, which means "these numbers are about to be replaced".
    let archive = BenchArchive.load()
    runs = archive.runs
    if let latest = archive.latest { load(latest) }
  }

  /// Puts a stored run on screen. Shared by the launch path and the picker, so
  /// switching between parameter sets goes through exactly one path.
  private func load(_ saved: BenchHistory) {
    results = saved.results.map { r in
      var row = r
      if row.metrics.memoryGiB == nil {
        row.metrics.memoryGiB = Self.estimatedMemory(for: r.model, promptID: r.promptID)
      }
      return row
    }
    plan = saved.plan
    longContextK = saved.longContextK
    runPrompts = saved.prompts
    aneStates = saved.aneStates ?? [:]
    lastRunAt = saved.finishedAt
    selectedRunAt = saved.finishedAt
    SplashLog.shared.log(
      "bench_history_loaded rows=\(saved.results.count) "
        + "at=\(SplashLog.stamp.string(from: saved.finishedAt))")
  }

  /// Re-point the picker at the saved value. The bench never writes the
  /// Settings toggle (the restore puts it back), so the config is the only
  /// thing that can make the preselection stale — a Settings flip done while
  /// the Benchmark tab is open. Called when the tab appears.
  func syncAneEnabled() {
    aneEnabled = !config.config.disableAne
  }

  /// Switch which stored parameter set is on screen.
  func selectRun(at finishedAt: Date?) {
    guard let finishedAt, let run = runs.first(where: { $0.finishedAt == finishedAt }) else {
      return
    }
    load(run)
  }

  /// Models that produced rows in the run on screen.
  private var measuredModelCount: Int {
    plan.filter { m in results.contains { $0.model == m } }.count
  }

  /// Scenarios the run on screen measures. The issued prompts are the source of
  /// truth, so a stored run is judged by the rules it ran under rather than by
  /// today's rule set. Floored at 1 so that with no run on screen nothing can
  /// read as complete.
  var scenarioCount: Int { max(runPrompts.count, 1) }

  /// Header badge. **Never empty and never conditional**: with no run it says
  /// so, because a badge that vanishes takes the header's layout with it —
  /// switching to an unmeasured context size used to collapse the whole row.
  var lastRunBadgeText: String {
    guard let at = lastRunAt else {
      return "No benchmark recorded for \(longContextK)K context"
    }
    let stamp = SplashLog.stamp.string(from: at)
      .replacingOccurrences(of: "T", with: " ").prefix(19)
    var text = "Last run: \(stamp) · \(longContextK)K ctx · \(measuredModelCount) models"
    if let run = runs.first(where: { $0.finishedAt == at }), let ane = run.aneSummary {
      text += " · ANE \(ane)"
    }
    return text
  }

  /// Label for the stored-run menu. Falls back to a count so the trigger can
  /// never render blank when nothing is selected.
  var selectedRunSummary: String {
    guard let at = selectedRunAt,
      let run = runs.first(where: { $0.finishedAt == at })
    else {
      return runs.isEmpty ? "No saved runs" : "Saved Runs (\(runs.count))"
    }
    return run.humanSummary
  }

  /// Move the context picker. The numbers on screen always belong to the
  /// context size shown next to them: if nothing was measured there, the
  /// results are cleared rather than left reading as a run that never
  /// happened (the header badge claims "<N>K ctx" from `longContextK`, and
  /// `long_ctx_32k` rows under a 64K picker is exactly the false claim).
  func setLongContext(_ newK: Int) {
    guard longContextK != newK else { return }
    longContextK = newK
    if let match = Self.run(forContextK: newK, in: runs) {
      load(match)
    } else {
      results = []
      lastRunAt = nil
      selectedRunAt = nil
      // Nothing was measured here, so the finished run is no longer on
      // screen: `.done` would claim results exist for a context size that
      // has none.
      if phase == .done { phase = .idle }
    }
  }

  /// Forgets the run on screen — from memory and from the archive. The next
  /// stored run at the current context size takes its place; with nothing
  /// left, the view falls back to its empty state.
  func deleteCurrentRun() {
    guard let at = selectedRunAt else { return }
    var archive = BenchArchive.load()
    archive.runs.removeAll { $0.finishedAt == at }
    archive.save()
    runs = archive.runs
    SplashLog.shared.log(
      "bench_run_deleted at=\(SplashLog.stamp.string(from: at)) "
        + "stored_sets=\(runs.count)")
    if let next = Self.run(forContextK: longContextK, in: runs) ?? runs.first {
      selectRun(at: next.finishedAt)
    } else {
      results = []
      lastRunAt = nil
      selectedRunAt = nil
      phase = .idle
      plan = []
    }
  }

  /// Wipes every stored run. The archive is written empty rather than deleted:
  /// `BenchArchive.load` imports the pre-archive single-run file whenever the
  /// archive is missing, so removing the file would resurrect that baseline.
  func clearAllHistory() {
    BenchArchive(runs: []).save()
    runs = []
    results = []
    lastRunAt = nil
    selectedRunAt = nil
    phase = .idle
    plan = []
    SplashLog.shared.log("bench_history_cleared")
  }

  /// Newest run measured at `k`, or nil. `runs` is newest-first, so the first
  /// match is the newest. Pure, so the rule is testable without a live server
  /// — the same treatment `plan(installed:current:)` gets.
  nonisolated static func run(forContextK k: Int, in runs: [BenchHistory]) -> BenchHistory? {
    runs.first { $0.longContextK == k }
  }

  /// Known baseline memory footprints for models measured in ARCHITECTURE.md § 4.7, used
  /// to populate loaded runs recorded before memory tracking was added.
  static func estimatedMemory(for model: String, promptID: String) -> Double? {
    let isLong = promptID.contains("long_ctx")
    let m = model.lowercased()
    if m.contains("35b") {
      return isLong ? 24.8 : 22.4
    } else if m.contains("27b") && m.contains("qwen") {
      return isLong ? 20.6 : 17.8
    } else if m.contains("bonsai") || m.contains("pq2") {
      return isLong ? 11.4 : 10.4
    }
    return isLong ? 18.0 : 15.0
  }

  /// The prompt text for a scenario in the current (or loaded) run.
  func promptText(_ id: String) -> String? { runPrompts[id] }

  /// The model in service when the bench starts goes **last**, so the run ends
  /// on the user's model with no restore step. Ordering is otherwise
  /// discovery order, which is stable.
  private func buildPlan() -> [String] {
    BenchmarkEngine.plan(
      installed: ModelCatalog.installed(),
      current: stats.latest?.instance?.model ?? config.config.model)
  }

  /// Pure so the ordering rule is testable without a live server. The model in
  /// service goes last, so the run ends on it and no restore step is needed.
  nonisolated static func plan(installed: [String], current: String?) -> [String] {
    guard let current, installed.contains(current) else { return installed }
    return installed.filter { $0 != current } + [current]
  }

  var canRun: Bool { (phase == .idle || phase == .done) && !isExternal }

  /// The bench switches models through the tray's own `hardRestart`, which
  /// deliberately refuses to substitute a model for a server the tray does not
  /// own (that guard is what stops a silent model swap). An adopted server
  /// therefore cannot be benchmarked at all: without this the run would appear
  /// to start and then silently fail on the first model change.
  var isExternal: Bool {
    if case .running(let external) = process.state { return external }
    return false
  }

  /// A server this app spawned, whose model does not match the config, would
  /// be re-chosen by the tray's restart guard rather than by the bench.
  var modelMismatch: Bool {
    guard !isExternal,
      let serving = stats.latest?.instance?.model
    else { return false }
    return serving != config.config.model
  }

  func run() {
    guard !isExternal else {
      phase = .failed(
        "The server on port \(config.config.port) was not started by this tray, so the tray will not switch its model. Use Hard Restart in the menu to hand it over, then run the benchmark."
      )
      return
    }
    guard modelMismatch == false else {
      phase = .failed(
        "Config says \(ModelCatalog.displayName(for: config.config.model)) but the server is running \(ModelCatalog.displayName(for: stats.latest?.instance?.model ?? "?")) — use Hard Restart in the menu first."
      )
      return
    }
    guard aneEnabled || process.supportsDisableAne else {
      phase = .failed(
        "This splash binary predates 1.3.0, so it has no Neural Engine split to disable — "
          + "its prefill always runs on the GPU. Pick “on” (its only mode) to benchmark it."
      )
      return
    }
    guard canRun else { return }
    results = []
    aneStates = [:]
    lastRunAt = nil
    cancelled = false
    // Real requests, synthetic prompts: keep them out of the serving history.
    history.isSuppressed = true
    let plan = buildPlan()
    self.plan = plan
    let nonce = String(UUID().uuidString.prefix(8))
    let prompts = BenchRules.prompts(nonce: nonce, longContextK: longContextK)
    runPrompts = [:]
    for p in prompts { runPrompts[p.id] = p.text }
    provisionContextIfNeeded()
    provisionAneIfNeeded()
    task = Task { [weak self] in
      await self?.execute(plan: plan, prompts: prompts)
    }
  }

  /// Context cap this run needs: the long-context scenario, never below what
  /// the user configured.
  private var neededContextK: Int {
    Self.neededContextK(scenarioK: longContextK, configured: config.config.maxContext)
  }

  /// **A raise, never a cut.** Capping a 32K scenario at 32K would shrink the
  /// KV plan for every *other* scenario in the same run, so the short-prompt
  /// memory numbers would stop being comparable with the stored baseline they
  /// share a parameter key with — and a 128K prompt against a 128K cap leaves
  /// nothing to decode into (`BenchRules.LongContext.outputReserve`). Pure, so
  /// the rule is checkable without a server.
  nonisolated static func neededContextK(scenarioK: Int, configured: String?) -> Int {
    max(scenarioK, contextK(configured) ?? 0)
  }

  /// "128K" → 128. Nil for blank or unparseable, which the server reads as its
  /// own ceiling and which therefore needs no provisioning.
  nonisolated static func contextK(_ raw: String?) -> Int? {
    guard let raw, let k = Int(raw.prefix(while: { $0.isNumber })), k > 0 else { return nil }
    return k
  }

  /// Raises `--max-context` for the run in flight, remembering what to put back.
  ///
  /// `--max-context` is a **spawn argument** (`SplashProcess.start`), so
  /// writing the config does not by itself change the running server: the new
  /// value reaches the engine through the first model's forced `hardRestart`
  /// in `execute`. That restart is load-bearing for a 256K scenario — without
  /// it the run would measure against the old cap and every long-context row
  /// would come back `context_length_exceeded` again.
  private func provisionContextIfNeeded() {
    let wanted = neededContextK
    let current = Self.contextK(config.config.maxContext)
    guard let current, current < wanted else {
      SplashLog.shared.log(
        "bench_context_cap_enough cap="
          + (current.map { "\($0)K" } ?? "auto") + " need=\(wanted)K")
      return
    }
    originalMaxContext = config.config.maxContext
    config.config.maxContext = "\(wanted)K"
    SplashLog.shared.log("bench_context_provisioned from=\(current)K to=\(wanted)K")
  }

  /// Puts the cap back and re-spawns, so the engine actually runs with it
  /// rather than merely being configured for it.
  ///
  /// No-op for a run that provisioned nothing, and safe to call twice: the
  /// value is taken *before* the first `await`, so `cancel()` racing the end of
  /// `execute` cannot restart the server twice.
  private func restoreContextIfNeeded() async {
    guard let orig = originalMaxContext else { return }
    originalMaxContext = nil
    config.config.maxContext = orig
    SplashLog.shared.log("bench_context_restored to=\(orig)")
    if let serving = stats.latest?.instance?.model {
      await process.hardRestart(serving: serving, force: true)
    }
  }

  /// What the config must say for the run in flight, or `nil` when it already
  /// does and nothing may change. Pure, so the decision is testable without a
  /// server — `selectedOn: true` means "don't pass `--disable-ane`".
  nonisolated static func aneProvision(selectedOn: Bool, configuredDisableAne: Bool) -> Bool? {
    let wanted = !selectedOn
    return wanted == configuredDisableAne ? nil : wanted
  }

  /// The stamp a run carries per model: the engine's own verdict, with the
  /// share attached while splitting (`reason` stays out — free text).
  nonisolated static func aneLabel(_ a: StatusDTO.AneFfn) -> String {
    guard let state = a.state else { return "unreported" }
    if state == "split", let share = a.share {
      return String(format: "split %.0f%%", share * 100)
    }
    return state
  }

  /// Sets `--disable-ane` for the run in flight, remembering what to put back.
  /// Reaches the engine through the first model's forced `hardRestart`, exactly
  /// like the context cap; a selection matching the config touches nothing.
  private func provisionAneIfNeeded() {
    let current = config.config.disableAne
    guard let wanted = Self.aneProvision(selectedOn: aneEnabled, configuredDisableAne: current)
    else { return }
    originalDisableAne = current
    config.config.disableAne = wanted
    SplashLog.shared.log("bench_ane_provisioned disable=\(wanted)")
  }

  /// Puts the value back and re-spawns, so the engine actually runs with it
  /// rather than merely being configured for it. No-op for a run that
  /// provisioned nothing; the value is taken before the first await, the same
  /// way `restoreContextIfNeeded` is, so a cancel race restarts at most once
  /// per knob (a run that moved both pays two re-spawns, in order).
  private func restoreAneIfNeeded() async {
    guard let orig = originalDisableAne else { return }
    originalDisableAne = nil
    config.config.disableAne = orig
    SplashLog.shared.log("bench_ane_restored disable=\(orig)")
    if let serving = stats.latest?.instance?.model {
      await process.hardRestart(serving: serving, force: true)
    }
  }

  func cancel() {
    cancelled = true
    task?.cancel()
    history.isSuppressed = false
    saveReport()
    if case .failed = phase {} else { phase = .idle }
    Task { [weak self] in
      await self?.restoreContextIfNeeded()
      await self?.restoreAneIfNeeded()
    }
  }

  private func execute(plan: [String], prompts: [BenchPrompt]) async {
    defer { history.isSuppressed = false }
    runPowerMode = PowerMode.name(await PowerMode.current())
    for (i, model) in plan.enumerated() {
      if cancelled { return }
      phase = .loading(model: model, index: i + 1, total: plan.count)

      // The tray's own switch path: this persists the config and triggers
      // hardRestart, so the server is re-spawned as `splash serve --model
      // <id>` and stays a child of this app.
      let loadStart = Date()
      if i == 0 {
        // Force a cold engine for the first model. Setting config.model
        // only restarts when the value actually *changes*, so a single
        // installed model (or a `current` not in installed) would leave
        // the bench measuring an already-warm process. There is no cache
        // -clear endpoint in splash, so a fresh `splash serve` process is
        // the only way to start from an empty KV cache.
        config.config.model = model
        await process.hardRestart(serving: model, force: true)
      } else {
        config.config.model = model
      }
      guard await waitUntilReady(model: model) else {
        if cancelled { return }
        results.append(
          BenchResult(
            model: model, promptID: "—",
            effort: BenchRules.reasoningEffort,
            order: i, metrics: BenchMetrics(error: "load timeout")))
        continue
      }
      let loadSeconds = Date().timeIntervalSince(loadStart)
      let loadMemory: Double? = (stats.latest?.memoryActual?.currentBytes).map {
        Double($0) / 1_073_741_824
      }
      // Ground truth for the stamp: the same /status snapshot that reported
      // ready carries the engine's ANE verdict for this model. Per model on
      // purpose — the split is calibrated per Mac+model+build, so one plan
      // can honestly hold "split 41%" and "off" at once.
      if let ane = stats.latest?.aneFfn, ane.state != nil {
        aneStates[model] = Self.aneLabel(ane)
      }
      for (n, prompt) in prompts.enumerated() {
        if cancelled { return }
        phase = .running(model: model, prompt: prompt.id)
        var r = await measure(model: model, prompt: prompt, order: i)
        if n == 0 {
          r.loadSeconds = loadSeconds
          r.loadMemoryGiB = loadMemory
        }
        results.append(r)
      }
    }
    saveReport()
    phase = .done
    // Back to the configured cap, with a re-spawn so it is the running cap
    // and not just the saved one. The engine stays on the last plan model,
    // which `buildPlan` put there on purpose.
    await restoreContextIfNeeded()
    await restoreAneIfNeeded()
  }

  /// Written on every exit that has results, so a cancelled run is still on
  /// disk. Cancelling mid-prompt leaves that model's last row missing, which
  /// the partial table shows honestly. Both the human-readable report and the
  /// structured history are written, because they answer different questions:
  /// one is for pasting, the other is for reloading into the UI.
  private func saveReport() {
    guard !results.isEmpty else { return }
    BenchReport.write(results, plan: plan, longContextK: longContextK, aneStates: aneStates)
    lastRunAt = Date()
    let params = BenchmarkParamKey(
      plan: plan, longContextK: longContextK, visionMode: visionMode,
      kvFormat: config.config.kvFormat ?? "server default",
      maxMemory: config.config.maxMemory ?? "auto",
      maxCacheDisk: (config.config.maxCacheDisk?.isEmpty == false
        && config.config.maxCacheDisk != "0")
        ? config.config.maxCacheDisk! : "off",
      powerMode: runPowerMode, aneEnabled: aneEnabled)
    var archive = BenchArchive.load()
    archive.insert(
      BenchHistory(
        finishedAt: lastRunAt ?? Date(), plan: plan,
        longContextK: longContextK, results: results,
        prompts: runPrompts, params: params,
        aneStates: aneStates.isEmpty ? nil : aneStates))
    archive.save()
    runs = archive.runs
    selectedRunAt = lastRunAt
    SplashLog.shared.log("bench_run_saved params=\(params.id) stored_sets=\(runs.count)")
  }

  /// What the run could measure visually. `--language-only` wins over an
  /// attached image: the server would refuse the image, so the vision scenario
  /// is recorded as skipped rather than failing once per model.
  private var visionMode: String {
    if config.config.languageOnly { return "language_only" }
    return imagePath == nil ? "none" : "image_attached"
  }

  /// Poll /ready via the live stats snapshot rather than a second client, so
  /// the bench waits on the same signal the dashboard shows.
  private func waitUntilReady(model: String, timeout: TimeInterval = 180) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if cancelled { return false }
      if case .running = process.state,
        let s = stats.latest,
        s.ready == true,
        s.instance?.model == model
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
    return false
  }

  private func measure(model: String, prompt: BenchPrompt, order: Int) async -> BenchResult {
    // The image is optional: without one the vision prompt is recorded as
    // skipped rather than blocking the run or erroring per model.
    if prompt.needsImage, imagePath == nil || config.config.languageOnly {
      return BenchResult(
        model: model, promptID: prompt.id, effort: prompt.effort,
        order: order,
        metrics: BenchMetrics(
          skipped: config.config.languageOnly
            ? "language only (vision disabled)" : "no image chosen"))
    }
    let started = Date()
    // Estimated from the text we are about to send: ~3.78 chars/token measured
    // on this corpus. Division is in Double — `Int(3.78)` truncates to 3 and
    // inflated the 64K estimate to 80 640 tokens, a 17-minute ceiling.
    let estTokens = Int(Double(prompt.text.count) / BenchRules.LongContext.charsPerToken)
    let limit = BenchRules.timeout(promptTokens: estTokens, budget: prompt.maxTokens)
    let body: [String: Any] = [
      "model": model,
      "messages": [["role": "user", "content": imageContent(prompt)]],
      "max_tokens": prompt.maxTokens,
      "temperature": BenchRules.temperature,
      "reasoning_effort": prompt.effort,
    ]
    // No `context_size`: the server's own --max-context already governs, and
    // the longest prompt here is ~8.7k tokens against a 128K cap. Sending the
    // *native* 262144 window instead would fight the enforced limit.

    do {
      let data = try JSONSerialization.data(withJSONObject: body)
      let reply = try await client.complete(
        port: config.config.port, body: data,
        timeout: limit)
      let elapsed = Date().timeIntervalSince(started)
      let t = reply.timings
      let promptSec = (t?.promptMs ?? 0) / 1000
      // Derived TTFT, not measured: the request is non-streaming, so the
      // only time-to-first-token the engine can tell us about is prefill
      // plus the first decoded token. Subtracting timings from the wall
      // clock instead yields ~0.04 s, because `timings` accounts for
      // essentially the whole request and leaves only scheduling overhead.
      let tps: Double = t?.predictedPerSecond ?? 0
      let firstToken: Double = tps > 0 ? 1.0 / tps : 0
      let predictedN: Int? = reply.usage?.completionTokens ?? t?.predictedN
      var m = BenchMetrics()
      m.ttft = promptSec + firstToken
      m.elapsed = elapsed
      m.promptTps = t?.promptPerSecond
      m.outputTps = tps > 0 ? tps : nil
      m.promptTokens = reply.usage?.promptTokens ?? t?.promptN
      m.completionTokens = predictedN
      m.reasoningTokens = reply.usage?.completionTokensDetails?.reasoningTokens
      m.cacheN = t?.cacheN
      m.finishReason = reply.choices?.first?.finishReason
      m.contentChars = reply.choices?.first?.message?.content?.count
      // Live resident memory sample immediately following scenario completion
      if let st = try? await client.status(port: config.config.port),
        let cur = st.memoryActual?.currentBytes
      {
        m.memoryGiB = Double(cur) / 1_073_741_824
      } else if let cur = stats.latest?.memoryActual?.currentBytes {
        m.memoryGiB = Double(cur) / 1_073_741_824
      }
      // Truncated hard: an inspector that renders a 40 kB answer is worse
      // than one that says "first 2 000 characters". The full text is in
      // neither place — the point is to see whether an answer came back.
      let answer = reply.choices?.first?.message?.content
      return BenchResult(
        model: model, promptID: prompt.id, effort: prompt.effort,
        order: order, metrics: m,
        output: answer.map { String($0.prefix(2_000)) })
    } catch let e as URLError where e.code == .timedOut {
      let elapsed = Date().timeIntervalSince(started)
      var m = BenchMetrics(
        error:
          "gave up after \(BenchRules.describe(elapsed)) of a \(BenchRules.describe(limit)) limit — raise the request ceiling or pick a smaller context"
      )
      if let cur = stats.latest?.memoryActual?.currentBytes {
        m.memoryGiB = Double(cur) / 1_073_741_824
      }
      return BenchResult(
        model: model, promptID: prompt.id, effort: prompt.effort,
        order: order, metrics: m)
    } catch let e as SplashClient.SplashError {
      let msg = e.errorDescription ?? "\(e)"
      return BenchResult(
        model: model, promptID: prompt.id, effort: prompt.effort,
        order: order,
        metrics: BenchMetrics(
          skipped: isVisionRejection(msg) ? "no vision" : nil,
          error: isVisionRejection(msg) ? nil : msg))
    } catch {
      return BenchResult(
        model: model, promptID: prompt.id, effort: prompt.effort,
        order: order, metrics: BenchMetrics(error: "\(error)"))
    }
  }

  /// Matched against the server's own wording (see ARCHITECTURE.md § 4.2): a model without
  /// a vision projector answers 400 rather than running the prompt.
  private func isVisionRejection(_ msg: String) -> Bool {
    let needles = [
      "does not support image", "image input", "no vision",
      "cannot read", "vision", "multimodal",
    ]
    let m = msg.lowercased()
    return needles.contains { m.contains($0) }
  }

  private func imageContent(_ p: BenchPrompt) -> Any {
    guard p.needsImage, let path = imagePath,
      let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else {
      return p.text
    }
    // The reference sends the image as an OpenAI-style data URL.
    let url = "data:image/png;base64," + data.base64EncodedString()
    return [
      ["type": "text", "text": p.text],
      ["type": "image_url", "image_url": ["url": url]],
    ]
  }
}

// MARK: - Report on disk

/// Writes the finished run to a plain-text file so the numbers can be read,
/// diffed or pasted without screenshotting the dashboard. Text, not JSON: the
/// ask was "so I do not have to paste the image", and a human-readable table
/// answers that directly. Reloading a run into the UI is not supported — results
/// live in memory only.
enum BenchReport {
  static let filename = "bench-report.txt"

  static var url: URL {
    ModelStats.directory.appendingPathComponent(filename)
  }

  /// `results` in display order. Written on completion *and* on cancel, so a
  /// partial run is still on disk.
  static func write(
    _ results: [BenchResult], plan: [String], longContextK: Int,
    aneStates: [String: String] = [:],
    to directory: URL? = nil
  ) {
    let dir = directory ?? ModelStats.directory
    var out = ""
    let stamp = SplashLog.stamp.string(from: Date())
    out += "Splash model benchmark\n"
    out += "run    \(stamp)\n"
    out += "rules  greedy (temperature 0), effort fixed per scenario"
    out += ", long context \(longContextK)K, prompts nonced\n"
    out +=
      "order  \(plan.enumerated().map { "\($0.offset + 1) \(ModelCatalog.displayName(for: $0.element))" }.joined(separator: "  "))\n"
    if let last = plan.indices.last, results.contains(where: { $0.order == last }) {
      out += "       (last in order ran on the hottest machine)\n"
    }
    out += "\n"

    let models = plan.filter { m in results.contains { $0.model == m } }
    for model in models {
      let rows = results.filter { $0.model == model }
      let ok = rows.filter { $0.metrics.error == nil && $0.metrics.skipped == nil }
      let tps = ok.compactMap { $0.metrics.outputTps }
      let mean = tps.isEmpty ? nil : tps.reduce(0, +) / Double(tps.count)
      let times = ok.compactMap { $0.metrics.elapsed }
      let total = times.isEmpty ? nil : times.reduce(0, +)
      let load = rows.first?.loadSeconds
      let mems = ok.compactMap { $0.metrics.memoryGiB }
      let avgMem = mems.isEmpty ? nil : mems.reduce(0, +) / Double(mems.count)
      let peakMem = mems.max()

      out += "\(ModelCatalog.displayName(for: model))"
      if let mean { out += String(format: "  mean %.1f tok/s", mean) }
      if let total { out += String(format: "  total %.1fs", total) }
      if let load { out += String(format: "  load %.1fs", load) }
      if let avgMem { out += String(format: "  mem avg %.1fG", avgMem) }
      if let peakMem, let avgMem, abs(peakMem - avgMem) > 0.1 {
        out += String(format: " (peak %.1fG)", peakMem)
      }
      if let o = rows.first?.order, o == plan.count - 1 { out += "  ran last (hottest)" }
      if let ane = aneStates[model] { out += "  ANE \(ane)" }
      out += "\n"
      out +=
        "  "
        + row([
          "prompt", "effort", "tok/s", "prefill", "ttft",
          "in/out", "think", "end", "cache", "time", "mem",
        ]) + "\n"
      for r in rows {
        let m = r.metrics
        let fmt: (Double?) -> String = { v in
          guard let v else { return "-" }
          return String(format: "%.2f", v)
        }
        out +=
          "  "
          + row([
            r.promptID, r.effort,
            m.outputTps.map { String(format: "%.1f", $0) } ?? "-",
            m.promptTps.map { String(format: "%.0f", $0) } ?? "-",
            fmt(m.ttft),
            pair(m.promptTokens, m.completionTokens),
            think(m),
            end(m),
            m.cacheN.map(String.init) ?? "-",
            m.elapsed.map { String(format: "%.2fs", $0) } ?? "-",
            m.memoryGiB.map { String(format: "%.1fG", $0) } ?? "-",
          ]) + "\n"
        if let note = m.skipped ?? m.error {
          out += "      \(note)\n"
        }
      }
      out += "\n"
    }

    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try out.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
      SplashLog.shared.log(
        "bench_report_written path=\(dir.appendingPathComponent(filename).path) models=\(models.count) rows=\(results.count)"
      )
    } catch {
      SplashLog.shared.log("bench_report_failed error=\(error)")
    }
  }

  /// `in/out` plus `think`, which is `reasoning (answer)`. Without the split,
  /// `out` is unreadable: code_gen reported 3121 out of which 2445 was thinking.
  private static func pair(_ i: Int?, _ o: Int?) -> String {
    guard let i, let o else { return "-" }
    return "\(i)/\(o)"
  }

  private static func think(_ m: BenchMetrics) -> String {
    guard let out = m.completionTokens, let t = m.reasoningTokens else { return "-" }
    return "\(t)(\(max(0, out - t)))"
  }

  private static func end(_ m: BenchMetrics) -> String {
    if m.contentChars == 0 { return "empty" }
    guard let reason = m.finishReason else { return "-" }
    return reason == "length" ? "truncated" : reason
  }

  private static func row(_ cells: [String]) -> String {
    let w = [14, 7, 8, 9, 6, 12, 12, 10, 6, 8, 7]
    var out = ""
    for (i, c) in cells.enumerated() where i < w.count {
      out += c.padding(toLength: max(c.count, w[i]), withPad: " ", startingAt: 0)
      if i < min(cells.count, w.count) - 1 { out += " " }
    }
    return out
  }
}
