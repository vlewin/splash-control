import AppKit
import SwiftUI

/// Native segmented control with an explicit total width, or sized to its
/// labels when `width` is nil.
///
/// A SwiftUI segmented Picker cannot be sized or freely positioned inside a
/// grouped Form: the Form columnizes Picker rows and NSSegmentedControl sizes
/// to fit, so frames are defeated. This wraps NSSegmentedControl directly and
/// pins every segment to an equal share of `width`. It is opaque to the Form,
/// so it lays out as plain content (like the model menu Picker row).
///
/// It is also the only segmented control the app uses: every evaluation of a
/// SwiftUI segmented `Picker` allocates an `ObservationRegistrar` that is
/// never released (macOS 26). Inline in bodies that re-run on each stats poll
/// that leaked ~2 per second, 457k after four days, until every layout pass
/// walked them all and pinned the main thread at 100% CPU.
struct FixedSegmented<Value: Hashable>: NSViewRepresentable {
  let width: CGFloat?
  let titles: [String]
  let values: [Value]
  @Binding var selection: Value
  /// Explicit step override. The toolbar pill lives in native chrome that
  /// must stay system-sized; `.environment(\\.uiScale, 1)` set on a
  /// representable in a `ToolbarItem` does not reliably reach its own
  /// environment reads (the same root-view trap as `DashboardView`), so the
  /// toolbar passes `scale: 1` directly. `nil` = ride the environment.
  var scale: CGFloat? = nil
  @Environment(\.uiScale) private var uiScale

  private var step: CGFloat { scale ?? uiScale }

  /// Native label size of a rounded segmented control, measured at 100 %
  /// by pixel-height probe. The zoom step sets the control's font to this
  /// × step: AppKit re-renders the labels as vectors and grows the bezel to
  /// fit — the sharp way to scale the pill, no bitmap involved.
  static var baseFontSize: CGFloat { 11 }

  func makeNSView(context: Context) -> ScaledSegmentedControl {
    let control = ScaledSegmentedControl(
      labels: titles,
      trackingMode: .selectOne,
      target: context.coordinator,
      action: #selector(Coordinator.changed(_:))
    )
    applyFontAndWidth(control)
    return control
  }

  func updateNSView(_ control: ScaledSegmentedControl, context: Context) {
    // Refreshed every update: a `Binding(get:set:)` captured once in
    // `makeCoordinator` would keep writing through the first body's closures.
    context.coordinator.selection = $selection
    control.isEnabled = context.environment.isEnabled
    applyFontAndWidth(control)
    context.coordinator.sync(control: control, selection: selection)
  }

  private func applyFontAndWidth(_ control: ScaledSegmentedControl) {
    // A `.small` environment (the Logs level row and file bar) clamps the
    // bezel to 20 pt no matter the font, and truncates the step's glyphs
    // ("Warnings & Err..." - the ellipsis is vertical clipping, not a
    // narrow frame). From 125 % up the control locks its bezel to the
    // zoomedControlSize ladder (base `.small`): `.regular` carries the
    // step's glyphs from 125 %, `.large` takes over at 175 % so the pill
    // keeps pace with the grown buttons instead of standing out as a thin
    // 24 pt strip under 22 pt labels. At 100 % nothing is locked: the row
    // keeps exactly what the environment asks for, so the pre-zoom look is
    // untouched. The lock must live on the subclass - SwiftUI's bridge
    // re-asserts the environment's control size after every `updateNSView`,
    // undoing a plain assignment there.
    if step > 1 {
      // zoomedControlSize speaks SwiftUI's ControlSize; the NSControl lock
      // below is AppKit's same-named enum. Map rung by rung.
      let swui = step.zoomedControlSize(base: .small)
      let appkit: NSControl.ControlSize
      switch swui {
      case .mini: appkit = .mini
      case .small: appkit = .small
      case .regular: appkit = .regular
      case .large: appkit = .large
      default: appkit = .extraLarge
      }
      control.lockedControlSize = appkit
    } else {
      control.lockedControlSize = nil
    }
    control.font = .systemFont(ofSize: Self.baseFontSize * step)
    if let width {
      // `width` is the 100 % total; the step scales font and labels, so the
      // per-segment widths ride the same factor.
      for i in titles.indices {
        control.setWidth(width * step / CGFloat(titles.count), forSegment: i)
      }
      // Never pin below what the control actually draws: AppKit keeps the
      // natural label width when a requested segment width is too small for
      // the labels (the 530 pt toolbar pill has drawn 563 pt since before the
      // zoom existed). Pinning the nominal number would frame the pill
      // narrower than its own drawing - segments outside their container.
      control.pinnedWidth = max(width * step, control.naturalWidth)
      // Same stale-font story as the label-sized path below: zooming back
      // down re-measured `naturalWidth` against the still-committed larger
      // font, so the max() pinned the pill at the *zoomed-in* width and it
      // hung out of the shrunken window (observed on the Logs file bar and
      // the other width-pinned pills after a 100 -> 200 -> 100 round trip).
      control.lateRefit = { [weak control] in
        guard let control else { return }
        control.pinnedWidth = max(width * step, control.naturalWidth)
      }
    } else {
      // Label-sized: AppKit caches its intrinsic width from the first layout
      // pass, so the level filter kept the 100 % measurement at every step
      // and its glyphs truncated horizontally too. `sizeToFit()` is the call
      // that re-measures against the current font - but only with the pin
      // released: `fittingSize` consults `intrinsicContentSize`, and the
      // override would hand back the *previous* step's width, so re-
      // measuring against a live pin re-measures the pin (a zoom step then
      // never moves the control; only a fresh launch picked the new size up).
      // (No `sizeToFit` on the width-pinned path: it would discard the
      // explicit widths.)
      control.pinnedWidth = nil
      // Re-setting the labels is what makes AppKit drop its per-segment text
      // measurement *and* mark the cells dirty: `sizeToFit()` alone re-measures
      // against a cached width, and even a correct width left the hosting view
      // compositing the previous step's drawing until a segment click dirtied
      // it. Both halves of the bug go through this one call.
      for (i, title) in titles.enumerated() { control.setLabel(title, forSegment: i) }
      control.invalidateIntrinsicContentSize()
      control.sizeToFit()
      control.pinnedWidth = control.fittingSize.width
      // The inline fit measures the font AppKit has *committed* to the cell
      // so far. During a zoom burst (several `updateNSView`s in one runloop
      // turn) and for a control created off-window (tab switch back to Logs)
      // that is still the previous step's font - measured: the mid-burst
      // update and the fresh control both landed one step behind (pin=380/
      // 488 where 530 was due) until a segment click re-measured - on a turn
      // whose draw had already run with the new font. Drawing is exactly the
      // commit point: arm a one-shot re-fit, run it after the next draw,
      // `pinnedWidth` re-invalidates, SwiftUI re-frames - the click's effect
      // without the click. Converges because the armed pass re-fits to the
      // same width, and only actual draws re-arm.
      control.lateRefit = { [weak control] in
        guard let control else { return }
        control.pinnedWidth = nil
        control.sizeToFit()
        control.pinnedWidth = control.fittingSize.width
      }
    }
    // Arm only on a genuine step change (or first fit): `updateNSView`
    // also runs on every stats poll, and re-arming there would redraw and
    // re-measure once per second for a width that cannot have moved.
    if control.lastFitStep != step {
      control.lastFitStep = step
      control.needsLateRefit = true
      control.needsDisplay = true
    }
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

/// `NSSegmentedControl` keeps reporting its unscaled intrinsic width no
/// matter which font it was given, so at a zoom step SwiftUI's `.fixedSize()`
/// frames the control by the 100 % measurement while the scaled fonts widen
/// the drawn pill: the pill draws wider than its frame and the outer
/// segments land outside it — visible, but their clicks hit whatever is
/// behind the view (the Settings nav lost exactly "Server Limits" and
/// "Advanced" this way). Pinning the intrinsic width to the scaled total
/// keeps frame, drawing and hit area on the same rect.
final class ScaledSegmentedControl: NSSegmentedControl {
  /// The step the last width fit ran at. Re-arming the post-draw re-fit is
  /// only useful when this changes; polling `updateNSView` calls with the
  /// same step cannot move the measurement.
  var lastFitStep: CGFloat?

  /// Re-runs this control's width fit (see `FixedSegmented.applyFontAndWidth`
  /// - both the width-pinned and the label-sized path install one). AppKit
  /// commits a new font to the cell when it next draws the control: an
  /// inline fit during a zoom burst or before the control is in a window
  /// still measures the *previous* step's font - too small when zooming up,
  /// too large when zooming back down. So the path arms `needsLateRefit`;
  /// the re-fit runs after the next draw (or after attach, when that comes
  /// first) - a segment click's effect, without the click.
  var lateRefit: (() -> Void)?

  /// Set when the inline fit may have measured a stale font; cleared when
  /// the post-draw re-fit runs.
  var needsLateRefit = false

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard needsLateRefit, window != nil else { return }
    needsLateRefit = false
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil else { return }
      self.lateRefit?()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // A control created off-window (tab switch away and back) is measured
    // before AppKit has ever drawn it - its inline fit is stale by whole
    // steps and no `updateNSView` follows the attach. Attaching is the
    // first draw's doorstep; re-fit right after it.
    guard window != nil, needsLateRefit else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil, self.needsLateRefit else { return }
      self.needsLateRefit = false
      self.lateRefit?()
    }
  }

  /// What AppKit would size this control to on its own, at the current font
  /// and segment widths - the width the bezel is actually drawn at.
  var naturalWidth: CGFloat { super.intrinsicContentSize.width }

  var pinnedWidth: CGFloat? {
    didSet {
      if pinnedWidth != oldValue { invalidateIntrinsicContentSize() }
    }
  }

  /// Non-nil wins over every other writer. SwiftUI's `NSViewRepresentable`
  /// bridge applies the environment's `controlSize` *after* `updateNSView`
  /// returns, so an assignment in the coordinator is undone before the next
  /// draw; overriding the setter is the only place the lock survives.
  var lockedControlSize: NSControl.ControlSize? {
    didSet {
      if let lockedControlSize, super.controlSize != lockedControlSize {
        super.controlSize = lockedControlSize
      }
    }
  }

  override var controlSize: NSControl.ControlSize {
    get { super.controlSize }
    set {
      guard lockedControlSize == nil else { return }
      super.controlSize = newValue
    }
  }

  override var intrinsicContentSize: NSSize {
    guard let pinnedWidth else { return super.intrinsicContentSize }
    var size = super.intrinsicContentSize
    size.width = pinnedWidth
    return size
  }
}
