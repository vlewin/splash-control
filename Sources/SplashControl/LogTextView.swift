import AppKit
import SwiftUI

/// The log pane's text, as a read-only `NSTextView`.
///
/// AppKit on purpose. SwiftUI's `.textSelection(.enabled)` is scoped to one
/// `Text`, so a drag never spanned lines, and the alternative — one `Text` for
/// the whole tail — cost seconds of layout per refresh. `NSTextView` gives
/// block selection (and so ⌘C over a range) for free, and lays out with
/// TextKit, which is what it was written for.
struct LogTextView: NSViewRepresentable {
  let lines: [String]
  let needle: String
  @Binding var followTail: Bool

  func makeCoordinator() -> Coordinator { Coordinator(followTail: $followTail) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true

    let text = NSTextView()
    text.isEditable = false
    text.isSelectable = true
    text.drawsBackground = false
    text.textContainerInset = NSSize(width: 12, height: 6)
    text.textContainer?.widthTracksTextView = true
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    // Wrapping must recompute at the pane's width, not the window's.
    text.minSize = .zero
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = text

    context.coordinator.observe(scroll)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    LogText.apply(LogText.attributed(lines, needle: needle), to: text)
    if followTail { LogText.scrollToEnd(scroll) }
  }

  /// Owns the "am I still following the tail?" signal. It is the scroll view's
  /// own position that answers it, debounced: a programmatic scroll to the end
  /// posts several bounds changes, and judging the first one would read as "the
  /// reader scrolled up" and silently lock the tail. Only where the view comes
  /// to rest says what the reader did.
  final class Coordinator: NSObject {
    private let followTail: Binding<Bool>
    private weak var scroll: NSScrollView?
    private var observer: NSObjectProtocol?
    private var settle: DispatchWorkItem?

    init(followTail: Binding<Bool>) { self.followTail = followTail }

    func observe(_ scroll: NSScrollView) {
      self.scroll = scroll
      scroll.contentView.postsBoundsChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
          guard let self, let scroll = self.scroll else { return }
          let pinned = LogText.isAtEnd(scroll)
          guard self.followTail.wrappedValue != pinned else { return }
          self.followTail.wrappedValue = pinned
        }
        self.settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
      }
    }

    deinit {
      settle?.cancel()
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }
}

/// Text building and scrolling, split out so `check_core.sh` can assert the
/// attributes without a window.
enum LogText {
  static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
  static let hitFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

  static func attributed(_ lines: [String], needle: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let out = NSMutableAttributedString()
    for line in lines {
      let base: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(LogsView.colour(for: line)),
        .paragraphStyle: paragraph,
      ]
      if needle.isEmpty {
        out.append(NSAttributedString(string: line, attributes: base))
      } else {
        // The runs come from `LogsView.highlighted`, the same builder the
        // tests pin, so a matching line is tinted for the same reason the
        // filter matched it.
        let highlighted = LogsView.highlighted(line, needle: needle)
        for run in highlighted.runs {
          var attributes = base
          if run.backgroundColor != nil {
            attributes[.font] = hitFont
            attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.28)
          }
          out.append(
            NSAttributedString(
              string: String(highlighted[run.range].characters), attributes: attributes))
        }
      }
      out.append(NSAttributedString(string: "\n", attributes: base))
    }
    return out
  }

  /// Append when the tail only grew: replacing the storage would drop the
  /// selection the reader is dragging, and jump a scrolled-up reader.
  static func apply(_ text: NSAttributedString, to view: NSTextView) {
    guard let storage = view.textStorage else { return }
    let old = storage.string
    let new = text.string
    guard new != old else { return }
    if !old.isEmpty, new.hasPrefix(old) {
      let tail = NSRange(location: old.utf16.count, length: text.length - old.utf16.count)
      storage.append(text.attributedSubstring(from: tail))
      return
    }
    let selected = view.selectedRanges
    storage.setAttributedString(text)
    let whole = NSRange(location: 0, length: storage.length)
    view.selectedRanges = selected.map { NSValue(range: NSIntersectionRange($0.rangeValue, whole)) }
  }

  static func isAtEnd(_ scroll: NSScrollView) -> Bool {
    let clip = scroll.contentView.bounds
    let height = scroll.documentView?.frame.height ?? 0
    return clip.maxY >= height - 2
  }

  static func scrollToEnd(_ scroll: NSScrollView) {
    guard let view = scroll.documentView as? NSTextView else { return }
    // `scrollRangeToVisible` lays the text out far enough to know where the end
    // is. Reading `frame.height` instead raced the layout pass and landed the
    // pane at the top of a fresh tail.
    view.scrollRangeToVisible(NSRange(location: (view.string as NSString).length, length: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
  }
}
