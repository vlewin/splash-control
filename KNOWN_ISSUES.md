# Known Issues

Platform and upstream bugs this app works around rather than fixes. Each
entry says what breaks, how it was confirmed, what we do instead, and what
would let us drop the workaround.

## SwiftUI segmented `Picker` leaks an `ObservationRegistrar` per evaluation (macOS 26)

**Upstream:** Apple (SwiftUI / AppKit). Not fixed here; avoided.

**Symptom.** Splash Control's CPU usage climbs with uptime until the main
thread is pinned at ~100%, alongside a steadily growing memory footprint.
In the reported case, after four days of uptime: 99.5% CPU, ~680 MB
footprint, and ~457,000 live `ObservationRegistrar` states.

**Cause.** Every evaluation of a SwiftUI `Picker` with
`.pickerStyle(.segmented)` allocates a new `ObservationRegistrar` from inside
the AppKit-backed control's body (`ViewBodyAccessor.updateBody` → AppKit →
DesignLibrary → `ObservationRegistrar.init()`), and SwiftUI's observation
tracking never releases it. One leak per evaluation is harmless; ours sat in
bodies that re-run on every `/status` poll (`DashboardView` observes
`StatsModel`), so it leaked ~2 per second. SwiftUI's `ObservationCenter`
walks every one of them on each layout and render pass, so the per-frame cost
grows with uptime. The leak continues even while the dashboard window is
closed, because the window (and its toolbar) is kept alive.

**How it was confirmed.**
- `sample <pid>`: the main thread spends its time in
  `ObservationCenter.invalidate` / `ObservationRegistrar.Context.cancel`,
  with almost no time in app code.
- `heap <pid>`: hundreds of thousands of
  `_ManagedCriticalState<ObservationRegistrar.State>` buffers; the count
  rises steadily with polling.
- `MallocStackLogging=1` + `malloc_history`: every leaked registrar is
  allocated from a segmented control's body.
- A/B under identical conditions: the build with SwiftUI segmented pickers
  grew by +40 to +120 registrars per 20 s depending on the tab; the
  workaround build grew by 0 on every tab and with the window closed.

To check a running copy:

```bash
heap "$(pgrep -x SplashControl)" | grep 'ObservationRegistrar.*LockedBuffer'
```

The first column is the live count. Sample it twice, a minute apart: a
healthy app does not grow.

**Workaround.** Every segmented control is `FixedSegmented`
(`Sources/SplashControl/FixedSegmented.swift`), a thin
`NSViewRepresentable` around `NSSegmentedControl` that never goes through
SwiftUI's `Picker`. A `check_core.sh` lint fails the build if
`pickerStyle(.segmented)` appears anywhere under `Sources/SplashControl`.

An `Equatable` wrapper that skips re-evaluation was tried first and rejected:
comparing the selection through two `Binding`s reads the same live value, so
the control stopped following selection changes made in code (for example,
opening Settings from the menu bar).

Other AppKit-backed controls (`.menu` pickers, toggles, text fields) showed
no registrar growth in the same measurements.

**Removing the workaround.** Once a macOS release fixes this, a SwiftUI
segmented `Picker` placed in a per-poll body should keep the registrar count
flat (use the `heap` check above). Only then drop the lint and go back to
`Picker`.
