import AppKit
import SplashControlKit
import SwiftUI

/// Settings, organized by domain into three focused sub-tabs conforming to DESIGN.md § 2.1:
/// - Server Limits: Hardware sizing presets and runtime memory/cache limits.
/// - App Behavior: Launch, quit, menu bar, and polling telemetry preferences.
/// - Advanced: Executable binary overrides, security, and low-level engine CLI flags.
///
/// Every row across all sub-tabs adheres to the consistent macOS form pattern:
/// Title and human-readable explanation on the left, right-aligned control on the right.
struct SettingsView: View {
  @ObservedObject var config: ConfigStore
  @ObservedObject var process: SplashProcess
  @ObservedObject var stats: StatsModel
  var onClose: (() -> Void)? = nil

  enum SettingsSubTab: String, CaseIterable, Identifiable {
    case server = "Server Limits"
    case behavior = "App Behavior"
    case advanced = "Advanced"

    var id: String { rawValue }
  }

  @AppStorage("settings_subtab") private var subTab: SettingsSubTab = .server
  @State private var copiedEndpoint = false

  // Effective server defaults, shown in inline placeholders.
  private let defMaxMemory = "58G"  // auto resolves to 58G on a 64 GiB Mac
  private let defMaxRequestSize = "128M"  // server default

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        // Nested Sub-Navigation (DESIGN.md § 2.1)
        Picker("", selection: $subTab) {
          ForEach(SettingsSubTab.allCases) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 380)
        .padding(.top, 4)

        switch subTab {
        case .server:
          presetsCard
          serverCard
        case .behavior:
          lifecycleCard
        case .advanced:
          advancedFlagsCard
        }

        HStack {
          Text("Preset: \(activePresetName)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Spacer()
          if let onClose {
            Button("Close") { onClose() }
              .keyboardShortcut(.defaultAction)
              .controlSize(.small)
          }
        }
        .padding(.top, 4)
      }
      .padding(16)
      .reportContentHeight("settings-\(subTab.rawValue)")
    }
    .frame(minWidth: 760)
    .scrollIndicators(.automatic)
    .defaultScrollAnchor(.top)
    .onAppear { PowerMode.invalidate() }
  }

  private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
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

  // MARK: - Form Row Helpers

  private func formRow<Control: View>(
    _ title: String,
    _ subtitle: String,
    warning: String? = nil,
    help: String? = nil,
    disabled: Bool = false,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if let warning, !warning.isEmpty {
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color.orange)
            .lineLimit(1)
        } else {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 16)
      control()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(disabled)
    .modifier(OptionalHelp(text: help))
  }

  private func toggleRow(
    _ title: String,
    _ subtitle: String,
    warning: String? = nil,
    isOn: Binding<Bool>,
    disabled: Bool = false,
    help: String? = nil
  ) -> some View {
    formRow(title, subtitle, warning: warning, help: help, disabled: disabled) {
      Toggle("", isOn: isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }

  // MARK: - Sub-Tab 1: Hardware Presets

  private var presetsCard: some View {
    card("Hardware presets") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          ForEach(presets) { preset in
            let isActive = preset.isCustom ? isCustomActive : preset.matches(config.config)
            Button {
              withAnimation(.easeInOut(duration: 0.15)) {
                preset.apply(to: &config.config)
              }
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                  Image(systemName: preset.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                  Text(preset.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  Spacer(minLength: 4)
                  if isActive {
                    HStack(spacing: 3) {
                      Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                      Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                  } else {
                    Text(preset.tagline)
                      .font(.system(size: 9, weight: .medium))
                      .foregroundStyle(.tertiary)
                      .lineLimit(1)
                  }
                }
                Text(preset.specSummary)
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .foregroundStyle(isActive ? .primary : .secondary)
                  .lineLimit(1)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 9)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                isActive
                  ? Color.accentColor.opacity(0.08)
                  : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 8)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .stroke(
                    isActive ? Color.accentColor : Color.primary.opacity(0.07),
                    lineWidth: isActive ? 1.5 : 0.5
                  )
              )
            }
            .buttonStyle(.plain)
            .disabled(preset.isCustom)
            .help(preset.detail)
          }
        }

        Text(presetsFootnote)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .help(
            "Presets write the config immediately. The server reads its flags only at launch, so a running server keeps the old values until Restart Server (⌘R)."
          )
      }
    }
  }

  private var presets: [HardwarePreset] {
    HardwarePreset.choices(physicalGiB: physicalGiB) + [HardwarePreset.custom(config.config)]
  }

  private var isCustomActive: Bool {
    !presets.dropLast().contains { $0.matches(config.config) }
  }

  private var presetsFootnote: String {
    isCustomActive
      ? "Your settings differ from both presets. They apply on the next server start."
      : "Presets set max memory, context and the disk tier. Applied on next server start."
  }

  // MARK: - Sub-Tab 1: Server & Runtime Limits

  private var serverCard: some View {
    card("Server & runtime limits") {
      VStack(alignment: .leading, spacing: 10) {
        // API Endpoint
        formRow(
          "API Endpoint", "Base URL for OpenAI and Anthropic client connections",
          help:
            "Base URL for OpenAI- and Anthropic-shaped clients: append /chat/completions, /responses or /messages."
        ) {
          HStack(spacing: 6) {
            Text("http://127.0.0.1:\(String(config.config.port))/v1")
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(Color.accentColor)
              .lineLimit(1)
              .textSelection(.enabled)
            Button {
              let pb = NSPasteboard.general
              pb.clearContents()
              pb.setString("http://127.0.0.1:\(String(config.config.port))/v1", forType: .string)
              copiedEndpoint = true
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                copiedEndpoint = false
              }
            } label: {
              HStack(spacing: 3) {
                Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                Text(copiedEndpoint ? "Copied" : "Copy")
              }
              .font(.caption2.weight(.medium))
              .foregroundStyle(copiedEndpoint ? Color.green : Color.primary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Copy http://127.0.0.1:\(String(config.config.port))/v1")
          }
          .padding(.horizontal, 8)
          .frame(height: 24)
          .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }

        // Port
        let portVerdict = SettingsValidator.port(
          config.config.port,
          inUse: process.portListening,
          external: process.isExternal,
          running: process.isActivelyServing(on: config.config.port)
        )
        let portWarning = portVerdict?.ok == false ? portVerdict?.text : nil
        let portSubtitle =
          portWarning == nil ? (portVerdict?.text ?? "HTTP port splash listens on") : ""
        formRow(
          "Port", portSubtitle, warning: portWarning,
          help:
            "The port splash serve listens on. It is also this app's base URL, and the port the tray polls."
        ) {
          TextField("8000", value: $config.config.port, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 140, alignment: .trailing)
        }

        Divider().opacity(0.4)

        // Max Memory
        let memVerdict = SettingsValidator.memory(config.config.maxMemory, physical: physicalGiB)
        let memWarning = memVerdict?.ok == false ? memVerdict?.text : nil
        let memSubtitle =
          memWarning == nil
          ? (memVerdict?.text ?? "Unified RAM budget · blank = auto (\(defMaxMemory))") : ""
        formRow(
          "Max Memory", memSubtitle, warning: memWarning,
          help:
            "Unified-memory budget for the engine. \(defMaxMemory) is auto on this host; leaving host headroom keeps macOS from paging the model out."
        ) {
          TextField(
            "Auto (\(defMaxMemory))",
            text: Binding(
              get: { config.config.maxMemory ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.maxMemory = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 140, alignment: .trailing)
        }

        // Context Window
        let ctxVerdict = SettingsValidator.context(config.config.maxContext)
        let ctxWarning = ctxVerdict?.ok == false ? ctxVerdict?.text : nil
        let ctxSubtitle =
          ctxWarning == nil
          ? (ctxVerdict?.text ?? "Maximum token limit per request · Auto = engine decides")
          : ""
        formRow(
          "Context Window", ctxSubtitle, warning: ctxWarning,
          help:
            "The enforced context window. Keep it equal to what your client caps at, or a request is rejected before it reaches the engine. Auto lets the engine decide; 256K, the server's cap, is offered only on hosts with 64 GiB or more of unified memory."
        ) {
          Picker(
            "",
            selection: Binding(
              get: { config.config.maxContext ?? "" },
              set: { config.config.maxContext = $0.isEmpty ? nil : $0 }
            )
          ) {
            Text("Auto").tag("")
            ForEach(contextWindowRows, id: \.self) { row in
              Text(row == contextRecommendedTier ? "\(row) (Recommended)" : row).tag(row)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }

        // KV Cache Precision
        formRow(
          "KV Cache Precision", "INT8 halves RAM usage; BF16 preserves full precision",
          help:
            "int8 halves the KV cache footprint. bf16 keeps full precision at roughly twice the cache cost."
        ) {
          Picker(
            "",
            selection: Binding(
              get: { config.config.kvFormat ?? "int8" },
              set: { config.config.kvFormat = $0 == "int8" ? nil : $0 }
            )
          ) {
            Text("INT8 (Compact, Default)").tag("int8")
            Text("BF16 (Full Precision)").tag("bf16")
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }

        // Idle Release
        let (idleSub, idleWarn) = idleReleaseSubtitle()
        formRow(
          "Idle Release", idleSub, warning: idleWarn,
          help:
            "How long the engine keeps weights in memory without a request. A longer interval keeps the model ready and the memory figure honest; off keeps weights allocated between requests."
        ) {
          TextField(
            "10m (Default)",
            text: Binding(
              get: { config.config.idleRelease ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.idleRelease = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 140, alignment: .trailing)
        }

        Divider().opacity(0.4)

        // Disk Cache Tier
        let diskVerdict = SettingsValidator.diskTier(config.config.maxCacheDisk)
        let diskWarning = diskVerdict?.ok == false ? diskVerdict?.text : nil
        let diskSubtitle =
          diskWarning == nil
          ? (diskVerdict?.text ?? "SSD quota for offloading KV cache · blank or 0 = off") : ""
        formRow(
          "Disk Cache Tier", diskSubtitle, warning: diskWarning,
          help:
            "SSD quota for cached KV pages and states. Temporary unless Persistent disk cache is on: the tier is discarded on restart."
        ) {
          TextField(
            "0 (Off)",
            text: Binding(
              get: { config.config.maxCacheDisk ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.maxCacheDisk = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 140, alignment: .trailing)
        }

        // Persistent Disk Cache (Paired directly with Disk Cache Tier)
        let diskTierEnabled = SettingsValidator.diskTierEnabled(config.config.maxCacheDisk)
        toggleRow(
          "Persist Cache Across Restarts",
          diskTierEnabled
            ? "Retains conversation prompt prefix cache on SSD across restarts"
            : "Requires Disk Cache Tier above 0",
          isOn: $config.config.persistentCache,
          disabled: !diskTierEnabled,
          help:
            "Preserves the prefix KV cache on disk between server restarts. Requires a disk cache tier to be configured."
        )
      }
    }
  }

  private func idleReleaseSubtitle() -> (subtitle: String, warning: String?) {
    let configured = SettingsValidator.idleRelease(config.config.idleRelease)
    let effective = SettingsValidator.idleReleaseEffective(
      configured: config.config.idleRelease,
      weights: stats.latest?.weights
    )
    if let configured, !configured.ok {
      return ("", configured.text)
    }
    if let effective, !effective.ok {
      return ("", effective.text)
    }
    if let effective {
      return (effective.text, nil)
    }
    if let configured {
      return (configured.text, nil)
    }
    return ("Unload weights during inactivity · blank = 10m", nil)
  }

  // MARK: - Sub-Tab 2: App Behavior

  private var lifecycleCard: some View {
    card("Application & Lifecycle") {
      VStack(alignment: .leading, spacing: 12) {
        toggleRow(
          "Launch at login", "Open SplashControl automatically when you log in",
          isOn: $config.config.startOnLogin)
        toggleRow(
          "Start server on launch", "Run splash serve automatically when SplashControl starts",
          isOn: $config.config.autoStart)
        toggleRow(
          "Stop server on quit", "Terminate splash server when SplashControl exits",
          isOn: $config.config.stopOnQuit)
        toggleRow(
          "Menu bar token rate", "Show decode tokens/sec beside the tray icon",
          isOn: $config.config.showTrayTps)

        Divider().opacity(0.4)

        formRow("Poll Interval", "GET /status query cadence") {
          FixedSegmented(
            width: 180, titles: ["1 s", "2 s", "5 s"], values: [1.0, 2.0, 5.0],
            selection: Binding(
              get: { config.config.pollIntervalSec },
              set: { config.config.pollIntervalSec = $0 }
            )
          )
          .fixedSize()
        }

        formRow("Chart Window", "Rolling time window for telemetry charts") {
          FixedSegmented(
            width: 180, titles: ["15 min", "30 min", "1 h"], values: [15, 30, 60],
            selection: Binding(
              get: { config.config.windowMinutes },
              set: { config.config.windowMinutes = $0 }
            )
          )
          .fixedSize()
        }
      }
    }
  }

  // MARK: - Sub-Tab 3: Advanced

  private var advancedFlagsCard: some View {
    card("Advanced Engine Flags") {
      VStack(alignment: .leading, spacing: 12) {
        formRow(
          "Splash Binary", "Executable path for splash serve · blank = /opt/homebrew/bin/splash",
          help: "Executable path for splash serve. Override it to run a custom build."
        ) {
          TextField(
            "/opt/homebrew/bin/splash",
            text: Binding(
              get: { config.config.splashPath ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.splashPath = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 240, alignment: .trailing)
        }

        formRow(
          "API Key", "Bearer token for client authentication · blank = none",
          help:
            "Sent as --api-key. Clients must send the same value; blank allows local loopback without a token."
        ) {
          TextField(
            "Optional",
            text: Binding(
              get: { config.config.apiKey ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.apiKey = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 240, alignment: .trailing)
        }

        formRow(
          "Allowed Hosts", "Space-separated extra Host headers accepted · blank = none",
          help: "Extra Host header values the server answers to. Repeatable via --allowed-host."
        ) {
          TextField(
            "Optional",
            text: Binding(
              get: { config.config.allowedHost ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.allowedHost = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 240, alignment: .trailing)
        }

        formRow(
          "Max Request Size", "Largest accepted HTTP request body · blank = 128M",
          help: "Largest accepted request body. Blank uses the server default of 128M."
        ) {
          TextField(
            "128M (Default)",
            text: Binding(
              get: { config.config.maxRequestSize ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.maxRequestSize = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 140, alignment: .trailing)
        }

        formRow(
          "Max Image Pixels", "Maximum image resolution for vision models · blank = server default",
          help: "Largest image the vision path will encode, in pixels. Blank uses server default."
        ) {
          TextField(
            "Server default",
            text: Binding(
              get: { config.config.maxImagePixels ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.maxImagePixels = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 140, alignment: .trailing)
        }

        formRow(
          "Model Alias", "Extra name clients can use instead of the model id · blank = none",
          help:
            "Passed as --served-model-name. Clients using the alias keep working across model switches. Remove any --served-model-name from Extra Serve Args below to avoid a second alias."
        ) {
          TextField(
            "default",
            text: Binding(
              get: { config.config.servedModelName ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.servedModelName = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 240, alignment: .trailing)
        }

        toggleRow(
          "Announce Alias",
          "Report the alias first in /v1/models and replies (--announce-served-name)",
          isOn: $config.config.announceServedName,
          disabled: (config.config.servedModelName?.trimmingCharacters(in: .whitespaces).isEmpty
            ?? true),
          help: "Needs a Model Alias above; without one the flag is never passed.")

        formRow(
          "Reasoning Effort", "Default thinking depth for chat clients · blank = model template",
          help:
            "Passed as --default-reasoning-effort. Shapes the prompt via the chat template; a model whose template ignores it is unaffected."
        ) {
          Picker(
            "",
            selection: Binding(
              get: { config.config.reasoningEffort ?? "" },
              set: { config.config.reasoningEffort = $0.isEmpty ? nil : $0 }
            )
          ) {
            Text("Model Template").tag("")
            ForEach(SplashConfig.reasoningEffortValues, id: \.self) { v in
              Text(v.capitalized).tag(v)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }

        Divider().opacity(0.4)

        toggleRow(
          "Disable Web UI", "Disable the browser chat interface (--no-webui)",
          isOn: $config.config.noWebUI)
        toggleRow(
          "Language Only", "Skip vision weights to conserve memory (--language-only)",
          isOn: $config.config.languageOnly)

        VStack(alignment: .leading, spacing: 4) {
          Text("Extra Serve Args")
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Text("Only flags with no control above · appended verbatim")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          TextEditor(
            text: Binding(
              get: { config.config.extraArgs ?? "" },
              set: { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                config.config.extraArgs = trimmed.isEmpty ? nil : trimmed
              }
            )
          )
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 56, maxHeight: 84)
          .padding(4)
          .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
        .modifier(
          OptionalHelp(
            text:
              "Appended verbatim to splash serve, after every dedicated control. Escape hatch for experimental runtime flags."
          ))

        Divider().opacity(0.4)

        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("LAUNCH COMMAND")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(process.launchCommandPreview, forType: .string)
            } label: {
              HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                Text("Copy Command")
              }
              .font(.caption2.weight(.medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
          }

          Text(process.launchCommandPreview)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
      }
    }
  }

  // MARK: - Sizing & Helpers

  private var physicalGiB: Double? {
    let host = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    if host > 0 { return host }
    return stats.latest?.memoryPlan?.device?.physicalMemoryBytes
      .map { Double($0) / 1_073_741_824 }
  }

  /// Picker rows for the context window: the choices the host can afford plus
  /// whatever is configured, so a non-standard value stays selectable (the
  /// `""` Auto row is always present, so the selection is always in range).
  private var contextWindowRows: [String] {
    var rows = SplashConfig.contextChoices(physicalGiB: HostMemory.physicalGiB)
    let configured = config.config.maxContext ?? ""
    if !rows.contains(configured) { rows.append(configured) }
    return rows
  }

  /// The recommended preset's tier, so its row carries the badge.
  private var contextRecommendedTier: String {
    HardwarePreset.recommended(physicalGiB: HostMemory.physicalGiB).maxContext
  }

  private var activePresetName: String {
    presets.dropLast().first { $0.matches(config.config) }?.title ?? "Custom"
  }
}

// MARK: - Tooltip Helper

private struct OptionalHelp: ViewModifier {
  let text: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let text, !text.isEmpty {
      content.help(text)
    } else {
      content
    }
  }
}

// MARK: - Hardware Presets

/// One-click server sizing. The three numbers move together because that is how
/// they interact — a bigger cache is only affordable if the engine budget leaves
/// host headroom — so a preset is a coherent choice rather than three fields.
///
/// **The recommended preset is derived from this Mac's memory, not from a table
/// of machine names.** A fixed "64 GB Mac" button is a claim about hardware the
/// user may not own, and on a 24 GB machine it offers a budget that does not fit.
///
/// The arithmetic is headroom, not authority: each tier leaves 8–12 GiB for
/// macOS and the rest of the session, which is what keeps the OS from paging the
/// model out mid-request (`docs/performance.md`: splash gives cached memory back
/// under pressure, but *a request in service still takes the memory it needs*
/// within `--max-memory`). Two upstream facts anchor it and are the only ones
/// claimed — `incoai/splash` README § Models states the 4-bit examples need at
/// least 36 GB, 48 GB recommended, and a live server's own auto budget on a
/// 64 GiB host is `memory_plan.device.recommended_max_working_set_bytes`
/// = 51.85 GiB, which is where the 52G below comes from.
struct HardwarePreset: Identifiable {
  let id: String
  let title: String
  let tagline: String
  let icon: String
  let specSummary: String
  let detail: String
  let maxMemory: String
  let maxContext: String
  let maxCacheDisk: String?
  /// The custom card renders what is configured, so applying it is a no-op.
  let isCustom: Bool

  /// Sizing for a host with `gib` GiB of unified memory. The host decides the
  /// tier; `nil` (no server, and `ProcessInfo` unreadable) takes the documented
  /// smallest tier rather than guessing a large one.
  static func recommended(physicalGiB gib: Double?) -> HardwarePreset {
    let (memory, context, disk, tagline): (String, String, String?, String)
    // Unknown host takes the 24 GB tier: the smallest one we document, so a
    // budget that cannot fit is not something we hand out. `ProcessInfo` is
    // not documented never to fail, hence the fallback.
    let gib = gib ?? 24
    switch gib {
    // Below 32 GiB the budget is headroom arithmetic, not a fixed figure:
    // `gib - 8` is 16G on a 24 GiB Mac, and it keeps the tier honest on a
    // 16 GiB host, where a flat 16G would be the whole machine.
    case ..<32:
      (memory, context, disk, tagline) = (
        "\(Int(gib - 8))G", "64K", "10G",
        gib <= 24 ? "Optimized for 24 GB" : "Tight fit for 16 GB"
      )
    // Taglines stay short on purpose: they sit beside the title in a ~270 pt
    // card, and `Recommended for this Mac (64 GB)` truncated to
    // `Recommended for this Ma…`. The full host size is in the tooltip.
    case ..<48: (memory, context, disk, tagline) = ("24G", "64K", "5G", "Optimized · 32/36 GB")
    case ..<60: (memory, context, disk, tagline) = ("36G", "128K", "10G", "Recommended · 48 GB")
    case ..<80: (memory, context, disk, tagline) = ("52G", "128K", "10G", "Recommended · 64 GB")
    default: (memory, context, disk, tagline) = ("80G", "128K", "16G", "Max performance · 96 GB+")
    }
    let ram = String(format: "%.0f GB", gib)
    return HardwarePreset(
      id: "recommended",
      title: "Recommended",
      tagline: tagline,
      icon: "checkmark.seal",
      specSummary: "\(memory) RAM · \(context) ctx · \(disk.map { "\($0) disk" } ?? "tier off")",
      detail: "--max-memory \(memory) --max-context \(context)"
        + (disk.map { " --max-cache-disk \($0)" } ?? ", disk tier off")
        + ". Sized from this Mac's \(ram) of unified memory, leaving host headroom "
        + "for macOS — the 4-bit models need at least 36 GB (48 GB recommended) per the "
        + "splash README, and a request in service still takes the memory it needs "
        + "within --max-memory.",
      maxMemory: memory, maxContext: context, maxCacheDisk: disk, isCustom: false)
  }

  /// Smallest footprint that still serves a real request. For running a heavy
  /// IDE, a browser and a build alongside the model.
  static let minimal = HardwarePreset(
    id: "minimal",
    title: "Minimal",
    tagline: "Smallest footprint",
    icon: "leaf.fill",
    specSummary: "18G RAM · 32K ctx · tier off",
    detail: "--max-memory 18G --max-context 32K, disk tier off. Leaves the machine to "
      + "everything else it is running. Costs long-context work and cache reuse, and "
      + "the tier is off so nothing is kept on SSD between requests.",
    maxMemory: "18G", maxContext: "32K", maxCacheDisk: nil, isCustom: false)

  /// The third card: whatever is actually configured, so a diverged config is
  /// visible as numbers rather than as the absence of a highlight.
  static func custom(_ config: SplashConfig) -> HardwarePreset {
    let memory = config.maxMemory?.isEmpty == false ? config.maxMemory! : "auto"
    let context = config.maxContext?.isEmpty == false ? config.maxContext! : "auto"
    let disk = config.maxCacheDisk?.isEmpty == false ? config.maxCacheDisk! : "off"
    return HardwarePreset(
      id: "custom",
      title: "Custom",
      tagline: "Your settings, unchanged",
      icon: "slider.horizontal.3",
      specSummary: "\(memory) RAM · \(context) ctx · \(disk) disk",
      detail: "These are your configured values: --max-memory \(memory), "
        + "--max-context \(context), --max-cache-disk \(disk). Editing any field above "
        + "lands here. The server reads its flags only at launch, so a running server "
        + "keeps the values it was started with until Restart Server.",
      maxMemory: memory, maxContext: context, maxCacheDisk: disk, isCustom: true)
  }

  /// The two presets a click can apply. The custom card is not among them.
  static func choices(physicalGiB gib: Double?) -> [HardwarePreset] {
    [recommended(physicalGiB: gib), minimal]
  }

  func apply(to config: inout SplashConfig) {
    set(on: &config)
    SplashLog.shared.log(
      "settings_preset_applied preset=\(id) memory=\(maxMemory) context=\(maxContext) disk=\(maxCacheDisk ?? "off")"
    )
  }

  /// The write itself, without the log. `check_core.sh` asserts through this:
  /// `SplashLog.shared` is process-global, so calling `apply` from the check
  /// suite would rotate a running install's real logs.
  func set(on config: inout SplashConfig) {
    guard !isCustom else { return }
    config.maxMemory = maxMemory
    config.maxContext = maxContext
    config.maxCacheDisk = maxCacheDisk
  }

  func matches(_ config: SplashConfig) -> Bool {
    !isCustom
      && config.maxMemory == maxMemory
      && config.maxContext == maxContext
      && (config.maxCacheDisk ?? nil) == maxCacheDisk
  }
}

// MARK: - Validation

/// Field-level checks for the values that otherwise fail late.
///
/// Every one of these is a value splash accepts at the CLI but may reject, or
/// silently reinterpret, at launch — so the point is to say it here rather than
/// in the crash log.
enum SettingsValidator {
  struct Verdict {
    let ok: Bool
    let text: String
  }

  /// `--idle-release` takes `off`, a bare number of **seconds**, or a number
  /// with one `s`/`m`/`h` suffix. The server's parser is strict — `abc`, `15x`
  /// and `1h30m` all abort startup with exit 2 — so a typo here is a dead
  /// server, not a warning. The accept/reject decision comes from
  /// `SplashProcess.sanitizedIdleRelease`, the same function the launcher uses,
  /// so this verdict cannot disagree with what actually gets passed.
  ///
  /// The trap it exists to name: a bare number is **seconds**. `15` means
  /// fifteen seconds, which fails silently by releasing the weights almost
  /// immediately — the same trap `--max-memory 32` sets for GiB.
  static func idleRelease(_ value: String?) -> Verdict? {
    guard let value else { return nil }
    let raw = value.trimmingCharacters(in: .whitespaces)
    if raw.isEmpty { return Verdict(ok: true, text: "Server default · 10m") }

    guard let sanitized = SplashProcess.sanitizedIdleRelease(value) else {
      return Verdict(ok: false, text: "Not a duration — try 90s, 30m, 2h, or off")
    }
    if sanitized == "off" {
      return Verdict(ok: true, text: "Weights stay resident between requests")
    }
    guard let n = Double(sanitized.dropLast(sanitized.last!.isNumber ? 0 : 1)) else { return nil }
    let noun =
      sanitized.last!.isNumber
      ? "seconds" : ["s": "seconds", "m": "minutes", "h": "hours"][String(sanitized.last!)]!
    let suffix = sanitized.last!.isNumber ? " — a bare number is seconds, not minutes" : ""
    return Verdict(ok: true, text: String(format: "%.0f %@%@", n, noun, suffix))
  }

  /// What the *running* server reports, as opposed to what is typed above.
  ///
  /// This exists to catch one failure that nothing else would: the capability
  /// gate (ARCHITECTURE.md § 4.6) silently omits `--idle-release` on a binary
  /// older than 1.2.1, and the server then applies its own 10-minute default. Nothing
  /// looks broken — the engine works, weights still release, just on a schedule
  /// nobody chose. Showing the resolved interval is how that becomes visible.
  ///
  /// The three outcomes are deliberately distinct, because `nil` here means two
  /// different things and conflating them would be its own lie: `weights == nil`
  /// means the server predates 1.2.1 or has not answered yet (say nothing), and
  /// a present `weights` with a null interval means idle release is **off**.
  /// Compact human form of an interval. Deliberately never rounds: 90 s must
  /// not become "2m", which is the kind of quiet 33% error nobody would ever
  /// report.
  private static func interval(_ seconds: Double) -> String {
    let whole = seconds.truncatingRemainder(dividingBy: 1) == 0
    if whole, seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
      return "\(Int(seconds / 3600))h"
    }
    if whole, seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
      return "\(Int(seconds / 60))m"
    }
    return "\(Int(seconds))s"
  }

  static func idleReleaseEffective(
    configured: String?,
    weights: StatusDTO.Weights?
  ) -> Verdict? {
    guard let weights else { return nil }
    guard let seconds = weights.idleReleaseSeconds else {
      return Verdict(ok: true, text: "Server: off · weights stay resident")
    }
    let shown = interval(seconds)

    guard let sanitized = SplashProcess.sanitizedIdleRelease(configured) else {
      return Verdict(ok: true, text: "Server: \(shown)")
    }
    if sanitized == "off" {
      return Verdict(
        ok: false, text: "Server: \(shown) — you set off, so weights are being released")
    }
    guard let wanted = SplashProcess.idleReleaseSeconds(configured) else {
      return Verdict(ok: true, text: "Server: \(shown)")
    }
    if abs(wanted - seconds) < 1 { return Verdict(ok: true, text: "Server: \(shown)") }
    return Verdict(ok: false, text: "Server: \(shown) — not the \(interval(wanted)) you set")
  }

  /// `58G`, `24G`, `4G`, `80%`, or blank for auto. A bare number is the trap:
  /// `--max-memory 32` is not 32 GiB, and it does not fail where you typed it.
  static func memory(_ value: String?, physical: Double?) -> Verdict? {
    guard let value, !value.isEmpty else { return nil }
    let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
    if lower.hasSuffix("%") {
      guard let pct = Double(lower.dropLast()), (1...100).contains(pct) else {
        return Verdict(ok: false, text: "Not a percentage: write e.g. 80%")
      }
      return Verdict(ok: true, text: String(format: "%.0f%% of physical memory", pct))
    }
    guard let number = Double(lower.dropLast(lower.hasSuffix("g") ? 1 : 0)),
      lower.hasSuffix("g") || lower.hasSuffix("m") || lower.hasSuffix("k")
    else {
      return Verdict(
        ok: false,
        text: "Expected a size like 36G — a bare number is not GiB")
    }
    let gib =
      lower.hasSuffix("g")
      ? number
      : lower.hasSuffix("m")
        ? number / 1024
        : number / (1024 * 1024)
    guard gib >= 1 else {
      return Verdict(ok: false, text: String(format: "%.3f GiB is too small to hold a model", gib))
    }
    if let physical, gib >= physical {
      return Verdict(
        ok: false,
        text: String(format: "%.0f GiB is the whole machine — leave headroom for the OS", physical))
    }
    let base = String(format: "%.1f GiB", gib)
    guard let physical else { return Verdict(ok: true, text: base) }
    return Verdict(
      ok: true,
      text: base
        + String(
          format: " · headroom %.1f GiB on %.0f GiB",
          physical - gib, physical))
  }

  /// `128K`, `32K`, `262144` — splash takes a count too, which is why this
  /// accepts both and why the window is shown in tokens either way.
  static func context(_ value: String?) -> Verdict? {
    guard let value, !value.isEmpty else { return nil }
    let lower = value.trimmingCharacters(in: .whitespaces).lowercased()
    let tokens: Double
    if lower.hasSuffix("k") {
      guard let k = Double(lower.dropLast()) else {
        return Verdict(ok: false, text: "Expected a count like 128K")
      }
      tokens = k * 1024
    } else if lower.hasSuffix("m") {
      guard let m = Double(lower.dropLast()) else {
        return Verdict(ok: false, text: "Expected a count like 1M")
      }
      tokens = m * 1024 * 1024
    } else {
      guard let n = Double(lower) else {
        return Verdict(ok: false, text: "Expected a count like 128K or 262144")
      }
      tokens = n
    }
    guard tokens >= 4096 else {
      return Verdict(ok: false, text: "Below 4K tokens — no request would fit")
    }
    return Verdict(ok: true, text: "Window: " + String(Int(tokens)) + " tokens")
  }

  static func diskTier(_ value: String?) -> Verdict? {
    guard let value, !value.isEmpty, value != "0" else {
      return Verdict(ok: true, text: "Disabled — cached KV pages stay in memory")
    }
    guard let verdict = memory(value, physical: nil) else { return nil }
    return Verdict(
      ok: verdict.ok,
      text: verdict.ok
        ? verdict.text + " of SSD for cached KV pages"
        : verdict.text + " (disk tier)")
  }

  /// Whether `--persistent-cache` would do anything. The flag needs a
  /// non-zero tier: with none, the setting is inert, so its control is
  /// disabled rather than quietly accepting a value that does nothing.
  static func diskTierEnabled(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value != "0" else { return false }
    return memory(value, physical: nil)?.ok ?? false
  }

  /// Port range, and — the part that actually bites — whether anything is
  /// already listening. A port collision is not a config error the server
  /// reports clearly; it is a tray that appears to start and never becomes
  /// ready.
  static func port(_ value: Int, inUse: Bool, external: Bool, running: Bool = false) -> Verdict? {
    guard (1...65535).contains(value) else {
      return Verdict(ok: false, text: "Port must be 1–65535")
    }
    if running {
      return Verdict(ok: true, text: "Active on port \(value)")
    }
    if inUse {
      return Verdict(
        ok: false,
        text: external
          ? "Port \(value) is in use by an adopted splash — that is the server this tray is watching"
          : "Port \(value) is in use by another process")
    }
    return Verdict(ok: true, text: "Port is available")
  }
}

// MARK: - Native Segmented Control

/// Native segmented control with an explicit total width.
///
/// A SwiftUI segmented Picker cannot be sized or freely positioned inside a
/// grouped Form: the Form columnizes Picker rows and NSSegmentedControl sizes
/// to fit, so frames are defeated. This wraps NSSegmentedControl directly and
/// pins every segment to an equal share of `width`. It is opaque to the Form,
/// so it lays out as plain content (like the model menu Picker row).
private struct FixedSegmented<Value: Hashable>: NSViewRepresentable {
  let width: CGFloat
  let titles: [String]
  let values: [Value]
  @Binding var selection: Value

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: titles,
      trackingMode: .selectOne,
      target: context.coordinator,
      action: #selector(Coordinator.changed(_:))
    )
    for i in titles.indices {
      control.setWidth(width / CGFloat(titles.count), forSegment: i)
    }
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.sync(control: control, selection: selection)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(values: values, selection: $selection)
  }

  final class Coordinator: NSObject {
    let values: [Value]
    var selection: Binding<Value>

    init(values: [Value], selection: Binding<Value>) {
      self.values = values
      self.selection = selection
    }

    @objc func changed(_ sender: NSSegmentedControl) {
      guard sender.selectedSegment >= 0 else { return }
      selection.wrappedValue = values[sender.selectedSegment]
    }

    func sync(control: NSSegmentedControl, selection: Value) {
      if let i = values.firstIndex(of: selection), control.selectedSegment != i {
        control.selectedSegment = i
      }
    }
  }
}
