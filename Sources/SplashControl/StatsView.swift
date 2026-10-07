import SwiftUI

/// Cross-model performance history and benchmark suite.
///
/// Organized with view nested tabs (`[ Model History | Benchmark ]`) conforming to
/// DESIGN.md guidelines:
/// - Nested segmented control directly beneath the window toolbar.
/// - Clear domain separation between passive accumulated telemetry across serving sessions
///   and active synthetic multi-model benchmarking.
struct StatsView: View {
  @ObservedObject var stats: ModelStats
  @ObservedObject var bench: BenchmarkEngine
  var onReset: () -> Void = {}

  enum SubTab: String, CaseIterable, Identifiable {
    case history = "Model History"
    case benchmark = "Benchmark"
    var id: String { rawValue }
  }
  @State private var subTab: SubTab = .history

  private let columns: [(id: String, title: String)] = [
    ("min", "MIN"), ("p50", "P50"), ("avg", "AVG"),
    ("p95", "P95"), ("max", "MAX"),
  ]
  private let metricColWidth: CGFloat = 110
  private let colWidth: CGFloat = 65
  private let avgColWidth: CGFloat = 70
  private let unitColWidth: CGFloat = 48
  private let countColWidth: CGFloat = 58

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        // Nested Sub-Navigation (DESIGN.md Standard)
        Picker("", selection: $subTab) {
          ForEach(SubTab.allCases) { t in
            Text(t.rawValue).tag(t)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .padding(.top, 4)

        switch subTab {
        case .history:
          historyContent
        case .benchmark:
          BenchSection(bench: bench)
        }
      }
      .padding(16)
      .reportContentHeight("stats-\(subTab.rawValue)-rows\(stats.rows.count)")
    }
    .frame(minWidth: 760)
    .scrollIndicators(.automatic)
  }

  // MARK: - Model History Tab

  private var historyContent: some View {
    VStack(spacing: 16) {
      header
      if stats.rows.isEmpty {
        emptyState
      } else {
        ForEach(stats.rows) { row in
          modelCard(row)
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Model Performance History")
          .font(.title3.weight(.semibold))
        Text("Aggregated telemetry across serving sessions and restarts")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        stats.resetAll()
        onReset()
      } label: {
        Label("Reset All", systemImage: "arrow.counterclockwise")
      }
      .controlSize(.small)
      .disabled(stats.rows.isEmpty)
    }
  }

  private func modelCard(_ row: ModelStats.Row) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "cpu")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(row.key.model)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)

        conditionChips(row.key)

        Spacer()

        Button {
          stats.reset(row.id)
          onReset()
        } label: {
          Label("Reset", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Reset telemetry for this model configuration")
      }

      VStack(spacing: 0) {
        tableHeaderView
        Divider().opacity(0.3).padding(.vertical, 6)
        metricRow(
          name: "Decode", icon: "bolt.fill", iconColor: .green,
          unit: "tok/s", agg: row.decode, reservoir: row.decodeReservoir)
        Divider().opacity(0.15).padding(.vertical, 4)
        metricRow(
          name: "Prefill", icon: "arrow.right.to.line.compact", iconColor: .purple,
          unit: "tok/s", agg: row.prefill, reservoir: row.prefillReservoir)
        Divider().opacity(0.15).padding(.vertical, 4)
        metricRow(
          name: "Memory", icon: "memorychip", iconColor: .orange,
          unit: "GiB", agg: row.memory, reservoir: row.memoryReservoir)
      }
      .padding(12)
      .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
      )

      HStack(spacing: 4) {
        Image(systemName: "info.circle")
          .font(.caption2)
        Text(
          "min/avg/max cover all recorded history · p50/p95 cover the most recent \(ModelStats.Reservoir().limit) samples"
        )
        .font(.system(size: 10))
      }
      .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private func conditionChips(_ key: ModelStats.Key) -> some View {
    HStack(spacing: 6) {
      if !key.kvFormat.isEmpty {
        chip("KV \(key.kvFormat)")
      }
      if !key.maxContext.isEmpty {
        chip("CTX \(key.maxContext)")
      }
      if !key.maxMemory.isEmpty {
        chip("MEM \(key.maxMemory)")
      }
      if !key.maxCacheDisk.isEmpty {
        chip("DISK \(key.maxCacheDisk)")
      }
    }
  }

  private func chip(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
  }

  private var tableHeaderView: some View {
    HStack(spacing: 12) {
      Text("METRIC")
        .frame(width: metricColWidth, alignment: .leading)
      ForEach(columns, id: \.id) { col in
        Text(col.title)
          .frame(width: col.id == "avg" ? avgColWidth : colWidth, alignment: .trailing)
      }
      Text("UNIT")
        .frame(width: unitColWidth, alignment: .leading)
      Text("SAMPLES")
        .frame(width: countColWidth, alignment: .trailing)
    }
    .font(.system(size: 10, weight: .bold))
    .foregroundStyle(.tertiary)
  }

  private func metricRow(
    name: String, icon: String, iconColor: Color,
    unit: String, agg: ModelStats.Aggregate,
    reservoir: ModelStats.Reservoir?
  ) -> some View {
    let values: [(String, Double?)] = [
      (fmt(agg.min), agg.min),
      (fmt(reservoir?.percentile(0.50)), reservoir?.percentile(0.50)),
      (fmt(agg.avg), agg.avg),
      (fmt(reservoir?.percentile(0.95)), reservoir?.percentile(0.95)),
      (fmt(agg.max), agg.max),
    ]
    return HStack(spacing: 12) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 11))
          .foregroundStyle(iconColor)
          .frame(width: 14)
        Text(name)
          .font(.system(size: 12, weight: .medium))
      }
      .frame(width: metricColWidth, alignment: .leading)

      ForEach(Array(values.enumerated()), id: \.offset) { i, pair in
        let (formatted, _) = pair
        let isAvg = (i == 2)
        Text(formatted)
          .font(.system(size: 12, weight: isAvg ? .bold : .regular, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(
            formatted == "—"
              ? AnyShapeStyle(.tertiary)
              : (isAvg ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
          )
          .frame(width: isAvg ? avgColWidth : colWidth, alignment: .trailing)
      }

      Text(unit)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .frame(width: unitColWidth, alignment: .leading)

      Text(agg.count > 0 ? String(agg.count) : "—")
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .frame(width: countColWidth, alignment: .trailing)
    }
  }

  private func fmt(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "—" }
    if v >= 1000 { return String(format: "%.0f", v) }
    if v >= 100 { return String(format: "%.0f", v) }
    return String(format: "%.1f", v)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "chart.bar.xaxis")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)
      Text("No Model Telemetry Recorded")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text("Telemetry accumulates automatically once requests are decoded or prefilled.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }
}
