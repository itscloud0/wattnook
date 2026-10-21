---
name: WattNook
description: Native macOS battery and system monitor in Apple's dark grouped style
colors:
  ground: "#1C1C1E"
  group: "#2C2C2E"
  group-highlight: "#3A3A3E"
  energy: "system accent of the saved palette (systemBlue, systemMint, systemPurple, systemOrange; Glass uses controlAccentColor)"
  charging: "systemGreen"
  warning: "systemOrange"
typography:
  charge:
    fontFamily: "SF Pro, system-ui"
    fontSize: "66pt"
    fontWeight: 300
  system-metric:
    fontFamily: "SF Pro tabular digits, system-ui"
    fontSize: "22pt"
    fontWeight: 600
  reading:
    fontFamily: "SF Pro tabular digits, system-ui"
    fontSize: "14pt"
    fontWeight: 500
  label:
    fontFamily: "SF Pro, system-ui"
    fontSize: "11pt"
    fontWeight: 500
  destination:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12pt"
    fontWeight: 500
rounded:
  tile: "14pt"
  small-action: "10pt"
  destination: "capsule"
  rail: "3pt"
spacing:
  rhythm: "4pt"
  tile-margin: "12pt"
  content-margin: "24pt"
components:
  page-destination:
    typography: "{typography.destination}"
    rounded: "{rounded.destination}"
    height: "28pt"
    width: "112pt"
  tile:
    background: "{colors.tile}"
    rounded: "{rounded.tile}"
  action-tile:
    height: "56pt"
    width: "184pt"
  power-tile:
    height: "118pt"
  power-strip:
    height: "62pt"
    samples: 90
---

# Design System: WattNook

## Overview

**Creative North Star: "Apple's own dark grouped style, with the data in colour."**

A flat neutral ground (#1C1C1E) and groups one grey step lighter (#2C2C2E), the greys macOS uses for its own grouped settings. No gradient, no tint, no translucent cards over colour: the user rejected the state-sky gradient on 2026-10-21 ("feels AI"). Colour appears only where it carries meaning: green for charging, orange for heat and warnings, the palette accent for energy and selection.

**Key characteristics**

- One light 66 pt charge numeral with a small muted percent sign.
- Groups instead of rules; no borders, no resting shadows.
- Plain-language labels. No middle-dot separators ("Paused while the battery cools", "Battery idle", "Last 15 minutes").

## Colors

Ground `#1C1C1E`, groups `#2C2C2E` (hover `#3A3A3E`). In the Glass palette the ground drops to 55% and groups become 8% white so the popover's Liquid Glass shows through. Energy and selection use the saved palette's system colour; charging is system green; heat pause, hot CPU, low health and memory pressure are system orange. The state line under the charge is orange during a heat pause, green while charging, otherwise secondary.

## Typography

SF Pro throughout. The charge is 66 pt Light; System headline values 22 pt Semibold tabular; readings (temperatures, health) 14 pt Medium tabular with 11 pt muted names; labels 11 pt Medium; destinations 12 pt Medium. Figures in ink, units and words in secondary white (`WattFigureWithQuietUnits`).

## Layout

400 pt wide. Battery is 502 pt tall, System, Storage, Settings and History 532 pt. One 8 pt grid: tiles and full-width controls at a 16 pt margin (16–384), every text edge at 32 pt (32–368) whether on the ground or inside a tile, 8 pt between a heading and its tile and between stacked tiles, 20–24 pt between groups, 12 pt inside tiles.

**Battery, top to bottom:** header (WattNook, Settings); Battery / System / Storage destinations; the 66 pt charge with its state line and the Battery / CPU / Health readings on the right; the draggable limit rail with its action (Top Up, Discharge, or Update Helper); the Power tile holding the flow; the 15-minute Mac-power strip tile; Heat Protection and Keep Awake action tiles side by side (Keep Awake spans both when heat is unavailable).

**System:** memory pressure and History on the ground; one tile with CPU / Memory / Disk readings and their context row; "Top consumers" and its underlined CPU / Memory / Disk sort in one row; one tile with six consumer rows; Open Activity Monitor.

**Storage:** category segments, search and Scan on the ground; the results list on one tile.

**Settings:** headings on the ground, each group (Appearance, Menu bar, Monitoring) on its own tile, then Keep Awake details and Advanced controls side by side.

## Elevation & Depth

None beyond the ground and one group step. No hairlines, no shadows except the limit grip's small lift. Glass-palette backing shapes remain behind destinations and the action tiles.

## Components

### The power strip (`WattPowerStripView`)

The forecast's hourly row, for power: 90 bars, one per 10 s of Mac draw (15 minutes), oldest on the left. Bar colour says what the battery did: green charging, amber heat pause, white held or on battery. Empty slots are a faint baseline, never invented bars. Header: "Mac power · last 15 min" and "avg · peak". Samples come from the same AppleSmartBattery snapshot as the flow and are skipped while readings disagree.

### Power flow

AlDente-style Sankey across the full 368 pt width and 124 pt height, no group behind it: full-height rounded blocks (64 pt, 12 pt corners, the group grey) for the single side, two blocks split by share (6 pt apart, 36 pt minimum) for the other, bands as thick as their share of the watts with the watts inside (14 pt semibold). Charging: adapter block with its total, bands to Battery (green, 38%) and Mac (palette accent, 30%). Adapter can't keep up: Adapter (accent) and Battery (orange, 38%) bands into the Mac block with its total. One source: a single accent band with its watts and "Battery idle" when the battery is held. The travelling highlight runs inside the bands only.

Icons are one family: SF Symbols at 18 pt, white (bolt, a battery at the real charge level, laptop). No raster artwork, no chips beyond the blocks themselves.

### Charge action

One button beside the rail shows exactly the action it performs: Top Up, Discharge (charge above the limit), the running action's Stop, or Update/Install Helper when the helper does not match the app (charging controls are hidden until then). A running action is a quiet tint with accent ink.

### Health reading

Full-charge capacity against design capacity (`BatteryData.NominalChargeCapacity / DesignCapacity`), amber below 80%; the tooltip adds the cycle count.

### Destinations, sort, tiles

Destinations are capsules with a filled selection. Sorting is underlined, never filled (it filters, it does not navigate). Tile-sized buttons share the tiles' 14 pt corners and fill; small text actions keep 10 pt and sit 6 pt from their icon.

## Do's and Don'ts

- **Do** put colour on data and state only.
- **Do** put grouped content on groups and leave headings on the ground.
- **Do** keep figures in ink and units quiet.
- **Don't** add hairlines, borders or resting shadows.
- **Don't** bring back gradients, tinted grounds or middle-dot separators.
- **Don't** invent strip bars or zero readings when data is missing.
