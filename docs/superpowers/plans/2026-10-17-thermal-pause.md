# Thermal Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish whether real thermal pause is possible on this Mac, then implement only a verified, explicitly opted-in actuator with recovery and truthful status.

**Architecture:** Keep native Apple limiting authoritative and unchanged. First assess the adapter actuator and independent restoration under a separately approved one-shot test; then a pure clock-injected policy may drive a serialized validated adapter through explicit opt-in. An unresolved hardware or recovery gate blocks activation, not just the success label.

**Tech Stack:** Existing Go daemon/SMC bridge and Objective-C/AppKit GUI; no new dependencies or security-policy changes.

**Spec:** `docs/superpowers/specs/2026-10-17-thermal-pause-design.md` (approved; not live-test authorization).

**Execution status (2026-10-17):** Offline Task 2 implemented and Go/race tests pass; see [progress](../../thermal-pause-progress.md). Task 1 hardware/recovery evidence remains blocked, so Task 3 is not started. No installed runtime behavior changed.

**Execution update (2026-10-19):** The separately authorized single hardware probe passed. User then explicitly requested working control/activation. Task 3 is implemented with a detached stdin-heartbeat guardian and durable ownership record; the actual 33/30°C hot pause was observed while preserving Apple 80% and Keep Awake. Full Go/race/native checks and build pass. The progress record distinguishes on-host observations, fixture recovery and unverified overnight/closed-lid/hardware-crash behavior. Earlier blocked statements below are historical gates, not the current delivery state.

## Global Constraints

- Preserve native Apple 80% limit, direct-charge backend behavior and Keep Awake; no sleep/display changes or silent adapter fallback.
- No SIP changes, private entitlement forgery, key brute force or guessed full-byte writes. Readable CHIE metadata is not proof of writable hardware.
- Source defaults 35°C pause / 32°C resume; preserve saved user thresholds. Pause 20–60°C inclusive; resume at least 10°C and strictly below pause; reject nonfinite values.
- At least 60 seconds between automatic transitions; recovery/disable/low reserve bypass cooldown. Restore/refuse cut at or below 20%; rearm only above 25%.
- Explicit new opt-in defaults off; an old heat-enabled preference must never activate adapter mode. No automatic retry on faults.
- Separate approval for physical one-cut/restore probe and for administrator daemon installation; no commits/push without request.

## Review Focus

1. Unknown CHIE flags/type/length or acknowledgement without physical response: stop, never call it paused (Tasks 1, 3).
2. Worker/daemon dies while AC is held: independently bounded recovery must exist before cut; unresolved recovery blocks unattended activation (Tasks 1, 3).
3. Jitter, stale/nonfinite temperatures, low reserve and competing operations: no chattering or unowned writes (Tasks 2–3).
4. Old config, disable, shutdown and wake: no implicit activation and no lifecycle SMC writes in ordinary native mode (Task 3).
5. Failed read/write/readback or uncertain restoration: latched visible fault, no retry loop or false successful pause (Tasks 2–3).

### Task 1: Supervised actuator and recovery feasibility

**Files:** Update `docs/charge-cleanup-research-20261015.md`; create fixture-only `pkg/smc/adapter_verified_test.go`; conditional probe tooling under `tools/thermal-probe/` only after restoration design review.

**Interfaces:** Produce a recorded feasibility verdict with key/type/length, documented known-bit semantics, before/requested/observed/restored state, native-limit readback and independent recovery owner. A verdict is evidence, not a capability inferred from metadata. No new actuator interface is enabled by this task alone.

- [ ] RED: add `TestAdapterProbeRejectsUnknownEncoding` against a test-only validation seam; assert unknown flags/length/type, missing restoration owner and missing physical-AC evidence cannot authorize writes. Run `go test ./pkg/smc -run TestAdapterProbe`; expect FAIL before the validation seam exists.
- [ ] Implement only the validation seam and fake transport; run focused tests, expect PASS with zero real SMC writes. Record exact supported command semantics from current code/primary evidence, separating known from unverified.
- [ ] Establish and document an independent bounded restoration strategy that survives primary-process termination; if semantics or restoration remain unknown, STOP before hardware write and report the specific blocker. A defer or unit-tested fake is insufficient.
- [ ] Request explicit one-cut/restore approval explaining temporary battery use and reconnect sound. Confirm lid open, user present/saved work, physical AC, sufficient reserve and actual native limit. No approval means continue only offline tests, never run the probe.
- [ ] If approved and all prerequisites proven, perform at most one cut/restore; capture independent power telemetry/readback and unchanged native limit. Stop on uncertainty/failure, do not retry or auto-enable. Record narrow awake feasibility only; no overnight claim.

### Task 2: Offline thermal state machine

**Files:** Create `pkg/daemon/thermal_adapter_policy.go`, `pkg/daemon/thermal_adapter_policy_test.go`; modify `pkg/daemon/handlers.go` only for shared finite threshold validation with regression tests.

**Interfaces:** Define `ThermalAdapterInput { Now time.Time; Temperature *float64; SensorAt time.Time; BatteryPercent float64; PhysicalAC, Enabled, Conflicting bool; Observed string; ActuatorError error }`; `ThermalAdapterPolicy { Pause, Resume float64; Freshness time.Duration }`; `ThermalAdapterState { Requested, Observed, Reason string; LastTransition time.Time; ReserveBlocked, Fault bool }`; produce `NextThermalAdapter(policy ThermalAdapterPolicy, state ThermalAdapterState, input ThermalAdapterInput) (ThermalAdapterState, string)`, command is empty, `hold`, or `restore`. Require an explicit positive freshness bound from the sensor sampling contract; do not guess that stale data is fresh.

- [x] RED: table tests `TestThermalAdapterHysteresis`, `TestThermalAdapterCooldown`, `TestThermalAdapterReserve`, `TestThermalAdapterFaults` and `TestHeatThresholdsFinite`. Assert 35/32 defaults, exact 60-second boundary, 20/25 reserve boundaries, no repeated satisfied writes, disable/recovery bypass, missing/stale/NaN/Inf, unplug/replug, conflict and latched failure behavior.
- [x] Run `go test ./pkg/daemon -run 'TestThermalAdapter|TestHeatThresholdsFinite'`; expect FAIL before implementation.
- [x] Implement pure policy without hardware/config writes, preserving direct-inhibit sensor behavior. Missing/stale sensor cannot begin cut; held adapter requests controlled restoration and exposes a fault. A commanded transition never sets observed verified-paused by itself.
- [x] Run focused tests and `go test -race ./pkg/daemon`; expect PASS. This task may proceed offline while hardware feasibility remains blocked; it does not enable a feature.

### Task 3: Conditional integration, truthful GUI and deployment

**Files:** Conditional changes to `pkg/smc/adapter.go`, `pkg/smc/adapter_verified_test.go`, `pkg/smc/write_audit_test.go`, `pkg/daemon/thermal.go`, new `pkg/daemon/thermal_adapter.go` and tests, `pkg/daemon/compatibility.go`, `pkg/daemon/handlers.go`, `pkg/daemon/loop.go`, `pkg/daemon/daemon.go`, `pkg/config/file.go`, `pkg/client/apis.go`, `pkg/compatibility/compatibility.go`, `pkg/gui/controller.go`, `pkg/gui/native_preferences.m`, `pkg/gui/native_battery.m`; update research/PRODUCT/README after verification.

**Interfaces:** Only after Task 1 passes, define `ThermalAdapterActuator` with `Read(context.Context) (string, error)`, `Hold(context.Context) error`, `Restore(context.Context) error`; observed states `held`, `restored`, `unknown`. Define a controller `Reconcile(context.Context, ThermalAdapterInput) HeatProtectionStatus` consuming Task 2 policy and a single serialized owner. Extend existing status compatibly with mechanism, requested/observed state, freshness, cooldown, reserve/fault and last transition; preserve existing fields without falsely setting Paused. Add a distinct persisted thermal-adapter opt-in default false, not an alias of HeatProtectionEnabled.

- [ ] RED: add `TestNativeAdapterOptIn`, `TestNativeLifecycleNoAdapterWrites`, `TestThermalAdapterOwnership`, `TestThermalAdapterRecovery` and `TestThermalAdapterObservedStatus`. Assert legacy config/no opt-in means zero writes; native limit unchanged; calibration/discharge conflicts rejected; disable/shutdown/wake/crash/restart reconciliation; read/write/readback errors latch and never retry; requested is not observed. Preserve existing native zero-write tests unchanged in meaning.
- [ ] Run focused daemon/SMC tests; expect FAIL for new explicit-mode behavior. If hardware or independent recovery remains unproven, STOP integration/activation here; retain unavailable GUI, document exact limitation, do not weaken tests.
- [ ] Implement validated key operations and serialized controller without changing native-limit authority. Wire explicit opt-in/status only; no independent polling loop competing with existing ownership. Use documented known-bit commands only and require observed actuator plus consistent power telemetry before Paused=true.
- [ ] Update GUI mechanism disclosure: adapter cut uses battery and can sound on reconnection; distinguish unavailable, requested, verified held, reserve bypass and fault. No flow-geometry/fabricated watts changes. Update client/status compatibility tests and native assertions for these states.
- [ ] Run `go test ./...`, relevant daemon/SMC/GUI race tests, native dashboard/Storage/Keep Awake harnesses, build and `git diff --check`; expect PASS. Record exact commands/evidence and unverified runtime limits.
- [ ] Seek separate administrator-approved deployment with daemon/GUI/config backups; verify native 80% and Keep Awake unchanged. Perform a supervised transition/recovery check followed by a longer monitored run only with explicit authorization. Any fault disables automatic transitions and stops further rollout; do not promise overnight reliability from unit tests/one probe.

## Handoff

Task 2 offline policy is implemented, not deployed. The next step is Task 1 command/recovery feasibility; unknown semantics and unproven independent restoration block physical writes and Task 3. Readback contract and bounded recovery state additions are recorded in the progress document. Physical testing remains separately gated. Earliest failed gate is the stop condition, not permission to bypass it.
