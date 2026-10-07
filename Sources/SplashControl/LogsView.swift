import AppKit
import SwiftUI

/// The tray's own log and the server's log, side by side, filterable.
///
/// Reads a bounded tail rather than the whole file: both files are rotated at
/// 1 MB, and pulling a megabyte into a `Text` on a timer would be wasteful.
///
/// Three things changed the shape of this view:
///
/// * Both channels are readable here. `splash-control.log` used to be reachable
///   only from Settings, as a static 20-line preview, so the answer to "what did
///   the app do?" meant opening Console.app or a terminal.
/// * The read is off the main thread. Under load the tail is 256 KB–1 MB; the
///   old synchronous read plus the row rebuild ran on the main actor on a 2 s
///   timer, which showed up as the dashboard and menu bar stuttering.
/// * Scrolling up un-pins autoscroll. The view pinned itself to the bottom on
///   every refresh, so reading an earlier stack trace meant being yanked back to
///   the newest line every two seconds.
struct LogsView: View {
  /// Shown at most. Cheap now that only visible rows are laid out, so this is
  /// history rather than a render budget — a rotation generation is ~4 days
  /// at the observed request rate.
  nonisolated static let tailLimit = 2_000

  enum Level: String, CaseIterable, Identifiable {
    case all, requests, problems, governor
    var id: String { rawValue }
    var label: String {
      switch self {
      case .all: return "All"
      case .requests: return "Requests"
      case .problems: return "Warnings & Errors"
      case .governor: return "Memory Audit"
      }
    }
    /// Substring match, lowercased. Kept deliberately loose: these are
    /// display filters over free-form console text, and a filter that silently
    /// hides the one line you need is worse than a slightly over-broad one.
    func matches(_ lower: String) -> Bool {
      switch self {
      case .all: return true
      case .requests:
        // Anchored on the request line, not on loose words: a bare "get "
        // also matches "budGET ceiling", which is a governor line.
        return lower.contains("post /v1") || lower.contains("get /v1")
          || lower.contains("/v1/chat/completions") || lower.contains("/v1/responses")
          || lower.contains("ttft")
      case .problems:
        return lower.contains("warn") || lower.contains("error")
          || lower.contains("fail") || lower.contains("denied")
          || lower.contains("refus") || lower.contains("critical")
          || lower.contains("traceback") || lower.contains("exception")
      case .governor:
        // A request completion carries token statistics — `Done · input
        // 1,008 · cached 128 · output 412 · TTFT 1.12s` — and "cached"
        // contains "cache", so on the observed 1 226-line server log
        // this filter matched 902 request lines and buried the 76 real
        // ones. Token counts belong to the Requests filter.
        if lower.contains("cached ") { return false }
        return lower.contains("governor") || lower.contains("memory")
          || lower.contains("evict") || lower.contains("cache")
          || lower.contains("headroom") || lower.contains("budget")
      }
    }
  }

  @State private var channel: SplashLog.Channel = .server
  @State private var lines: [String] = []
  @State private var sizeText = "—"
  @State private var mtimeText = "—"
  @State private var missing = false
  @State private var confirmingRotate = false
  @State private var copied = false
  @State private var query = ""
  @State private var level: Level = .all
  /// When false, new lines do not scroll the view. Toggled off automatically
  /// when the user scrolls up, back on when they scroll to the bottom.
  @State private var followTail = true

  /// Last state written to the view, so an idle server does not re-render
  /// 2000 rows every 2 s for nothing.
  @State private var lastSize = -1
  @State private var lastMtime: Date?
  /// Guards against an older in-flight read overwriting a newer one.
  @State private var readGeneration = 0

  /// Fires only while this view is in the hierarchy, and the dashboard builds
  /// it only for the Logs tab — so "refresh while visible" needs no timer
  /// bookkeeping here.
  private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  private var url: URL { SplashLog.url(for: channel) }
  private var displayPath: String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  /// One definition, shared by the filter and the highlighter: a needle
  /// derived twice is a filter that matches on text the highlighter never
  /// finds.
  private var needle: String {
    query.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// Query and level applied. Filtering the whole tail and then rendering with
  /// `ForEach(…, id: \.offset)` means the visible rows are the first N of the
  /// filtered list, which is what a tail-log reader wants (most recent last).
  private var visible: [String] {
    guard !needle.isEmpty || level != .all else { return lines }
    return lines.filter { line in
      let lower = line.lowercased()
      guard needle.isEmpty || lower.contains(needle) else { return false }
      return level.matches(lower)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      filterBar
      if missing {
        Text(
          SplashLog.unavailable.contains(channel)
            ? "\(channel.filename) could not be opened — output is being discarded."
            : "No \(channel.filename) yet — it is created when the tray launches a server."
        )
        .font(.callout)
        .foregroundStyle(SplashLog.unavailable.contains(channel) ? Color.red : Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      } else if lines.isEmpty {
        // An empty file is a *rotated* log waiting for the server's next
        // line, not a missing one. Saying "no log yet" here is what made
        // Rotate look like it had failed and needed a restart.
        Text("Log is empty — waiting for the next line.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 28)
      } else {
        logBody
      }
      footer
    }
    .padding(16)
    .onAppear(perform: reload)
    .onChange(of: channel) { _, _ in
      // `lines` is deliberately NOT emptied here. Clearing it tore the
      // scroll view out of the hierarchy for a frame, and the bottom
      // anchor's `onDisappear` — the "user scrolled up into history"
      // signal — fired on that teardown, so a channel switch silently
      // unlocked the tail and then refused to scroll to it. It also made
      // the pane flash "Log is empty" for a file that is not empty.
      // `reload()` replaces `lines` wholesale and bumps `readGeneration`,
      // so an in-flight read of the old channel cannot land.
      lastSize = -1
      followTail = true
      reload()
    }
    .onReceive(ticker) { _ in reload() }
    .confirmationDialog("Rotate \(channel.filename)?", isPresented: $confirmingRotate) {
      Button("Rotate", role: .destructive) {
        SplashLog.shared.rotateNow(channel)
        reload()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Confirm because the shift is not reversible: there are no archived
      // generations, so the current log is deleted. Naming that is honest; a
      // generic "are you sure" is not.
      Text(
        "The current \(channel.filename) is deleted and an empty one is started — nothing is archived. The server is not restarted."
      )
    }
  }

  private var logBody: some View {
    ScrollViewReader { proxy in
      // A Text PER LINE in a LazyVStack, not one Text for the whole
      // log. One giant Text measured 3.07 s to lay out at 400 lines /
      // 168 KB — ~18 ms of SwiftUI layout per KB, ~600x raw
      // CoreText — because every character is laid out even off
      // screen, and long lines wrap into several visual rows each.
      // LazyVStack lays out only what is visible, so the cost stops
      // depending on how much history the log holds. The cost is that
      // a drag selects one line at a time instead of a block.
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
            Self.row(line, needle: needle)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(Self.colour(for: line))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          // Bottom marker. It is only on screen when the tail is, so its
          // disappearance IS the "user scrolled up into history" signal.
          // The alternative — `defaultScrollAnchor(.bottom)` — re-pinned
          // on every update, which is exactly the defect being fixed, and
          // the precise geometry API for "distance from bottom" is macOS
          // 15, above this app's floor.
          Color.clear.frame(height: 1)
            .id(Self.tailAnchor)
            .onAppear { followTail = true }
            .onDisappear { followTail = false }
        }
        .padding(.vertical, 6)
      }
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.primary.opacity(0.03))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
      )
      // Greedy, so a short or empty log does not hand its ideal height back to
      // the VStack. `ScrollView` has no intrinsic height, so left alone
      // this box contributes ~0 and the window is free to shrink to
      // header + footer whenever the row count drops.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(id: tailKey) { await scrollToTail(proxy) }
    }
  }

  /// Everything that changes which rows are on screen. `visible.count` covers
  /// both a filter change and new lines, and the filter identity is in the key
  /// too because two different filters can select the same number of rows.
  private var tailKey: String {
    "\(channel.rawValue)|\(level.rawValue)|\(needle)|\(followTail)|\(visible.count)"
  }

  /// Pin to the bottom, then pin again after one runloop beat.
  ///
  /// The second attempt is the load-bearing one: the anchor is the last item
  /// of a `LazyVStack`, so on a channel or filter switch it has not been laid
  /// out when the task starts, and `scrollTo` on an id that does not exist yet
  /// is a silent no-op — which is what left the pane parked on line 1 with
  /// "Following tail" lit. The task also re-arms on appear, so the first paint
  /// of a freshly loaded tail lands at the bottom instead of the top.
  private func scrollToTail(_ proxy: ScrollViewProxy) async {
    guard followTail else { return }
    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
    try? await Task.sleep(for: .milliseconds(60))
    guard !Task.isCancelled, followTail else { return }
    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
  }

  private static let tailAnchor = "log-tail-anchor"

  private var filterBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        TextField("filter — e.g. error, fail, denied, 400", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 11, design: .monospaced))
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
          }
          .buttonStyle(.borderless)
          .help("Clear the search")
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
      )
      HStack(spacing: 6) {
        Picker("Level", selection: $level) {
          ForEach(Level.allCases) { l in
            Text(l.label).tag(l)
          }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: 400)

        Spacer(minLength: 0)
        // Tail following is a viewport mode, not a query: keeping it
        // inside the search field made it look like part of the text.
        Button {
          followTail.toggle()
        } label: {
          Label(
            followTail ? "Following tail" : "Tail locked",
            systemImage: followTail ? "arrow.down.circle.fill" : "lock.fill"
          )
          .font(.caption)
          .fixedSize()
        }
        .buttonStyle(.borderless)
        .help(
          followTail
            ? "New lines scroll into view. Scroll up to unlock."
            : "Autoscroll is off, so scrolling back through history stays put.")
        // `verbatim`: a `Text` built from an interpolated literal is a
        // LocalizedStringKey, and an Int interpolation inside one is
        // grouped per locale — 1 219 lines read as "1.219 lines".
        Text(
          verbatim: visible.count == lines.count
            ? "\(lines.count) lines"
            : "\(visible.count) of \(lines.count) lines"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
      }
    }
  }

  /// The file this pane is showing, copyable, with its size and age. The
  /// metadata belongs here and not in the header: it describes *this file*,
  /// and floating it between the channel picker and the action buttons left
  /// it unanchored at every window width. The path truncates in the middle so
  /// both ends stay readable; the metadata never compresses, or it wraps into
  /// a second line.
  private var footer: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc.text")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(displayPath)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(displayPath)
      Text(sizeText)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
      Text("updated \(mtimeText)")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
      Spacer(minLength: 8)
      Button {
        let text = visible.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Label(copied ? "Copied" : "Copy filtered", systemImage: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help("Copy the \(visible.count) lines currently shown")
      Button {
        export()
      } label: {
        Label("Export", systemImage: "square.and.arrow.down")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help("Write the filtered lines to a text file")
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .help(copied ? "Copied" : "Copy the full log path")
      .accessibilityLabel(copied ? "Log path copied" : "Copy log path")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        Text("Logs").font(.title3.weight(.semibold))
        // Channel switcher: the server stream and the tray's own lifecycle
        // log are both answers to "what happened", and forcing one of them
        // into Settings made the tray log effectively invisible.
        Picker("", selection: $channel) {
          ForEach(SplashLog.Channel.allCases, id: \.self) { c in
            Text(c.filename).tag(c)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320)
        Spacer(minLength: 0)
        Button("Rotate") { confirmingRotate = true }
          .disabled(missing)
          .help(
            "Delete \(channel.filename) and start an empty one. Nothing is archived. The server is not restarted."
          )
        Button("Refresh") { reload() }
        Button("Reveal in Finder") {
          let u = url
          if !NSWorkspace.shared.open(u) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
          }
        }
        .disabled(missing)
      }
      .controlSize(.small)
    }
  }

  private func reload() {
    let target = url
    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    let mtime = attributes?[.modificationDate] as? Date
    // Nothing has been appended since the last tick, so leave the (fairly
    // expensive) tail read and row rebuild alone.
    if size == lastSize, mtime == lastMtime { return }
    lastSize = size
    lastMtime = mtime
    readGeneration += 1
    let generation = readGeneration

    // File metadata before the early exits: a just-rotated log is 0 B, and
    // its footer still has to say so rather than keep the previous size.
    sizeText = byteText(size)
    if let mtime {
      mtimeText =
        SplashLog.stamp.string(from: mtime)
        .replacingOccurrences(of: "T", with: " ")
        .prefix(19).description
    }

    guard size > 0 else {
      lines = []
      // Existence, not length, is what "missing" means. `size == 0` is the
      // normal state for the first two seconds after a rotation.
      missing = !FileManager.default.fileExists(atPath: target.path)
      return
    }
    missing = false
    // Off the main actor: the read is up to a megabyte of I/O plus a line
    // split, and this runs every 2 s while the dashboard window is open.
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        LogsView.tail(of: target, limit: LogsView.tailLimit)
      }.value
      // Drop a read that a newer one has already superseded, so a slow read
      // of a file that has since been rotated cannot resurrect stale lines.
      guard generation == readGeneration else { return }
      lines = result
    }
  }

  private func export() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      "\(channel.filename.replacingOccurrences(of: ".log", with: ""))-export.txt"
    guard panel.runModal() == .OK, let target = panel.url else { return }
    let text = visible.joined(separator: "\n")
    SplashLog.shared.log(
      "log_exported path=\(target.path) lines=\(visible.count) channel=\(channel.rawValue)")
    Task.detached(priority: .utility) {
      try? text.write(to: target, atomically: true, encoding: .utf8)
    }
  }

  /// The last `limit` lines, read without pulling the entire file in.
  /// Nonisolated by construction: called from a detached task.
  nonisolated static func tail(of url: URL, limit: Int) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    // A generous cap per line; if it is still not enough newlines, fall
    // back to reading the whole (already bounded, rotated) file.
    // Read window. Not a render limit: the loop below grows this ×4 until it has
    // enough newlines, so a smaller window makes it read MORE, not less
    // (measured: 96 KB start → 898 lines rendered, 256 KB start → 607).
    // Disk reads are cheap here; `tailLimit` is what bounds the layout.
    var window = 256 * 1024
    var start: UInt64 = 0
    var text = ""
    while window <= max(size, 262_144) {
      start = size > UInt64(window) ? size - UInt64(window) : 0
      try? handle.seek(toOffset: start)
      let data = (try? handle.readToEnd()) ?? Data()
      text = String(data: data, encoding: .utf8) ?? ""
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      if lines.count > limit || start == 0 { return suffix(lines, limit, trimmed: start > 0) }
      window *= 4
    }
    return suffix(
      text.split(separator: "\n", omittingEmptySubsequences: false),
      limit, trimmed: start > 0)
  }

  nonisolated private static func suffix(_ lines: [Substring], _ limit: Int, trimmed: Bool)
    -> [String]
  {
    var out = lines
    // A partial first line is expected when the read began mid-file.
    if trimmed, let first = out.first, !first.hasSuffix("\n") { out.removeFirst() }
    if out.count > limit { out.removeFirst(out.count - limit) }
    return out.map(String.init)
  }

  private func byteText(_ bytes: Int) -> String {
    bytes < 1024
      ? "\(bytes) B"
      : bytes < 1_048_576
        ? String(format: "%.0f KB", Double(bytes) / 1024)
        : String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  /// A log line. With no query this is the plain string: building an
  /// `AttributedString` per row costs real time over a 2 000-line tail and
  /// buys nothing when nothing is searched.
  private static func row(_ line: String, needle: String) -> Text {
    needle.isEmpty ? Text(line) : Text(highlighted(line, needle: needle))
  }

  /// Every occurrence of `needle` tinted and bolded, the rest verbatim. A
  /// filter that does not show *why* a 200-character line matched is half a
  /// filter. Non-private so `check_core.sh` can assert the run boundaries —
  /// concatenating attributed pieces is easy to break silently.
  nonisolated static func highlighted(_ line: String, needle: String) -> AttributedString {
    func piece(_ slice: Substring, hit: Bool) -> AttributedString {
      var part = AttributedString(String(slice))
      part.font = Font.system(size: 11, design: .monospaced).bold(hit)
      if hit { part.backgroundColor = Color.yellow.opacity(0.28) }
      return part
    }
    var out = AttributedString()
    var rest = line[...]
    while let r = rest.range(of: needle, options: .caseInsensitive) {
      out += piece(rest[..<r.lowerBound], hit: false)
      out += piece(rest[r], hit: true)
      rest = rest[r.upperBound...]
    }
    return out + piece(rest, hit: false)
  }

  /// Errors are worth spotting without reading every line.
  private static func colour(for line: String) -> Color {
    let lower = line.lowercased()
    if lower.contains("error") || lower.contains("traceback")
      || lower.contains("exception") || lower.contains("failed")
    {
      return .red
    }
    if lower.contains("ready ·") { return .green }
    if lower.contains("warning") { return .orange }
    return .primary
  }
}
