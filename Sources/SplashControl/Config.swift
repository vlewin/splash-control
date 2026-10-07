import Combine
import Foundation

/// Persisted user configuration (~/Library/Application Support/SplashControl/splash-control-config.json).
struct SplashConfig: Codable, Equatable {
  var model: String = "incoai/Qwen3.8-27B-Splash"
  var port: Int = 9000
  /// e.g. "28G" — passed to `splash serve --max-memory`; nil = auto
  var maxMemory: String? = "58G"  // this Mac: auto would resolve to 58G anyway
  /// e.g. "100K" — passed to `splash serve --max-context`; nil = auto
  var maxContext: String? = "128K"  // matches the pi agent cap
  /// "int8" or "bf16" — `splash serve --kv-format`; nil = int8 (server default)
  var kvFormat: String? = nil
  /// e.g. "5G" — `splash serve --max-cache-disk` SSD tier; nil/0 = disabled
  var maxCacheDisk: String? = nil
  /// Keep the SSD tier's conversation prefixes across restarts
  /// (`splash serve --persistent-cache`). Needs a non-zero `maxCacheDisk`.
  /// splash 1.2.0+ only; omitted entirely on an older binary.
  var persistentCache: Bool = false
  /// How long the engine keeps weights resident without a request, e.g. "30m"
  /// or "off" (`splash serve --idle-release`). nil/empty = server default
  /// (10m). splash 1.2.1+ only; omitted entirely on an older binary.
  var idleRelease: String? = nil
  var noWebUI: Bool = false
  /// Skip vision preparation and loading (`splash serve --language-only`)
  var languageOnly: Bool = false
  /// Space-separated, maps to repeatable --allowed-host
  var allowedHost: String? = nil
  /// e.g. "128M" — --max-request-size; nil = server default
  var maxRequestSize: String? = nil
  /// e.g. "1048576" — --max-image-pixels; nil = server default
  var maxImagePixels: String? = nil
  /// --api-key; nil = SPLASH_API_KEY env / unset
  var apiKey: String? = nil
  /// Free-form extra `splash serve` arguments, whitespace-separated
  var extraArgs: String? = nil
  /// Default thinking depth (`splash serve --default-reasoning-effort`);
  /// nil = model template. Closed set from `serve --help`; anything else is
  /// refused by buildLaunchArgs rather than forwarded to crash-loop.
  var reasoningEffort: String? = nil
  /// Model alias (`splash serve --served-model-name`); blank/nil = none.
  /// Defaults to "default" so harness configs survive model switches.
  /// Gated on the binary advertising the flag.
  var servedModelName: String? = "default"
  /// Report the alias first in /v1/models and in response `model` fields
  /// (`splash serve --announce-served-name`). Needs `servedModelName`
  /// (enforced in buildLaunchArgs); defaults on so clients configured from
  /// the alias survive model switches end-to-end. Gated on the binary
  /// advertising the flag.
  var announceServedName: Bool = true
  /// Override for the splash executable (nil = /opt/homebrew/bin/splash or PATH)
  var splashPath: String? = nil
  /// Show current decode tok/s as text next to the menu bar icon
  var showTrayTps: Bool = true
  /// Launch the server when the app starts
  var autoStart: Bool = false
  /// Stop a launched server when the app quits (Yes/No confirmed); false = leave it running
  var stopOnQuit: Bool = true
  /// Launch the monitor app itself at macOS login (SMAppService)
  var startOnLogin: Bool = false
  /// Status poll cadence in seconds (1, 2 or 5)
  var pollIntervalSec: Double = 2
  /// Chart rolling window in minutes (15 / 30 / 60 = 15 min / 30 min / 1 h)
  var windowMinutes: Int = 15

  init() {}

  /// Closed value set for `--default-reasoning-effort`, from `serve --help`.
  /// Ordered for the Settings menu; membership decides what buildLaunchArgs
  /// forwards and what the extraArgs migration accepts.
  static let reasoningEffortValues = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

  /// Pull a `--default-reasoning-effort <value>` pair out of a raw extraArgs
  /// string (both `--flag value` and `--flag=value` forms; last valid wins).
  /// Pure so the migration is assertable without a live server. Unknown
  /// values stay put — the server rejects them today, and the migration must
  /// not change what a running install passes.
  nonisolated static func extractReasoningEffort(from extra: String?) -> (
    rest: String?, effort: String?
  ) {
    guard let extra, !extra.isEmpty else { return (extra, nil) }
    var tokens = extra.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(
      String.init)
    var effort: String? = nil
    var i = tokens.startIndex
    while i < tokens.endIndex {
      let t = tokens[i]
      var value: String? = nil
      var width = 0
      if t == "--default-reasoning-effort", tokens.index(after: i) < tokens.endIndex {
        value = tokens[tokens.index(after: i)]
        width = 2
      } else if t.hasPrefix("--default-reasoning-effort=") {
        value = String(t.dropFirst("--default-reasoning-effort=".count))
        width = 1
      }
      if let value, reasoningEffortValues.contains(value) {
        effort = value
        tokens.removeSubrange(i..<(tokens.index(i, offsetBy: width)))
      } else {
        i = tokens.index(after: i)
      }
    }
    let rest = tokens.joined(separator: " ")
    return (rest.isEmpty ? nil : rest, effort)
  }

  private enum CodingKeys: String, CodingKey {
    case model, port, maxMemory, maxContext, kvFormat, maxCacheDisk, noWebUI, languageOnly,
      allowedHost,
      maxRequestSize, maxImagePixels, apiKey, extraArgs, splashPath,
      servedModelName, announceServedName, reasoningEffort,
      showTrayTps, autoStart, stopOnQuit, startOnLogin, pollIntervalSec, windowMinutes,
      persistentCache, idleRelease
  }

  /// Tolerant decode: every field falls back to the default when the key is
  /// absent, so files written by older app versions never fail to load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ConfigStore.defaults
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
    maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory) ?? d.maxMemory
    maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext) ?? d.maxContext
    kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat) ?? d.kvFormat
    maxCacheDisk = try c.decodeIfPresent(String.self, forKey: .maxCacheDisk) ?? d.maxCacheDisk
    persistentCache =
      try c.decodeIfPresent(Bool.self, forKey: .persistentCache) ?? d.persistentCache
    idleRelease = try c.decodeIfPresent(String.self, forKey: .idleRelease) ?? d.idleRelease
    noWebUI = try c.decodeIfPresent(Bool.self, forKey: .noWebUI) ?? d.noWebUI
    languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? d.languageOnly
    allowedHost = try c.decodeIfPresent(String.self, forKey: .allowedHost) ?? d.allowedHost
    maxRequestSize = try c.decodeIfPresent(String.self, forKey: .maxRequestSize) ?? d.maxRequestSize
    maxImagePixels = try c.decodeIfPresent(String.self, forKey: .maxImagePixels) ?? d.maxImagePixels
    apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
    extraArgs = try c.decodeIfPresent(String.self, forKey: .extraArgs) ?? d.extraArgs
    servedModelName =
      try c.decodeIfPresent(String.self, forKey: .servedModelName) ?? d.servedModelName
    announceServedName =
      try c.decodeIfPresent(Bool.self, forKey: .announceServedName) ?? d.announceServedName
    reasoningEffort =
      try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? d.reasoningEffort
    splashPath = try c.decodeIfPresent(String.self, forKey: .splashPath) ?? d.splashPath
    showTrayTps = try c.decodeIfPresent(Bool.self, forKey: .showTrayTps) ?? d.showTrayTps
    autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
    stopOnQuit = try c.decodeIfPresent(Bool.self, forKey: .stopOnQuit) ?? d.stopOnQuit
    startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? d.startOnLogin
    pollIntervalSec =
      try c.decodeIfPresent(Double.self, forKey: .pollIntervalSec) ?? d.pollIntervalSec
    windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? d.windowMinutes
  }
}

final class ConfigStore: ObservableObject {
  @Published var config: SplashConfig

  static let defaults = SplashConfig()

  static let fileName = "splash-control-config.json"

  /// Pre-rename filename, kept only to migrate the file once.
  private static let legacyFileName = "monitor-config.json"

  static func configDir() -> URL {
    // "SplashControl" (not "Splash"): the splash runtime itself uses Application Support/Splash
    // for its model catalog/runtime files.
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SplashControl", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func configURL() -> URL {
    configDir().appendingPathComponent(fileName)
  }

  /// Carry an existing `monitor-config.json` over to the new name, then drop the
  /// leftovers. A rename without this would silently revert every setting to
  /// `defaults` on next launch: the tolerant decoder treats a missing file as an
  /// empty one, and the first `save()` writes defaults over it.
  private static func migrateLegacyConfig() {
    let fm = FileManager.default
    let dir = configDir()
    let legacy = dir.appendingPathComponent(legacyFileName)
    guard fm.fileExists(atPath: legacy.path) else { return }
    let current = dir.appendingPathComponent(fileName)
    if !fm.fileExists(atPath: current.path) {
      try? fm.moveItem(at: legacy, to: current)
    }
    // Stale `.bak-*` siblings from earlier experiments: same settings, older.
    for name in [
      "\(legacyFileName).bak-before-bonsai-persist",
      "\(legacyFileName).bak-pre5g",
    ] {
      try? fm.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  init() {
    Self.migrateLegacyConfig()
    let url = Self.configURL()
    var migrated = false
    if let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(SplashConfig.self, from: data)
    {
      config = decoded
      // Migrate pre-default configs: "what you see in Settings is what runs".
      if config.maxMemory == nil {
        config.maxMemory = Self.defaults.maxMemory
        migrated = true
      }
      if config.maxContext == nil {
        config.maxContext = Self.defaults.maxContext
        migrated = true
      }
      if ![15, 30, 60].contains(config.windowMinutes) {
        config.windowMinutes = 60
        migrated = true
      }
      // `--default-reasoning-effort` gained a dedicated control: lift it
      // out of the raw string so the menu shows the truth. Silent like
      // the migrations above; the value stays visible in Settings and
      // the launch preview.
      if config.reasoningEffort == nil {
        let (rest, effort) = SplashConfig.extractReasoningEffort(from: config.extraArgs)
        if let effort {
          config.reasoningEffort = effort
          config.extraArgs = rest
          migrated = true
        }
      }
    } else {
      config = Self.defaults
    }
    if migrated { save() }
  }

  func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(config) {
      try? data.write(to: Self.configURL(), options: .atomic)
    }
  }
}
