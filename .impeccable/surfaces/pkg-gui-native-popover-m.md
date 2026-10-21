---
version: 1
slug: "pkg-gui-native-popover-m"
primary_target: "pkg/gui/native_popover.m"
related_targets: ["pkg/gui/native_power_flow.m","pkg/gui/native_preferences.m","pkg/gui/native_cleanup_view.m"]
---

# WattNook native popover

Mode: Operate. Daily quick checks during desk work and overnight AI/CLI sessions on a MacBook (dark menu bar, indoor desk light, often late). The user rejected the graphite wayfinding look as "weak" on 2026-10-21 and asked for a full, juicy redesign referencing CleanMyMac's menu (saturated ground, translucent tiles) and AlDente (grouped controls). Behaviour, data truth, controls, units, palettes and all charging/sleep logic stay.

## Direction contract

THESIS: The popover is a weather report for power. The whole ground is a sky whose colour is the Mac's power state, read before any word; it refuses the category default of a grey panel with one accent.

OWN-WORLD: Full-bleed vertical sky gradients per state: day blue (charging), dusk blue (held on adapter), sunset orange-magenta-plum (heat pause), night indigo (on battery), twilight violet (Discharge). White SF Pro, light 64 pt charge numeral, translucent white tiles (10%, 14 pt corners, no borders or shadows), palette accent only on energy and selection.

STORY: Read charge and the sky's mood, then where the watts go, then the last 15 minutes, then act (limit, Top Up/Discharge, Heat, Keep Awake).

FIRST VIEWPORT: Header and three-way navigation; 64 pt charge with state line, battery/CPU/health readings right; draggable limit rail with its action; a Power tile holding the flow; a 15-minute Mac-power strip tile like an hourly forecast; Heat and Keep Awake tiles side by side.

FORM: Weather-forecast app (4th of 7 grounded candidates: EV charging screen, thermal imaging, battery wrapper, weather forecast, stage lighting, utility meter, transit wayfinding). Raises: scale contrast between numeral and labels (variable-font specimen); colour owns the whole region, not an accent (guide map); one state owns the whole surface (vertical feed); nothing labelled twice (catalog sleeve). seed:3eb6d2297435b8e7

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
