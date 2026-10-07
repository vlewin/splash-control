import AppKit
import Combine
import SplashControlKit
import SwiftUI

/// NSStatusItem with live title (tok/s) and the oMLX-style menu.
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()

  private let process: SplashProcess
  private let stats: StatsModel
  private let config: ConfigStore
  private let openDashboard: () -> Void
  private let openSettings: () -> Void
  private let requestQuit: () -> Void

  private var cancellables = Set<AnyCancellable>()
  private var appearanceObservation: NSKeyValueObservation?

  init(
    process: SplashProcess, stats: StatsModel, config: ConfigStore,
    openDashboard: @escaping () -> Void, openSettings: @escaping () -> Void,
    requestQuit: @escaping () -> Void
  ) {
    self.process = process
    self.stats = stats
    self.config = config
    self.openDashboard = openDashboard
    self.openSettings = openSettings
    self.requestQuit = requestQuit
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    statusItem.menu = menu
    menu.delegate = self

    buildMenu(requestQuit: requestQuit)

    config.$config
      .receive(on: RunLoop.main)
      .sink { [weak self] cfg in
        self?.applyConfig(cfg)
      }
      .store(in: &cancellables)

    // Title (tps) updates every stats tick.
    stats.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] in
        // The icon belongs here too, and not only on `process.$state`.
        // It used to be wired to the lifecycle alone, which meant the dot
        // was never re-evaluated when the AGENT changed: it kept whatever
        // the last restart drew, and — because `setAnimating(false)` was
        // likewise never called — a pulse timer started during a request
        // kept flipping forever. That is what left the dot blinking
        // white/grey in a steady idle state, and empty during a decode.
        // `receive(on:)` defers delivery past the mutation, so
        // `stats.agentStatus` is the new value, not the previous one.
        self?.updateIcon()
        self?.updateTitle()
        self?.updateWebUIVisibility()
      }
      .store(in: &cancellables)

    process.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateIcon()
        self?.updateTitle()
        self?.updateActions()
      }
      .store(in: &cancellables)

    // The state icon is a non-template composite; re-render when the
    // system switches appearance (ring tint must track the bar color).
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
      Task { @MainActor in self?.updateIcon() }
    }

    applyConfig(config.config)
    updateIcon()
    updateTitle()
    updateActions()
  }

  // MARK: - Icon / title

  /// Dotted ring with a filled centre dot. The dot colour is the **only**
  /// carrier of engine state in the menu bar — the bar shows just the rate —
  /// so the palette is six distinct hues. Tooltip and the menu's Status row
  /// carry the same state in words.
  ///
  /// | dot | meaning |
  /// |---|---|
  /// | green | ok — idle, or actively decoding |
  /// | blue | busy — prefill, mask-blocked, or still starting |
  /// | orange | warn — queued, suspended, draining, recovering, stale, memory-capped, memory-pressure |
  /// | red | error — the engine reported a failure |
  /// | purple | our own start/stop/restart is in flight (an *action*, not a health signal, so it must not share orange with warn) |
  /// | grey | no server, or nothing heard yet |
  ///
  /// Non-template (a template image would tint the coloured dot monochrome);
  /// the ring is tinted white/black to track the menu bar appearance.
  ///
  /// `pulse` is 0…1 and only ever below 1 for a state that is actively
  /// working, so motion carries meaning rather than decoration.
  private static func stateImage(
    look: StatsModel.TrayLook, dark: Bool,
    scale: Double = 1
  ) -> NSImage? {
    guard
      let symbol = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Splash")
    else { return nil }
    let image = NSImage(size: symbol.size)
    image.lockFocus()
    symbol.draw(
      in: NSRect(origin: .zero, size: symbol.size),
      from: NSRect(origin: .zero, size: symbol.size),
      operation: .sourceOver, fraction: 1)
    (dark ? NSColor.white : NSColor.black).set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)

    let hue = look.hue
    // No server: leave the ring empty. The stroke and fill are what assert
    // "a server is behind this", so drawing a zero-sized dot of any colour
    // would be a lie in the wrong direction — and a zero-width oval is not
    // reliably invisible, so the whole inner drawing is skipped.
    guard hue != .none else {
      image.unlockFocus()
      image.isTemplate = false
      return image
    }
    // The dot is ALWAYS a full filled circle. Only its size moves, and only
    // on the dim half of a pulse — see `StatsModel.dotScale`. Outline first,
    // in the polarity OPPOSITE the dot: white on a dark or tinted menu bar,
    // black on a light one. That contrast is what keeps the dot legible on
    // an arbitrary background; the fill colour alone does not, which is how
    // a dark green vanished against a blue bar.
    let side = min(symbol.size.width, symbol.size.height) * StatsModel.dotWeight(hue) * scale
    let center = NSPoint(x: symbol.size.width / 2, y: symbol.size.height / 2)
    let fill = NSRect(
      x: center.x - side / 2, y: center.y - side / 2,
      width: side, height: side)
    let strokeSide = side * (1 + StatsModel.dotStrokeFraction)
    let stroke = NSRect(
      x: center.x - strokeSide / 2, y: center.y - strokeSide / 2,
      width: strokeSide, height: strokeSide)
    (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: stroke).fill()

    let (r, g, b) = StatsModel.dotRGB(hue)
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
    NSBezierPath(ovalIn: fill).fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }

  /// The single point where the SERVICE lifecycle becomes the service axis, and
  /// the single point where the agent's look is read. `updateIcon`,
  /// `redrawDot` and `updateTitle` all call this instead of each re-deriving
  /// the state — that duplication is what let the icon show a dotless ring
  /// while the menu said "decoding".
  private func currentLook() -> StatsModel.TrayLook {
    let service: StatsModel.ServiceState
    switch process.state {
    case .stopped: service = .down
    case .starting: service = .starting
    case .restarting: service = .restarting
    case .running: service = .up
    case .failed: service = .down
    }
    return StatsModel.trayLook(service: service, agent: stats.agentStatus)
  }

  private func serviceIsUp() -> Bool {
    if case .running = process.state { return true }
    return false
  }

  private func updateIcon() {
    guard let button = statusItem.button else { return }
    let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let look = currentLook()
    setAnimating(look.blinks)
    button.image = Self.stateImage(look: look, dark: dark, scale: dotScale())
    button.toolTip = process.isBusy ? "Splash Control: restarting…" : agentStatusLine()
  }

  // MARK: - Pulse
  //
  // `decoding` and `loading` blink; every other state is solid, so motion means
  // "the engine is working on something right now". Driven by its own timer
  // because the 2 s poll is far too slow to read as a blink, and torn down as
  // soon as the working state ends so an idle bar costs nothing.
  //
  // `animating` and `phaseBright` are separate on purpose. Collapsing them into
  // one flag is what made the first version render every steady state at 30%
  // (so the dot looked white) and never dim the animating one at all.

  private var pulseTimer: Timer?
  private var animating = false
  private var phaseBright = true

  private func dotScale() -> Double {
    StatsModel.dotScale(
      animating: animating,
      phaseBright: phaseBright)
  }

  private func setAnimating(_ should: Bool) {
    guard should != animating else { return }
    animating = should
    phaseBright = true
    if should {
      pulseTimer?.invalidate()
      let t = Timer(timeInterval: 0.22, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.flipPhase() }
      }
      RunLoop.main.add(t, forMode: .common)
      pulseTimer = t
    } else {
      pulseTimer?.invalidate()
      pulseTimer = nil
    }
  }

  private func flipPhase() {
    phaseBright.toggle()
    redrawDot()
  }

  private func redrawDot() {
    guard let button = statusItem.button else { return }
    let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    button.image = Self.stateImage(look: currentLook(), dark: dark, scale: dotScale())
  }

  /// The bar carries the rate only. Engine state lives in the dot colour, the
  /// tooltip and the menu's Status row, so no text is shown here — which also
  /// restores the pre-2026-09-25 behaviour of an empty bar when idle.
  private func updateTitle() {
    guard let button = statusItem.button else { return }
    guard serviceIsUp(), config.config.showTrayTps, let tps = stats.displayTps else {
      button.title = ""
      return
    }
    button.title = " \(Int(tps.rounded()))"
  }

  private func updateActions() {
    let isRunning: Bool
    if case .running = process.state { isRunning = true } else { isRunning = false }
    let isStarting = process.state == .starting
    let isRestarting = process.state == .restarting
    let isBusy = process.isBusy

    if isRunning {
      startItem.isHidden = true

      restartItem.isHidden = false
      restartItem.title = "Restart Server"
      restartItem.isEnabled = !isBusy

      stopItem.isHidden = false
      stopItem.title = "Stop Server"
      stopItem.isEnabled = true

      engineStatusSeparator.isHidden = false
      engineStatusCaption.isHidden = false
      for (item, _) in statsBlock { item.isHidden = false }
    } else if isStarting || isRestarting {
      startItem.isHidden = !isStarting
      startItem.title = "Starting Server…"
      startItem.isEnabled = false

      restartItem.isHidden = !isRestarting
      restartItem.title = "Restarting Server…"
      restartItem.isEnabled = false

      stopItem.isHidden = false
      stopItem.title = "Cancel Start"
      stopItem.isEnabled = true

      engineStatusSeparator.isHidden = true
      engineStatusCaption.isHidden = true
      for (item, _) in statsBlock { item.isHidden = true }
    } else {
      // Stopped or failed
      startItem.isHidden = false
      startItem.title = {
        if case .failed = process.state { return "Retry Start Server" }
        return "Start Server"
      }()
      startItem.isEnabled = true

      restartItem.isHidden = true
      stopItem.isHidden = true

      engineStatusSeparator.isHidden = true
      engineStatusCaption.isHidden = true
      for (item, _) in statsBlock { item.isHidden = true }
    }
  }

  // MARK: - Menu

  private var headerItem: NSMenuItem!
  private var headerView: MenuFillingHostingView<TrayHeaderView>!
  private var dashboardItem: NSMenuItem!
  private var webuiItem: NSMenuItem!
  private var modelSelectItem: NSMenuItem!
  private var modelMenu: NSMenu!
  private var modelMenuItems: [NSMenuItem] = []
  /// Last list the Model submenu was built from. The catalog is FSEvents-backed,
  /// so the scan is cached and this guard only avoids rebuilding identical items.
  private var modelIDs: [String] = []
  private var mismatchItem: NSMenuItem!
  private var startItem: NSMenuItem!
  private var restartItem: NSMenuItem!
  private var stopItem: NSMenuItem!
  private var engineStatusSeparator: NSMenuItem!
  private var engineStatusCaption: NSMenuItem!
  private var statsBlock: [(NSMenuItem, (_ placeholder: String) -> String)] = []
  private var copyURLItem: NSMenuItem!
  private var copyCurlItem: NSMenuItem!
  /// Stable titles for the items that flash a "Copied" confirmation.
  private var defaultTitles: [ObjectIdentifier: String] = [:]

  private func buildMenu(requestQuit: @escaping () -> Void) {
    menu.removeAllItems()
    menu.autoenablesItems = false  // we drive Start/Stop enabled-state ourselves

    // 1. Header (Hosted SwiftUI view with title, status pill, detail)
    headerView = MenuFillingHostingView(
      rootView: TrayHeaderView(
        title: "Splash Control",
        status: "Connecting…",
        detail: "",
        busy: false,
        tint: .secondary))
    headerView.frame = NSRect(x: 0, y: 0, width: 330, height: 48)
    headerItem = NSMenuItem()
    headerItem.view = headerView
    menu.addItem(headerItem)

    menu.addItem(.separator())

    // 2. Primary Navigation
    dashboardItem = actionItem("Open Dashboard", "gauge.with.needle", #selector(dashboardAction))
    dashboardItem.keyEquivalent = "d"
    dashboardItem.keyEquivalentModifierMask = .command
    menu.addItem(dashboardItem)

    webuiItem = actionItem("Open WebUI", "safari", #selector(webuiAction))
    menu.addItem(webuiItem)

    menu.addItem(.separator())

    // 3. Model & Server Operations
    modelMenu = NSMenu()
    modelIDs = []
    modelSelectItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
    modelSelectItem.image = Self.menuIcon("cpu")
    modelSelectItem.submenu = modelMenu
    menu.addItem(modelSelectItem)

    mismatchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    mismatchItem.isEnabled = false
    mismatchItem.isHidden = true
    menu.addItem(mismatchItem)

    startItem = actionItem("Start Server", "play.fill", #selector(startAction))
    menu.addItem(startItem)

    restartItem = actionItem("Restart Server", "arrow.clockwise", #selector(restartAction))
    restartItem.keyEquivalent = "r"
    restartItem.keyEquivalentModifierMask = .command
    menu.addItem(restartItem)

    stopItem = actionItem("Stop Server", "stop.fill", #selector(stopAction))
    menu.addItem(stopItem)

    // 4. Live Engine Status
    engineStatusSeparator = .separator()
    menu.addItem(engineStatusSeparator)

    engineStatusCaption = caption("Engine Status")

    let statTitles: [(String, (_ placeholder: String) -> String)] = [
      ("bolt.fill", { self.statDecode($0) }),
      ("clock.fill", { self.statTTFT($0) }),
      ("arrow.down.circle.fill", { self.statPrefill($0) }),
      ("memorychip.fill", { self.statMetal($0) }),
      ("internaldrive.fill", { self.statDisk($0) }),
    ]
    statsBlock.removeAll()
    for (symbol, render) in statTitles {
      let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = Self.menuIcon(symbol)
      menu.addItem(item)
      statsBlock.append((item, render))
    }

    // 5. Developer Tools
    menu.addItem(.separator())
    caption("Developer Tools")

    copyURLItem = actionItem("Copy API Endpoint", "link", #selector(copyEndpoint))
    copyCurlItem = actionItem("Copy curl Snippet", "terminal", #selector(copyCurl))
    menu.addItem(copyURLItem)
    menu.addItem(copyCurlItem)

    // 6. Preferences & App Lifecycle
    menu.addItem(.separator())
    let settings = actionItem("Settings…", "gearshape", #selector(settingsAction))
    settings.keyEquivalent = "s"
    settings.keyEquivalentModifierMask = .command
    menu.addItem(settings)

    let quit = actionItem("Quit Splash Control", "power", #selector(quitAction))
    quit.keyEquivalent = "q"
    quit.keyEquivalentModifierMask = .command
    menu.addItem(quit)

    // 7. Attribution
    menu.addItem(.separator())
    let credit = NSMenuItem(
      title: "Special Thanks to IncoAI · github.com/incoai/splash", action: #selector(creditAction),
      keyEquivalent: "")
    credit.target = self
    credit.isEnabled = true
    credit.image = Self.menuIcon("heart.fill")
    menu.addItem(credit)
  }

  /// A muted group caption, so the rows below read as a named block instead of
  /// loose items in a list.
  @discardableResult
  private func caption(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title.uppercased(),
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    menu.addItem(item)
    return item
  }

  private func actionItem(
    _ title: String, _ symbol: String,
    _ action: Selector
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = Self.menuIcon(symbol)
    defaultTitles[ObjectIdentifier(item)] = title  // what `flash` restores
    return item
  }

  private static func menuIcon(_ symbol: String) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
  }

  /// Momentary confirmation. A clipboard write with no feedback is
  /// indistinguishable from a dead button.
  private func flash(_ item: NSMenuItem) {
    let original = defaultTitles[ObjectIdentifier(item)] ?? item.title
    item.title = "Copied ✓"
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      item.title = original
    }
  }

  @objc private func copyEndpoint() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(process.endpointURL, forType: .string)
    SplashLog.shared.log("copy_endpoint value=\(process.endpointURL)")
    flash(copyURLItem)
  }

  @objc private func copyCurl() {
    let snippet = process.curlSnippet(serving: stats.latest?.instance?.model)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(snippet, forType: .string)
    SplashLog.shared.log("copy_curl bytes=\(snippet.count)")
    flash(copyCurlItem)
  }

  @objc private func creditAction() {
    if let url = URL(string: "https://github.com/incoai/splash") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func startAction() {
    guard !process.isBusy else { return }
    process.start()
  }
  @objc private func stopAction() {
    process.stop()
  }
  @objc private func restartAction() {
    guard !process.isBusy else { return }
    // A restart launches the *configured* model. If something else is
    // actually serving — a model started by hand — that is a swap, so ask
    // before destroying it rather than doing it silently.
    let serving = stats.latest?.instance?.model
    if process.isExternal,
      let other = StatsModel.modelMismatch(configured: config.config.model, serving: serving)
    {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Replace the running model?"
      alert.informativeText = """
        A different model is serving on port \(config.config.port):

          running:   \(other)
          tray will: \(config.config.model)

        Restarting stops \(other), discards its cached prefixes, and starts \
        the configured model instead.
        """
      alert.addButton(withTitle: "Restart Anyway")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      Task { [weak self] in
        await self?.process.hardRestart(serving: serving, force: true)
      }
      return
    }
    Task { [weak self] in
      await self?.process.hardRestart(serving: serving, force: true)
    }
  }
  @objc private func dashboardAction() { openDashboard() }
  @objc private func webuiAction() {
    guard let url = URL(string: "http://127.0.0.1:\(config.config.port)/") else { return }
    NSWorkspace.shared.open(url)
  }
  @objc private func settingsAction() { openSettings() }
  @objc private func quitAction() { requestQuit() }

  @objc private func selectModel(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    if id == config.config.model { return }

    let serving = stats.latest?.instance?.model
    if process.isExternal {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Switch to \(ModelCatalog.displayName(for: id))?"
      alert.informativeText = """
        An external splash server is currently serving:
          \(serving ?? "unknown")

        Switching models will stop the running server and launch \(ModelCatalog.displayName(for: id)) on port \(config.config.port).
        """
      alert.addButton(withTitle: "Switch Model")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    // Persisted by AppDelegate's config sink, which restarts the server too.
    config.config.model = id
  }

  /// Rebuilds the Model submenu from the models on disk. Called on every
  /// `menuWillOpen`, so the list the user looks at is never stale: a model
  /// installed from a terminal appears the next time the menu opens, with no
  /// refresh step and nothing to announce.
  ///
  /// Deliberately does not restart the server when it finds a new model. A
  /// restart discards cached prefixes (cold prefill on the next request),
  /// swapping the model is not ours to decide, and the server is often one
  /// we merely adopted (`running(external:)`) so we cannot restart it at all.
  /// `Hard Restart` is right there when the user wants one.
  private func rebuildModelMenu() {
    var ids = ModelCatalog.installed()
    // Keep a set-but-not-yet-installed model selectable, so the menu
    // reflects the config rather than silently omitting what is running.
    let configured = config.config.model
    if !configured.isEmpty && !ids.contains(configured) { ids.append(configured) }
    ids.sort()
    guard ids != modelIDs else { return }  // unchanged: leave the items alone
    modelIDs = ids

    modelMenu.removeAllItems()
    modelMenuItems.removeAll()
    for id in ids {
      let item = NSMenuItem(
        title: ModelCatalog.displayName(for: id),
        action: #selector(selectModel(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = id
      modelMenu.addItem(item)
      modelMenuItems.append(item)
    }
  }

  // MARK: - Model status line

  /// Returns "Qwen 3.6 35B A3B (<status>)" for the modelStatItem.
  private func modelStatusLine(for shortModel: String, dto: StatusDTO?) -> String {
    let statusTag = statusTag(for: dto)
    guard let duration = process.startupDuration else {
      return "\(shortModel) (\(statusTag))"
    }
    let durationStr =
      duration >= 60
      ? String(format: "%.1fm", duration / 60)
      : String(format: "%.0fs", duration)
    return "\(shortModel) (\(statusTag), \(durationStr))"
  }

  /// "Status: decoding · prefill 0 · decode 1 · active 1" — the first line of
  /// the menu, so the bar's word is explained in full on click.
  private func agentStatusLine() -> String {
    if case .failed = process.state { return "Status: Error" }
    guard let status = stats.agentStatus else { return "Status: Connecting…" }
    if let detail = stats.agentStatusDetail {
      return "Status: \(status.displayName) · \(detail)"
    }
    return "Status: \(status.displayName)"
  }

  /// One-word status for display.
  private func statusTag(for dto: StatusDTO?) -> String {
    switch process.state {
    case .stopped:
      return "stopped"
    case .starting:
      return "loading"
    case .restarting:
      return "restarting"
    case .running(let external):
      if external {
        return "running"
      } else if dto?.ready == true {
        return "running"
      } else {
        return "warming"
      }
    case .failed:
      return "error"
    }
  }

  // MARK: - Refresh in place (menuWillOpen)

  func menuNeedsUpdate(_ menu: NSMenu) {
    let s = stats.latest
    rebuildModelMenu()
    let liveModel = s?.instance?.model ?? config.config.model
    let shortModel = (liveModel as NSString).lastPathComponent
    updateHeader(shortModel: shortModel, status: s)

    updateActions()
    updateWebUIVisibility()

    let currentDisplayName = ModelCatalog.displayName(for: shortModel)
    modelSelectItem.title = "Model: \(currentDisplayName)"

    for item in modelMenuItems {
      item.state = (item.representedObject as? String) == config.config.model ? .on : .off
    }

    // The status line above shows the *serving* model and the menu checkmark
    // follows the *configured* one, so a mismatch would otherwise be visible
    // only by noticing the two disagree. Say it outright.
    if let other = StatsModel.modelMismatch(
      configured: config.config.model,
      serving: s?.instance?.model)
    {
      mismatchItem.title =
        "⚠︎ Serving \((other as NSString).lastPathComponent) — tray will start \((config.config.model as NSString).lastPathComponent)"
      mismatchItem.attributedTitle = NSAttributedString(
        string: mismatchItem.title,
        attributes: [
          .font: NSFont.systemFont(ofSize: 11),
          .foregroundColor: NSColor.systemOrange,
        ])
      mismatchItem.isHidden = false
    } else {
      mismatchItem.isHidden = true
    }

    for (item, render) in statsBlock {
      item.title = render("—")
    }
  }

  private func statDecode(_ _: String) -> String {
    guard let tps = stats.displayTps else { return "Decode — no batch" }
    return String(format: "Decode %.0f tok/s", tps)
  }
  private func statTTFT(_ _: String) -> String {
    guard let ms = stats.latestTTFTp95Ms else { return "TTFT — no data" }
    return String(
      format: "TTFT p50 %.1fs / p95 %.1fs",
      (stats.latest?.metrics?.ttftMs?.p50 ?? 0) / 1000, ms / 1000)
  }
  private func statPrefill(_ _: String) -> String {
    guard let tps = stats.latest?.metrics?.prefillTokensPerSecond else {
      return "Prefill — no data"
    }
    return String(format: "Prefill %.0f tok/s (avg)", tps)
  }
  private func statMetal(_ _: String) -> String {
    guard let bytes = stats.latest?.memoryActual?.currentBytes else { return "Metal — no data" }
    let g = Double(bytes) / 1_073_741_824
    if let budget = stats.latest?.memoryGovernor?.limitBytes {
      return String(format: "Metal %.1f / %.1f GiB", g, Double(budget) / 1_073_741_824)
    }
    return String(format: "Metal %.1f GiB", g)
  }

  /// The SSD tier. Saturation needs the quota as the denominator — used bytes
  /// alone cannot tell an idle tier from a full one — and refusals are the part
  /// that says which it is.
  private func statDisk(_ _: String) -> String {
    guard let d = stats.latest?.disk else { return "SSD tier — not reported" }
    let used = (d.usedBytes ?? 0) + (d.kvBytes ?? 0)
    let g = Double(used) / 1_073_741_824
    let quota = d.capacityBytes.map { String(format: "%.1f", Double($0) / 1_073_741_824) } ?? "?"
    let refused = d.kvDemotionsRefused ?? 0
    return String(format: "SSD tier %.1f / %@ GiB", g, quota)
      + (refused > 0 ? " (\(refused) refused)" : "")
  }

  /// The header row: what is running, on what, and what it is doing right now.
  private func updateHeader(shortModel: String, status: StatusDTO?) {
    let look = currentLook()
    var detail = ModelCatalog.displayName(for: shortModel)
    if let d = stats.latest?.memoryActual?.currentBytes {
      detail += String(format: " · %.1f GiB", Double(d) / 1_073_741_824)
    }
    if let duration = process.startupDuration {
      detail +=
        duration >= 60
        ? String(format: " · Uptime %.0fm", duration / 60)
        : String(format: " · Uptime %.0fs", duration)
    }
    if process.isExternal {
      detail += " · adopted"
    }

    let statusText: String
    switch process.state {
    case .running:
      statusText = "Running · :\(config.config.port)"
    case .starting:
      statusText = "Starting…"
    case .restarting:
      statusText = "Restarting…"
    case .stopped:
      statusText = "Stopped"
      detail = "Port \(config.config.port) · No active server"
    case .failed:
      statusText = "Error"
    }

    let (r, g, b) = StatsModel.dotRGB(look.hue)
    let tint: Color = look.hue == .none ? .secondary : Color(.sRGB, red: r, green: g, blue: b)
    headerView.rootView = TrayHeaderView(
      title: "Splash Control",
      status: statusText,
      detail: detail,
      busy: process.isBusy,
      tint: tint)
  }

  /// The WebUI item tracks the *running server*, not our launch flag: it only
  /// appears when the live server actually serves the WebUI (i.e. was started
  /// without --no-webui). Probed from the poll loop into stats.webUIAvailable.
  private func updateWebUIVisibility() {
    let isRunning: Bool
    if case .running = process.state { isRunning = true } else { isRunning = false }
    webuiItem.isHidden = !stats.webUIAvailable || !isRunning
    webuiItem.isEnabled = isRunning
  }

  private func applyConfig(_ cfg: SplashConfig) {
    updateWebUIVisibility()
    updateIcon()
    updateTitle()
  }
}

/// Header view that tracks the width of the menu it is embedded in.
///
/// An `NSMenuItem` lays a custom view out at the frame it was handed, not at the
/// menu's width, and the menu is as wide as its widest item: a long model name
/// or the IncoAI credit line pushes it well past the 330 pt the header was
/// created at, stranding the status capsule mid-menu. The item's superview *is*
/// the menu's own content view, so mirroring its bounds is the width — whatever
/// the widest item happened to be this time, with no measuring of our own.
private final class MenuFillingHostingView<Content: View>: NSHostingView<Content> {
  override func layout() {
    super.layout()
    guard let width = superview?.bounds.width, width > 0, abs(width - frame.width) > 0.5 else {
      return
    }
    frame.size.width = width
  }
}

/// Menu-bar header, hosted in the first `NSMenuItem`.
private struct TrayHeaderView: View {
  let title: String
  let status: String
  let detail: String
  let busy: Bool
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12, weight: .bold))
        Spacer(minLength: 4)
        HStack(spacing: 4) {
          if busy {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.55)
              .frame(width: 10, height: 10)
          } else {
            Circle()
              .fill(tint)
              .frame(width: 6, height: 6)
          }
          Text(status)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.12), in: Capsule())
      }
      Text(detail)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    // Fills whatever width the menu gives this view rather than pinning a
    // 310 pt content box: the `Spacer(minLength: 4)` then parks the status
    // capsule against the menu's right edge — flush with the ⌘D shortcut
    // glyphs below — at any menu width.
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .padding(.vertical, 4)
  }
}
