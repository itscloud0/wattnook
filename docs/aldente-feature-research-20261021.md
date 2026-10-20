# AlDente feature mechanisms — static study, 2026-10-21

Purpose: learn how AlDente's paid features behave so WattNook can implement its own versions. Facts only; no AlDente code, assets or UI copied.

Artifact: official `AlDente.dmg` 1.39.4 from GitHub release `1.39.4` (SHA-256 `b2634ae4…aa701b`, matches the published digest). arm64 main `2d5e9e6d…527bb0c`, helper `07c67bf3…a2e21` (same as the 2026-10-17 study). Mounted read-only, not installed or run. Sources: Swift/ObjC type and log strings in the main binary, and the app's own English help strings (paraphrased below). Static only: nothing here was observed running.

## Architecture (observed in strings)

- Four charge intents: off, charge, hold, discharge. A `BackendResolver` registers candidate backends (`LegacyIntelSMCBackend`, `TahoeSMCBackend`, `GoldenGateSMCBackend`, `PreferencesBackend`, `PowerUIBackend`), tries them in order and falls back on failure. It defers intents while Apple's own battery gauging runs.
- `PreferencesBackend` writes the top-off-protection defaults (`mclLimitValue`, `isManuallyChargeLimited`, …), posts the defaults-changed notification, reads back, and for hold pulses CHIE (see `aldente-backend-research-20261017.md`). It also logs "apply discharge: writing MCL limit" — a discharge target below the current charge, which makes macOS drain slowly on AC (matches WattNook attempt 3).
- `TahoeSMCBackend` "only supports discharge on macOS 27 or newer" and checks "SMC discharge keys". Its key table sits next to `CHIE`, the adapter-inhibit key; the user-facing text says the Mac then runs "solely on battery". Inference: on macOS 27 active discharge = adapter input held off via CHIE, not a preferences hold. Not verified at runtime.
- No strings for the USB-PD contract (`UsbHvc*`, HVC index, renegotiation). It reads adapter voltage/watts for display. Bounded negative: AlDente does not appear to check whether the charger fell back to 5 V after a pulse. WattNook already does.

## Features and behaviour (from help strings)

| Feature | Behaviour |
|---|---|
| Discharge | Runs the Mac on battery while plugged in until the charge reaches the limit. Only on AC; limit must be below the current charge. Disables sleep during discharge (also in clamshell, Pro-only there); optional MagSafe LED blinks orange. Quitting mid-discharge waits for macOS to notice, or the screen may blank once. |
| Automatic Discharge | Starts Discharge automatically whenever the limit is below the current charge. |
| Sailing Mode | After reaching the limit, lets the charge fall by a "sailing level" (recommended 5–10%) before charging again, to avoid micro-charging. Always charges below 20%. Off during Top Up and Calibration. |
| Top Up | Sets the limit to 100% and keeps charging (including asleep) until unplugged. Only on AC, not during Calibration. Optional schedule: every Monday 5:00. |
| Calibration Mode | Phases: charge to 100% → hold for a set time → discharge to ~10% → charge to 100% → return to the previous limit. Charger required; sleep disabled; clamshell keeps the display on. Schedules: monthly or every two weeks. Waits out macOS's own gauging (macOS may temporarily override limits and charge to 100%). |
| Heat Protection | Stops charging above a battery temperature (recommended 35 °C), resumes after a cool-down; off during Calibration. |
| Limits below 80% | Opt-in setting; unavailable through the PowerUI method (80–100 only). |
| Hardware battery percentage | Shows the raw battery percentage instead of macOS's rounded/adjusted value. |

## What this means for WattNook

Already equal or ahead: Heat Protection (charge-only on macOS 27), limits below 80%, PD-fallback warning.

Buildable with mechanisms we have verified:
- **Sailing** — pure policy on the existing hold: after reaching the limit, release to normal charging only below `limit − sailing`.
- **Top Up** — release holds and set Apple's limit to 100% until AC disconnects, then restore.
- **Discharge** — two options: (a) preferences hold below the current charge (verified to drain on AC, slow, keeps adapter powering part of the load); (b) CHIE held off = true battery-only run (fast; needs a guardian that always restores AC, sleep handling, and the existing PD check on release). Our retired thermal-adapter controller already contains (b)'s owned-hold and recovery machinery.
- **Calibration** — sequence of the above (Top Up → hold → Discharge → Top Up → restore).
- **Hardware battery percentage** — `AppleRawCurrentCapacity / AppleRawMaxCapacity` from IOKit.

Open questions for runtime verification: exact discharge key and value on this Mac (CHIE 08 held vs. other), how long macOS keeps the Mac on battery with CHIE held, and sleep behaviour while held.
