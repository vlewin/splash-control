import AppKit
import SwiftUI

/// Multiline field for literal text, used by Extra Serve Args.
///
/// SwiftUI's `TextEditor` inherits the user's macOS text substitutions, and
/// the one that mattered here was fatal: a typed `--probe` came back as
/// `—probe` (smart dashes), silently corrupting every flag typed fresh.
/// SwiftUI has no macOS switch for it, so this wraps `NSTextView` with the
/// substitutions off. Same AppKit-island shape as `FixedSegmented`.
///
/// `shortcut:` the system-wide "add period with double-space" preference is
/// applied in the text input stack below the view (AppKit exposes only the
/// read-only `NSSpellChecker.isAutomaticPeriodSubstitutionEnabled`), so two
/// typed spaces still become `. `; nothing here can switch it off.
struct LiteralTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Environment(\.uiScale) private var uiScale

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder

    let view = NSTextView(frame: scroll.contentView.bounds)
    Self.configure(view, scale: uiScale)
    view.delegate = context.coordinator
    view.string = text
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView else { return }
    context.coordinator.text = $text
    Self.configure(view, scale: uiScale)
    // Never rewrite the buffer under the caret; only sync an external change.
    if view.string != text { view.string = text }
  }

  /// `NSTextView` ships with the user's typography substitutions on, and
  /// there is no SwiftUI modifier for them on macOS.
  static func configure(_ view: NSTextView, scale: CGFloat) {
    view.isRichText = false
    view.allowsUndo = true
    view.drawsBackground = false
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainerInset = NSSize(width: 2, height: 2)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    view.font = .monospacedSystemFont(ofSize: TextBase.size(.body) * scale, weight: .regular)

    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      text.wrappedValue = view.string
    }
  }
}
