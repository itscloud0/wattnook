---
version: 1
slug: "pkg-gui-native-popover-m"
primary_target: "pkg/gui/native_popover.m"
related_targets: ["pkg/gui/native_power_flow.m","pkg/gui/native_preferences.m","pkg/gui/native_cleanup_view.m"]
---

# WattNook native popover

Mode: Operate. Daily quick checks during desk work and overnight AI/CLI sessions on a MacBook. On 2026-10-21 the user rejected the graphite wayfinding look ("weak"), then the state-sky gradient ("don't like the gradient", "feels AI"). Behaviour, data truth, controls, units, palettes and all charging/sleep logic stay.

## Direction contract

THESIS: A native Mac utility in Apple's own dark grouped style; colour lives only on data and state. It refuses gradients, tinted grounds, translucent card stacks and middle-dot copy.

OWN-WORLD: Ground #1C1C1E, groups #2C2C2E with 14 pt corners and no borders, SF Pro, system green/orange/accent, a light 66 pt charge numeral with a small muted percent sign, plain-language labels.

STORY: Read charge and state, then where the watts go, then the last 15 minutes, then act (limit, Top Up/Discharge, Heat, Keep Awake).

FIRST VIEWPORT: Header and three-way navigation; charge numeral with its state line and Battery/CPU/Health readings; the draggable limit rail with its action; the Power group holding the flow with real endpoints (this Mac's artwork, a level-accurate battery, a plug); the 15-minute Mac-power strip; Heat and Keep Awake actions side by side.

FORM: User steer away from the rolled weather-sky direction to the platform's own grouped style (convention as commitment, alongside macOS System Settings and AlDente). seed:3eb6d2297435b8e7

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
