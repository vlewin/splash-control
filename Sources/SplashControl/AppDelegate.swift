import AppKit
import Combine
import QuartzCore
import ServiceManagement
import SplashControlKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let config = ConfigStore()
  private var process: SplashProcess!
  private let client = SplashClient()
  private let stats = StatsModel()
  /// Long-term per-model history, separate from the rolling live window.
  private let modelStats = ModelStats()
  /// Long-running model benchmark; owns the model switch so the tray survives.
  /// Built in launch (not here) because it needs `process`.
  private var bench: BenchmarkEngine!
  private var tray: TrayController!

  private let navigation = DashboardNavigation()
  private var dashboardWindow: NSWindow?
  /// Last zoom step applied to the open window's size, so the config sink
  /// re-fits only when the step actually changed (and can scale the current
  /// height by the step ratio).
  private var lastAppliedScale = 1.0
  /// Local key monitor for Cmd +/− (see `installZoomKeyShortcuts`).
  private var zoomKeyMonitor: Any?
  private var pollTask: Task<Void, Never>?
  private var lastHealthy: Bool?
  private var lastReady: Bool?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Creates the log file; logs launch for diagnosis.
    SplashLog.shared.log(
      "app_launch version=\(SplashLog.version) pid=\(ProcessInfo.processInfo.processIdentifier)")

    if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "png")
      ?? Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
      let iconImg = NSImage(contentsOfFile: iconPath)
    {
      NSApp.applicationIconImage = iconImg
    }

    // Enforce single instance: multiple copies create duplicate tray icons,
    // double pollers, and clobbered logs. Activate the existing one, quit.
    if let bundleID = Bundle.main.bundleIdentifier {
      let others = NSWorkspace.shared.runningApplications
        .filter {
          $0.bundleIdentifier == bundleID
            && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
      if let existing = others.first {
        SplashLog.shared.log("app_launch duplicate pid=\(existing.processIdentifier) -> quitting")
        existing.activate(options: [])
        NSApp.terminate(nil)
        return
      }
    }
    // Only the primary instance may read or write stats.json: a duplicate
    // that loaded a snapshot and then quit would flush that stale snapshot
    // over whatever the live owner has accumulated since.
    ownsHistory = true
    modelStats.load()  // long-term per-model history survives restarts

    process = SplashProcess(config: config.config)
    bench = BenchmarkEngine(config: config, process: process, stats: stats, history: modelStats)

    tray = TrayController(
      process: process,
      stats: stats,
      config: config,
      openDashboard: { [weak self] in self?.showDashboard() },
      openSettings: { [weak self] in self?.showSettings() },
      openInfo: { [weak self] in self?.showInfo() },
      requestQuit: { [weak self] in self?.quit() }
    )

    installZoomKeyShortcuts()

    lastModel = config.config.model
    config.$config
      .receive(on: RunLoop.main)
      .sink { [weak self] cfg in
        guard let self else { return }
        // Persist here, not in SettingsView: this sink is the single
        // funnel every config change passes through, including the ones
        // Settings never sees. Picking a model from the **tray menu**
        // used to change memory and restart the server while the file on
        // disk kept the old model — the change survived only until the
        // next launch, then silently reverted. Verified 2026-09-30: a
        // tray-menu switch to Bonsai left monitor-config.json untouched
        // from the previous day.
        self.config.save()
        self.process.updateConfig(cfg)
        if cfg.model != self.lastModel {
          self.lastModel = cfg.model
          // A different model needs a fresh engine; restart if live.
          switch self.process.state {
          case .running, .starting:
            // `serving` so an intentional switch is logged as such;
            // `force: true` because this is the user's explicit model choice.
            // A restart is async now (graceful SIGTERM first), so it
            // cannot run inside this synchronous Combine sink.
            let serving = self.stats.latest?.instance?.model
            Task { [weak self] in
              await self?.process.hardRestart(serving: serving, force: true)
            }
          default: break
          }
        }
        self.applyLoginItem(cfg.startOnLogin)
        self.applyDashboardZoom(cfg.dashboardScaleFactor)
        self.restartPolling()
      }
      .store(in: &cancellables)

    applyLoginItem(config.config.startOnLogin)

    // Watch the model directory instead of rescanning it whenever the tray
    // menu opens. Skipped harmlessly when the directory does not exist yet —
    // the catalog keeps a short TTL fallback.
    ModelCatalog.startWatching()

    if config.config.autoStart {
      process.start()
    }

    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        let interval = self.map { max(0.5, $0.config.config.pollIntervalSec) } ?? 2
        // Conditions are re-read every tick rather than observed, so a
        // stats row can never be filed under stale settings.
        self?.syncHistoryConditions()
        await self?.pollOnce()

        try? await Task.sleep(for: .seconds(interval))
      }
    }

    // Unobtrusive update check 3 seconds after launch so startup remains instant
    Task {
      try? await Task.sleep(for: .seconds(3))
      await UpdateManager.shared.checkForUpdates(silent: true)
    }
  }

  /// Points the sample recorder at the long-term store, using the current
  /// server settings as the comparability key.
  private func syncHistoryConditions() {
    let c = config.config
    stats.history = modelStats
    stats.conditions = ModelStats.Key.conditions(
      kvFormat: c.kvFormat ?? "", maxContext: c.maxContext ?? "",
      maxMemory: c.maxMemory ?? "", maxCacheDisk: c.maxCacheDisk ?? "")
    stats.fallbackModel = c.model
  }

  private var cancellables = Set<AnyCancellable>()
  private var lastModel: String = ""
  /// True only for the instance that passed the single-instance check; gates
  /// every stats.json read and write.
  private var ownsHistory = false
  /// User chose "Keep Running" in the quit confirm; set only per quit.
  private var keepServerOnQuit = false

  func applicationWillTerminate(_ notification: Notification) {
    pollTask?.cancel()
    // Before the guard below: history must survive every quit, including
    // the "keep the server running" path that returns early.
    if ownsHistory { modelStats.flush() }
    // stopOnQuit off (or the user answering "Keep Running" on quit) keeps
    // the server alive, whether we launched it or it runs externally.
    guard config.config.stopOnQuit, !keepServerOnQuit else { return }
    if process.isExternal {
      process.stopExternal()
    } else {
      process.stop()
    }
  }

  /// Quit flow: if "stop on quit" is on and the server is live (launched or
  /// external), confirm first — Stop Server vs Keep Running.
  private func quit() {
    let serverLive: Bool
    switch process.state {
    case .running, .starting, .restarting: serverLive = true
    default: serverLive = false
    }
    guard config.config.stopOnQuit, serverLive else {
      NSApp.terminate(nil)
      return
    }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Stop server on quit?"
    alert.informativeText =
      "The splash server is running. Stopping it will interrupt any in-flight requests. Choose Keep Running to leave it up after Splash Control exits."
    alert.addButton(withTitle: "Stop Server")
    alert.addButton(withTitle: "Keep Running")
    keepServerOnQuit = alert.runModal() == .alertSecondButtonReturn
    NSApp.terminate(nil)
  }

  // MARK: - Polling

  private func pollOnce() async {
    let port = config.config.port
    // Port probe lives in published state, refreshed here — never from a
    // view getter, where the fork re-entered SwiftUI evaluation (BUG-17).
    await process.refreshPortListening(port: port)
    // ONE request per tick. This used to be three sequential round trips
    // (`/health`, then `/ready`, then `/status`), which tripled the socket
    // churn, the JSON work and the actor hops for no extra information:
    // a 200 from `/status` is itself proof the server is healthy, and
    // `ready` is a field in the payload. `/health` is kept purely as the
    // fallback for a server that is listening but not yet serving `/status`
    // (503 mid-boot), where the poll still needs to know something is up.
    var status: StatusDTO?
    var healthy: Bool
    do {
      status = try await client.status(port: port)
      healthy = true
    } catch {
      healthy = await client.health(port: port)
    }
    let ready = status?.ready == true
    // Log the first probe and every status change — no per-tick spam.
    if lastHealthy == nil || lastReady == nil || healthy != lastHealthy || ready != lastReady {
      SplashLog.shared.log(
        "endpoints port=\(port) status=\(healthy ? "up" : "down") ready=\(ready ? "up" : "down")")
    }
    lastHealthy = healthy
    lastReady = ready
    process.reconcile(healthy: healthy)
    guard healthy else {
      stats.setWebUIAvailable(false)
      return
    }
    if let status {
      let power = await PowerMode.current()
      stats.ingest(status, powerMode: power)
    }
    // WebUI availability derives from our own --no-webui setting; the app
    // only ever talks to /health and /status, never the root route.
    stats.setWebUIAvailable(!config.config.noWebUI)
  }

  private func restartPolling() {
    // The poll loop re-reads config each tick, so port/model changes apply
    // within 2 s without restarting the task.
  }

  private func applyLoginItem(_ enabled: Bool) {
    let service = SMAppService.mainApp
    do {
      if enabled {
        if service.status != .enabled { try service.register() }
      } else {
        if service.status == .enabled { try service.unregister() }
      }
    } catch {
      NSLog("SplashControl: login item: \(error)")
    }
  }

  // MARK: - Windows

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showDashboard()
    return true
  }

  /// Window height per tab, in points, keyed by the same tag the `Picker` uses
  /// (`DashboardView`): 0 Live, 1 Metrics, 2 Statistics, 3 Logs, 4 Settings,
  /// 5 Info. `resizeDashboard` applies the entry on every switch.
  ///
  /// Typed numbers rather than a measured fit, because nothing here has an
  /// intrinsic height to measure against: every tab body is a `ScrollView` (and
  /// `LogsView` is a scroll view over a list that starts empty), so
  /// `NSHostingController` has nothing to size to. Declaring them in one place
  /// keeps the table honest when a tab's content grows.
  ///
  /// Each value was read off a `Scripts/screenshot.sh` capture on 2026-10-03:
  /// Live is 760 because that is the smallest height showing its last tile row
  /// plus the footer. Logs is capped at the Live height (740) instead: long
  /// logs scroll inside the console, so height buys nothing there. Settings
  /// and Statistics ask for more than any screen here allows and get
  /// clamped, because their content grows with the field count and the
  /// model count — height buys content there. Metrics deliberately stays at 780: its four charts are fixed
  /// height, so every extra point would be void instead (780 leaves ~135 pt
  /// below the last chart, and 590 clipped them once data arrived). Asking for
  /// less than a tab's content is not honoured anyway: AppKit clamps to
  /// `contentMinSize`, so an under-request lands on the content height instead
  /// (Info asked for 470 and opened at 544; 545 is snug).
  private static let tabHeights: [Int: CGFloat] = [
    0: 760,  // Live
    1: 780,  // Metrics
    2: 880,  // Statistics — a list that grows with the model count
    3: 740,  // Logs — capped at the Live height; long logs scroll inside
    4: 880,  // Settings
    5: 545,  // Info — the snug About panel
  ]

  /// Resize the dashboard to the active tab's height, pinned by the top edge so
  /// only the bottom edge moves and the segmented control never jumps.
  ///
  /// Called once from `showDashboard` (unanimated, so the window opens at the
  /// right tab's height rather than visibly growing into it) and then from
  /// `DashboardView` on every tab switch.
  ///
  /// Only Logs still resolves through this table. Every other tab reports
  /// its measured content height (see ContentHeightKey) and lands in
  /// `resizeDashboardToContent`; the entries below are its opening
  /// fallback until the first report arrives, a frame later.
  ///
  func resizeDashboard(forTab tab: Int, animate: Bool = true) {
    guard let window = dashboardWindow,
      let visible = (window.screen ?? NSScreen.main)?.visibleFrame
    else { return }
    // The table is the 100 % opening height, and the zoom step multiplies it:
    // the same ratio measured in pt grows with the typography, and the entry
    // is only a fallback until the tab's own content report arrives.
    let s = CGFloat(config.config.dashboardScaleFactor)
    let height = min((Self.tabHeights[tab] ?? 740) * s, visible.height - 16)
    applyDashboardHeight(height, animate: animate)
  }

  /// Fit the window to measured tab content (min/max below). The chrome
  /// (toolbar + titlebar) is read off the live window, not a constant, so it
  /// survives toolbar changes. Reports arrive continuously, so sub-tab
  /// switches and model-count changes resize with no extra calls.
  ///
  /// Floor is the 380 pt container floor plus the 52 pt toolbar: below that
  /// AppKit would clamp to `contentMinSize` anyway. No tab ScrollView may
  /// declare its own taller minHeight — a 560 floor under a shorter report
  /// compressed the ScrollView until content slid under the toolbar.
  ///
  ///
  /// The zoom step scales typography *inside* the content, so reports
  /// already carry it — no step multiplication here. The floor is the fixed
  /// view-level 380 pt plus chrome; ceiling is the screen.
  func resizeDashboardToContent(_ contentHeight: CGFloat, animate: Bool = true) {
    guard let window = dashboardWindow,
      let contentView = window.contentView,
      let visible = (window.screen ?? NSScreen.main)?.visibleFrame
    else { return }
    let chrome = max(0, window.frame.height - contentView.frame.height)
    let height = min(max(contentHeight + chrome, 432), visible.height - 16)
    SplashLog.shared.log(
      "resize content=\(Int(contentHeight)) chrome=\(Int(chrome)) -> frame=\(Int(height)) (was \(Int(window.frame.height)))"
    )
    applyDashboardHeight(height, animate: animate)
  }

  private func applyDashboardHeight(_ height: CGFloat, animate: Bool) {
    guard let window = dashboardWindow else { return }
    let delta = height - window.frame.height
    guard abs(delta) > 0.5 else { return }
    var frame = window.frame
    frame.origin.y -= delta
    frame.size.height = height
    if animate {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      }
    } else {
      window.setFrame(frame, display: true)
    }
  }

  /// Size and place a window from the visible frame of the screen it opens on.
  ///
  /// Fixed content sizes are wrong on every machine that is not the one the
  /// number was typed on: too tall on a laptop, too short on a 27", and
  /// anchored to the wrong display in a two-screen setup. Height is the full
  /// visible frame minus 40 pt, capped at 1100 pt so a very large display does
  /// not stretch the window past the point where a Settings field is
  /// comfortable to read. `showDashboard` then trims it to the opening tab.
  private func fitToScreen(_ window: NSWindow) {
    // AppKit-level floor, so no tab's content can talk the window below the
    // size every tab already declares in SwiftUI. 380 rather than the old
    // 560 so the Info tab has room to be short.
    window.minSize = NSSize(width: 760, height: 380)
    guard let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
      window.center()
      return
    }
    // The zoom step scales typography inside the content; the window width
    // follows it so the layout keeps its 100 % proportions and grown rows
    // never run past the edge. Height needs no step: tabs report their own
    // (already scaled) content height.
    let width: CGFloat = 880 * CGFloat(config.config.dashboardScaleFactor)
    let height = min(visible.height - 40, 1100)
    window.setContentSize(NSSize(width: width, height: height))
    // Top-inside the visible frame, not `visible.minY + 20`: that put the
    // window's top 20 pt *above* the screen, because the height there was a
    // content height and the frame is that plus the toolbar. Only shows up
    // once a tab grows back to full height and stays there.
    window.setFrameOrigin(
      NSPoint(
        x: visible.midX - width / 2,
        y: visible.maxY - window.frame.height - 16))
  }

  private func showDashboard(tab: Int? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    if let targetTab = tab {
      navigation.selectedTab = targetTab
    }
    if let window = dashboardWindow {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      if let targetTab = tab {
        resizeDashboard(forTab: targetTab, animate: true)
      }
      return
    }
    let targetTab = tab ?? navigation.selectedTab
    navigation.selectedTab = targetTab
    let view = DashboardView(
      stats: stats, process: process, config: config,
      modelStats: modelStats, bench: bench, navigation: navigation)
    let hosting = NSHostingController(rootView: view)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Splash"
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    fitToScreen(window)
    window.isReleasedWhenClosed = false
    dashboardWindow = window
    window.makeKeyAndOrderFront(nil)
    // Not from `DashboardView.onAppear`: the hosting view appears inside
    // `NSWindow(contentViewController:)` above, before `dashboardWindow` is
    // assigned, so that call found no window and the window opened at
    // `fitToScreen`'s full-screen height (873 pt) until the first tab switch.
    resizeDashboard(forTab: targetTab, animate: false)
  }

  private func showSettings() {
    showDashboard(tab: 4)
  }

  /// Cmd +/- step the dashboard zoom, matching the editor convention. The
  /// tray is an accessory app without a main menu, so menu key equivalents
  /// only fire while a menu is open - a local event monitor is the path that
  /// works while the dashboard itself has focus. Cmd+= / Cmd++ step up,
  /// Cmd+- steps down, clamped at the ends of the closed step set. The
  /// accepted characters follow the *layout*: US sends the unshifted glyph
  /// ("=" for Cmd+Shift+=), a German layout sends the literal "+" (its +
  /// needs no shift) and "-" likewise.
  private func installZoomKeyShortcuts() {
    zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // `contains` + exclusions, not `== [.command]`: AppKit ORs a device
      // side-bit (which Command key) into `deviceIndependentFlagsMask`, so
      // equality against [.command] rejects every real Cmd keystroke. Shift
      // stays allowed: the physical Cmd++ arrives as shift+Cmd+"=" on US.
      let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let key = event.charactersIgnoringModifiers
      guard mods.contains(.command), !mods.contains(.control), !mods.contains(.option),
        key == "=" || key == "+" || key == "-"
      else { return event }
      let steps = SplashConfig.dashboardScaleValues
      guard let i = steps.firstIndex(of: self.config.config.dashboardScale) else { return event }
      let dir = (key == "=" || key == "+") ? 1 : -1
      let next = min(max(i + dir, 0), steps.count - 1)
      guard steps[next] != self.config.config.dashboardScale else { return event }
      self.config.config.dashboardScale = steps[next]
      return nil
    }
  }

  /// Apply a new zoom step to the open dashboard (Tray ▸ Zoom through the
  /// config sink). The step lives in the SwiftUI environment, so the content
  /// re-renders at the new text size on its own and reports a new height a
  /// frame later (`ContentHeightKey`) — the window follows through the normal
  /// content-fit path. What cannot re-render itself is the window *width*:
  /// the layout keeps its 100 % proportions only if the frame grows with the
  /// step, so it is set here. Top-left stays pinned, so the toolbar never
  /// jumps; the frame is clamped into the visible display.
  private func applyDashboardZoom(_ scale: Double) {
    let s = CGFloat(scale)
    guard abs(s - lastAppliedScale) > 0.001 else { return }
    lastAppliedScale = s
    guard let window = dashboardWindow,
      let visible = (window.screen ?? NSScreen.main)?.visibleFrame
    else { return }
    let width = min(880 * s, visible.width - 16)
    SplashLog.shared.log(
      "zoom s=\(s) -> width=\(Int(width)) (was \(Int(window.frame.width)))")
    var frame = window.frame
    frame.size.width = width
    frame.origin.x = min(frame.origin.x, visible.maxX - width - 8)
    frame.origin.x = max(frame.origin.x, visible.minX + 8)
    window.setFrame(frame, display: true)
    // Logs is the only tab that reports no measured height: its frame comes
    // from the `tabHeights` table times the step, applied on tab switches.
    // A zoom change re-renders its rows but refits nothing, so the window
    // would keep the *old* step's height under the new content. Re-apply the
    // tab's height here, same top-pinned path - but never animated: a held
    // Cmd++ lands several steps per second, and overlapping `animator()`
    // transitions leave the window's live-resize drawing pass stuck on the
    // previous step's raster (the filter row and search field kept drawing
    // at 100 % under a 200 % frame until a click dirtied the view). A zoom
    // step is discrete anyway - the width jump is already instant.
    if navigation.selectedTab == 3 {
      resizeDashboard(forTab: 3, animate: false)
    }
    window.displayIfNeeded()
  }

  private func showInfo() {
    showDashboard(tab: 5)
  }
}
