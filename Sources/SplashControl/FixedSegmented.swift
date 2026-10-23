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

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: titles,
      trackingMode: .selectOne,
      target: context.coordinator,
      action: #selector(Coordinator.changed(_:))
    )
    if let width {
      for i in titles.indices {
        control.setWidth(width / CGFloat(titles.count), forSegment: i)
      }
    }
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    // Refreshed every update: a `Binding(get:set:)` captured once in
    // `makeCoordinator` would keep writing through the first body's closures.
    context.coordinator.selection = $selection
    control.isEnabled = context.environment.isEnabled
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
