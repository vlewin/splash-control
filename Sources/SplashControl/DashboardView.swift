import Charts
import SwiftUI

// MARK: - Formatting helpers

private func fmt(_ value: Double?, _ format: String, suffix: String = "") -> String {
  guard let value else { return "—" }
  return String(format: format, value) + suffix
}

private func fmtGiB(_ bytes: UInt64?) -> String {
  guard let bytes else { return "—" }
  return String(format: "%.1f", Double(bytes) / 1_073_741_824)
}

private func fmtTok(_ tokens: UInt64?) -> String {
  guard let tokens else { return "—" }
  if tokens >= 1_000_000 {
    return String(format: "%.1fM", Double(tokens) / 1_000_000)
  } else if tokens >= 1_000 {
    return String(format: "%.1fK", Double(tokens) / 1_000)
  }
  return "\(tokens)"
}

/// One formatter for the scrub readout and the window buttons. Local time, the
/// same zone both log channels are pinned to, so a caret time can be matched
/// against a log line by eye.
enum Stamp {
  static let clock: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Europe/Berlin")
    f.dateFormat = "HH:mm:ss"
    return f
  }()
}

// MARK: - Hero panels

private struct HeroPanel: View {
  let title: String
  let value: String
  let unit: String
  let accent: Color
  let caption: String
  /// Optional status icon, top-right of the title row (e.g. power ⚡, pressure ⚠).
  var icon: (() -> AnyView)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        if let icon { icon() }
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value)
          .font(.system(size: 40, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.3)
          .foregroundStyle(accent)
        Text(unit)
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
      Text(caption)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .leading)
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }
}

// MARK: - Chart

private struct SeriesChart: View {
  let title: String
  let unit: String
  let samples: [Sample]
  let markers: [Marker]
  let value: (Sample) -> Double?
  let color: Color
  var primaryName: String = "value"
  /// Shared scrub instant. One binding, four charts: the same x position means
  /// the same second everywhere, which is what makes a TTFT spike readable
  /// against the memory curve that preceded it.
  @Binding var hoverDate: Date?
  /// Extra series. An array rather than one `secondary` because a memory chart
  /// legitimately carries three lines (load, available, and a floor marker),
  /// and a second slot would have meant inventing a third property each time.
  var extras: [Extra] = []
  struct Extra {
    let name: String
    let color: Color
    let value: (Sample) -> Double?
  }
  /// Fixed y-axis ceiling (e.g. 150 tok/s on this machine, or physical memory
  /// on the memory chart); nil = auto-scale
  var yMax: Double? = nil
  /// Minimum y-axis floor to prevent micro-decimal ticks when idle (e.g. 1.0 s on TTFT)
  var yMinFloor: Double? = nil
  /// Desired count of x-axis tick marks (fewer for side-by-side charts)
  var desiredTicks: Int = 5
  /// Rolling window for the x-axis (the buffer may retain more).
  var window: TimeInterval = 60 * 60
  /// Primary-series render mode: plain line or prominent bars.
  var mode: Mode = .line

  enum Mode {
    case line
    case bars
  }

  private var bucketName: String {
    let seconds = Int(bucketDuration)
    return seconds >= 60 ? "\(seconds / 60)m avg" : "\(seconds)s avg"
  }

  private var seriesNames: [String] {
    [primaryName] + extras.map(\.name)
  }

  private var seriesColors: [Color] {
    [color] + extras.map(\.color)
  }

  /// One closure for every plotted series, indexed the same way as
  /// `seriesNames` — so the bucketing below has a single extract function
  /// instead of a parallel array of optionals per sample.
  private var extractors: [(Sample) -> Double?] {
    [value] + extras.map(\.value)
  }

  private var rawPoints: [StatsModel.ChartPoint] {
    var out: [StatsModel.ChartPoint] = []
    for s in windowSamples {
      let v = s.gap ? nil : value(s)
      out.append(StatsModel.ChartPoint(date: s.date, value: v, series: primaryName))
      for e in extras {
        out.append(
          StatsModel.ChartPoint(
            date: s.date, value: s.gap ? nil : e.value(s),
            series: e.name))
      }
    }
    return out
  }

  private var bucketDuration: TimeInterval {
    guard mode == .bars else { return 1 }
    // Dynamic batch duration scaling with window:
    // - 15m (900s)  -> 10s buckets (90 bars max, solid 6-10pt width, responsive real-time view)
    // - 30m (1800s) -> 20s buckets (90 bars max, solid 6-10pt width)
    // - 1h  (3600s) -> 40s buckets (90 bars max, solid 6-10pt width)
    if window <= 900 {
      return 10
    } else if window <= 1800 {
      return 20
    } else {
      return 40
    }
  }

  private func barDate(for point: StatsModel.ChartPoint) -> Date {
    let count = seriesNames.count
    guard count > 1 else {
      return point.date.addingTimeInterval(bucketDuration * 0.5)
    }
    let idx = seriesNames.firstIndex(of: point.series) ?? 0
    if count == 2 {
      let frac = idx == 0 ? 0.28 : 0.72
      return point.date.addingTimeInterval(bucketDuration * frac)
    }
    let step = 0.8 / Double(count - 1)
    let frac = 0.1 + Double(idx) * step
    return point.date.addingTimeInterval(bucketDuration * frac)
  }

  private var barWidth: CGFloat {
    guard let domain = plotDomain else { return 6.0 }
    let span = max(bucketDuration, domain.upperBound.timeIntervalSince(domain.lowerBound))
    let visibleSlots = max(1.0, span / bucketDuration)
    let slotWidth = 740.0 / visibleSlots
    let seriesCount = CGFloat(max(1, seriesNames.count))
    if seriesCount > 1 {
      let dynamic = slotWidth * 0.38
      return max(2.0, min(5.0, dynamic))
    } else {
      let dynamic = slotWidth * 0.75
      return max(4.0, min(10.0, dynamic))
    }
  }

  private func bucketStart(for date: Date) -> Date {
    StatsModel.bucketStart(for: date, duration: bucketDuration)
  }

  /// Samples inside the rolling x window. `samples` is append-only in date
  /// order, so the lower bound is a binary search rather than a filter: a 5 h
  /// retention buffer at a 1 s poll holds ~18 000 samples, and building marks
  /// for all of them to keep the ~900 on screen is what made every layout
  /// pass cost ~200 ms. One bucket of slack keeps a bucket straddling the
  /// lower bound fully accumulated, so the leftmost bar is unchanged.
  private var windowSamples: ArraySlice<Sample> {
    guard let last = samples.last?.date else { return [] }
    let cutoff = last.addingTimeInterval(-window - bucketDuration)
    return samples[StatsModel.lowerBound(cutoff, in: samples)...]
  }

  /// Bar charts bucket; line charts plot raw samples. Bucketing itself lives in
  /// `StatsModel.chartPoints` — pure, assertable, and no longer part of this
  /// view's body evaluation.
  private var points: [StatsModel.ChartPoint] {
    guard mode == .bars else { return rawPoints }
    let fns = extractors
    return StatsModel.chartPoints(
      samples: windowSamples, series: seriesNames,
      duration: bucketDuration
    ) { sample, i in
      fns[i](sample)
    }
  }

  /// Points inside the rolling x window. Marks outside the domain would be
  /// clipped anyway; filtering keeps the mark count small for wide buffers.
  private var visiblePoints: [StatsModel.ChartPoint] {
    guard let d = xDomain else { return points }
    return points.filter { d.contains($0.date) }
  }

  private var visiblePrimaryValues: [Double] {
    visiblePoints.filter { $0.series == primaryName }.compactMap(\.value)
  }

  private var visibleAverage: Double? {
    let values = visiblePrimaryValues
    guard !values.isEmpty else { return nil }
    return values.reduce(0.0, +) / Double(values.count)
  }

  /// Fixed-span rolling window: the axis always covers the last `window`
  /// of wall-clock time (clamped to the first sample while the buffer fills).
  private var xDomain: ClosedRange<Date>? {
    guard let last = samples.last?.date else { return nil }
    let lower = max(samples.first?.date ?? last, last.addingTimeInterval(-window))
    return lower...last
  }

  private var barPadding: TimeInterval {
    guard mode == .bars else { return 1 }
    let dates =
      visiblePoints
      .filter { $0.series == primaryName }
      .map(\.date)
    guard dates.count > 1 else { return bucketDuration }
    let intervals = zip(dates, dates.dropFirst())
      .map { $1.timeIntervalSince($0) }
      .filter { $0 > 0 }
    return intervals.min() ?? bucketDuration
  }

  private var plotDomain: ClosedRange<Date>? {
    guard let domain = xDomain else { return nil }
    guard mode == .bars else {
      return domain.lowerBound...domain.upperBound.addingTimeInterval(1.5)
    }
    let padding = barPadding
    return domain.lowerBound.addingTimeInterval(
      -padding)...domain.upperBound.addingTimeInterval(padding)
  }

  private var yUpper: Double {
    if let yMax { return yMax }
    let top = visiblePoints.compactMap(\.value).max() ?? 0
    if let yMinFloor { return max(top, yMinFloor) }
    if mode != .bars { return max(top, 1.0) }
    return StatsModel.autoScaleCeiling(observed: top)
  }

  private func statLabel(_ name: String, _ v: Double?) -> some View {
    HStack(spacing: 3) {
      Text("\(name):")
        .foregroundStyle(.secondary)
      Text(v.map { String(format: "%.1f", $0) + (unit.isEmpty ? "" : " " + unit) } ?? "—")
        .fontWeight(.semibold)
        .monospacedDigit()
    }
    .font(.caption2)
  }

  private func legendItem(_ name: String, _ col: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(col)
        .frame(width: 6, height: 6)
      Text(name)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  /// Readout for the scrub cursor, reporting values for all series at this chart's instant.
  private var scrubReadout: some View {
    guard let d = hoverDate, let s = nearest(to: d) else {
      return AnyView(EmptyView())
    }
    let pv = value(s)
    return AnyView(
      HStack(spacing: 8) {
        HStack(spacing: 3) {
          Circle().fill(color).frame(width: 5, height: 5)
          Text(pv.map { String(format: "%.1f", $0) } ?? "—")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        ForEach(extras, id: \.name) { e in
          let ev = e.value(s)
          HStack(spacing: 3) {
            Circle().fill(e.color).frame(width: 5, height: 5)
            Text(ev.map { String(format: "%.1f", $0) } ?? "—")
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
          }
        }
      }
    )
  }

  /// Closest sample in the window to an instant. Binary search, because the
  /// buffer reaches 18 000 samples and this runs on every pointer move.
  private func nearest(to date: Date) -> Sample? {
    let all = Array(windowSamples)
    guard !all.isEmpty else { return nil }
    var lo = 0
    var hi = all.count - 1
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if all[mid].date < date { lo = mid + 1 } else { hi = mid }
    }
    return [max(0, lo - 1), lo]
      .map { all[$0] }
      .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
  }

  /// Shared scrub cursor. A drag (or hover) anywhere on any chart sets the date;
  /// every chart then draws its rule at that instant. `.chartOverlay` rather
  /// than per-chart geometry so the x position is mapped by the framework.
  private var scrubOverlay: some View {
    GeometryReader { geo in
      Rectangle()
        .fill(.clear)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { drag in
              let domain = plotDomain ?? .distantPast ... .distantFuture
              let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
              guard span > 0 else { return }
              let x = min(max(drag.location.x, 0), geo.size.width)
              hoverDate = domain.lowerBound.addingTimeInterval(span * x / geo.size.width)
            }
        )
        .onTapGesture { hoverDate = nil }
    }
  }

  private var styledChart: some View {
    let chart = Chart {
      if mode == .bars {
        ForEach(visiblePoints) { point in
          if let pv = point.value {
            if extras.isEmpty {
              BarMark(
                x: .value("Time", barDate(for: point)),
                y: .value(unit, pv),
                width: .fixed(barWidth)
              )
              .foregroundStyle(color.opacity(0.85))
              .cornerRadius(2)
            } else {
              BarMark(
                x: .value("Time", barDate(for: point)),
                y: .value(unit, pv),
                width: .fixed(barWidth)
              )
              .foregroundStyle(by: .value("Series", point.series))
              .cornerRadius(1.5)
            }
          }
        }
      } else {
        ForEach(visiblePoints) { point in
          if let pv = point.value {
            LineMark(
              x: .value("Time", point.date),
              y: .value(unit, pv),
              series: .value("Series", point.series)
            )
            .foregroundStyle(by: .value("Series", point.series))
            .interpolationMethod(.monotone)
          }
        }
      }
      let domain = plotDomain ?? .distantPast ... .distantFuture
      ForEach(markers.filter { domain.lowerBound <= $0.date && $0.date <= domain.upperBound }) {
        marker in
        RuleMark(x: .value("Mark", marker.date))
          .foregroundStyle(.secondary.opacity(0.6))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .annotation(position: .top, alignment: .center, spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
              .font(.system(size: 6))
              .foregroundStyle(Color.secondary.opacity(0.85))
          }
          .annotation(
            position: .top, alignment: .center, spacing: 6,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            Text(marker.label)
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(.primary.opacity(0.85))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 3)
                  .fill(Color(nsColor: .controlBackgroundColor))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 3)
                  .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
              )
          }
      }
      // The scrub rule, drawn last so it sits above the data.
      if let hoverDate, plotDomain.map({ $0.contains(hoverDate) }) == true {
        RuleMark(x: .value("Scrub", hoverDate))
          .foregroundStyle(.primary.opacity(0.55))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .zIndex(10)
      }
    }
    .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
    .chartLegend(.hidden)
    .chartXAxis {
      // Seconds are mandatory below a minute. Four consecutive 15 s bars
      // formatted hour:minute all read "23:32", which is exactly how a
      // working 15 s chart was read as one bar per minute.
      AxisMarks(values: .automatic(desiredCount: desiredTicks)) { _ in
        AxisGridLine()
        AxisValueLabel(
          format: bucketDuration < 60
            ? .dateTime.hour().minute().second()
            : .dateTime.hour().minute(),
          anchor: .top)
      }
    }
    .chartYScale(domain: 0...yUpper)
    .chartOverlay { _ in scrubOverlay }
    .padding(.top, 16)
    .frame(height: 114)

    if let domain = plotDomain {
      return AnyView(chart.chartXScale(domain: domain))
    }
    return AnyView(chart)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(
          "\(title) \(unit.isEmpty ? "" : "(" + unit + ")")\(mode == .bars ? " · \(bucketName)" : "")"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Spacer()
        if hoverDate != nil {
          scrubReadout
        } else if !extras.isEmpty {
          HStack(spacing: 8) {
            legendItem(primaryName, color)
            ForEach(extras, id: \.name) { e in
              legendItem(e.name, e.color)
            }
          }
          .lineLimit(1)
        } else if mode == .bars {
          HStack(spacing: 8) {
            statLabel("min", visiblePrimaryValues.min())
            statLabel("max", visiblePrimaryValues.max())
            statLabel("avg", visibleAverage)
            statLabel("last", visiblePrimaryValues.last)
          }
          .lineLimit(1)
        }
      }
      // Not `points.isEmpty`: empty buckets now contribute nil-valued
      // points, so a chart with nothing to plot is non-empty.
      if points.allSatisfy({ $0.value == nil }) {
        Text("collecting…")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 90)
      } else {
        styledChart
      }
    }
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
    .frame(maxWidth: .infinity, alignment: .center)
  }
}

// MARK: - Small stat tiles

private struct Tile: View {
  let title: String
  let value: String
  var warning: Bool = false
  var caption: String? = nil
  /// When set, a warning icon appears top-right of the title with this as tooltip.
  var alert: String? = nil
  var alertColor: Color = .orange
  /// Optional action control, top-right of the title row after any alert icon
  /// (e.g. the SSD tier's cache reset). Rigid like the alert: it must never
  /// flex or the title's Spacer math shifts.
  var action: (() -> AnyView)? = nil

  var body: some View {
    // Exactly three rows on every tile; the caption row always exists
    // (blank when unused), truncates with ellipsis, full text on hover.
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(title.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        if let alert {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(alertColor)
            .help(alert)
        }
        if let action { action() }
      }
      Text(value)
        .font(.body.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(warning ? .orange : .primary)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(caption ?? " ")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(caption ?? "")
    }
    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.04))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
    )
  }
}

// MARK: - Dashboard Navigation

final class DashboardNavigation: ObservableObject {
  @Published var selectedTab: Int

  init(selectedTab: Int = DashboardView.initialTab) {
    self.selectedTab = selectedTab
  }
}

// MARK: - Dashboard

struct DashboardView: View {
  /// Tag the dashboard opens on. Named because `AppDelegate.showDashboard`
  /// sizes the window from it: the window has to be at the right height before
  /// the view's `onAppear` could report anything, and by then the view has
  /// already appeared once (inside `NSWindow(contentViewController:)`).
  static let initialTab = 0

  @ObservedObject var stats: StatsModel
  @ObservedObject var process: SplashProcess
  @ObservedObject var config: ConfigStore
  @ObservedObject var modelStats: ModelStats
  @ObservedObject var bench: BenchmarkEngine
  @ObservedObject var navigation: DashboardNavigation
  /// The scrub instant shared by every chart in the Live tab.
  @State private var hoverDate: Date?
  /// True for a beat after a clipboard write, so the buttons confirm.
  @State private var copiedWhat: String?
  @State private var confirmRestart = false
  @State private var confirmSSDCacheReset = false

  init(
    stats: StatsModel, process: SplashProcess, config: ConfigStore,
    modelStats: ModelStats, bench: BenchmarkEngine,
    navigation: DashboardNavigation = DashboardNavigation()
  ) {
    self.stats = stats
    self.process = process
    self.config = config
    self.modelStats = modelStats
    self.bench = bench
    self.navigation = navigation
  }

  var body: some View {
    VStack(spacing: 0) {
      // Each branch builds its view only when selected, so the Logs tab's
      // 2 s refresh stops the moment you switch away.
      switch navigation.selectedTab {
      case 0: live
      case 1: metrics
      case 2: StatsView(stats: modelStats, bench: bench)
      case 3: LogsView()
      case 4: SettingsView(config: config, process: process, stats: stats, onClose: nil)
      default: InfoView(config: config, process: process, stats: stats)
      }
    }
    // The floor for *every* tab, pinned on the container rather than on each
    // branch: LogsView has no intrinsic height (its content is a scroll view
    // over a list that is briefly empty while the next channel is read), so on
    // the switch the hosting controller recomputed the fitting size from the
    // header + footer alone and shrank the window to ~150 pt, leaving three log
    // rows. One pin here covers all five tabs and any future sixth.
    //
    // 380, not 560: the window no longer stays at full screen height, so the
    // floor only has to clear the shortest tab (`AppDelegate.tabHeights`).
    // Below this the hosting controller would refuse to shrink further.
    .frame(minWidth: 760, minHeight: 380)
    // Per-tab height. Logs keeps its fixed table height; every other tab
    // applies its measured content height (ContentHeightKey), which
    // refires on sub-tab switches and model-count changes, so the window
    // follows the content. A report is applied only to the tab that
    // measured it: one landing after a fast tab switch shrank the new
    // tab to the old tab's height and cut its header.
    // There is deliberately no `onAppear` here: the view has already
    // appeared by the time AppDelegate can name this window, so the
    // opening height is set from `showDashboard` instead.
    .onChange(of: navigation.selectedTab) { _, new in
      if new == 3 { resizeDashboard(new) }
    }
    .onPreferenceChange(ContentHeightKey.self) { report in
      guard let report else { return }
      let owner: Int? =
        if report.source.hasPrefix("live") { 0 } else if report.source.hasPrefix("metrics") {
          1
        } else if report.source.hasPrefix("stats") { 2 } else if report.source.hasPrefix("settings")
        { 4 } else if report.source.hasPrefix("info") { 5 } else { nil }
      guard owner == navigation.selectedTab else {
        SplashLog.shared.log(
          "content-report dropped stale source=\(report.source) tab=\(navigation.selectedTab)")
        return
      }
      resizeToContent(report.height)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("View", selection: $navigation.selectedTab) {
          Text("Live").tag(0)
          Text("Metrics").tag(1)
          Text("Statistics").tag(2)
          Text("Logs").tag(3)
          Text("Settings").tag(4)
          Text("Info").tag(5)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // 530, not 440: six segments at the old width gave "Statistics"
        // ~73 pt, under its ~87 pt natural width, so the widest label is
        // the one that would have truncated.
        .frame(width: 530)
      }
    }
  }

  /// Ask `AppDelegate` to fit the window to the active tab's height.
  ///
  /// Two things in here are load-bearing, both from the window collapsing to
  /// 432 pt (= the 380 floor below plus the 52 pt toolbar) when switching from
  /// a tab that is already full height:
  ///
  /// - `MainActor.assumeIsolated`, because SwiftUI's `onChange` action is not
  ///   actor-isolated while `AppDelegate` is `@MainActor`, and both already run
  ///   on the main thread — the hop would be a lie about where we are.
  /// - The `async` hop. Read the frame in the same turn as the tab change and
  ///   it is still the *old* tab's correct height, so `resizeDashboard`
  ///   computed a delta of ~0 and returned without doing anything; `LogsView`
  ///   then laid out over a briefly empty list, `contentMinSize` dropped, and
  ///   AppKit clamped the window down to the floor with nothing left to
  ///   correct it. Coming back from a shorter tab masked it, because there the
  ///   delta is real and the explicit `setFrame` lands after the clamp.
  private func resizeDashboard(_ tab: Int) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        (NSApp.delegate as? AppDelegate)?.resizeDashboard(forTab: tab)
      }
    }
  }

  /// Fit the window to measured tab content (see ContentHeightKey). Same
  /// main-thread hop as above, for the same reason.
  private func resizeToContent(_ height: CGFloat) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        (NSApp.delegate as? AppDelegate)?.resizeDashboardToContent(height)
      }
    }
  }

  /// Controls that used to require leaving this window for the menu bar.
  /// Restarting from here is a real action on a real process, so it keeps the
  /// same confirm-if-a-model-swap guard the menu has — one guard, two doors,
  /// rather than a second, lazier one.
  private var actionBar: some View {
    HStack(spacing: 8) {
      Button {
        guard !process.isBusy else { return }
        if case .running = process.state { process.stop() } else { process.start() }
      } label: {
        Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.fill" : "play.fill")
      }
      .disabled(process.isBusy)
      Button {
        confirmRestart = true
      } label: {
        Label("Restart", systemImage: "arrow.clockwise")
      }
      .disabled(process.isBusy)
      Divider().frame(height: 18)
      Button {
        copy("endpoint", process.endpointURL)
      } label: {
        Label(
          copiedWhat == "endpoint" ? "Copied" : process.endpointURL,
          systemImage: copiedWhat == "endpoint" ? "checkmark" : "link"
        )
        .lineLimit(1)
      }
      .help("Copy the OpenAI-compatible base URL")
      Button {
        copy("curl", process.curlSnippet(serving: stats.latest?.instance?.model))
      } label: {
        Label(
          copiedWhat == "curl" ? "Copied" : "curl",
          systemImage: copiedWhat == "curl" ? "checkmark" : "terminal")
      }
      .help("Copy a runnable chat-completion request")
      Button {
        if let url = URL(string: "http://127.0.0.1:\(config.config.port)/") {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label("WebUI", systemImage: "safari")
      }
      .disabled(!stats.webUIAvailable)
      .help("Open the server's own web interface")
      Spacer()
    }
    .controlSize(.small)
    .confirmationDialog("Hard restart the server?", isPresented: $confirmRestart) {
      Button("Restart") {
        Task { await process.hardRestart(serving: stats.latest?.instance?.model) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Says which model goes away and which arrives, because that is the
      // part with consequences: cached prefixes are dropped and the
      // configured model replaces whatever is serving.
      if let other = StatsModel.modelMismatch(
        configured: config.config.model,
        serving: stats.latest?.instance?.model)
      {
        Text(
          "Restarting stops \(ModelCatalog.displayName(for: other)) and starts "
            + "\(ModelCatalog.displayName(for: config.config.model)). "
            + "Cached prefixes are discarded, so the next request pays a cold prefill.")
      } else {
        Text("Cached prefixes are discarded, so the next request pays a cold prefill.")
      }
    }
  }

  private var isRunning: Bool {
    if case .running = process.state { return true }
    return false
  }

  private func copy(_ what: String, _ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    SplashLog.shared.log("dashboard_copy what=\(what) bytes=\(text.count)")
    copiedWhat = what
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      if copiedWhat == what { copiedWhat = nil }
    }
  }

  private var live: some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          header
          actionBar
        }

        Divider()

        hero
        grid
        Text(
          "Polling 127.0.0.1:\(String(config.config.port))/status every \(Int(config.config.pollIntervalSec)) s \u{b7} tok/s = sustained \u{b7} batch peak swings with draft acceptance \u{b7} percentiles = engine rolling window"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .reportContentHeight("live")
    }
    .frame(minWidth: 760)
  }

  private var metrics: some View {
    ScrollView {
      VStack(spacing: 14) {
        metricsHeader

        Divider()

        charts

        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .foregroundStyle(.tertiary)
          Text(
            "Drag horizontally on any chart to inspect synchronized values across all four series"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)

          if let d = hoverDate {
            Spacer()
            Text("Scrubbing \(Stamp.clock.string(from: d))")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            Button("Clear") { hoverDate = nil }
              .buttonStyle(.link)
              .font(.caption2)
          }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .reportContentHeight("metrics")
    }
    .frame(minWidth: 760)
  }

  private var metricsHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      let model = stats.latest?.instance?.model ?? config.config.model
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text("Metrics")
            .font(.title3.weight(.semibold))
          statusChip
          powerChip
        }
        Text("Rolling engine time series \u{b7} \(ModelCatalog.displayName(for: model))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 8) {
        Text("Window:")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Picker("Chart window", selection: $config.config.windowMinutes) {
          Text("15 min").tag(15)
          Text("30 min").tag(30)
          Text("1 h").tag(60)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
      }
    }
  }

  /// The four charts, bound to one scrub instant.
  /// Rows 1 & 2 span full width for time-series throughput/latency resolution.
  /// Row 3 places Memory and KV cache side-by-side for direct resource comparison.
  private var charts: some View {
    VStack(spacing: 12) {
      let window = TimeInterval(config.config.windowMinutes * 60)
      SeriesChart(
        title: "Decode throughput", unit: "tok/s",
        samples: stats.samples, markers: stats.markers,
        // Primary line is the sustained rate — the figure comparable to
        // the server's own per-request log line. Was bars of the
        // per-batch reading, which is not a rate: its spread comes from
        // speculative-draft acceptance, measured 36.7 to 323.7 tok/s on
        // one model inside a single request.
        value: { $0.sustainedTps }, color: decodeColor,
        primaryName: "sustained",
        hoverDate: $hoverDate,
        // Overlay keeps the batch reading visible, because a collapse in
        // draft acceptance is a real upstream fault worth spotting.
        extras: [
          SeriesChart.Extra(
            name: "batch peak", color: .orange,
            value: { $0.decodeTps })
        ],
        window: window,
        mode: .bars
      )
      SeriesChart(
        title: "Prefill time (TTFT)", unit: "s",
        samples: stats.samples, markers: stats.markers,
        value: { $0.ttftP50Ms.map { $0 / 1000 } }, color: .purple,
        primaryName: "p50",
        hoverDate: $hoverDate,
        extras: [
          SeriesChart.Extra(
            name: "p95", color: .pink,
            value: { $0.ttftP95Ms.map { $0 / 1000 } })
        ],
        yMinFloor: 1.0,
        window: window
      )
      HStack(spacing: 12) {
        SeriesChart(
          title: "Memory", unit: "GiB",
          samples: stats.samples, markers: stats.markers,
          // Line 1 — everything the served model occupies: weights, KV
          // cache, state cache and runtime, in one number.
          value: { $0.metalBytes.map { Double($0) / 1_073_741_824 } }, color: .teal,
          primaryName: "splash (model)",
          hoverDate: $hoverDate,
          // Line 2 — the whole machine's usage.
          extras: [
            SeriesChart.Extra(
              name: "system in use", color: .indigo,
              value: {
                $0.totalLoadBytes.map { Double($0) / 1_073_741_824 }
              })
          ],
          yMax: stats.latest?.memoryPlan?.device?.physicalMemoryBytes
            .map { Double($0) / 1_073_741_824 },
          desiredTicks: 3,
          window: window
        )
        let pageTokens = stats.latest?.kv?.blockTokens ?? 32
        SeriesChart(
          title: "KV pages", unit: "pages · \(pageTokens) tok/page",
          samples: stats.samples, markers: stats.markers,
          value: { $0.kvPagesActive.map(Double.init) }, color: .teal,
          primaryName: "active",
          hoverDate: $hoverDate,
          yMinFloor: 100,
          desiredTicks: 3,
          window: window
        )
      }
    }
  }

  /// Compact age for a held reading: seconds while that is meaningful, then
  /// minutes. A held hero value that never admits it is minutes old is the
  /// same defect as a stale average.
  private static func ageLabel(_ t: TimeInterval) -> String {
    t < 90 ? "\(max(0, Int(t.rounded())))s ago" : "\(max(1, Int((t / 60).rounded())))m ago"
  }

  private var availableModels: [String] {
    var ids = ModelCatalog.installed()
    let current = config.config.model
    if !ids.contains(current) {
      ids.insert(current, at: 0)
    }
    return ids
  }

  private func selectModel(_ id: String) {
    if id == config.config.model { return }
    let serving = stats.latest?.instance?.model
    if process.isExternal {
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
    } else if stats.agentStatus == .decoding {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Switch to \(ModelCatalog.displayName(for: id))?"
      alert.informativeText =
        "Splash is currently decoding an inference request. Switching models will stop the server and discard active work."
      alert.addButton(withTitle: "Switch Model")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    config.config.model = id
  }

  private var modelSelector: some View {
    let currentId = stats.latest?.instance?.model ?? config.config.model
    let shortName = (currentId as NSString).lastPathComponent
    let labelText = modelStatusText(modelName: shortName)

    return Menu {
      Section("Installed Models") {
        ForEach(availableModels, id: \.self) { id in
          Button {
            selectModel(id)
          } label: {
            if id == currentId {
              Label(ModelCatalog.displayName(for: id), systemImage: "checkmark")
            } else {
              Text(ModelCatalog.displayName(for: id))
            }
          }
        }
      }
      Divider()
      Button {
        NSWorkspace.shared.open(ModelCatalog.modelsRoot)
      } label: {
        Label("Reveal Models in Finder", systemImage: "folder")
      }
      Button {
        navigation.selectedTab = 4
      } label: {
        Label("Configure in Settings…", systemImage: "gearshape")
      }
    } label: {
      Text(labelText)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.primary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.visible)
    .fixedSize()
  }

  private var modelCopyButton: some View {
    let currentId = stats.latest?.instance?.model ?? config.config.model
    let isCopied = copiedWhat == "model"
    return Button {
      copy("model", currentId)
    } label: {
      Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
        .font(.caption)
        .foregroundStyle(isCopied ? .green : .secondary)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isCopied ? "Copied!" : "Copy model ID: \(currentId)")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        modelSelector
        modelCopyButton
        statusChip
        if process.isBusy {
          ProgressView()
            .controlSize(.small)
            .tint(.orange)
        }
        powerChip
        if let device = stats.latest?.memoryPlan?.device?.deviceName {
          chip(device, .cyan)
        }
        if let n = stats.latest?.requests?.completed {
          chip("\(n) req", Color.secondary)
        }
        Spacer()
        if case .running(let external) = process.state {
          Text(external ? "Running (external)" : "Running")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      // The title above is the *serving* model; the tray starts the
      // *configured* one. When they differ, the next tray-started server
      // will be a different model, so it is rendered on its own line under the model name.
      if let other = StatsModel.modelMismatch(
        configured: config.config.model,
        serving: stats.latest?.instance?.model)
      {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
          Text(
            "Tray will start \((config.config.model as NSString).lastPathComponent), not \((other as NSString).lastPathComponent)"
          )
          .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .help(
          "The configured model and the serving model differ. A tray-started server will replace the running one."
        )
      }
    }
  }

  /// Engine status, from `StatsModel.agentStatus`. Falls back to our own
  /// lifecycle while the server is down (there is no `/status` to read).
  private var statusChip: some View {
    let resolved: AgentStatus
    switch process.state {
    case .stopped: resolved = .stopped
    case .starting, .restarting: resolved = .starting
    case .running: resolved = stats.agentStatus ?? .starting
    case .failed: resolved = .error
    }
    let base = chip(resolved.displayName, color(for: resolved.severity))
    if let detail = stats.agentStatusDetail {
      return AnyView(base.help(detail))
    }
    return AnyView(base)
  }

  private func color(for severity: AgentStatus.Severity) -> Color {
    switch severity {
    case .ok: return .green
    case .busy: return .blue
    case .warn: return .orange
    case .bad: return .red
    }
  }

  /// "Qwen 3.6 35B A3B (12m)" — model and uptime only. The status word lives
  /// in `statusChip`, so it is not repeated here.
  private func modelStatusText(modelName: String) -> String {
    guard let duration = process.startupDuration else { return modelName }
    let durationStr =
      duration >= 60
      ? String(format: "%.1fm", duration / 60)
      : String(format: "%.0fs", duration)
    return "\(modelName) (\(durationStr))"
  }

  private func chip(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private var powerColor: Color {
    switch stats.powerMode {
    case 1: return .green  // Efficiency (Low Power)
    case 2: return .orange  // Performance (Amber)
    default: return .blue  // Auto / Standard (Blue)
    }
  }

  /// Accent color for decode throughput and power mode (Auto -> Blue, Performance -> Amber).
  private var decodeColor: Color {
    powerColor
  }

  private var powerChip: some View {
    let color = powerColor
    return Text("⏻ \(PowerMode.name(stats.powerMode))")
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  /// Names the batch's draft acceptance, because that is the only visible cause
  /// of the per-batch rate spread. Without it a 9x swing between two adjacent
  /// readings looks like a broken counter rather than speculative decoding
  /// having a bad round. Kept short on purpose: the tile truncates, and a
  /// clipped acceptance ratio tells you less than the batch rate does.
  private var decodeCaption: String {
    guard let b = stats.latestDecodeBatch else { return "sustained \u{b7} no batch yet" }
    if let drafted = b.draftedTokens, drafted > 0 {
      return "batch \u{b7} \(b.acceptedDraftTokens ?? 0)/\(drafted) drafted in"
    }
    if let rate = b.tokensPerSecond {
      return String(format: "batch \u{b7} %.0f tok/s", rate)
    }
    return "sustained \u{b7} no batch yet"
  }

  private var hero: some View {
    HStack(spacing: 14) {
      HeroPanel(
        title: "Decode",
        value: fmt(stats.displayTps, "%.1f"),
        unit: "tok/s",
        accent: decodeColor,
        caption: decodeCaption
      )
      HeroPanel(
        title: "Prefill",
        value: fmt(stats.latestPrefillTps, "%.0f"),
        unit: "tok/s",
        accent: .purple,
        // The value is a windowed rate (Δ tokens ÷ Δ wall between polls),
        // held from the last prefill that actually ran, and the caption
        // admits its age. Both halves are needed: a held value with no age
        // is indistinguishable from a live one, which is exactly the
        // defect the server's lifetime average had.
        caption: stats.latestPrefillTpsAge.map { "last prefill \(Self.ageLabel($0))" }
          ?? "no prefill measured yet"
      )
      memoryHero
      let cache = stats.latest?.cache
      let hitRate = cache?.hitRate.map { $0 * 100 }
      HeroPanel(
        title: "Cache hit rate",
        value: fmt(hitRate, "%.1f"),
        unit: "%",
        accent: (hitRate ?? 0) >= 80 ? .mint : .teal,
        caption: cache.map { "\($0.hits ?? 0) hits · \(fmtTok($0.reusedTokens)) reused" }
          ?? "prefix & state reuse"
      )
    }
  }

  private var memoryHero: some View {
    let released = stats.weightsReleased
    let g = stats.latest?.memoryActual?.currentBytes.map { Double($0) / 1_073_741_824 }
    let budget = stats.latest?.memoryGovernor?.limitBytes.map { Double($0) / 1_073_741_824 }
    // A released engine is not a small engine. Reporting the percentage
    // anyway is how "1.2 GiB · 2% of 51 GiB budget" happened: true of the
    // bytes resident, false as a statement about the model.
    let pct = released ? nil : g.flatMap { x in budget.flatMap { b in b > 0 ? x / b * 100 : nil } }
    let pm = stats.latest?.memoryPressure
    let accent: Color
    if pm == "critical" {
      accent = .red
    } else if let p = pct, p >= 95 {
      accent = .red
    } else if let p = pct, p >= 85 {
      accent = .orange
    } else {
      accent = .teal
    }
    var icon: (() -> AnyView)? = nil
    if pm == "critical" || pm == "warning" {
      icon = {
        AnyView(
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(pm == "critical" ? Color.red : Color.orange)
            .help(
              pm == "critical"
                ? "Engine is at its --max-memory budget — expect evictions; sustained critical risks an OOM kill. Close other apps or raise --max-memory."
                : "Engine is approaching its --max-memory budget — file cache and KV pages may be evicted or lazily unmapped."
            )
        )
      }
    }
    return HeroPanel(
      title: "Memory",
      value: g.map { String(format: "%.1f", $0) } ?? "-",
      unit: "GiB",
      accent: accent,
      caption: released
        ? "weights released · on demand"
        : "\(pct.map { String(format: "%.0f", $0) } ?? "-")% of \(budget.map { String(format: "%.0f", $0) } ?? "-") GiB budget · Metal",
      icon: icon
    )
  }

  private var grid: some View {
    let s = stats.latest
    // Four columns: the four groups (Cache, Engine, Host, Decode) form four
    // equal cards side-by-side in a balanced row, leaving no orphaned cards.
    let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    let pct = stats.kvPoolTokens.flatMap { t in
      stats.contextCap.flatMap { c in c > 0 ? Double(t) / Double(c) * 100 : nil }
    }
    // The enforced cap is min(native, memory budget, --max-context), so say
    // which it is instead of implying the cap is the model's hard limit.
    let capLabel = {
      let cap = stats.contextCap.map { String(format: "%.0fK", Double($0) / 1024) } ?? "?"
      guard let native = stats.contextNative, native > (stats.contextCap ?? 0) else { return cap }
      return "\(cap) of \(String(format: "%.0fK", Double(native) / 1024)) window"
    }()
    return LazyVGrid(columns: cols, spacing: 14) {
      tileGroup("Cache & KV pool") {
        Tile(
          title: "KV pool",
          value: stats.kvPoolTokens.map { String(format: "%.1fK", Double($0) / 1000) } ?? "—",
          warning: (pct ?? 0) >= 150,
          caption: "\(pct.map { String(format: "%.0f", $0) } ?? "-")% of ctx cap · \(capLabel)")
        // KV CACHE was removed here. It was not a second fact but a
        // decomposition of MEMORY IN USE: fixed runtime 18.00 + KV 3.81
        // + state 10.19 = 32.00 GiB, exactly the card it duplicated.
        // KV is bounded by the context cap, and that bound is already on
        // screen as a percentage in KV POOL, so the byte figure carried
        // no threshold to act on. State is bounded by nothing, so FILE
        // CACHE below stays: it is the only view of an unbounded number.
        // The DTO mapping is kept and still tested - this is a display
        // decision, not a schema one.
        Tile(
          title: "File cache",
          value: fmt(s?.state?.residentBytes.map { Double($0) / 1_073_741_824 }, "%.1f") + " GiB",
          caption: "\(s?.state?.evictions.map(String.init) ?? "0") evict · squeezed first")
        Tile(
          title: "Tokens reused",
          value: s?.cache?.reusedTokens.map { fmtTok($0) + " tok" } ?? "—",
          caption: s?.cache.map { "\($0.hits ?? 0) prefix hits" } ?? "prompt tokens saved")
        // The SSD tier. `used_bytes` is the tier's whole quota use — the
        // quota is shared by states and KV, so it already includes the KV
        // that `kv_bytes` reports; summing the two is how this tile read
        // 132.7% of a 16 GiB quota the server never exceeded. Saturation
        // needs the quota as the denominator, and the refusals are what
        // say whether it is idle or full.
        //
        // The reset action is only offered while the tier is actually
        // enabled: a disabled tier has no files to wipe.
        let ssdReset: (() -> AnyView)? =
          (s?.disk?.capacityBytes ?? 0) > 0
          ? {
            AnyView(
              Button {
                confirmSSDCacheReset = true
              } label: {
                Image(systemName: "arrow.counterclockwise")
                  .font(.caption2)
              }
              .buttonStyle(.plain)
              .disabled(process.isBusy)
              .help("Reset the SSD cache: delete the on-disk tier and restart the server")
              .confirmationDialog("Reset the SSD cache?", isPresented: $confirmSSDCacheReset) {
                Button("Reset", role: .destructive) {
                  Task { await process.resetDiskCache(serving: stats.latest?.instance?.model) }
                }
                Button("Cancel", role: .cancel) {}
              } message: {
                Text(
                  "Deletes the on-disk SSD tier and restarts the server. "
                    + "Warm conversation prefixes are dropped, so the next "
                    + "long-context request prefills from scratch.")
              }
            )
          }
          : nil
        Tile(
          title: "SSD tier",
          value: s?.disk.map { d in
            fmtGiB(d.usedBytes ?? 0) + " / " + fmtGiB(d.capacityBytes) + " GiB"
          } ?? "—",
          warning: (s?.disk?.saturation ?? 0) >= 0.9,
          caption: s?.disk.map { d in
            let sat = d.saturation.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
            let refused =
              (d.kvDemotionsRefused ?? 0) > 0
              ? " · \(d.kvDemotionsRefused!) refused"
              : " · \(d.kvDemotions.map(String.init) ?? "0") demoted"
            return sat + refused
          } ?? "no disk tier reported",
          action: ssdReset)
      }
      tileGroup("Engine memory") {
        Tile(
          title: "Model weights",
          value: fmtGiB(s?.memoryPlan?.model?.memory?.totalWeightsBytes) + " GiB",
          caption: "target+draft+vision, fixed")
        Tile(
          title: "KV cache",
          value: fmtGiB(s?.kv?.residentBackingBytes) + " GiB",
          caption: s?.kv?.pagesResident.map { "\($0) allocated pages" } ?? "GPU allocation")
        let budget = s?.memoryGovernor?.limitBytes
        Tile(
          title: "Engine budget",
          value: fmtGiB(budget) + " GiB",
          warning: (s?.memoryGovernor?.growthAllowed ?? true) == false,
          caption: s.flatMap { st -> String? in
            guard let b = st.memoryActual?.currentBytes,
              let l = st.memoryGovernor?.limitBytes, l > 0
            else { return nil }
            // Same rule as the hero: never express a released
            // engine's byte count as a share of the budget.
            if stats.weightsReleased { return "weights released · on demand" }
            return String(
              format: "%.0f%% used · headroom %@ GiB",
              Double(b) / Double(l) * 100,
              fmtGiB(st.memoryGovernor?.headroomBytes))
          } ?? "--max-memory")
        Tile(
          title: "KV reclaimable",
          value: s?.kv?.reclaimableBytes.map { fmtGiB($0) + " GiB" } ?? "—",
          caption: "KV memory the engine could hand back")
      }
      tileGroup("Host system memory") {
        Tile(
          title: "Physical RAM",
          value: fmtGiB(s?.memoryPlan?.device?.physicalMemoryBytes) + " GiB",
          caption: s?.memoryPlan?.device?.deviceName ?? "—")
        Tile(
          title: "System in use",
          value: fmtGiB(
            s.flatMap { st in
              st.memoryPlan?.device?.physicalMemoryBytes
                .flatMap { p in st.memoryGovernor?.hostAvailableBytes.map { p - $0 } }
            }) + " GiB",
          caption: "physical − host available")
        Tile(
          title: "Host available", value: fmtGiB(s?.memoryGovernor?.hostAvailableBytes) + " GiB",
          caption: "OS free+cache, outside engine")
        Tile(
          title: "Other apps",
          value: fmtGiB(
            s.flatMap { st -> UInt64? in
              guard st.memoryGovernor?.hostMeasurementValid == true,
                let p = st.memoryPlan?.device?.physicalMemoryBytes,
                let o = st.memoryGovernor?.observedResidentBytes,
                let a = st.memoryGovernor?.hostAvailableBytes,
                a <= p, o <= p - a
              else { return nil }
              return p - o - a
            }) + " GiB",
          // A residual, and stated as one: it absorbs whatever splash
          // is not currently holding, so right after a cold start it
          // reads high. That is why it is a tile and not a chart line.
          caption: "residual · overstates when cold")
      }
      tileGroup("Decode & request") {
        Tile(
          title: "Prefill (TTFT)",
          value: fmt(s?.metrics?.ttftMs?.p50.map { $0 / 1000 }, "%.1f") + " s",
          caption:
            "p95 \(fmt(s?.metrics?.ttftMs?.p95.map { $0 / 1000 }, "%.1f")) s · n=\(s?.metrics?.ttftMs?.samples.map(String.init) ?? "-")"
        )
        Tile(
          title: "Stream latency", value: fmt(s?.metrics?.itlMs?.p50, "%.0f") + " ms",
          caption: "p95 \(fmt(s?.metrics?.itlMs?.p95, "%.0f")) ms inter-token")
        Tile(
          title: "Draft acceptance",
          value: fmt(s?.metrics?.draftAcceptanceRate.map { $0 * 100 }, "%.0f", suffix: "%"),
          caption: "spec-decode accepts")
        let pm = s?.memoryPressure
        Tile(
          title: "Memory pressure",
          value: pm ?? "—",
          warning: pm == "warning" || pm == "critical",
          caption: "engine self-report")
      }
    }
  }

  /// A labeled card holding its own tiles. Was a caption above a bare grid, so
  /// the groups had no shared boundary and the orphan tile looked like a bug in
  /// the layout rather than in the data.
  private func tileGroup(_ title: String, @ViewBuilder _ tiles: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      VStack(spacing: 8) { tiles() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }
}
