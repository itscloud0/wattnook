---
name: WattNook
description: Native macOS battery and system wayfinding monitor
colors:
  graphite-upper: "color(srgb 0.13 0.165 0.21)"
  graphite-lower: "color(srgb 0.085 0.12 0.165)"
typography:
  charge:
    fontFamily: "SF Pro, system-ui"
    fontSize: "48pt"
    fontWeight: 600
  system-metric:
    fontFamily: "SF Pro tabular digits, system-ui"
    fontSize: "22pt"
    fontWeight: 600
  action:
    fontFamily: "SF Pro, system-ui"
    fontSize: "11pt"
    fontWeight: 500
  destination:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12pt"
    fontWeight: 500
rounded:
  action: "10pt"
  destination: "14pt"
  flow-node: "8pt"
  rail: "3pt"
spacing:
  rhythm: "4pt"
  content-margin: "24pt"
components:
  page-destination:
    typography: "{typography.destination}"
    rounded: "{rounded.destination}"
    height: "28pt"
    width: "112pt"
  battery-action:
    typography: "{typography.action}"
    rounded: "{rounded.action}"
    height: "44pt"
  energy-flow:
    height: "220pt"
  consumer-row:
    height: "34pt"
  storage-review:
    width: "400pt"
    height: "450pt"
  storage-row:
    height: "44pt"
  keep-awake-diagnostics:
    width: "520pt"
    height: "520pt"
---

# Design System: WattNook

## Overview

**Creative North Star: "Transit wayfinding for Mac power."**

WattNook is an operable energy overview, not a stack of equally weighted controls: read charge and state first, follow the source-to-destination energy trace, then choose a deliberate action or deeper destination. The compact native surface stays quiet, spacious, and precise. It uses real AppKit Liquid Glass where available; it is not an HTML glass treatment.

The Battery, System, Settings, History, Storage review, and Keep Awake diagnostics all use native controls and platform typography. The full visual system replaces the former 360×480 visual guidance; behavior remains unchanged, including saved palettes/menu units, unavailable heat protection, and Keep Awake's `noScreenOff` policy.

**Key Characteristics:**

- One headline state, three explicit destinations, and a directional energy trace.
- SF Pro with tabular readings; semantic labels over decorative color.
- A 24 pt inset and 4 pt rhythm make a small native utility legible.

## Colors

The base is a two-stop calibrated graphite fallback; interface meaning comes from AppKit semantic colors and the selected user palette, not hard-coded web swatches.

### Primary

- **Selected energy:** `NSColor.systemBlueColor` by default; Glass uses `NSColor.controlAccentColor`, while Mint, Violet, and Amber use the saved calibrated palette. Use it for the flow, storage fill, and selected non-Glass controls.

### Secondary

- **Charging / warning:** `NSColor.systemGreenColor` marks charging; `NSColor.systemOrangeColor` marks low charge or a real heat pause. These are status-only, never the sole carrier of state.

### Neutral

- **Graphite fallback:** frontmatter `graphite-upper` and `graphite-lower` form the non-Glass popover gradient.
- **Semantic ink:** `NSColor.labelColor`, `secondaryLabelColor`, `disabledControlTextColor`, and `keyboardFocusIndicatorColor` adapt text, disabled state, and focus to macOS appearance.
- **Native material:** the Glass palette leaves the popover backdrop visible and places `NSGlassEffectView` shapes only behind destinations and primary actions, when the macOS 26 APIs are available.

**The Semantic-First Rule.** Do not replace AppKit semantic colors with fixed HTML approximations; appearance, accessibility, and the selected palette must remain live.

## Typography

**Display Font:** SF Pro (system fallback).
**Body Font:** SF Pro (system fallback).
**Label/Mono Font:** SF Pro tabular figures for measurements; SF Mono only for diagnostic report text.

**Character:** The hierarchy is native and information-led: a large charge reading establishes state, then compact labels make destinations and measurements scannable. Readings use monospaced digits where column alignment matters.

### Hierarchy

- **Charge** (600, 48 pt): Battery percentage in the power-flow header.
- **System metric** (600, 22 pt): System-page headline values; Battery summary values are 16 pt tabular.
- **Section title** (600, 13–16 pt): App name, `Top consumers`, and Settings groups.
- **Body** (400, 11–13 pt): Status, context, labels, and destination names.
- **Action / detail** (500/400, 11–11.5 pt): Primary action labels and consumer measurements; consumer secondary detail is 10.5 pt.

**The Measurement Rule.** Preserve tabular digits and whole-machine CPU normalization; do not turn compact units, unavailable values, or updating states into invented zeroes.

## Layout

The popover is 400×532 pt with 24 pt content margins and a repeated 4 pt rhythm. Its header is followed by three 112×28 pt Battery/System/Storage destinations with 8 pt gaps. Battery gives the 400×220 pt power-flow view the largest lane, with its charge-limit label, 44 pt actions, then System/SSD destinations and three summary columns. The percentage has no duplicate battery glyph. The compact header preserves the charge rail, pointer targets and flow geometry below it.

System owns three aligned headline columns, one context row (processes, Swap, free storage), a `Top consumers` destination, 112 pt sort targets, and exactly six 34 pt consumer rows. Settings uses the same inset for Appearance, Menu bar, Monitoring, and utility destinations; History stays on its own page. Storage occupies a 400×450 pt page within the same popover: explicit Scan, Applications/App caches segments, case- and diacritic-insensitive name search, and a native 44 pt results table. Keep Awake diagnostics remains a separate 520×520 pt panel.

**The Destination Rule.** Page navigation is a filled selection; underline-like treatment is not reused for it. Battery, System, History, Settings, Storage review, and diagnostics stay distinct destinations rather than being compressed into one scroll.

## Elevation & Depth

Depth is platform material and tonal layering, not custom shadow. The fallback dashboard paints the graphite gradient; Glass mode uses the popover's own Liquid Glass with grouped native glass shapes behind the navigation and the visible primary Battery actions. Native separators at 45% opacity split dense regions. Storage inherits the dashboard surface with a transparent native table and standard segmented category control; diagnostics uses `windowBackgroundColor` and system controls.

**The Glass-Is-Platform Rule.** Do not claim a browser backdrop filter or a CSS shadow reproduces this material. Keep runtime Glass availability checks and the graphite fallback.

## Shapes

Controls are gently rounded: ordinary actions use 10 pt corners, while grouped destinations and Glass-backed controls use capsules. The charge rail and SSD bar use 3 pt rounding. Flow endpoints are 34×34 pt soft-square nodes with 8 pt corners.

The signature trace is one closed silhouette, not a literal map or proportional Sankey: single-source flow uses smooth 18%-span flares and ports no taller than 18 pt; split/merge has one 3 pt rounded inner junction and no seam outline. The visible Battery page alone may show the existing 2.2 s travelling highlight; it stops when hidden or Reduce Motion is on. Width remains a clamped decorative hint.

## Components

### Menu-bar battery

On macOS 27 use the installed BatteryUIKit `BUIImage` modern renderer at its natural 26×14 pt size; never redraw, stretch, or bundle a silhouette. Preserve Apple's charge fill, bolt, AC plug, low-battery/Low Power colors, service and no-battery artwork. A failed reading is unknown, not an empty or physically absent battery. Neutral content remains an AppKit status-item template; a passive, vibrancy-enabled image view retains native color states without intercepting clicks or duplicating accessibility. Keep the existing 8 pt gap to metrics/percentage. Check the private ABI and returned image dimensions; retain older Control Center resources as fallback, and show an unavailable symbol if artwork cannot be rendered. This UI path creates no observer, timer or power-setting writes.

### Native destinations and actions

Battery/System/Storage are grouped 112×28 pt destinations with icons and a filled selected segment. Supported Heat protection and Keep Awake are 44 pt two-line actions: title plus a 10.5 pt semantic subtitle. When heat control is unavailable, hide its Battery action and expand Keep Awake to 320 pt, keeping its independent info button. Settings carries a compact, tooltip-backed unavailable explanation instead. Rebuild actual Glass backing shapes when availability changes; never leave a phantom tile behind the hidden action. Hover, pressed, disabled, and keyboard-focus treatments are native AppKit states.

### Power flow and charge limit

The 48 pt charge, status line, temperature, rail, and limit marker form one state region. The charge-limit label passes pointer events through to the native slider; keyboard and accessibility slider paths remain available. Unavailable telemetry says so; inconsistent readings show an updating state rather than a false measured load.

### System consumers and metrics

Metric activation cycles that metric's saved unit. Consumer rows keep an app icon, name, two right-aligned tabular readings, and a quiet normal Quit action only where allowed. CPU is whole-machine capacity, memory is resident bytes/percentage, and disk is throughput; six rows remain unboxed.

### Storage review and diagnostics

Storage uses the third destination inside the main popover, never a separate panel. Scan/Cancel/Rescan is explicit; native segments filter Applications and App caches, and case- and diacritic-insensitive search matches application names. Real macOS application icons accompany 44 pt rows. Complete logical sizes are shown as measured; partial sizes carry a `+`, and unknown sizes say `Not measured`. Select Review for an inline detail page with Back, a selectable full path, and Show in Finder. Only `/Applications` and `~/Applications` (one vendor-folder level, at most 200 results) are inventoried. App caches include only exact `~/Library/Caches/<bundle-id>` directories uniquely mapped to a third-party app after complete inventory discovery. Identity classification uses metadata and basic code-signing checks, not full resource validation. The UI states `Read-only · Removal unavailable`; no Trash action is offered. Leaving the page or closing the popover cancels and clears results; stale generations cannot repopulate them. Keep Awake diagnostics uses a stacked native panel, semantic status/error text, and a selectable monospaced report. These are native component descriptions, not HTML render specifications.

## Do's and Don'ts

### Do:

- **Do** keep 24 pt margins and the 4 pt rhythm in the popover.
- **Do** place every watt label outside the energy ribbon and name the source/destination.
- **Do** use the selected palette only for selection and energy; reserve green/orange for actual status.
- **Do** preserve visible-only, Reduce-Motion-aware flow animation and native focus/accessibility paths.
- **Do** retain `Limit unavailable`, unavailable heat, and telemetry-updating states as explicit truthful content.

### Don't:

- **Don't** reintroduce the former 360×480 layout, duplicate consumer rows on Battery, or squeeze History into System.
- **Don't** substitute fixed HTML colors, CSS Glass, glyph icons, or a display typeface for native AppKit semantics and SF Symbols.
- **Don't** make ribbon width a claimed quantitative power scale or draw separate ribbons with a seam.
- **Don't** hide saved palette/menu-unit behavior, convert unavailable data to zero, or add Screen off to Keep Awake.
