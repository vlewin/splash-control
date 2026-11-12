import SwiftUI

/// The dashboard's typography zoom (Tray ▸ Zoom, 100–200 % in 25 % steps),
/// injected once at the DashboardView root from `SplashConfig.dashboardScale`.
///
/// This is deliberately *not* `environment(\.dynamicTypeSize, …)`: measured
/// on macOS against a hosted `Text`, every DynamicTypeSize from `.large` to
/// `.accessibility5` rendered an identical 16 pt line for a `.body` font —
/// dynamic type is effectively inert for SwiftUI text on macOS, and even on
/// iOS its steps are not the closed 25 % ladder the tray menu offers.
/// Scaling therefore happens at the token level: every `.font(…)` in the
/// dashboard goes through `ScaledFont` (design-system name `f`), which
/// multiplies the style's base point size by the step. Text, SF Symbols
/// (they are glyphs in the same font) and everything sized by their line
/// height grow natively — re-rendered by the text engine, not stretched,
/// so every step is as sharp as 100 %.
///
/// Window chrome stays system-sized on purpose: the native toolbar, the
/// menu bar, and AppKit control chrome (`.controlSize`) never see the step.
private struct UIScaleKey: EnvironmentKey {
  static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
  var uiScale: CGFloat {
    get { self[UIScaleKey.self] }
    set { self[UIScaleKey.self] = newValue }
  }
}

/// macOS base point sizes of the SwiftUI text styles, measured on the
/// 26.4 SDK (fitting width of a hosted sample text against every
/// size × weight grid): every style equals its HIG base size at regular
/// weight, except `.caption2`, whose width matches `medium` at 10 pt and
/// nothing at 11. Default weights follow the same probe and the HIG table:
/// `.headline` bold at 13, `.caption2` medium at 10, the rest regular.
/// At scale 1 every token below must render exactly like the semantic
/// font it replaces — the 100 % screenshot diff is the test for that claim.
enum TextBase {
  static func size(_ style: Font.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: return 26
    case .title: return 22
    case .title2: return 17
    case .title3: return 15
    case .headline: return 13
    case .body: return 13
    case .callout: return 12
    case .subheadline: return 11
    case .footnote: return 10
    case .caption: return 10
    case .caption2: return 10
    @unknown default: return 13
    }
  }

  static func weight(_ style: Font.TextStyle) -> Font.Weight {
    switch style {
    case .headline: return .bold
    case .caption2: return .medium
    default: return .regular
    }
  }
}

/// Font factory for one zoom step. Used as `f(.caption2, .semibold)` and
/// `f(size: 11, design: .monospaced)` — call sites read like the semantic
/// fonts they replace, with the step applied underneath.
///
/// Chaining `Font` APIs (`weight`, `monospaced`) still works on the result.
struct ScaledFont {
  let s: CGFloat

  func callAsFunction(
    _ style: Font.TextStyle, _ weight: Font.Weight? = nil, design: Font.Design = .default
  ) -> Font {
    .system(
      size: TextBase.size(style) * s, weight: weight ?? TextBase.weight(style), design: design)
  }

  func callAsFunction(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
    -> Font
  {
    .system(size: size * s, weight: weight, design: design)
  }
}
