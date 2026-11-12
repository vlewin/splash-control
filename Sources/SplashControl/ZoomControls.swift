import SwiftUI

/// Chrome that scales with the dashboard zoom step (Tray ▸ Zoom) and stays
/// vector-sharp at every step.
///
/// The zoom is typography-level (`.environment(\.uiScale, …)` → `ScaledFont`),
/// because every window- or view-level transform tried so far rasterises the
/// SwiftUI layer tree at 1× and stretches the bitmap: text re-renders sharp,
/// but Shapes and control bezels arrive as scaled pixels (measured 2026-11-01:
/// a caption under the transform was crisp, the Capsule behind it blocky).
/// That leaves AppKit-drawn chrome — default buttons, rounded TextFields,
/// segmented controls, switches — at its fixed system size next to grown
/// text. This file replaces exactly that chrome with SwiftUI shapes, which
/// draw at the laid-out size: sharp by construction, and their padding,
/// corner radius and height scale with the step like the fonts do.
///
/// Use via the `uiScale`-carrying environment: call sites read
/// `.zoomButton()`, `.zoomField()`, no factor parameters.
private struct ZoomChrome {
  let s: CGFloat

  /// Vertical button padding; the label's scaled line height makes the rest.
  var buttonY: CGFloat { 4 * s }
  var buttonX: CGFloat { 10 * s }
  var fieldY: CGFloat { 4 * s }
  var fieldX: CGFloat { 7 * s }
  var radius: CGFloat { 6 * s }
  /// Hairline stroke stays hairline — this is chrome, not content.
  var stroke: CGFloat { 1 }
}

extension EnvironmentValues {
  fileprivate var zoomChrome: ZoomChrome { ZoomChrome(s: uiScale) }
}

/// Vector button chrome replacing `.bordered` / `.borderedProminent` styles,
/// which AppKit draws at fixed sizes. The label must already use `ScaledFont`
/// (every call site's does); height and padding follow the step from there.
struct ZoomButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.zoomChrome) private var chrome
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.vertical, chrome.buttonY)
      .padding(.horizontal, chrome.buttonX)
      .background(
        prominent
          ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.65 : 0.85))
          : AnyShapeStyle(.background.secondary.opacity(configuration.isPressed ? 0.6 : 1)),
        in: RoundedRectangle(cornerRadius: chrome.radius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: chrome.radius)
          .strokeBorder(.separator, lineWidth: chrome.stroke)
      )
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: chrome.radius))
  }
}

/// Vector chrome for text input: pair with `.textFieldStyle(.plain)`. The
/// default rounded-border style is an NSTextField bezel drawn at a fixed
/// height, which sits stubby next to scaled text.
struct ZoomFieldChrome: ViewModifier {
  @Environment(\.zoomChrome) private var chrome

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      // The plain field takes the system body font (13 pt), which stayed
      // small inside the grown chrome - the chrome scales with the step,
      // so the label must ride it too. At s = 1 this is the same 13 pt the
      // field drew before.
      .font(.system(size: 13 * chrome.s))
      .padding(.vertical, chrome.fieldY)
      .padding(.horizontal, chrome.fieldX)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: chrome.radius))
      .overlay(
        RoundedRectangle(cornerRadius: chrome.radius)
          .strokeBorder(.separator, lineWidth: chrome.stroke)
      )
  }
}

extension View {
  func zoomButton(prominent: Bool = false) -> some View {
    buttonStyle(ZoomButtonStyle(prominent: prominent))
  }

  func zoomField() -> some View {
    modifier(ZoomFieldChrome())
  }
}

/// Map a control's design-time `ControlSize` through the zoom step. AppKit
/// controls draw their bezels at exactly these five named sizes and nothing
/// between, so the step moves a control along the ladder — coarse, but every
/// rung is vector-drawn by AppKit itself. For the chrome this file replaces
/// outright (buttons, fields, switches, segmented), the step is continuous.
extension CGFloat {
  /// `self` is the zoom step (≥ 1). `base` is the site's 100 % size.
  func zoomedControlSize(base: ControlSize) -> ControlSize {
    let ladder: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
    let idx = ladder.firstIndex(of: base) ?? 2
    // Two rungs per step keeps 200 % ≈ one full rung below label growth;
    // clamped at extraLarge, the biggest AppKit draws.
    let rise = Int((self - 1) * 2 + 0.5)
    return ladder[Swift.min(idx + rise, ladder.count - 1)]
  }
}

/// Vector switch replacing `.toggleStyle(.switch)`, whose AppKit cell draws
/// at three fixed sizes. Same palette (accent on, tertiary fill off), track
/// and knob follow the step. Tap anywhere on it toggles.
struct ZoomSwitch: View {
  @Binding var isOn: Bool
  @Environment(\.uiScale) private var s
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Capsule()
      .fill(isOn ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
      // 54 x 24 pt with a 20 pt knob is the native switch this replaces,
      // measured off a 100 % capture on the platform floor; the earlier
      // 38 x 22 shrank the control at 100 % instead of only at zoom steps.
      .frame(width: 54 * s, height: 24 * s)
      .overlay(alignment: isOn ? .trailing : .leading) {
        Circle()
          .fill(.white)
          .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
          .frame(width: 20 * s, height: 20 * s)
          .padding(2 * s)
      }
      .animation(.easeOut(duration: 0.12), value: isOn)
      .contentShape(Capsule())
      .onTapGesture { if isEnabled { isOn.toggle() } }
      // Hand the drawing-only capsule back its switch semantics: without this
      // VoiceOver has no element to focus and the keyboard has nothing to
      // activate, which the native `Toggle` this replaced provided for free.
      .accessibilityRepresentation { Toggle("", isOn: $isOn) }
      .opacity(isEnabled ? 1 : 0.4)
  }
}
