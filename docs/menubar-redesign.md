# Batt Thermal: menu-bar UI redesign proposal

Status: compact native popover implementation installed 2026-09-27. Based on the user's AlDente power-flow references, five-state ImageGen pack, and feedback through 2026-09-27. The [ImageGen concept](../.lazyweb/design-improve/batt-popover-2026-09-26/references/concept-imagegen.png) is a visual direction, not a pixel-exact target.

## Product job

One menu-bar item should answer, in order: (1) what is happening to the battery, (2) where power is going, (3) whether charge and heat limits are protecting it, and (4) what to change. CPU/RAM/SSD and process diagnostics remain available without another menu-bar item.

## Structural decision

Keep the existing macOS-style status icon and adjacent CPU/RAM/SSD readout. Replace the current `NSMenu` with a transient `NSPopover` anchored to that one status item. Keep a compact right-click menu for conventional commands such as Settings and Quit. The current custom drawing inside an `NSMenuItem` makes the graph and the actions feel like two unrelated interfaces and prevents proper interactive controls.

Current content width is 332 pt and height is 350 pt, fitting the five-state composition without scrolling. The popover follows light/dark mode and Escape-to-dismiss.

## Default view

```text
  41%   On battery                         29.2°C
  ━━━━━━━━━━━━━━━╷────────────────         Limit 80%

  Battery ━━━━━━━━━━━━━━━→ Mac
                 ≈8.8 W

  Charge limit                         80%  ›
  Heat protection              On · 33°/30° ›
  Dark Work                  Turn screen off

  CPU 8%     RAM 68%     SSD 71%          ›
  Settings ···
```

The number and state lead. The charge rail shows current level and a separate limit marker; no text lies over its fill. The diagram is the second visual focus. Controls are compact rows, not menu dumps. CPU/RAM/SSD lead to the existing per-app diagnostics; the footer houses settings and rare commands.

## Power-flow grammar

Use a real Sankey topology, not a blue rectangle between two icons. Source and destination labels stay fixed on a grid. Draw only measured/inferred active paths, with smooth joins and no hard vertical cliff. Band width follows watts within a readable min/max; the numeric value sits adjacent to the band so a thin flow never collides with text. A restrained blue-gray is the flow color; green/orange are reserved for charging/discharging state, not decoration. Use the same icon size in every state.

| State | Diagram | Primary status |
| --- | --- | --- |
| Battery only | Battery → Mac | Discharging |
| AC bypass / charge held | Adapter → Mac; Battery 0 W remains visible but inactive | Plugged in · not charging, or Paused by heat |
| AC charging | Adapter splits → Mac and Battery | Charging |
| Hybrid | Adapter and Battery merge → Mac | Discharging while plugged in |
| Data unavailable | No fabricated ribbons; show an explicit unavailable state | Battery percentage from macOS if known |

Show Mac total once, at the destination; show each source/branch wattage once. Values from IOKit/powerkit calculations are estimates: use `≈` where appropriate and do not imply an exact physical split when inputs do not reconcile. A small details view can expose raw adapter, battery, and system values and the last update time.

## Interaction and hierarchy

- Charge limit: one row opens 50/60/70/80/90% choices and temporary disable options. Current value remains visible on the default view.
- Heat protection: one row shows On/Off, current battery temperature, and pause/resume thresholds; opens presets/custom thresholds. A heat hold is distinct from reaching the charge limit.
- Dark Work: one explicit action, `Turn screen off`; when active, `Restore screen`. State and recovery method must be clear before activation.
- Diagnostics: CPU/RAM/SSD strip opens a second popover page with top processes and graceful Quit. Destructive force-quit, if added later, needs a separate confirmation.
- Settings/Advanced: contains MagSafe LED, sleep hooks, calibration, force discharge, daemon maintenance, and Quit. These must not compete with daily actions.

Keep all controls keyboard-reachable, VoiceOver-labeled, and live-state-aware. Popover closes with Escape or click outside. Menu-bar icon continues to show native macOS battery states; no extra status item is added.

## Verification and remaining work

The `NSPopover` shell, three daily controls, stats/diagnostics entry and More menu are implemented. Rendered battery-only, hybrid and charging diagrams in dark appearance and battery-only in light appearance; inspected the installed popover on the user's Mac. `go test ./...` and `git diff --check` passed. The daemon was not changed by this UI deployment.

Remaining: verify the charge/heat submenus, keyboard and VoiceOver interactions on-device; render the AC-held and unavailable states; replace the legacy advanced menu when a separate settings page is designed. The watt flows are estimates, not a physical power-meter reading. The pre-existing build still emits Objective-C category and macOS deployment-target warnings.

## 2026-09-27 visual-state handoff

The installed 380×440 pt implementation does not match the approved ImageGen composition. The user supplied a current screenshot and asked for all power states before another UI implementation pass. A five-state ImageGen set and comparison report now live at [`.lazyweb/design-improve/batt-states-2026-09-27/report.html`](../.lazyweb/design-improve/batt-states-2026-09-27/report.html): battery-only, heat hold, charge-limit hold, charging split, and adapter+battery hybrid. The earlier single discharge concept is reused as the first state. The installed app and daemon were not modified during this design pass.

Implementation uses the report's shared geometry and state matrix, not generated bitmaps. The five vector states, inset controls, and three footer cells are in `pkg/gui/native_power_flow.m` and `pkg/gui/native_menu.m`. The rail marker is draggable left/right: preview in 5% steps, commit only on release, 20–95% range. Keyboard arrows and accessibility slider values use the same range. 100% remains an explicit menu action because it disables charge control.

Verified 2026-09-27: rendered all five states plus unavailable and light-mode battery-only through the AppKit preview harness; inspected the installed popover after its opening animation; `go test ./...` and `git diff --check` passed. The installed UI binary matches `/tmp/batt-thermal-v2` by SHA-256. The daemon binary was not replaced during this UI pass. The rail drag was not exercised against the live daemon, to avoid changing the user's actual charge limit during QA. Existing Objective-C category and deployment-target warnings remain.

Next step: check drag/keyboard/VoiceOver interaction on-device without leaving a changed limit, then address any visual feedback. Keep power readings labeled approximate: these flows are inferred, not direct per-branch meters.

## 2026-09-27 compact pass

User screenshot showed that the 456×500 pt popover was oversized, the power ribbon tapered into an ugly wedge, and action icons crowded their text. Reduced width by 27% and height by 30% to 332×350 pt. Flow paths are now constant-width rounded curves, with width bounded by estimated watts. Action icons and titles have extra spacing; card rows are 36 pt high. Footer captions explicitly distinguish CPU `load`, RAM `memory used`, and SSD `space used`; these are not three comparable utilization percentages. Footer controls still open the existing diagnostics. The menu-bar percentages use the same underlying measurements, though their compact format does not have room for the captions.

`go test ./...` passed. Rendered heat hold, charging split, and hybrid state at the new size. Installed `/tmp/batt-thermal-compact` as the UI app; pre-pass binary is backed up at `/tmp/batt-thermal-ui-before-compact-20260927`. The display was in Dark Work mode during live capture, so `screencapture` yielded a black frame; the installed popover's final on-screen geometry was **not** visually verified. Do not treat the isolated state renders as proof of the complete popover. Next: inspect one settled screenshot after the display is restored and fix any actual clipping. Daemon was not replaced.

## 2026-09-27 icon aspect fix

The user's settled screenshot showed squashed Battery and Mac symbols. `Symbol()` drew every SF Symbol into the caller's fixed rectangle, stretching `battery.100percent` (intrinsic 36×17 pt) and `laptopcomputer` (35×20 pt) into roughly square bounds. The helper now aspect-fits and centers the tinted symbol. Verified battery-only and heat-hold preview renders; `go test ./pkg/gui` and `git diff --check` passed. Installed UI binary `/tmp/batt-thermal-icons-fixed`; daemon unchanged. The `impeccable` detector returned no findings for the touched Objective-C file.

## 2026-09-27 unplugged heat-status copy

The daemon's heat-protection `paused` flag persists while unplugged until the battery cools to its resume threshold. It describes the charge gate, not active charging. The UI previously prioritized that flag even while the actual flow showed Battery → Mac. The popover now says `On battery` whenever unplugged; its heat row says `Cooling · <temperature>` while the gate remains paused. The status-item tooltip likewise avoids claiming charging is paused without AC, and the advanced power item no longer says `Battery held` when the adapter reports no power. No daemon logic, thresholds, or charge configuration changed. Rendered the unplugged-hot state, then visually checked the installed popover with AC disconnected: `On battery`, `Cooling · 34.0°C`, Battery → Mac. `go test ./...` and `git diff --check` passed. The launch agent uses `/usr/bin/open`, so after replacing the app binary the existing UI process must be terminated before kickstarting the agent; `kickstart -k` alone did not replace the running LaunchServices process.

## 2026-09-27 Sankey and inconsistent telemetry

The powerkit-go 0.9.4 IOKit calculation uses `SystemPower = max(0, AdapterPower - BatteryPower)`. A live transient sample reported 3.68 W adapter, 17.47 W charging, and 0 W system; that last value is a clamped contradiction, not a measured zero. The popover and advanced summary now say the readings are updating when charging power exceeds adapter power or system power is implausibly near zero. They do not draw a fake split or show `0 W` for the Mac in that case. Later coherent samples rendered normally. The GUI change does not alter telemetry or daemon control.

Initial separated strokes removed overdraw but lost the split/merge topology. The final vector diagram uses adjacent filled ribbons with conserved branch widths and one shared trunk: adapter → battery + Mac, or adapter + battery → Mac. It no longer layers round-capped strokes at the junction. Rendered charging, hybrid, and inconsistent sample states in the AppKit harness. `go test ./...`, `git diff --check`, and the `impeccable` detector passed. Installed `/tmp/batt-thermal-ribbon`; hash matched the app bundle and the UI process restarted. At final live check, heat protection held charging and only the single adapter → Mac flow was visible, so the *branched* live appearance was validated with the render harness, not an on-device screenshot. The heat preset caption was compacted to avoid truncation in the 332 pt popover.

## 2026-09-27 public fork and compact control rows

The 332×350 pt popover now uses flat full-width control rows with inset separators instead of a nested gray action card. Value labels pass hit tests through to the row buttons. The installed UI process was restarted without touching the privileged daemon, and the live battery-only popover was visually checked. `go test ./...`, `git diff --cached --check`, and the `impeccable` detector passed; existing Objective-C category and linker deployment-target warnings remain.

The source-only commit `add0c6e` is published at `https://github.com/itscloud0/batt` in the public `thermal-ui` default branch, preserving upstream history and GPLv2. Generated `.lazyweb` files and the local binary are ignored; this internal handoff document remains untracked. The fork's `master` is newer upstream (`7995404`) and includes significant daemon changes. Do not blindly rebase/cherry-pick the thermal charge-control code; reconcile and retest it separately before merging. No prebuilt fork release exists yet.

## 2026-09-27 battery + system redesign

The user rejected the prior popover and chose equal first-screen priority for battery and system. The native AppKit popover is now 340×400 pt with a flat graphite surface. Its power area gives every watt reading a named source or destination; the charge-limit marker has a separate exact-value button. A compact action strip exposes heat protection and Dark Work. The system area labels CPU load, physical memory used, and disk space used, then shows top CPU and memory apps with normal Quit buttons. Quit still uses the existing confirmation and PID/bundle revalidation. No force-quit was added.

Added `PRODUCT.md`, `DESIGN.md`, and a small non-daemon preview harness in `tools/power-flow-preview/main.m`. The harness rendered battery, charging split, charge held, heat held, hybrid, and unavailable states without changing the real battery. The live UI was inspected once in heat-hold state after deploying only the GUI binary. A second live capture after the final typography change was obscured by another foreground app, so that last appearance change has build/test verification and state-render verification, but no clean settled popover screenshot. `go test ./...`, `git diff --check`, and the Impeccable detector passed; existing ObjC and deployment-target warnings remain. ImageGen and Lazyweb MCP were unavailable (404/no tool), so the local quick-reference report uses earlier project concepts and official AlDente material.
