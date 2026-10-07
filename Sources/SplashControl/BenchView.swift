import AppKit
import SwiftUI

/// Benchmark controls + results, presented in the Benchmark nested tab.
///
/// Designed conforming to DESIGN.md:
/// - Isolated in its own nested sub-tab so synthetic testing does not collide with rolling history.
/// - Configuration and status housed in styled container cards.
/// - Tabular results aligned with monospaced figures and clear scenario inspection.
struct BenchSection: View {
  @ObservedObject var bench: BenchmarkEngine
  /// Track expanded scenario preview per model. Keyed by model ID, value is promptID.
  @State private var expandedPromptByModel: [String: String] = [:]

  private let promptOrder = ["instruction", "reasoning", "code_gen", "long_ctx_8k", "vision"]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      head
      configCard
      if !bench.plan.isEmpty { planCard }
      if !bench.results.isEmpty {
        comparison
        resultsCard
      } else if bench.phase == .idle || bench.phase == .done {
        // `.done` counts: `run()` clears `results` but leaves the phase
        // alone until `execute` sets the first `.loading`, and moving the
        // context picker to an unmeasured size does the same. Neither is
        // "no results" — it is "nothing on screen", and the placeholder
        // is what keeps the page from going blank below.
        emptyState
      }
      if case .failed(let m) = bench.phase {
        note(m, .red)
      }
    }
    // Only the results block swaps, and only between two fixed-size states.
    .animation(.easeInOut(duration: 0.2), value: bench.results.isEmpty)
  }

  private var head: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Model Benchmark Suite")
          .font(.title3.weight(.semibold))
          .lineLimit(1)
        Text("Standardized synthetic evaluation across installed models under fixed rule sets.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      runBadge
    }
  }

  /// The one header control on the right. Always present and always the same
  /// width, so switching context size cannot move anything: a menu when more
  /// than one run is stored, the plain badge otherwise, both drawn from the
  /// same content so the two states differ by a chevron and not by a reflow.
  private var runBadge: some View {
    let busy = bench.phase != .idle && bench.phase != .done
    let content = HStack(spacing: 6) {
      Image(systemName: bench.runs.count > 1 ? "clock.arrow.circlepath" : "clock")
        .font(.caption2)
      Text(bench.runs.count > 1 ? bench.selectedRunSummary : bench.lastRunBadgeText)
        .font(.caption2)
        .lineLimit(1)
      if bench.runs.count > 1 {
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8))
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(width: 380, alignment: .trailing)
    .background(Color.primary.opacity(0.04), in: Capsule())

    return Group {
      if bench.runs.count > 1 {
        // A Picker here rendered blank when `selectedRunAt` was nil, which
        // is exactly the state an unmeasured context size puts it in.
        Menu {
          ForEach(bench.runs, id: \.finishedAt) { run in
            Button {
              bench.selectRun(at: run.finishedAt)
            } label: {
              if run.finishedAt == bench.selectedRunAt {
                Label(run.humanSummary, systemImage: "checkmark")
              } else {
                Text(run.humanSummary)
              }
            }
          }
          // Destructive, so disabled mid-run: the run in flight has not
          // been archived yet, so `selectedRunAt` still names the run
          // on screen and deleting it would throw away the baseline
          // the numbers are being compared against.
          Divider()
          Button(role: .destructive) {
            bench.deleteCurrentRun()
          } label: {
            Label("Delete Selected Run", systemImage: "trash")
          }
          .disabled(busy || bench.selectedRunAt == nil)
          Button(role: .destructive) {
            bench.clearAllHistory()
          } label: {
            Label("Clear All Stored Runs…", systemImage: "trash.fill")
          }
          .disabled(busy)
        } label: {
          content
        }
        .menuStyle(.borderlessButton)
        .frame(width: 380, alignment: .trailing)
        .help(
          "Stored benchmark runs, one per parameter set. Re-running a set replaces its entry; a run under different settings is kept beside it."
        )
      } else {
        content
      }
    }
  }

  /// Nothing has been measured at the context size the picker is on. Shown
  /// instead of empty charts, so a cleared selection reads as "not measured
  /// yet" rather than as a run that produced nothing.
  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        .font(.system(size: 32))
        .foregroundStyle(.tertiary)
      Text("No Benchmark Recorded for \(bench.longContextK)K Context")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text(
        "Run Benchmark to measure model throughput, prefill latency and memory under a "
          + "\(bench.longContextK)K context window."
          + (bench.runs.isEmpty
            ? ""
            : " \(bench.runs.count) other parameter set\(bench.runs.count == 1 ? " is" : "s are") "
              + "stored — pick one from the menu above to compare.")
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
      .multilineTextAlignment(.center)
    }
    .padding(.vertical, 48)
    .padding(.horizontal, 24)
    // A floor, so clearing the results cannot collapse the window from a full
    // page of cards to a single caption.
    .frame(maxWidth: .infinity, minHeight: 280)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  private var configCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("BENCHMARK CONFIGURATION")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)

      // Three columns, not two spacers. Equal flexible wings around a rigid centre
      // put the picker on the card's true midpoint whatever the buttons'
      // widths are (they differ by ~35 pt, which skewed it), and `.fixedSize()`
      // on the centre makes it non-negotiable in the other direction: as a
      // flexible member between two spacers it was offered 2.67 pt for its
      // label after the rigid 228 pt picker took the rest, and SwiftUI wrapped
      // "Context:" one character per line.
      HStack(spacing: 0) {
        Button {
          pickImage()
        } label: {
          Label(
            bench.imagePath.map { imageLabel($0) } ?? "Add Image (Optional)",
            systemImage: "photo")
        }
        .controlSize(.regular)
        .disabled(bench.isExternal || (bench.phase != .idle && bench.phase != .done))
        .help(
          "Optional. Adds a 5th vision prompt, applied to every model. Without it that prompt is skipped."
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 8) {
          Text("Context:")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Picker(
            "Context",
            selection: Binding(
              get: { bench.longContextK },
              set: { bench.setLongContext($0) })
          ) {
            ForEach(BenchRules.LongContext.options, id: \.self) {
              Text("\($0)K").tag($0)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 228)
          .disabled(bench.phase != .idle && bench.phase != .done)
          .help("Size of the long-context scenario (KV cache stress test).")
        }
        .fixedSize()

        Button {
          if bench.phase == .idle || bench.phase == .done {
            bench.run()
          } else {
            bench.cancel()
          }
        } label: {
          if bench.phase == .idle || bench.phase == .done {
            Label("Run Benchmark", systemImage: "play.fill")
          } else {
            Label("Cancel", systemImage: "stop.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(bench.phase == .idle || bench.phase == .done ? .blue : .red)
        .controlSize(.regular)
        .disabled(bench.isExternal)
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      if bench.isExternal {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(
            "Server not owned by this tray — use Restart Server in the menu bar first to benchmark installed models."
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      }

      if bench.phase != .idle && bench.phase != .done {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          statusLine
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  /// Where one model stands in the sequential run.
  ///
  /// Read from `phase`, which *names* the model in flight, rather than
  /// inferred from row counts. The alternative — "the models with rows so far
  /// number my index in the plan" — holds only while every earlier model
  /// produced at least one row, and it cannot tell loading from running.
  private enum ModelRunStatus: Equatable {
    case completed
    case active(done: Int)
    case queued
    /// Nothing is claimed: no run in flight, or this model has no rows yet.
    case none

    var isActive: Bool {
      switch self {
      case .active: return true
      default: return false
      }
    }
  }

  private func runStatus(for model: String) -> ModelRunStatus {
    let rows = bench.results.filter { $0.model == model }.count
    if rows >= bench.scenarioCount || (bench.phase == .done && rows > 0) {
      return .completed
    }
    switch bench.phase {
    // Two cases, not one comma-separated case: `where` binds to the last
    // pattern only, so `case .loading(let m,…), .running(let m,…) where m == model`
    // would leave a loading model falling through to `.queued`.
    case .loading(let m, _, _) where m == model:
      return .active(done: rows)
    case .running(let m, _) where m == model:
      return .active(done: rows)
    case .idle, .done, .failed:
      return .none
    default:
      return .queued
    }
  }

  private var planCard: some View {
    HStack(spacing: 8) {
      Text("EXECUTION ORDER:")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)

      // One step per model rather than a flat "1 · name  2 · name" line:
      // the run is sequential, so the row should show which model is in
      // flight and not only what the order is.
      ForEach(Array(bench.plan.enumerated()), id: \.element) { idx, model in
        let status = runStatus(for: model)
        HStack(spacing: 4) {
          switch status {
          case .completed:
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 11))
              .foregroundStyle(.green)
          case .active:
            ProgressView()
              .controlSize(.mini)
          case .queued, .none:
            Text("\(idx + 1)")
              .font(.system(size: 10, weight: .bold, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
          Text(ModelCatalog.displayName(for: model))
            .font(.system(size: 11, design: .monospaced))
            .fontWeight(status.isActive ? .bold : .regular)
            .foregroundStyle(
              status == .completed
                ? Color.secondary.opacity(0.8)
                : (status.isActive ? Color.primary : Color.secondary.opacity(0.55))
            )
            .lineLimit(1)
          if case .active(let done) = status {
            Text("(\(done)/\(bench.scenarioCount))")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.blue)
              .lineLimit(1)
          }
        }
        .fixedSize()

        if idx < bench.plan.count - 1 {
          Image(systemName: "arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(.quaternary)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
  }

  /// Distinct, harmonious Apple HIG palette for multi-model comparison.
  /// Eliminates duplicated bar colors so each model has a consistent color identity.
  private func modelColor(for model: String) -> Color {
    let idx = bench.plan.firstIndex(of: model) ?? 0
    let palette: [Color] = [
      Color(red: 0.04, green: 0.52, blue: 1.0),  // macOS System Blue (#0A84FF)
      Color(red: 0.69, green: 0.32, blue: 0.87),  // macOS System Purple (#AF52DE)
      Color(red: 1.00, green: 0.58, blue: 0.00),  // macOS System Orange (#FF9500)
      Color(red: 0.00, green: 0.78, blue: 0.75),  // macOS System Teal (#00C7BE)
      Color(red: 1.00, green: 0.18, blue: 0.33),  // macOS System Pink (#FF2D55)
      Color(red: 0.35, green: 0.34, blue: 0.84),  // macOS System Indigo (#5856D6)
    ]
    return palette[idx % palette.count]
  }

  /// One row per scenario per model, and the side-by-side bars.
  private var comparison: some View {
    // Completed models only. A half-measured model would contribute a mean
    // over 2 of 5 scenarios and be charted against 5-of-5 models as if the
    // numbers were comparable — which is the whole point of the card.
    let models = bench.plan.filter { runStatus(for: $0) == .completed }
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("BENCHMARK COMPARISON")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        HStack(spacing: 12) {
          ForEach(models, id: \.self) { model in
            HStack(spacing: 4) {
              Circle()
                .fill(modelColor(for: model))
                .frame(width: 6, height: 6)
              Text(ModelCatalog.displayName(for: model))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(.horizontal, 4)

      // A placeholder, not an empty card: hiding the whole comparison while
      // the first model is in flight makes the page jump the moment it
      // completes.
      if models.isEmpty {
        Text(
          "No model has finished all \(bench.scenarioCount) scenarios yet — bars appear as each one completes."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      } else {
        barChart(
          title: "Throughput (mean output tok/s — higher is better)",
          models: models, higherIsBetter: true
        ) { model in
          let ok = bench.results.filter {
            $0.model == model
              && $0.metrics.error == nil && $0.metrics.skipped == nil
          }
          let tps = ok.compactMap { $0.metrics.outputTps }
          return tps.isEmpty ? nil : tps.reduce(0, +) / Double(tps.count)
        }
        barChart(
          title: "Prefill (mean TTFT in seconds — lower is better)",
          models: models, higherIsBetter: false, unit: "s"
        ) { model in
          let rows = bench.results.filter {
            $0.model == model
              && $0.metrics.error == nil && $0.metrics.skipped == nil
          }
          let ttft = rows.compactMap { $0.metrics.ttft }
          return ttft.isEmpty ? nil : ttft.reduce(0, +) / Double(ttft.count)
        }
        barChart(
          title: "Memory (mean resident in GiB — lower is better)",
          models: models, higherIsBetter: false, unit: " GiB"
        ) { model in
          let ok = bench.results.filter {
            $0.model == model
              && $0.metrics.error == nil && $0.metrics.skipped == nil
          }
          let mems = ok.compactMap { $0.metrics.memoryGiB }
          return mems.isEmpty ? nil : mems.reduce(0, +) / Double(mems.count)
        }
        barChart(
          title: "Load time (seconds — lower is better)",
          models: models, higherIsBetter: false, unit: "s"
        ) { model in
          bench.results.first { $0.model == model && $0.loadSeconds != nil }?.loadSeconds
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  private func barChart(
    title: String, models: [String],
    higherIsBetter: Bool = true,
    unit: String = "",
    value: (String) -> Double?
  ) -> some View {
    let values = models.map { ($0, value($0)) }
    let present = values.compactMap { $0.1 }
    let bestValue = higherIsBetter ? present.max() : present.min()
    let maxMagnitude = present.max() ?? 1.0

    return VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      if present.isEmpty || maxMagnitude == 0 {
        Text("no data")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(values, id: \.0) { model, v in
          let isBest = (v != nil && bestValue != nil && abs(v! - bestValue!) < 0.001)
          let frac = (v != nil && maxMagnitude > 0) ? (v! / maxMagnitude) : 0
          let color = modelColor(for: model)

          HStack(spacing: 8) {
            HStack(spacing: 5) {
              Circle()
                .fill(color)
                .frame(width: 6, height: 6)
              Text(ModelCatalog.displayName(for: model))
                .font(.system(size: 11))
                .lineLimit(1)
            }
            .frame(width: 175, alignment: .leading)

            GeometryReader { geo in
              RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(isBest ? 1.0 : 0.72))
                .frame(width: max(3, geo.size.width * frac))
            }
            .frame(height: 12)

            HStack(spacing: 4) {
              Text(v.map { String(format: "%.1f", $0) + unit } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(isBest ? .bold : .regular)
                .foregroundStyle(isBest ? Color.green : Color.primary)
                .lineLimit(1)
              if isBest && present.count > 1 {
                Text("BEST")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(.green)
                  .lineLimit(1)
                  .padding(.horizontal, 3.5)
                  .padding(.vertical, 1)
                  .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
              }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 108, alignment: .trailing)
          }
        }
      }
    }
  }

  private var resultsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      // Trailing clear, in the same row as the title: the card is the
      // thing being discarded, so its own header is where the control
      // belongs. Disabled mid-run, when the rows on screen are the run in
      // flight rather than a stored one.
      HStack {
        Text("SCENARIO BREAKDOWN")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 12)
        Button {
          bench.deleteCurrentRun()
        } label: {
          Label("Clear", systemImage: "trash")
            .font(.caption2)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(bench.phase != .idle && bench.phase != .done)
        .help("Delete the run on screen from the stored archive.")
      }

      // Every planned model, not only the ones with rows: a run in flight
      // has to show what is still to come, not just what exists so far.
      ForEach(bench.plan, id: \.self) { model in
        modelBlock(model, bench.results.filter { $0.model == model })
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  /// Status pill beside a model's name in the breakdown. `fixedSize()` so it
  /// can never be squeezed into the single-line summary text next to it.
  @ViewBuilder
  private func statusBadge(for model: String) -> some View {
    switch runStatus(for: model) {
    case .completed:
      pill("COMPLETED", .green)
    case .active(let done):
      HStack(spacing: 3) {
        ProgressView()
          .controlSize(.mini)
        Text("RUNNING (\(done)/\(bench.scenarioCount))")
          .lineLimit(1)
      }
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.blue)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(Color.blue.opacity(0.12), in: Capsule())
      .fixedSize()
    case .queued:
      pill("QUEUED", .secondary)
    case .none:
      EmptyView()
    }
  }

  private func pill(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(color.opacity(0.12), in: Capsule())
      .fixedSize()
  }

  private func modelBlock(_ model: String, _ rows: [BenchResult]) -> some View {
    let ok = rows.filter { $0.metrics.error == nil && $0.metrics.skipped == nil }
    let outTps = ok.compactMap { $0.metrics.outputTps }
    let mean = outTps.isEmpty ? nil : outTps.reduce(0, +) / Double(outTps.count)

    let times = ok.compactMap { $0.metrics.elapsed }
    let total = times.isEmpty ? nil : times.reduce(0, +)

    let mems = ok.compactMap { $0.metrics.memoryGiB }
    let avgMem = mems.isEmpty ? nil : mems.reduce(0, +) / Double(mems.count)
    let peakMem = mems.max()

    let color = modelColor(for: model)

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle()
          .fill(color)
          .frame(width: 8, height: 8)
        Text(ModelCatalog.displayName(for: model))
          .font(.subheadline.weight(.semibold))
        statusBadge(for: model)
        if let mean {
          Text(String(format: "mean %.1f tok/s", mean))
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
        }
        if let avgMem, let peakMem {
          Text(String(format: "· mem avg %.1fG (peak %.1fG)", avgMem, peakMem))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let total {
          Text(String(format: "· total %.1fs", total))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let load = rows.first?.loadSeconds {
          Text(String(format: "· load %.1fs", load))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        if let o = rows.first?.order, o == bench.plan.count - 1 {
          Text("(ran last, hottest)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      if runStatus(for: model) == .queued {
        Text("Waiting for the previous model to finish and unload from memory.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        grid(model)
      }

      if let activePromptID = expandedPromptByModel[model],
        let result = rows.first(where: { $0.promptID == activePromptID })
      {
        scenarioPreviewBox(model: model, result: result)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
    )
  }

  private func grid(_ model: String) -> some View {
    let rows = bench.results.filter { $0.model == model }
    return VStack(spacing: 3) {
      HStack(spacing: 0) {
        cell("PROMPT", width: 96, align: .leading, dim: true)
        cell("EFFORT", width: 50, dim: true)
        cell("TOK/S", width: 58, dim: true)
        cell("PREFILL", width: 58, dim: true)
        cell("TTFT", width: 52, dim: true)
        cell("MEM", width: 48, dim: true)
        cell("IN/OUT TOK", width: 76, dim: true)
        cell("THINK", width: 48, dim: true)
        cell("END", width: 46, dim: true)
        cell("CACHE", width: 44, dim: true)
        cell("TIME", width: 46, dim: true)
        cell("", width: 40, dim: true)
      }
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.tertiary)

      ForEach(rows) { r in
        let isExpanded = expandedPromptByModel[model] == r.promptID
        HStack(spacing: 0) {
          cell(r.promptID, width: 96, align: .leading, dim: false)
          cell(r.effort, width: 50)
          cell(r.metrics.outputTps.map { String(format: "%.1f", $0) } ?? "—", width: 58)
          cell(r.metrics.promptTps.map { String(format: "%.0f", $0) } ?? "—", width: 58)
          cell(r.metrics.ttft.map { String(format: "%.2f", $0) } ?? "—", width: 52)
          cell(r.metrics.memoryGiB.map { String(format: "%.1fG", $0) } ?? "—", width: 48)
          cell(tokens(r), width: 76)
          cell(think(r), width: 48)
          cell(end(r), width: 46)
          cell(r.metrics.cacheN.map(String.init) ?? "—", width: 44)
          cell(r.metrics.elapsed.map { String(format: "%.2fs", $0) } ?? "—", width: 46)
          Button {
            withAnimation(.easeInOut(duration: 0.18)) {
              if isExpanded {
                expandedPromptByModel[model] = nil
              } else {
                expandedPromptByModel[model] = r.promptID
              }
            }
          } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
              .frame(width: 24, height: 18)
              .background(
                isExpanded ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4))
          }
          .buttonStyle(.plain)
          .frame(width: 40, alignment: .center)
          .help(
            isExpanded
              ? "Hide prompt & response preview" : "Inspect prompt & response for \(r.promptID)")
        }
        .font(.caption2)
        if let msg = r.metrics.error ?? r.metrics.skipped {
          HStack(spacing: 0) {
            cell(msg, width: 624, align: .leading, dim: true)
          }.font(.caption2)
        }
      }
    }
  }

  /// Collapsible scenario preview box rendered inline right after the model bench results table.
  private func scenarioPreviewBox(model: String, result: BenchResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      previewHeader(model: model, result: result)
      previewBadges(result: result)
      if let prompt = bench.promptText(result.promptID) {
        promptSnippet(prompt: prompt)
      }
      outputSnippet(result: result)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
  }

  private func previewHeader(model: String, result: BenchResult) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "text.magnifyingglass")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("SCENARIO PREVIEW · \(result.promptID)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.primary)
      Text("(\(result.effort) effort)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          expandedPromptByModel[model] = nil
        }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close preview")
    }
  }

  @ViewBuilder
  private func previewBadges(result: BenchResult) -> some View {
    HStack(spacing: 6) {
      if let tps = result.metrics.outputTps {
        metricBadge(title: "OUTPUT", value: String(format: "%.1f tok/s", tps), color: .green)
      }
      if let ttft = result.metrics.ttft {
        metricBadge(title: "TTFT", value: String(format: "%.2fs", ttft), color: .blue)
      }
      if let mem = result.metrics.memoryGiB {
        metricBadge(title: "MEM", value: String(format: "%.1f GiB", mem), color: .orange)
      }
      if let elapsed = result.metrics.elapsed {
        metricBadge(title: "TIME", value: String(format: "%.2fs", elapsed), color: .secondary)
      }
      if let pTok = result.metrics.promptTokens, let cTok = result.metrics.completionTokens {
        metricBadge(title: "TOKENS", value: "\(pTok) in / \(cTok) out", color: .purple)
      }
      if let reason = result.metrics.finishReason {
        metricBadge(
          title: "FINISH", value: reason == "length" ? "truncated" : reason,
          color: reason == "length" ? .orange : .secondary)
      }
    }
  }

  private func promptSnippet(prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text("PROMPT (\(prompt.count) chars)")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(prompt, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .font(.system(size: 10))
        }
        .buttonStyle(.link)
      }
      Text(prompt.count > 3_000 ? String(prompt.prefix(3_000)) + " … [truncated preview]" : prompt)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
  }

  private func outputSnippet(result: BenchResult) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text("MODEL OUTPUT")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
        if let think = result.metrics.reasoningTokens, think > 0 {
          Text("(\(think) reasoning tokens)")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let out = result.output, !out.isEmpty {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(out, forType: .string)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
              .font(.system(size: 10))
          }
          .buttonStyle(.link)
        }
      }
      let textToDisplay =
        result.output.flatMap { $0.isEmpty ? nil : $0 }
        ?? result.metrics.error
        ?? result.metrics.skipped
        ?? "(no output recorded)"
      Text(textToDisplay)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
  }

  private func metricBadge(title: String, value: String, color: Color) -> some View {
    HStack(spacing: 3) {
      Text(title)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(color)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  private var statusLine: some View {
    switch bench.phase {
    case .idle:
      EmptyView()
    case .loading(let m, let i, let n):
      Text("Loading \(i)/\(n) · \(ModelCatalog.displayName(for: m))…")
        .font(.caption).foregroundStyle(.secondary)
    case .running(let m, let p):
      Text("\(ModelCatalog.displayName(for: m)) · Scenario: \(p)…")
        .font(.caption).foregroundStyle(.secondary)
    case .done:
      Text("Completed").font(.caption).foregroundStyle(.green)
    case .failed(let m):
      note(m, .red)
    }
  }

  private func tokens(_ r: BenchResult) -> String {
    guard let i = r.metrics.promptTokens, let o = r.metrics.completionTokens else { return "—" }
    return "\(i)/\(o)"
  }

  private func think(_ r: BenchResult) -> String {
    guard let out = r.metrics.completionTokens, let t = r.metrics.reasoningTokens else {
      return "—"
    }
    return "\(t) (\(max(0, out - t)))"
  }

  private func end(_ r: BenchResult) -> String {
    if r.metrics.contentChars == 0 { return "empty" }
    guard let reason = r.metrics.finishReason else { return "—" }
    return reason == "length" ? "truncated" : reason
  }

  private func cell(
    _ t: String, width: CGFloat, align: Alignment = .trailing,
    dim: Bool = false
  ) -> some View {
    Text(t)
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(dim ? Color.secondary : Color.primary)
      .frame(width: width, alignment: align)
      .lineLimit(1)
  }

  private func note(_ m: String, _ c: Color) -> some View {
    Text(m).font(.caption).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
  }

  private func imageLabel(_ path: String) -> String {
    (path as NSString).lastPathComponent
  }

  private func pickImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Optional: an image for the vision benchmark prompt"
    if panel.runModal() == .OK, let url = panel.url {
      bench.imagePath = url.path
    }
  }
}
