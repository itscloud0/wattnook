---
target: WattNook popover (all screens)
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:<repo>/pkg/gui/native_popover.m"
target_fingerprint: "sha256:604dc1cd169ca08be70b493018018298a98874ee307f3e52f559b8628914ce60"
target_path: <repo>/pkg/gui/native_popover.m
timestamp: 2026-10-19T18-36-24Z
slug: pkg-gui-native-popover-m
---
Method: design review only (detector not applicable, native platform)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Heat button keeps saying "Temperature control" while charging is paused |
| 2 | Match System / Real World | 3 | "6 processes", "Swap", "Free" under Disk activity need translation |
| 3 | User Control and Freedom | 3 | Storage/History have Back; popover has no keyboard escape hints |
| 4 | Consistency and Standards | 2 | Three different "selected" styles; Keep Awake window is a different visual world |
| 5 | Error Prevention | 3 | Quit asks for confirmation; limit snaps to Apple values |
| 6 | Recognition Rather Than Recall | 2 | Draggable limit marker and heat presets have no visible affordance |
| 7 | Flexibility and Efficiency | 2 | Arrow keys on the limit only; no shortcuts for tabs or Keep Awake |
| 8 | Aesthetic and Minimalist Design | 2 | Battery page repeats System and Storage; System footer repeats Battery |
| 9 | Error Recovery | 2 | Alerts surface raw daemon text ("got 409: …") |
| 10 | Help and Documentation | 2 | Help lives only in tooltips |
| **Total** | | **24/40** | **Acceptable** |

## Design Specificity Verdict

The power-flow canvas and the dual Battery/CPU temperature header are authored for this product: they answer the two questions a MacBook owner opens WattNook for (where is the power going, why is it hot). Everything below the flow is a generic three-column stat dashboard that any monitor app could ship: System summary, SSD bar, Top consumers with Quit, History sparklines. The Keep Awake details window drops the popover's graphite world entirely for stock gray AppKit chrome and a terminal-black text area.

Deterministic scan: not applicable (native platform).

## Overall Impression

Battery is close to good after this session's fixes; the rest of the app reads as three separate tools sharing a tab bar. The biggest opportunity is to make Battery do one job (charge, temperature, power, two controls) and let System and Storage stop being echoed on it.

## What's Working

- Power flow: node-anchored captions with muted names and tabular watts read instantly in all four states (charging fork, AC + battery merge, single source, held).
- Header: 48 pt charge with a one-line state ("Charging paused · heat") plus Battery/CPU temperatures is a strong, scannable hierarchy.
- Storage now uses the dashboard's own tabs and buttons, and the relative size bars make the list comparable at a glance.

## Priority Issues

1. **[P1] Battery page repeats System and Storage.** System summary (CPU/Memory/Disk) and SSD used/free take the lower 40% of Battery and duplicate two tabs one click away. Fix: end Battery at the action row; promote Heat Protection and Keep Awake state there; move nothing else in. Command: $impeccable distill
2. **[P1] Inconsistent component language.** Selected state is a gray pill (tabs, sort, Storage), a solid accent fill (palette), and a bordered stock segment (old Storage). Back is "‹ System" text in History but a chevron WattButton in Storage. Section headings are 16 pt (Appearance, Menu bar) and 13 pt (Monitoring, Top consumers). Keep Awake details is a stock gray window. Fix: one selected style, one back control, one heading size, Keep Awake details rebuilt on the popover surface. Command: $impeccable polish
3. **[P1] Heat state is not on its own control.** While paused, the Heat protection button still reads "Temperature control"; orange on the battery temperature means "paused" but reads as "danger". Fix: subtitle shows the live state ("Paused · resumes at 30°", "Watching · pauses at 33°", "Off"); keep orange for the state line only. Command: $impeccable clarify
4. **[P2] System metrics carry noise.** "6 processes" under CPU, "Free 135 GB" under Disk activity (space under throughput), a per-row Quit on every app, and a footer repeating Battery. Fix: one caption per metric that explains it, Quit on hover/selection only, drop the footer. Command: $impeccable distill
5. **[P2] History charts are sparklines.** No scale, no time axis, a visible gap in Mac power, back button misaligned with "Last 15 minutes". Fix: shared time axis, min/max labels per series, align header row. Command: $impeccable layout

## Persona Red Flags

**Alex (power user):** Cannot switch tabs with ⌘1/2/3; changing the charge limit needs a precise drag on a 3 pt marker; Heat presets are four clicks deep (button → menu → preset).

**Sam (VoiceOver/keyboard):** Limit marker is the only keyboard-adjustable control and has no visible focus ring; power-flow values live only in the canvas and accessibility label, not as separate elements; orange state color has no text equivalent on the temperature.

**Project persona, "Ilia" (MacBook Air owner, heat-anxious, on video calls):** Opens WattNook to learn why the Mac is hot; sees CPU 88 °C now, but nothing tells which app is causing it without switching to System and sorting by CPU.

## Minor Observations

- "Limit 80%" vs "Charge limit 80%" depending on backend; pick one.
- Single-source flow has two caption rows (watts above, names below) unlike the fork's inline captions.
- Settings Monitoring heading sits on a looser rhythm than Menu bar.
- Keep Awake details text area uses 70% of the window to show "Assertions: none".

## Questions to Consider

- What if Battery ended at the controls and the popover got shorter?
- Should "why is it hot" be one tap: CPU temperature linking to the top CPU apps?
- Does the History page earn its place, or should it fold into System as a single CPU/power trend?
