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
