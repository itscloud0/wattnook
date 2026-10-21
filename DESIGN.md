---
name: WattNook
description: Native macOS battery and system monitor whose ground is a sky coloured by the Mac's power state
colors:
  sky-day: ["#0B2240", "#184A7E", "#2563A0"]
  sky-dusk: ["#101830", "#1F2D58", "#2F4580"]
  sky-sunset: ["#24133A", "#7E2C5C", "#B04A2E"]
  sky-night: ["#0A0B1C", "#171A3C", "#262B5E"]
  sky-twilight: ["#110E28", "#2B2052", "#4F3683"]
  sky-overcast: ["#161E2A", "#1B2532", "#212B3A"]
  tile: "rgba(255,255,255,0.10)"
  tile-highlight: "rgba(255,255,255,0.16)"
  energy-blue: "#8CCCFF"
  energy-mint: "#6BEBC7"
  energy-violet: "#C7ABFF"
  energy-amber: "#FFC76B"
  warning: "#FFB861"
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

**Creative North Star: "A weather report for power."**

The whole popover is a sky. Its gradient is the Mac's power state and is read before any word: day blue while charging, dusk blue while held on the adapter, a sunset when Heat Protection pauses charging, night on battery, twilight during Discharge, overcast when telemetry is unknown. Content sits on that sky as white type and translucent tiles, the way a forecast app sets its readings on the weather. Chosen on 2026-10-21 (Impeccable direction roll, seed:3eb6d2297435b8e7) after the user rejected the graphite wayfinding look as too weak and pointed at CleanMyMac's menu and AlDente.

**Key characteristics**

- One state owns the surface: the sky changes, the layout does not.
- One light numeral far larger than anything else (66 pt charge).
- Tiles instead of rules: 10% white, 14 pt corners, no borders, no shadows.
- Colour does jobs: sky = state, light accent = energy and selection, amber = warning, green = charging bars.

## Colors

### The sky (`WattSkyGradient`)

Three stops, bottom → middle (55%) → top. The brightest hue stays in the top band; text areas keep white at 4.5:1 or better. The sky cross-fades over 0.8 s on a state change (instant with Reduce Motion). In the Glass palette the sky drops to 62% opacity so the popover's Liquid Glass shows through.

| Sky | State | Rule |
|---|---|---|
| day | battery charging on adapter | `IsCharging`, or > 0.25 W into the battery |
| dusk | on adapter, not charging (limit reached, held) | plugged in, otherwise |
| sunset | Heat Protection pause | heat paused while plugged in |
| night | on battery | not plugged in |
| twilight | Discharge to the limit | discharging while plugged in |
| overcast | telemetry unknown | no power data or no charge reading |

### Accents (`WattAccentColor`, `WattWarningColor`)

The saved palette (Blue, Mint, Violet, Amber, Glass) now picks a light energy tone that reads on every sky: the flow ribbon, the charge rail, selection. Warnings (hot CPU, low health, heat bars in the strip, memory pressure) use light amber, never system orange, which disappears into the sunset. Green stays for charging.

**The Sky-Is-State Rule.** Never tint the sky for decoration or by page. Every page shows the current power state's sky.

## Typography

SF Pro throughout. The charge is 66 pt Light; System headline values 22 pt Semibold tabular; readings (temperatures, health) 14 pt Medium tabular with 11 pt muted names; labels 11 pt Medium; destinations 12 pt Medium. Figures in ink, units and words in secondary white (`WattFigureWithQuietUnits`).

## Layout

400 pt wide. Battery is 502 pt tall, System, Storage, Settings and History 532 pt. One 8 pt grid: tiles and full-width controls at a 16 pt margin (16–384), every text edge at 32 pt (32–368) whether on the sky or inside a tile, 8 pt between a heading and its tile and between stacked tiles, 20–24 pt between groups, 12 pt inside tiles.

**Battery, top to bottom:** header (WattNook, Settings); Battery / System / Storage destinations; the 66 pt charge with its state line and the Battery / CPU / Health readings on the right; the draggable limit rail with its action (Top Up, Discharge, or Update Helper); the Power tile holding the flow; the 15-minute Mac-power strip tile; Heat Protection and Keep Awake action tiles side by side (Keep Awake spans both when heat is unavailable).

**System:** memory pressure and History on the sky; one tile with CPU / Memory / Disk readings and their context row; "Top consumers" and its underlined CPU / Memory / Disk sort in one row; one tile with six consumer rows; Open Activity Monitor.

**Storage:** category segments, search and Scan on the sky; the results list on one tile.

**Settings:** headings on the sky, each group (Appearance, Menu bar, Monitoring) on its own tile, then Keep Awake details and Advanced controls as full-width actions.

## Elevation & Depth

None beyond the sky and one tile step. No hairlines, no shadows except the limit grip's small lift. Glass-palette backing shapes remain behind destinations and the action tiles.

## Components

### The power strip (`WattPowerStripView`)

The forecast's hourly row, for power: 90 bars, one per 10 s of Mac draw (15 minutes), oldest on the left. Bar colour says what the battery did: green charging, amber heat pause, white held or on battery. Empty slots are a faint baseline, never invented bars. Header: "Mac power · last 15 min" and "avg · peak". Samples come from the same AppleSmartBattery snapshot as the flow and are skipped while readings disagree.

### Flow endpoints

The endpoints are the things themselves: this Mac's own artwork (`NSImageNameComputer`), a battery symbol at the real charge level (0/25/50/75/100), a white plug. No grey chips behind them.

### Charge action

One button beside the rail shows exactly the action it performs: Top Up, Discharge (charge above the limit), the running action's Stop, or Update/Install Helper when the helper does not match the app (charging controls are hidden until then). A running action is a quiet tint with accent ink.

### Health reading

Full-charge capacity against design capacity (`BatteryData.NominalChargeCapacity / DesignCapacity`), amber below 80%; the tooltip adds the cycle count.

### Destinations, sort, tiles

Destinations are capsules with a filled selection. Sorting is underlined, never filled (it filters, it does not navigate). Tile-sized buttons share the tiles' 14 pt corners and fill; small text actions keep 10 pt and sit 6 pt from their icon.

## Do's and Don'ts

- **Do** let the sky carry the state; keep the state line white on the sunset.
- **Do** put grouped content on tiles and leave headings on the sky.
- **Do** keep figures in ink and units quiet.
- **Don't** add hairlines, borders or resting shadows.
- **Don't** use system orange or the old dark accent tones on the sky.
- **Don't** invent strip bars or zero readings when data is missing.
