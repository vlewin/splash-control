import AppKit
import SwiftUI

/// Version, hardware, config location, log directory and credits.
///
/// These were the fifth card at the bottom of Settings, which meant answering
/// "what version is this?" cost a scroll past four cards of editable flags —
/// none of which this view can change. Read-only facts get their own tab, so the
/// Settings column is only settings.
///
/// Shaped like a native About panel rather than a bare card: the window now
/// resizes to this tab (`AppDelegate.tabHeights`), so everything here has to fit
/// the short frame without a scrollbar.
///
/// The card chrome (`cardChrome`/`card`/`twoUp`/`info`) is copied from
/// `SettingsView` rather than shared: every tab file already carries its own
/// copy of that 12-line block (`BenchView` ×4, `DashboardView` ×3, `LogsView`,
/// `StatsView` ×2), so extracting it would be a cross-cutting refactor of eight
/// call sites for no behaviour change.
struct InfoView: View {
  @ObservedObject var config: ConfigStore
  @ObservedObject var process: SplashProcess
  @ObservedObject var stats: StatsModel

  /// Tested-against splash range ("supported" = releases this app renders
  /// fully). Floor 1.2.0 = status schema 6, the DTO's model; max 1.3.0 = the
  /// installed release on the live server here (its `/status` is still schema 6;
  /// 8 is its native wire protocol, which this app never speaks). Keep in sync
  /// with ARCHITECTURE.md § 4.1; the agent that re-verifies against a new
  /// splash release updates both in the same PR.
  static let supportedSplash = "1.2.0 – 1.3.0"

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        hero
        runtimeCard
        creditsCard
      }
      .padding(16)
      .reportContentHeight("info")
    }
    .defaultScrollAnchor(.top)
    .onAppear { PowerMode.invalidate() }
  }

  /// App identity plus the three facts that answer "what am I running".
  private var hero: some View {
    cardChrome {
      VStack(spacing: 8) {
        // No clipShape, no extra shadow: AppIcon.icns already ships a
        // squircle with transparent corners and its own baked-in drop
        // shadow. Clipping clipped nothing (corner alpha is 0) and the
        // second shadow stacked into a visible halo.
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 64, height: 64)
        Text("Splash Control")
          .font(.title2.weight(.bold))
          .lineLimit(1)
        Text("macOS menu bar controller for the Splash LLM inference engine")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        // Rigid, so the three capsules keep their natural widths and the
        // row stays centred instead of being stretched and re-wrapped.
        HStack(spacing: 6) {
          badge("v\(SplashLog.version)")
          badge("Splash \(process.splashVersion ?? "—")")
          badge("Power: \(PowerMode.name(stats.powerMode))")
        }
        .fixedSize()
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var runtimeCard: some View {
    card("Runtime environment") {
      VStack(alignment: .leading, spacing: 10) {
        // One column, no right wing: a right-aligned value next to a long
        // endpoint read as two unrelated facts sharing a row.
        info("Inference engine", "Splash \(process.splashVersion ?? "—")")
        info("Engine support", "splash \(Self.supportedSplash)")
        info("API endpoint", process.endpointURL)
        info("Models", "\(ModelCatalog.installed().count) installed")

        Divider().opacity(0.4)

        // No Console logs row: the Logs tab reveals the selected channel
        // in Finder itself, so a second path to the same directory here
        // was a duplicate. This card is facts plus where config lives.
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Config")
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            Text(displayConfigPath)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(ConfigStore.configURL().path)
          }
          Spacer()
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.configURL()])
          } label: {
            Label("Reveal in Finder", systemImage: "folder")
          }
          .controlSize(.small)
        }
      }
    }
  }

  private var displayConfigPath: String {
    ConfigStore.configURL().path
      .replacingOccurrences(of: NSHomeDirectory(), with: "~")
  }

  private var creditsCard: some View {
    card("Open source & credits") {
      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "heart.fill")
            .font(.system(size: 14))
            .foregroundStyle(.pink)
          Text("Splash LLM Runtime by IncoAI — special thanks for open-sourcing this engine.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          if let url = URL(string: "https://github.com/incoai/splash") {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("Splash on GitHub", systemImage: "arrow.up.right.square")
        }
        .controlSize(.small)
        Button {
          if let url = URL(string: "https://github.com/incoai") {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("IncoAI", systemImage: "person.2")
        }
        .controlSize(.small)
      }
    }
  }

  private func badge(_ text: String) -> some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Color.primary.opacity(0.07), in: Capsule())
  }

  private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
  }

  private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    cardChrome {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  /// One read-only fact, in a column with the others.
  private func info(_ label: String, _ value: String) -> some View {
    LabeledContent(label, value: value)
  }
}
