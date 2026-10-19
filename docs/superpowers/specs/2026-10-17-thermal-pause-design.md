# Thermal pause on gated macOS firmware

Status: Task 2 policy and native thermal integration implemented/tested. The separately authorized one-shot CHIE cut/restore passed, followed by user-requested installation and activation of actual 33/30°C control on 2026-10-19. A real hot pause was observed; Apple 80% and Keep Awake remained unchanged. Detached guardian recovery is covered by SIGKILL/heartbeat fixtures and durable startup reconciliation. Overnight/closed-lid and actual hardware crash recovery remain unverified. [Verified progress and rollback copies](../../thermal-pause-progress.md). This document itself does not authorize unrelated power experiments.

## Goal and current evidence

Pause charging when the battery reaches the chosen threshold and resume after a lower threshold, with truthful state/error reporting and without rapid connection cycling. Preserve the native Apple 80% limit and Keep Awake.

- Existing direct charge-inhibit backends are unavailable on the inspected macOS 27 firmware: legacy keys have zero size and firmware-limit keys returned NotPrivileged. Temperature telemetry is readable but does not confer actuator write permission.
- The native PowerUI backend supports advertised charge limits from 80%, not an immediate pause at an arbitrary state of charge. Do not oscillate 80/100 limits or call Apple's own thermal management WattNook heat protection.
- Upstream PR 154 implements adapter-cut limiting on another Mac: https://github.com/charlie0129/batt/pull/154. This is a candidate actuator, not proof for this host.
- Host KeyInfo read on 2026-10-16: CH0I size 0; CH0J NotPrivileged; CHIE size 1. This establishes readable metadata only. Current native compatibility returns early without adapter capability information; adapterControl=false is not a failed write test.
- User previously deferred the physical adapter test in favor of Storage. The latest request renews the heat-protection goal; it does not erase the need to disclose the different adapter-cut behavior and obtain approval for a particular live transition.

## Two distinct mechanisms

1. Direct charge inhibition: keep AC powering the Mac while stopping battery charge. Prefer when genuinely supported and verified; retain existing old-firmware behavior.
2. Native-limit plus explicit thermal adapter cut: when hot, disconnect wall-power input and run the Mac from its battery; reconnect after cooling. Native Apple limit remains unchanged. This is not silent fallback and is not labeled as equivalent to mechanism 1.

No SIP changes, forged/private entitlements, private API guessing, charge-controller key brute force, new dependencies or sleep/display policy changes. Do not replace the currently working native-limit backend merely to make its heat button available.

## Phase 1: supervised feasibility gate

- Before any write, show the exact operation/risk and obtain explicit approval for one cut/restore attempt. Require lid confirmed open, user present, saved work, sufficient battery reserve and known physical AC connection. No overnight test and no repeating loop.
- Read actual key value/type/length and current native limit. Unknown values or flags are not treated as enabled/disabled guesses. Confirm the exact command and safe restoration semantics before attempting a mutation; do not blindly reuse a full-byte write that may overwrite unrelated flags.
- Arrange a bounded independent restoration path before the cut. A primary-process defer alone is not recovery after a crash/SIGKILL. If restoration cannot be established safely, stop before the write.
- Perform at most one cut and restoration; collect read-only adapter/battery evidence, distinguish command acknowledgement from physical response, verify restored state and unchanged native limit. A failed or uncertain result ends the probe; no retries or automatic activation.
- Passing proves only one awake transition on this hardware/OS, not sleep/crash/overnight reliability. Failure keeps heat unavailable and leaves native limiting in place.

## Phase 2: proposed controller, only after the feasibility gate

- Explicit opt-in thermal adapter mode, default off, never enabled by an old persisted heat preference. UI explains temporary battery use and possible reconnect sound. Preserve the real native 80% setting.
- One serialized owner for actuator writes. No competing charge, temporary-discharge, calibration or sleep-hook loops. Native mode's current incompatible-operation rejection remains until ownership is explicitly designed and tested.
- Retain the user's saved temperature thresholds, without silently overwriting them. The current source defaults are 35°C pause / 32°C resume; earlier host notes record a user choice of 33/30°C, not a fresh read of today's configuration. Require finite, plausible, fresh sensor observations. Preserve existing finite threshold ranges: pause 20–60°C inclusive, resume at least 10°C and strictly below pause. Explicitly reject NaN/Infinity rather than relying on comparisons. These are configurable product thresholds, not medical/firmware safety guarantees.
- No periodic reapplication of an already satisfied actuator state. At least 60 seconds between automatic adapter transitions; a hot threshold alone cannot cause a cut/reconnect every 10 seconds. Critical recovery, user disable and low-battery restoration are not delayed by cooldown. Cooldown is a noise-control policy, not proof of thermal safety.
- Keep a minimum battery reserve: proposed restoration at 20%, refusal to begin a new adapter cut at or below 20%, and no rearm until reserve is above 25% with otherwise valid conditions. This sacrifices the custom pause to avoid draining the Mac; report that state explicitly. Thresholds are product policy, not firmware protection.
- Missing/stale temperature must not start a cut. If a held adapter can no longer be safely supervised, attempt controlled restoration and expose a fault instead of leaving battery power indefinitely. This differs intentionally from direct charge inhibition's fail-closed sensor rule.
- Actuator read/write/readback failures latch a visible fault and stop automatic transitions. Do not turn an error into retry chimes. "Paused" requires observed actuator state and sufficiently consistent power telemetry; a successful write alone is not enough.
- No-sleep prevention is outside this feature. Resume/wake, shutdown, disable, service crash and recovery require explicit state reconciliation and recovery ownership before unattended mode can ship. A userspace watchdog cannot provide a firmware guarantee; unresolved recovery blocks unattended activation.

## State and interface

Expose heat mechanism (direct/native-adapter/unavailable), enabled, requested pause, observed held/restored/unknown actuator, temperature and freshness, thresholds, cooldown, reserve/fault reason and last transition time. Preserve compatibility of existing fields; never conflate enabled, requested and verified paused.

Battery shows Heat protection as a real action only when usable. Detail states the mechanism and limitations. Unavailable/error/reserve states remain legible, not a generic success label. Do not change power-flow geometry or fabricate measured watts.

## Files and verification

Keep a pure, clock-injected policy separate from SMC effects. Candidate changes: pkg/daemon/thermal.go plus a focused thermal-adapter controller, compatibility/handler/status extensions, narrow validated pkg/smc adapter operations, and GUI capability/status handling. Preserve existing native lifecycle zero-write tests; add explicit opt-in tests rather than weakening those invariants.

Test first without hardware: hot/cool hysteresis; jitter; cooldown boundary; no repeated writes; minimum reserve/rearm; missing/stale/nonfinite sensor; unplug/replug; native-limit preservation; conflicting operation rejection; unknown key bits; read/write/readback errors; uncertain commands; user disable; shutdown/wake/crash recovery; restart with old heat-enabled config; and truthful requested versus observed status. Full Go/race/native suites and a build precede any daemon installation.

Separate administrator-approved installation with daemon/GUI/config backups is required. Do not deploy an untested hardware policy through a GUI-only update. Acceptance requires supervised transition/recovery evidence and a longer monitored run; do not claim overnight reliability from unit tests or one short probe.

Stop at the earliest failed hardware/recovery/permission gate. Done means verified real thermal control within clearly stated limits, not merely making the button visible.
