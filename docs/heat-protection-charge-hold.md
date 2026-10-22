# Heat Protection on macOS 27 — charge hold

Status 2026-10-19: implemented, installed (daemon + GUI SHA-256 `385872be…d9558`) and verified live once.

## Why

M4 / macOS 27 has no CH0B/CH0C/CHTE keys (zero-size placeholders) and no bfF0/bfD0/bfE0, so the legacy charge-inhibit loop cannot act. The only writable charging key, CHIE, disconnects the adapter entirely. See `smc-readonly-probe-20261019.md`.

## Mechanism (verified once by `tools/charge-hold-probe`, attempt 4)

Hold, at the current battery percentage:
1. Save the eight `com.apple.smartcharging.topoffprotection` keys (root CurrentUser/AnyHost) to `/var/db/wattnook-thermal/<config>.charge-hold.json` (0600). The record exists only while a hold is active.
2. Clear `checkpoint`, `currentState`, `MCLTempDisabledUntilDate`; set `mclLimitValue` = current %, `MCLFeatureState`, `isEngaged`, `isManuallyChargeLimited` = 1; post `com.apple.smartcharging.defaultschanged`.
3. Pulse CHIE `08` → 500 ms → `00` (always restored, verified by readback).

Release: restore the saved keys, delete the record, then one pulse.

A target below the current percentage makes macOS discharge on AC (attempt 3); the hold always uses the current percentage.

## Daemon policy (`pkg/daemon/native_heat_hold.go`)

Runs in the 10 s maintain loop in native mode, when `capabilities.chargeHold` is true (native + CHIE present).

- Hold when temperature ≥ pause, on AC, battery below Apple's limit and ≥ 5%.
- Release when temperature ≤ resume, when Heat Protection is turned off, and on daemon shutdown.
- A hold record found at startup (crash) is released before native capability detection.
- Sensor error: no new hold, no release; next valid reading decides.
- Hold/release failure: fault, no retries until Heat Protection is re-configured.
- While held, `GET /limit` reports the saved (or newly chosen) limit; `PUT /limit` stores the choice and applies it when the hold ends, so slider drags never pulse the adapter.
- Temperature: hottest of SMC TB1T/TB2T, IOKit fallback.

## Live verification — 2026-10-19 22:03–22:07

Apple limit temporarily 85%, battery 80%, AC, charging. Thresholds 25/20 at 30.3 °C → daemon hold at 80%: AC kept, 0 mA for 2+ min, `/limit` reported saved 85. Thresholds 60/59 → release: charging resumed after ~60 s at +2723 mA, no native-limit write needed. Then restored Apple limit 80% and set Heat Protection 33/30 °C.

Backups: daemon `/private/tmp/wattnook-daemon-backup.h824t5`, GUI `/private/tmp/wattnook-gui-backup.v2RQEC` (in /private/tmp, lost on reboot).

## Not yet verified

- Long holds (hours), sleep/wake while held, crash recovery on a real daemon restart while held.

## Hold target above the current charge — 2026-10-20 00:36

`charge-hold-probe --run-above`, record `/private/tmp/wattnook-charge-hold-3542841754`. Apple limit 80, battery 80%, AC, not charging. Hold target 82 + one CHIE pulse. After ~50 s charging started (+2629 mA), reached 81% then 82%, then stopped: 0 mA, AC retained, `mclLimitValue` 82 throughout. VERIFIED; recovery restored Apple 80%.

So the hold is a full charge limit: below the current charge it discharges on AC to the target (attempt 3 above), above it it charges to the target and stops. This enables limits outside Apple's 80/85/90/95/100.

## Charge limits below 80% (custom limits)

With `chargeHold`, `/compatibility` advertises 50/55/60/65/70/75 ahead of Apple's 80–100. Choosing one saves `customChargeLimit`, keeps Apple's limit at 80% underneath as a backstop and holds at the custom limit; if the battery is already above it, the hold stays at the current charge (no discharge on AC). Heat Protection and the custom limit share one hold and one snapshot: heat retargets to the current charge, cooling retargets back to the limit, each with a single pulse. Choosing an Apple value clears the custom limit and releases the hold (or defers the Apple value while heat still holds).

Live, 2026-10-20 00:47: daemon `8fbc40d8…`, PUT /limit 70 at 81% (Apple 80%, AC, 35 °C). Hold set at 81 (current charge, heat=true, custom 70). Nine samples over 3 min: 0 mA, AC and raw AC on, not charging; status paused/held. The "charges up to a custom limit and stops" path is covered by the probe at 82% but not yet observed through the daemon below 80%.

## Adapter fell back to 5 V after a pulse — 2026-10-20

After a heat hold at 15:13 the 60 W charger sat at `UsbHvcHvcIndex=255` (no high-voltage PD contract): ~4 V × 2.9 A = 11.7 W in while the Mac drew ~17–21 W, so the battery drained on AC. Reconnecting the cable restored index 3 (20 V, 42.6 W in). The daemon now records the PD contract before every hold/retarget/release pulse and waits up to 8 s for a high-voltage contract afterwards; if it does not return, `/heat-protection` carries `adapterWarning` and the GUI asks to reconnect the cable. The warning clears once 20 V is back.

## Discharge on AC — 2026-10-21

`PUT /discharge true` (GUI: **Discharge to Limit**, or the contextual Battery button when the charge is above the limit) holds at the limit while the charge is above it; macOS then runs the Mac partly from the battery with the adapter connected. It ends at the limit, on unplug or on Top Up, and outranks heat (draining never charges).

Live, MacBook Air M4, macOS 27, 70 W adapter at 20 V, battery 57 %, custom limit 55:

- Run 2 (02:52): hold 55 → battery −0.67 A within 5 s, −1.4…−1.6 A after two minutes, `ExternalConnected = Yes`, PD index 3 throughout. Stop → heat hold at 57; current returned to 0 mA after ~50 s. No replug needed.
- Run 1 (02:48): no drain within the 40 s observed before stopping; macOS re-evaluates on its own schedule (compare the ~50 s delay before charging in the run-above probe).
- First attempt (02:18): the pulse's brief adapter-off reading ended Discharge after 2 s (fixed: "unplugged" is ignored for 15 s after a pulse). Within 12 s macOS reported `ExternalConnected = No`, `PMUConfiguration = 0` while the charger stayed at 20 V (`SystemVoltageIn` 20.4 V); the Mac ran on battery at ~0.9 A. A retarget pulse, the release pulse and 3 minutes without a hold did not recover it; replugging the cable did. Not reproduced since. The daemon now reports `adapterWarning` ("reconnect the cable") when a live high-voltage charger is ignored for 30 s.

## Heat hold at the displayed charge — 2026-10-21

The heat hold used to target the charge plus one point, so it would never give back the fraction above the rounded-down display. Live at 03:00 that charged a hot battery (37 °C) from exactly 57.0 % towards 58 % at ~3.25 A (≈40 W). The hold now targets the displayed charge: after the pulse the battery gave back ~0.75 A for ~50 s, then 0 mA with the adapter powering the Mac (03:03). The low-charge reserve now counts only a drain below the hold point as "the adapter cannot keep up".
- Run 3 (03:11–03:21): Discharge from 58 % with the limit moved from 50 to 55 mid-run. −0.6…−0.9 A with `ExternalConnected = Yes` throughout; Discharge ended by itself at 55 % (03:21:37), the hold parked at 55 and the current settled at 0 mA with the adapter powering the Mac. No replug needed.

## Charger that keeps dropping out — 2026-10-22

At 24% on a 60 W charger the USB-C contract dropped every 4–5 s: charging started at ~3.5 A, then within 1–2 s the kernel logged `setVbusPresent 0` / `No plug detected` on the port and the PD contract re-negotiated (20 V → 5 V "usb host" → 20 V); between bursts the battery drained ~1–1.7 A. The daemon issued no pulse during it (last transition before plug-in), and it stopped by itself at ~28%, when charging current fell. AppleSmartBattery's `PortControllerInfo` counts it: `PortControllerDetachCount` 366 and `PortControllerIrqCntHrdRst` 156 on that port. The 5 s maintain loop cannot see each drop-out, so the daemon samples the detach counter every 10 s and sets `adapterWarning` ("keeps disconnecting") after 4 detaches within 2 min; it clears after 2 min with none.

The same episode showed two policy gaps, now closed: a heat pause started while unplugged (useless on battery, and it pulsed CHIE), and the 25% reserve latched on battery drain, which says nothing about the adapter. Heat now waits for the adapter, and the reserve counts only a drain on AC.

Later the same day a heat hold landed during a drop-out: CHIE read `0x10` (macOS's own value while the charger reconnects), the pulse refused it as unknown, and the fault stopped Heat Protection, so the hot battery (38 °C, 18%) charged until it was re-enabled. `Pulse` now waits up to 2 s for `0x10` to settle and otherwise returns `ErrAdapterBusy`; nothing is written, and the daemon retries on the next loop instead of faulting.
