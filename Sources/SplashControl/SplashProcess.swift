import Combine
import Foundation

/// Owns (or observes) the splash server process.
///
/// Two modes:
/// - launched: we spawned `splash serve` and can stop / hard-restart it
/// - external: the user runs splash themselves; we poll /health and can
///   stop the listener on the port (lsof) as a courtesy
@MainActor
final class SplashProcess: ObservableObject {
  enum State: Equatable {
    case stopped
    case starting
    case restarting
    case running(external: Bool)
    case failed(String)

    var logName: String {
      switch self {
      case .stopped: return "stopped"
      case .starting: return "starting"
      case .restarting: return "restarting"
      case .running(let external): return external ? "running(external)" : "running"
      case .failed(let msg): return "failed(\(msg.prefix(60)))"
      }
    }
  }

  var isBusy: Bool {
    switch state {
    case .starting, .restarting: return true
    default: return false
    }
  }

  @Published private(set) var state: State = .stopped {
    willSet {
      if newValue != state {
        SplashLog.shared.log("state \(state.logName) -> \(newValue.logName)")
      }
    }
  }
  /// When .starting was set; used to compute startup duration.
  private var startTimestamp: Date?
  /// When "Ready" was received.
  private var readyTimestamp: Date?
  /// Derived: seconds from start to ready (nil until ready).
  var startupDuration: TimeInterval? {
    guard let start = startTimestamp, let ready = readyTimestamp else { return nil }
    return ready.timeIntervalSince(start)
  }
  /// Tailing console lines ("Loading · …", "Ready · …", "Error · …").
  @Published private(set) var console: [String] = []

  /// The command line of an **adopted** (externally launched) server, from
  /// `ps -o args=`. Recorded on adoption because the tray cannot restart that
  /// process safely without knowing how it was started — and because
  /// "what is actually running" is otherwise invisible: the tray only ever sees
  /// its own config, which may name a different model entirely.
  @Published private(set) var adoptedArgs: [String]?
  /// The `--model` value parsed out of `adoptedArgs`, when there is one.
  var adoptedModel: String? { Self.parseModel(adoptedArgs) }

  /// Pure so the parse is assertable: `--model X` may appear as two argv
  /// entries or as `--model=X`, and a model id may contain dashes, so the
  /// split cannot be a substring match.
  nonisolated static func parseModel(_ args: [String]?) -> String? {
    guard let args else { return nil }
    for (i, arg) in args.enumerated() {
      if arg == "--model", i + 1 < args.count { return args[i + 1] }
      if arg.hasPrefix("--model=") { return String(arg.dropFirst("--model=".count)) }
    }
    return nil
  }

  /// Records what an adopted server is actually running. Once per adoption —
  /// `ps` is a subprocess spawn, and reconciliation asks this every poll.
  private func recordAdoption(pids: [pid_t]) {
    guard adoptedArgs == nil else { return }
    guard let pid = pids.first else { return }
    let args = Self.runTool("/bin/ps", ["-p", String(pid), "-o", "args="])?
      .split(separator: " ").map(String.init)
    adoptedArgs = args
    SplashLog.shared.log(
      "adopted_external pid=\(pid) args=\(args?.joined(separator: " ") ?? "unknown")"
        + " model=\(adoptedModel ?? "unknown")")
  }

  /// Resolved splash binary version ("1.2.0" from `splash --version`).
  @Published private(set) var splashVersion: String?

  /// Long flags the resolved binary's `serve --help` advertises, probed
  /// synchronously by `start()` immediately before the argv is built.
  ///
  /// Empty when the binary advertises nothing we asked about — and empty if
  /// the probe fails. Both mean "pass no optional flag", which is the
  /// conservative answer: an unknown flag makes strict `parse_args` refuse to
  /// start, so a failed probe must never widen the command line.
  ///
  /// Deliberately *not* filled by the launch-time `--version` probe. That one
  /// is asynchronous, and `autoStart` races it: the flag set would arrive
  /// after the argv was built, so a gated flag the user configured would be
  /// dropped on exactly the spawn where they set it. The only consumer is
  /// `buildLaunchArgs`, so the only correct place to resolve it is the spawn.
  private var serveFlags: Set<String> = []

  private var process: Process?
  private var config: SplashConfig

  init(config: SplashConfig) {
    self.config = config
    refreshSplashVersion()
  }

  func updateConfig(_ new: SplashConfig) {
    self.config = new
    refreshSplashVersion()
  }

  /// Runs `<binary> --version` off the main thread; publishes the parsed version.
  func refreshSplashVersion() {
    let binary = resolveBinary()
    let args: [String] = binary == "/usr/bin/env" ? ["splash", "--version"] : ["--version"]
    Task.detached {
      let version = Self.capture(binary: binary, args: args).flatMap(Self.parseVersion)
      await MainActor.run { self.splashVersion = version }
    }
  }

  /// Synchronous subprocess capture with the launcher's PATH resolved, so the
  /// `splash` launcher can find its Python runtime from a launchd-spawned GUI.
  nonisolated static func capture(binary: String, args: [String]) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: binary)
    task.arguments = args
    var env = ProcessInfo.processInfo.environment
    let inherited = env["PATH"] ?? ""
    env["PATH"] =
      "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      + (inherited.isEmpty ? "" : ":\(inherited)")
    task.environment = env
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (output?.isEmpty ?? true) ? nil : output
  }

  /// "Splash 1.2.0" → "1.2.0", or the whole trimmed output as fallback.
  nonisolated static func parseVersion(_ output: String) -> String? {
    for token in output.split(whereSeparator: { $0.isWhitespace || $0 == "\n" }) {
      let t = String(token)
      if t.first?.isNumber == true, t.contains(".") { return t }
    }
    return output.isEmpty ? nil : output
  }

  /// Every long flag `splash serve --help` lists, used to gate optional flags.
  /// Only a token at the start of a line counts: argparse prints each option
  /// there, while prose that merely mentions a flag ("needs --max-cache-disk")
  /// does not. Scanning every token would pick up mentions of flags the parser
  /// does not accept — which is the crash-loop this whole mechanism avoids.
  nonisolated static func longFlags(_ help: String) -> Set<String> {
    var out: Set<String> = []
    for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
      var rest = Substring(line)
      while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
      guard rest.hasPrefix("--") else { continue }
      let token = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
      if token.count > 2 { out.insert(String(token)) }
    }
    return out
  }

  /// The flags `buildLaunchArgs` gates on. A flag absent from this list is
  /// never passed, whatever the config says.
  nonisolated static let gatedFlags = [
    "--persistent-cache", "--idle-release", "--served-model-name", "--announce-served-name",
    "--default-reasoning-effort",
  ]

  /// Fills `serveFlags` from the binary about to be exec'd. Runs once per spawn
  /// and blocks for the length of one `--help` (~100 ms), which is inside the
  /// cost `start()` already pays: it calls `stop()`, which waits on a process.
  private func probeServeFlags(binary: String) {
    let args: [String] =
      binary == "/usr/bin/env" ? ["splash", "serve", "--help"] : ["serve", "--help"]
    serveFlags = Self.capture(binary: binary, args: args).map(Self.longFlags) ?? []
  }

  /// Which gated flags this config wants *and* the binary advertises. Logged so
  /// a silently-omitted flag is diagnosable from the tray log rather than only
  /// by reading `ps` output.
  private func gatedFlags(_ binary: String) -> [String] {
    var want: [String] = []
    if config.persistentCache { want.append("--persistent-cache") }
    if let idle = config.idleRelease, !idle.isEmpty { want.append("--idle-release") }
    if let name = config.servedModelName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      want.append("--served-model-name")
    }
    if config.announceServedName { want.append("--announce-served-name") }
    if let e = config.reasoningEffort, !e.isEmpty { want.append("--default-reasoning-effort") }
    return want.filter { serveFlags.contains($0) }
  }

  // MARK: - Launch

  /// Split a PATH value and drop duplicates (GUI launch inherits the shell's
  /// PATH, which on this machine carries repeated entries).
  private static func pathDirs(_ path: String) -> [String] {
    var seen = Set<String>()
    return path.split(separator: ":").map(String.init).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }

  func resolveBinary() -> String {
    if let override = config.splashPath, !override.isEmpty,
      FileManager.default.isExecutableFile(atPath: override)
    {
      return override
    }
    for candidate in ["/opt/homebrew/bin/splash", "/usr/local/bin/splash"] {
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/usr/bin/env"  // + "splash" appended to args
  }

  /// Mirrors `splash serve --help`; nil/empty config values are omitted
  /// so the server's own defaults (SPLASH_PORT, SPLASH_API_KEY, …) apply.
  var launchArgs: [String] { Self.buildLaunchArgs(config, supports: serveFlags) }

  /// The exact command `start()` will run — surfaced in Settings so the user
  /// can see (and copy) what the app applies.
  var launchCommandPreview: String {
    let binary = resolveBinary()
    // Plain shell form: `splash serve --…` (or the configured full path).
    let command =
      binary == "/usr/bin/env" || binary.hasSuffix("/splash")
      ? ["splash"]
      : [binary]
    return (command + launchArgs).joined(separator: " ")
  }

  /// The OpenAI-compatible base URL clients are pointed at. The thing a user
  /// configures Cline / OpenCode / Aider with, and the reason the menu has a
  /// "copy endpoint" action at all.
  var endpointURL: String { "http://127.0.0.1:\(config.port)/v1" }

  /// A runnable request against the *serving* model, falling back to the
  /// configured one when `/status` has not answered yet. Uses the configured
  /// API key when there is one, so the snippet is copy-pasteable as-is rather
  /// than needing a second edit.
  ///
  /// `serving` is passed in rather than read, because the tray holds two model
  /// facts (`config.model` and what `/status` reports) and a snippet naming the
  /// wrong one is the exact confusion the menu's mismatch row warns about.
  func curlSnippet(serving: String?) -> String {
    let model = (serving?.isEmpty == false ? serving : nil) ?? config.model
    var fields = [
      "\"model\": \"\(model)\"",
      "\"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one sentence.\"}]",
    ]
    if let key = config.apiKey, !key.isEmpty { fields.append("\"api_key\": \"\(key)\"") }
    return "curl \(endpointURL)/chat/completions \\\n"
      + "  -H 'Content-Type: application/json' \\\n"
      + "  -d '{" + fields.joined(separator: ", ") + "}'"
  }

  /// The exact `splash serve` command line for a config. Pure in `cfg`, so it
  /// is `static` and internal: Scripts/check_core.sh asserts it, because a
  /// wrong flag here is invisible until the server refuses to start.
  static func buildLaunchArgs(_ cfg: SplashConfig, supports: Set<String> = []) -> [String] {
    var args = ["serve", "--model", cfg.model, "--port", String(cfg.port)]
    if let m = cfg.maxMemory, !m.isEmpty { args += ["--max-memory", m] }
    if let c = cfg.maxContext, !c.isEmpty { args += ["--max-context", c] }
    if let f = cfg.kvFormat, !f.isEmpty { args += ["--kv-format", f] }
    if let d = cfg.maxCacheDisk, !d.isEmpty, d != "0" { args += ["--max-cache-disk", d] }
    if let h = cfg.allowedHost, !h.isEmpty {
      for host in h.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
        args += ["--allowed-host", String(host)]
      }
    }
    if let r = cfg.maxRequestSize, !r.isEmpty { args += ["--max-request-size", r] }
    if let p = cfg.maxImagePixels, !p.isEmpty { args += ["--max-image-pixels", p] }
    if let k = cfg.apiKey, !k.isEmpty { args += ["--api-key", k] }
    if cfg.noWebUI { args += ["--no-webui"] }
    if cfg.languageOnly { args += ["--language-only"] }
    // Gated flags: a release predating them rejects the flag outright, and
    // strict `parse_args` turns that into a crash-loop, not a warning. So a
    // flag the binary's own --help did not advertise is never passed.
    //
    // `--persistent-cache` additionally *requires* a tier: the server exits 2
    // with "--persistent-cache needs --max-cache-disk". A toggle left on
    // after the tier is set back to 0 would kill the spawn, so the pairing is
    // enforced here rather than only by disabling the control in Settings.
    let tierOn = (cfg.maxCacheDisk?.isEmpty == false) && cfg.maxCacheDisk != "0"
    if cfg.persistentCache, tierOn, supports.contains("--persistent-cache") {
      args += ["--persistent-cache"]
    }
    if supports.contains("--idle-release"),
      let idle = Self.sanitizedIdleRelease(cfg.idleRelease)
    {
      args += ["--idle-release", idle]
    }
    // `--announce-served-name` without a name is refused by the same logic:
    // it is only meaningful alongside `--served-model-name`, so the pairing
    // is enforced here rather than only by disabling the control in Settings.
    if let name = cfg.servedModelName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
      supports.contains("--served-model-name")
    {
      args += ["--served-model-name", name]
      if cfg.announceServedName, supports.contains("--announce-served-name") {
        args += ["--announce-served-name"]
      }
    }
    // Closed value set: a typo is a dead server under strict parse_args,
    // so anything outside it is refused here, like a malformed
    // --idle-release. Unknown values also stay in extraArgs untouched.
    if let e = cfg.reasoningEffort?.trimmingCharacters(in: .whitespaces), !e.isEmpty,
      SplashConfig.reasoningEffortValues.contains(e),
      supports.contains("--default-reasoning-effort")
    {
      args += ["--default-reasoning-effort", e]
    }
    if let extra = cfg.extraArgs, !extra.isEmpty {
      args += extra.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
    return args
  }

  /// `--idle-release` accepts `off`, a bare number of **seconds**, or a number
  /// with one `s`/`m`/`h` suffix — and nothing else. Its parser is strict:
  /// `abc`, `15x` and `1h30m` each abort startup with exit 2, so a typo here
  /// is a dead server, not a warning. Returns the value to pass, or nil when
  /// the server would refuse it. `buildLaunchArgs` drops a malformed value
  /// rather than forwarding it; `SettingsValidator.idleRelease` calls the same
  /// function so the UI cannot disagree with what gets launched.
  nonisolated static func sanitizedIdleRelease(_ value: String?) -> String? {
    guard let value else { return nil }
    let raw = value.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    if raw == "off" { return raw }
    // An embedded space is accepted by the server and means nothing sensible,
    // so it is rejected here rather than forwarded as one argv token.
    guard !raw.contains(where: { $0.isWhitespace }) else { return nil }
    for suffix in ["s", "m", "h"] where raw.hasSuffix(suffix) {
      if let n = Double(raw.dropLast(suffix.count)), n > 0 { return raw }
    }
    if let n = Double(raw), n > 0 { return raw }
    return nil
  }

  /// The same grammar as `sanitizedIdleRelease`, resolved to seconds, so a
  /// configured value can be compared against the interval the running server
  /// reports. `off` is nil because it has no interval — the server publishes
  /// null for it, and calling that "infinite" would invent a number.
  nonisolated static func idleReleaseSeconds(_ value: String?) -> Double? {
    guard let raw = sanitizedIdleRelease(value), raw != "off" else { return nil }
    var scale = 1.0
    var digits = Substring(raw)
    if let last = raw.last, last != "0" && !"123456789".contains(last) {
      scale = ["s": 1.0, "m": 60.0, "h": 3600.0][String(last)] ?? 1.0
      digits = raw.dropLast()
    }
    guard let n = Double(digits), n > 0 else { return nil }
    return n * scale
  }

  @discardableResult
  func start() -> String? {
    stop()
    console = []
    if let listeners = Self.listenerPids(port: config.port), !listeners.isEmpty {
      SplashLog.shared.log(
        "start_aborted port=\(config.port) already listening -> external pids=\(listeners)")
      if let detail = portOccupantDetail(port: config.port) {
        SplashLog.shared.log("start_aborted port=\(config.port) check: \(detail)")
      }
      recordAdoption(pids: listeners)
      state = .running(external: true)
      return "splash already listening on port \(config.port)"
    }
    // Port free (or lsof unavailable) -> fall through to launch.

    // Every server run starts with an empty server log. Rotating here, before
    // the spawn, is what makes the file a *session* log: the `$ splash serve
    // …` echo and the first `Loading ·` line are its first two lines, and
    // nothing from the previous run is mixed in. `start()` is the only place
    // that spawns, so restart, sleep/wake recovery and the memory guard all
    // get it. Recorded in the tray channel because the server log it resets
    // cannot say so itself.
    SplashLog.shared.rotateNow(.server)
    SplashLog.shared.log("server_log_reset before_start port=\(config.port)")

    let proc = Process()
    let binary = resolveBinary()
    // Resolve the capability set *here*, synchronously, immediately before
    // the argv is built. Doing it at launch time raced `autoStart` and
    // silently dropped the gated flags on the first spawn after a boot.
    probeServeFlags(binary: binary)
    SplashLog.shared.log(
      "serve_flags_probe n=\(serveFlags.count) gated=\(gatedFlags(binary).joined(separator: ","))")
    // `serve` is a splash subcommand — invoke via the `splash` launcher.
    // `serve` is already launchArgs[0] — the executable name supplies the rest.
    let args = launchArgs
    proc.executableURL = URL(fileURLWithPath: binary)
    proc.arguments = args
    // GUI apps inherit a minimal PATH (launchd); ensure Homebrew + standard
    // dirs are visible so the `splash` launcher can find its Python runtime.
    var env = ProcessInfo.processInfo.environment
    let inherited = env["PATH"] ?? ""
    env["PATH"] =
      "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      + (inherited.isEmpty ? "" : ":\(inherited)")
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    proc.standardInput = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let available = handle.availableData
      guard !available.isEmpty else { return }
      let text = String(data: available, encoding: .utf8) ?? ""
      let lines = text.split(separator: "\n").map(String.init)
      Task { @MainActor in
        self?.appendConsole(lines)
      }
    }

    proc.terminationHandler = { [weak self, pipe, proc] _ in
      // Break the pipe ↔ readabilityHandler retain cycle.
      pipe.fileHandleForReading.readabilityHandler = nil
      let status = proc.terminationStatus
      SplashLog.shared.log("process_exited status=\(status)")
      Task { @MainActor in
        guard let self, self.process === proc else { return }
        if self.state != .stopped { self.state = .stopped }
      }
    }

    let pathDirs = Self.pathDirs(env["PATH"] ?? "")
    do {
      try proc.run()
      self.process = proc
      self.startTimestamp = Date()
      self.readyTimestamp = nil
      // Anything recorded about a previous adoption is stale now: this
      // process is ours, and its command line is `launchCommandPreview`.
      adoptedArgs = nil
      SplashLog.shared.log(
        "startup_start model=\(config.model) binary=\(binary) port=\(config.port) PATH=\(pathDirs.count) dirs"
      )
      self.state = .starting
      appendConsole(["$ \(binary) \(args.joined(separator: " "))"])
    } catch {
      self.state = .failed("Could not launch splash: \(error.localizedDescription)")
      // Full deduped PATH on failure — this is where PATH matters.
      SplashLog.shared.log(
        "startup_failed error=\(error.localizedDescription) PATH=\(pathDirs.joined(separator: ":"))"
      )
    }
    return nil
  }

  func stop(hard: Bool = false) {
    if let proc = process {
      if proc.isRunning {
        if hard {
          kill(proc.processIdentifier, SIGKILL)
        } else {
          proc.terminate()  // SIGTERM: let the engine flush and unmap
        }
      }
      process = nil
      state = .stopped
      appendConsole(["(stopped)"])
    } else if isExternal || isPortListening(port: config.port) {
      stopExternal()
      appendConsole(["(stopped external)"])
    }
  }

  /// Two-stage shutdown: SIGTERM, and SIGKILL only if the process is still
  /// alive after `grace`.
  ///
  /// SIGKILL skips `atexit` handlers, the destructor cascade and every disk
  /// flush, so with `--max-cache-disk` enabled it can leave cached KV blocks on
  /// disk half-written. SIGTERM lets splash unmap its Metal allocations and
  /// close its sockets cleanly. The timeout is bounded because a wedged engine
  /// must not hold up a restart forever.
  private func terminate(pid: pid_t, grace: TimeInterval = 2.5) async {
    guard pid > 0 else { return }
    kill(pid, SIGTERM)
    var waited = 0.0
    while kill(pid, 0) == 0 && waited < grace {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 0.1
    }
    if kill(pid, 0) == 0 {
      SplashLog.shared.log("terminate_escalated pid=\(pid) after \(grace)s of SIGTERM")
      kill(pid, SIGKILL)
    }
  }

  /// Kill whatever is listening on the configured port (covers external starts).
  func stopExternal() {
    if let pids = Self.listenerPids(port: config.port), !pids.isEmpty {
      SplashLog.shared.log("stop_external pids=\(pids) port=\(config.port)")
      for pid in pids { kill(pid, SIGTERM) }
    } else {
      SplashLog.shared.log("stop_external pids=none port=\(config.port) (no listener found)")
    }
    state = .stopped
  }

  /// Restarts the server, launching `config.model`.
  ///
  /// `serving` is the model `/status` reports, when known. A restart always
  /// launches the **configured** model, so restarting an adopted server that
  /// is serving something else would substitute a different model without
  /// being asked — the swap that destroyed a Bonsai session on this machine.
  /// Unless `force` (the user confirmed it), that is refused and logged.
  func hardRestart(serving: String? = nil, force: Bool = false) async {
    let configured = config.model
    if let serving, !configured.isEmpty, serving != configured {
      if isExternal && !force {
        SplashLog.shared.log(
          "hard_restart_refused external_model_mismatch serving=\(serving) configured=\(configured) — refusing to substitute"
        )
        return
      }
      SplashLog.shared.log("hard_restart_model_change serving=\(serving) configured=\(configured)")
    }
    state = .restarting
    startTimestamp = Date()
    readyTimestamp = nil
    SplashLog.shared.log("hard_restart_begin")
    if let proc = process, proc.isRunning {
      SplashLog.shared.log("hard_reset mode=launched pid=\(proc.processIdentifier)")
      let pid = proc.processIdentifier
      process = nil
      await terminate(pid: pid)
    } else if let pids = Self.listenerPids(port: config.port), !pids.isEmpty {
      SplashLog.shared.log("hard_reset mode=external pids=\(pids) port=\(config.port)")
      for pid in pids { await terminate(pid: pid) }
    } else {
      SplashLog.shared.log(
        "hard_reset mode=external pids=none port=\(config.port) (no listener; plain restart)")
    }
    // kill(2) is async: give the kernel a moment to release the LISTEN
    // socket so the immediate start() port check doesn't re-trip.
    // `Task.sleep`, not `RunLoop.current.run(until:)` — pumping the run loop
    // from a main-actor method re-enters event delivery, so menu clicks and
    // timers kept firing while the app sat in this half-finished state.
    var waited = 0.0
    while let pids = Self.listenerPids(port: config.port), !pids.isEmpty, waited < 3.0 {
      try? await Task.sleep(for: .milliseconds(100))
      waited += 0.1
    }
    if let pids = Self.listenerPids(port: config.port), !pids.isEmpty {
      SplashLog.shared.log("hard_reset port=\(config.port) still occupied after wait pids=\(pids)")
    }
    SplashLog.shared.log("hard_restart_wait_complete")
    // The awaits above let `reconcile` run, and it flips `.restarting` to
    // `.stopped` as soon as the server stops answering. Re-assert the state we
    // are actually in so the menu and dot do not read "stopped" during a
    // restart that is in fact still running.
    if case .failed = state {} else { state = .restarting }
    _ = start()
  }

  /// Wipe the SSD tier's on-disk tree. `nonisolated` on purpose: unlinking a
  /// 16 GiB tree takes seconds and must not run on the main actor. The
  /// weights and models caches are sibling trees and are never touched.
  /// `ponytail`: the default root only — a `--cache-dir` in extraArgs would
  /// not be honoured; parse it when someone actually sets one.
  nonisolated static func wipeDiskCache() {
    let dir = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Splash/prefix-cache")
    do {
      try FileManager.default.removeItem(at: dir)
      SplashLog.shared.log("disk_cache_reset removed dir=\(dir.path)")
    } catch {
      SplashLog.shared.log("disk_cache_reset dir=\(dir.path) error=\(error.localizedDescription)")
    }
  }

  /// Reset the SSD cache: wipe the on-disk tier, then restart the server.
  ///
  /// The restart is load-bearing, not ceremony: macOS keeps unlinked files
  /// alive until the process that held them exits, so deleting alone would
  /// free nothing, and the fresh start opens an empty tier. The external
  /// model-mismatch guard from `hardRestart` is mirrored up front because
  /// the wipe is one-way: a refusal *after* deleting would leave a running
  /// server whose tier files have vanished.
  func resetDiskCache(serving: String?) async {
    let configured = config.model
    if isExternal, let serving, !configured.isEmpty, serving != configured {
      SplashLog.shared.log(
        "disk_cache_reset_refused external_model_mismatch serving=\(serving) configured=\(configured)"
      )
      return
    }
    await Task.detached { Self.wipeDiskCache() }.value
    await hardRestart(serving: serving)
  }

  /// Reconcile against a fresh /health result.
  func reconcile(healthy: Bool) {
    if let proc = process, proc.isRunning {
      if healthy && state != .running(external: false) {
        state = .running(external: false)
      } else if !healthy && state == .running(external: false) {
        state = .starting
      }
    } else {
      if healthy {
        if state != .running(external: true) { state = .running(external: true) }
        // Adoption can be detected by reconciliation rather than by a
        // failed `start()`, so record the command line here too.
        recordAdoption(pids: Self.listenerPids(port: config.port) ?? [])
      } else if state != .stopped {
        // Only fall back to stopped if we never launched it ourselves.
        if case .running = state { state = .stopped }
        if case .starting = state { state = .stopped }
      }
    }
  }

  // MARK: - Console

  private func appendConsole(_ new: [String]) {
    console.append(contentsOf: new)
    if console.count > 200 { console.removeFirst(console.count - 200) }
    // Every line the server prints is persisted to splash-server.log, not
    // just the loading window. The gate that used to sit here (and only
    // wrote while `.starting`) meant per-request output was never recorded:
    // 0 `Done ·` lines in the log against 58 startup lines on this machine.
    // The 200-line array above is a UI convenience; the file is the record.
    for line in new {
      SplashLog.shared.log(line, .server)
    }
    for line in new {
      if line.hasPrefix("Ready ·") {
        self.readyTimestamp = Date()
        let duration = startupDuration
        if let d = duration {
          SplashLog.shared.log("startup_ready duration=\(d)s model=\(config.model)")
        } else {
          SplashLog.shared.log("startup_ready model=\(config.model)")
        }
        if !isExternal { state = .running(external: false) }
      } else if line.hasPrefix("Error ·") {
        state = .failed(line)
      }
    }
  }

  var isExternal: Bool {
    if case .running(true) = state { return true }
    return false
  }

  /// Whether this splash instance (managed or adopted) is actively running on `port`.
  func isActivelyServing(on port: Int) -> Bool {
    guard port == config.port else { return false }
    switch state {
    case .running: return true
    default: return false
    }
  }

  // MARK: - Port helpers

  func isPortListening(port: Int) -> Bool {
    return !(Self.listenerPids(port: port) ?? []).isEmpty
  }

  /// Cached "something is listening on the configured port", refreshed once
  /// per poll tick — never from a view getter. `runTool` blocks in
  /// `waitUntilExit()`, which pumps the CFRunLoop; forking it during SwiftUI
  /// view evaluation re-entered rendering and segfaulted the app (BUG-17).
  /// Views read this; the verdict lags the editable port field by at most
  /// one tick, which is irrelevant for a warning badge.
  @Published private(set) var portListening = false

  /// Re-probe the listener set off the main thread and publish the result.
  func refreshPortListening(port: Int) async {
    let inUse = await Task.detached(priority: .utility) {
      !(Self.listenerPids(port: port) ?? []).isEmpty
    }.value
    portListening = inUse
  }

  private nonisolated static func listenerPids(port: Int) -> [pid_t]? {
    // Note: the port needs a colon (`-i :9000`). A bare number makes lsof
    // fail with "unknown protocol name" and print nothing.
    guard let output = runTool("/usr/sbin/lsof", ["-nP", "-i", ":\(port)", "-t", "-sTCP:LISTEN"])
    else {
      return nil
    }
    return output.split(separator: "\n").compactMap {
      pid_t($0.trimmingCharacters(in: .whitespaces))
    }
  }

  /// No-sudo, best-effort dump of who is actually occupying `port`: named
  /// lsof listing plus matching netstat lines, for the start_aborted log.
  private func portOccupantDetail(port: Int) -> String? {
    var parts: [String] = []
    if let lsof = Self.runTool("/usr/sbin/lsof", ["-nP", "-i", ":\(port)", "-sTCP:LISTEN"]) {
      parts.append("lsof[" + lsof.replacingOccurrences(of: "\n", with: " ") + "]")
    }
    if let netstat = Self.runTool("/usr/sbin/netstat", ["-an", "-p", "tcp"]) {
      let lines = netstat.split(separator: "\n").filter { $0.contains(":\(port)") }
      if !lines.isEmpty { parts.append("netstat[" + lines.joined(separator: " ") + "]") }
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " ").prefix(2000).description
  }

  /// Run a /usr tool, capture trimmed stdout (stderr discarded). Nil on failure.
  private nonisolated static func runTool(_ path: String, _ args: [String]) -> String? {
    let task = Process()
    task.launchPath = path
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return nil }
    return text
  }
}
