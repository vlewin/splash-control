import SwiftUI

/// A tab's measured content height plus which tab (and sub-state) measured it.
/// DashboardView fits the window to these reports; the source tag exists
/// because a report applied to the wrong tab cuts content.
struct ContentReport: Equatable {
  let height: CGFloat
  let source: String
}

/// Measured inside the ScrollView, where children size to their ideal height.
/// Logs is the exception: it reports nothing and keeps its fixed console
/// height, because a window that grows with every log line would jump while
/// watched.
struct ContentHeightKey: PreferenceKey {
  static var defaultValue: ContentReport? { nil }
  static func reduce(value: inout ContentReport?, nextValue: () -> ContentReport?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Report this view's laid-out height through ContentHeightKey. Attach to
  /// the content VStack inside the ScrollView (after padding), never to the
  /// ScrollView itself — that one fills the window and would report the
  /// window back to itself.
  func reportContentHeight(_ source: String = "unknown") -> some View {
    background(
      GeometryReader { geo in
        Color.clear.preference(
          key: ContentHeightKey.self,
          value: ContentReport(height: geo.size.height, source: source))
      }
    )
  }
}
