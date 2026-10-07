---
name: "Splash Control Design System"
version: "1.2.1"
description: "Design tokens and visual identity spec for Splash Control. The tables below are the source of truth for values; §1 states the principles that aren't expressible as a token. If code disagrees with this file, the code is wrong — fix it or fix this."
colors:
  primary: "#0A84FF"              # macOS System Blue (interactive accent, chart primary)
  primary-hover: "#0071E3"
  secondary: "#5E5CE6"            # macOS System Purple (starting/restarting, prefill accent)
  success: "#30D158"              # macOS System Green (decoding, healthy, benchmark winner)
  warning: "#FF9F0A"              # macOS System Orange (queued, budget capped, memory pressure)
  danger: "#FF453A"               # macOS System Red (error, stopped, failed)
  surface: "systemBackground"     # base window background
  surface-card: "secondarySystemBackground"   # container card — .background.secondary
  surface-tile: "Color.primary.opacity(0.04)"  # inner stat tile / table row
  border-subtle: "Color.primary.opacity(0.06)" # card and tile strokes
  text-primary: "primary"         # primary text / headline ink
  text-secondary: "secondary"     # secondary labels and subtitles
  text-tertiary: "tertiary"       # captions, footnotes, units
typography:
  heroValue:
    fontFamily: "system(design: .rounded)"
    fontSize: 40pt
    fontWeight: "bold"
    monospacedDigit: true
  title:      { fontSize: 15pt, fontWeight: "semibold" }
  cardTitle:  { fontSize: 13pt, fontWeight: "semibold" }
  sectionHeader:
    fontSize: 10pt
    fontWeight: "bold"
    textTransform: "uppercase"
    letterSpacing: "0.05em"
  tableHeader:
    fontSize: 10pt
    fontWeight: "bold"
    textTransform: "uppercase"
    letterSpacing: "0.04em"
  tableCellMono:
    fontFamily: "system(design: .monospaced)"
    fontSize: 12pt
    fontWeight: "medium"
    monospacedDigit: true
  caption:     { fontSize: 11pt, fontWeight: "regular" }
  captionMono: { fontFamily: "system(design: .monospaced)", fontSize: 10pt }
rounded:
  xs: 3px     # benchmark bar caps
  sm: 4px     # badges, tags, status pills
  md: 8px     # inner stat tiles, text fields, code blocks
  lg: 12px    # container cards
  pill: 9999px  # filter capsules, circular badges
layout:
  windowMinWidth: 760pt
  windowMinHeight: 380pt   # AppDelegate: the shortest tab must still fit
  outerMargin: 16pt
  cardPadding: 16pt
  innerTilePadding: 10pt
  gapLg: 16pt   # between container cards
  gapMd: 12pt   # between related control groups
  gapSm: 8pt    # between rows
  gapXs: 4pt
---

# Splash Control — design system

Visual identity spec for **Splash Control**, a macOS menu-bar controller and
dashboard. Platform floor is the runtime's own: **macOS 26.4+ on Apple M3+**.

**The YAML tables above are the lookup.** Sections 1–2 state only what a token
cannot: the rules and the reasoning. Do not restate a token's value in prose —
that is how this file drifted out of sync with the code three times.

## 1. Principles

1. **Clarity over decoration.** Dense tabular telemetry, zero ambiguity. No
   ornamental colour, shadow, or gradient.
2. **Hierarchy, four levels deep:** window navigation → view sub-navigation →
   container cards → inner tiles and table rows. Each level is visually distinct;
   a level may not borrow another's treatment.
3. **Steady hue carries state; motion carries work.** Colour is the primary
   channel and must stay distinguishable **without** the blink. If two states
   differ only by blinking, one of them is wrong. The tray dot's own rules live
   in ARCHITECTURE.md § 3 and are not restated here.
4. **Depth by surface layering, never shadow.** Window background → card
   (radius `lg`, hairline border) → tile/row (radius `md`, no border).
5. **Numbers align.** Any figure in a table or that changes over time uses
   monospaced digits and a pinned width, so nothing jitters between updates.

## 2. Rules

### 2.1 Nested sub-navigation

When one tab holds genuinely distinct domains (Settings sections; server
telemetry vs. synthetic benchmarking in Statistics), **do not** stack them in
one endless scroll. Use a segmented `Picker`:

- centered at the top of the view body, directly under the toolbar
- constrained: `maxWidth` 320 for 2 tabs, up to 480 for 4. Never full-ultrawide.
- 4 pt top padding, 8 pt bottom
- Title Case labels; mutually exclusive bodies via `switch subTab`
- view-specific actions (`Reset`, `Run benchmark`) stay in their sub-tab's header
- the user's selected sub-tab persists

### 2.2 Container cards

Radius `lg`, `.background.secondary`, hairline `border-subtle` stroke. Title is
an uppercase bold section header. Every view file carries its own copy of the
~12-line `cardChrome`/`card`/`twoUp` block rather than sharing one helper —
extracting it would be a cross-cutting refactor of eight call sites for no
behaviour change.

### 2.3 Data tables

Uppercase concise headers. Numbers right-aligned, metric labels left-aligned.
Comparative metrics (`AVG`) get primary ink or bolder weight; secondary extremes
(`MIN`, `MAX`) get standard weight. **Never a bare unlabelled number, and never
a column width that drifts between rows.**

### 2.4 Condition chips

Pill tags for model and hardware config (`ctx 128K`, `mem 52G`, `disk 10G`):
`border-subtle` fill, radius `sm`, 6 pt × 2 pt padding. Always `.lineLimit(1)`.

### 2.5 Header actions & title menus

The view hero element (e.g. active model name in Live) serves as both the title
and the switcher:
- **Native borderless title menu**: Use `Menu` with `.menuStyle(.borderlessButton)`
  and `.menuIndicator(.visible)` so the title retains `title3.weight(.semibold)`
  hierarchy while gaining a native system dropdown chevron.
- **Ghost action buttons**: Accompanying secondary actions (e.g. copy full model ID)
  sit immediately adjacent (`gapSm`), styled with `.buttonStyle(.plain)` and a
  18×18 pt bounding frame.
- **Ephemeral feedback**: On clipboard copy, swap the icon to a green `checkmark`
  for 1.5 s before reverting to `doc.on.doc`.

### 2.6 Form row rhythm & validation states

Settings views follow standard macOS preference layout:
- **Two-column row rhythm**: Left column holds bold title + caption description.
  Right column holds right-aligned controls (stepper, text field, toggle).
- **Validation feedback**: Valid states use calm secondary/tertiary text (e.g.
  `"64K window"`, `"Auto (58G)"`). Reserved amber warning badges (`⚠️`) are used
  strictly for invalid values or port collisions. Never use loud green checkmarks
  for standard valid inputs.
- **Inline placeholders**: Unset values display their computed default via inline
  placeholders (`Auto (58G)`, `10m (Default)`, `0 (Off)`, `9000`).
- **No vertical scrolling in sub-tabs**: Each sub-tab must fit fully within the
  standard window height (~380–540 pt) without vertical scrollbars.

### 2.7 Telemetry charts (Grouped bars vs lines)

- **Discrete batch rates** (decode throughput, tok/s) use bucketed grouped bar
  charts, never continuous lines. Lines deceptively interpolate between isolated
  bursts and idle pauses, rendering artificial hanging slopes.
- **Zero-overlap geometry**: Never rely on continuous date `position(by:)` with
  fixed widths. Multi-series temporal bars must use deterministic sub-bucket time
  offsets (`barDate`), with intra-group spacing narrower than inter-group spacing
  (~1:3 ratio) and proportional bar widths (`slotWidth * 0.38`).

### 2.8 Optical vertical alignment

Icons paired with single-line text or buttons (e.g. credits cards, header chips)
must be optically centered on the text midline:
- Use `HStack(spacing:)` with default vertical `.center` alignment.
- Never set `alignment: .top` on rows where action buttons or icon frames exceed
  text line height (which forces icons to hang below the text baseline).

### 2.9 Dynamic window auto-fitting

The dashboard window sizes directly to the rendered content of the active tab:
- **Preference-driven measurement**: Views report their laid-out height inside
  their `ScrollView` using `.reportContentHeight(source)` via `ContentHeightKey`.
- **Window floor**: The container enforces a minimum height (`windowMinHeight: 380pt`)
  matching the shortest tab, preventing jarring layout collapses during switches.
- **Console exception**: `LogsView` is the sole view that never reports content
  height; it maintains a fixed viewport height so the window does not jitter or
  grow uncontrollably as new console lines stream in.

### 2.10 Stat tile action slots

When a telemetry tile offers a secondary manual maintenance action (e.g. SSD tier
cache reset):
- Place the button in the top-right corner of the tile, mirroring any alert icon.
- Style as a subtle 16×16 pt ghost icon button (`.buttonStyle(.plain)`).
- Destructive operations (cache wipes, resets) must always present an AppKit
  confirmation dialog before proceeding.

### 2.11 Layout safety rules

1. **True centring via equal wings.** Never flank a centre control with
   `Spacer() … Spacer()` when the two side buttons differ in width — that
   offsets the centre by half the width difference. Use three columns:

   ```swift
   HStack(spacing: 0) {
       leftButton.frame(maxWidth: .infinity, alignment: .leading)
       centreControl.fixedSize()                    // rigid, never flexible
       rightButton.frame(maxWidth: .infinity, alignment: .trailing)
   }
   ```

   The rigid centre is equally load-bearing: as a flexible member it was
   offered 2.67 pt after a rigid sibling took the space, and SwiftUI wrapped
   the label one character per line.

2. **Single-line constraints are mandatory.** Any label, value or badge inside
   a fixed-width frame, table cell or capsule gets `.lineLimit(1)` and/or
   `.fixedSize()`.

3. **Permanent containers for anything that anchors a row.** Never put `if let`
   around a badge or control that establishes a baseline — the row jumps when
   the state goes nil. Keep the container, pin its width, render fallback text
   (`"No benchmark recorded for 64K context"`).

4. **Never bind a `Picker` to a nullable or out-of-range selection.** macOS
   draws an empty grey box. Use a `Menu` of buttons, or an explicit sentinel
   tag.

## 3. Do / Don't

**Do** — separate disparate workflows with nested tabs; use uppercase bold
section headers at secondary contrast; pin sub-tab state; keep the four
hierarchy levels visually distinct; mid-align paired icons; use grouped bars for
discontinuous throughput; auto-fit window to measured content height.

**Don't** — stack unrelated full-page forms into one scroll view; stretch a
segmented picker across the window; use bare numbers; add coloured borders or
heavy shadows; show loud green checkmarks for normal inputs; hardcode arbitrary
window heights when content can be measured; let a view grow past ~600 lines of
new UI (split it).

## 4. Verification

Capture with `./Scripts/screenshot.sh <png> <tab>` and look at the image.

The script is window-targeted (`screencapture -l <windowid>`), so it frames the
window only and survives the window moving, a second display, and non-native
scaling. Passing a tab switches tabs semantically (by targeting the toolbar
radio buttons) and settles the resize animation before capturing; omitting the
tab captures the current window as-is and fails if the dashboard was never
opened.

Inspect the PNG with your image-viewing tool. Do not measure pixels or probe
the accessibility tree:

- Never blind-coordinate clicks (`osascript … click at {x, y}`). They land in
  whatever window happens to be at those coordinates — this has typed into an
  unrelated application's input field before.
- Never ad-hoc `osascript` System Events probes for `size of window`,
  `scroll area`, `scroll bar`, or an AX hierarchy. They fail with AppleScript
  type errors (`-1700`) and unreadable indices (`-1719`) under AppKit/SwiftUI
  hosting, and burn execution cycles.
- If the construction is mathematically sound and the capture looks clean,
  accept it. Captures are smoke tests for human inspection, not measurements.