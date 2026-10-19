# AlDente charge backends — static investigation, 2026-10-17

## Outcome / scope

**2026-10-19 correction:** the earlier preferences-only probe did not reproduce the complete shipped `hold` path. A newly traced hold-only continuation invokes a short CHIE pulse **after** writing/notifying the defaults, then restores CHIE. That is materially different from keeping the adapter disabled throughout a thermal pause. Its physical charge-only outcome on this Mac remains unverified; the earlier negative test must not be presented as a test of this complete sequence. See the new static follow-up below.

Partially answered. AlDente 1.39.4 contains a preferences-based charge-limit backend in addition to PowerUI and SMC backends. The categorical claim that macOS 27 removed every third-party route is not supported. Conversely, release support does not establish that every backend works on this host, or that a persisted limit immediately stops battery charging. **Latest result: the single authorized preferences probe did not pause charging within its 60-second observation window; restoration verified. See final section.**

During the initial static pass, no AlDente executable/helper was launched or installed and no SMC/preference writes or physical test occurred. The subsequent explicitly approved preferences probe is recorded below. WattNook's installed heat protection remains unavailable; the existing pure thermal policy is not integrated.

## Artifact identity and evidence

Official release: https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/releases/tag/1.39.4 . Official `AlDente.dmg` downloaded from that release, 12,208,798 bytes; SHA-256 `b2634ae47f5f860fa75f5be0a9ae89b136dbb514003800ed256873f437aa701b` matched GitHub's asset digest.

REA archive inspection: `ev_cf8276cfb20bc2b7d69c25eb8817a7156088126dd30acfb7d8077558099e9a0c`; inventory `ev_389af76ce95d059ab206f76232e8b0b625c9dd1f5c38767fa05390ec84034bd5`. DMG extraction was unsupported; used an owned read-only mount instead. Arm64 slices made with `lipo` for static analysis:

- Main SHA-256: `2d5e9e6d099c838e97564ecc18f9c8110b6a9e14eb4abd8aa44fec3bc527bb0c`.
- Helper SHA-256: `07c67bf3c3811a9ddb979cc374942847da63b360a3512c82b3b441944b2a2e21`.
- REA helper dispatch metadata: `ev_547111bdcc497283b47f9acdd4cf59c99dfe2b2b1118c3b00063496783b8e3ec`; saved `/private/tmp/aldente-helper-dispatch.json`.

The following assembly observations are from shell `otool -ov/-tvV`, **not** successful REA decompilation or runtime evidence. Main assembly retained at `/private/tmp/aldente-main-disasm.txt`; ObjC/Swift metadata at `/private/tmp/aldente-main-objc.txt`. Addresses refer only to the main arm64 hash above.

## Findings

1. Metadata identifies `LegacyIntelSMCBackend`, `TahoeSMCBackend`, `GoldenGateSMCBackend`, `PreferencesBackend`, `PowerUIBackend`, and `BackendResolver`. Names alone do not establish availability.
2. GoldenGate assembly at `0x10022cd4c` onward constructs `bfD0`, `bfE0`, `bfF0`; availability at `0x10022d37c` checks required-key/helper state and can return keys-unavailable. This is not evidence of an alternative to those firmware-gated keys on this Mac.
3. PowerUI diagnostics explicitly restrict hold/MCL targets to 80–100. The shipped localization also explains that some selected methods cannot support targets below 80. WattNook's current `pkg/powerui` uses that limited framework route.
4. `PreferencesBackend` has `domain`, `notifyName`, `powerUIBackend`, and `previousIntent` fields. Its hold branch at `0x100224dc4` uses a supplied target or integer current battery percentage, then calls the defaults path at `0x1002255e4`. That path clamps the target to 1–100 at `0x100225624–0x100225634`; this is an **app-side range**, not a confirmed OS-supported range.
5. The preferences path serializes an NSNumber as a property list (`0x100226918` onward), passes domain/key/data through helper dispatch, logs PowerUI activation and defaults-notification results, and performs readback. Exact per-backend key list and eligibility flag initialization remain unresolved. Do not implement a writer by guessing them.
6. A related charge-limit path constructs domain `com.apple.smartcharging.topoffprotection`, keys `enabled`, `mclLimitValue`, and `MCLFeatureState`; see `0x1001fe9b4–0x1001fef54`. It references notification `com.apple.smartcharging.defaultschanged`. This does not prove all these keys are the complete sequence for `PreferencesBackend` on macOS 27.
7. REA helper dispatch confirms selectors `readDefaultsWithDomain:key:user:host:withReply:` (`0x1000040a0`), `writeDefaultsWithDomain:key:value:user:host:withReply:` (`0x1000041fc`), and `removeDefaultsWithDomain:key:user:host:withReply:` (`0x100004374`). It does not by itself prove their implementation's preference scope or OS acceptance.
8. Shipped localization warns that macOS can take minutes to reflect an applied charge state. Configuration readback is not proof of immediate thermal inhibition. Missing `/Library/Preferences/com.apple.smartcharging.topoffprotection.plist` on this host does not establish the absence of other CFPreferences scopes.

## Analysis limitations / next step

REA/Ghidra main analysis failed: initial search exceeded 180s startup; a focused GoldenGate function request with 330s startup also returned `Analysis failed`. No successful main pseudocode result, no invented Evidence ID. Do not repeat full-main analysis unchanged; use a bounded smaller target/provider or retained static assembly. Existing analysis tools only; no dependencies installed.

## Follow-up: eligibility and helper resolved

- Independently checked assembly at `0x10007ec0c–0x10007ec68`: `NSProcessInfo.operatingSystemVersion` gates the preferences flag on versions later than 26.3. Metadata identifies `HardwareManager.mbModel` (offset global `0x100505a20`); availability checks that flag plus helper connectivity. This is an application heuristic, not an OS guarantee.
- PreferencesBackend constructor at `0x10021d524–0x10021d550` confirms the same topoffprotection domain and defaultschanged notification. Static array at `0x1005094a8` contains the cleared keys `checkpoint`, `currentState`, `MCLTempDisabledUntilDate` (the third long string resolves to `0x100478020`, not mclLimitValue). It then writes NSNumber target to `mclLimitValue`, and NSNumber 1 to `MCLFeatureState`, `isEngaged`, `isManuallyChargeLimited`, posts a Darwin notification, and reads back. Hold optionally activates MCL; an already enabled MCL is not activated again.
- REA helper wrapper `ev_b989fad0b3920e19009c089df32e68683f00ae634bcc83ce2587dedabda37b68`, internal implementation `ev_97992d7a4b127d93db493908f47f38fb0445664f2a9594cb29f178ed9dc095bc`: property-list deserialization, CFPreferencesSetValue and CFPreferencesSynchronize. Artifacts `/private/tmp/aldente-helper-write-defaults.json` and `/private/tmp/aldente-helper-cfprefs.json` retain complete records. Decompiler has imperfect Swift types; corroborated nil-user/nil-host defaults in helper assembly (`0x10000656c`, `0x1000067d8`): CurrentUser / AnyHost. Since helper is root, CurrentUser means root, not logged-in user.
- Compiled and ran investigation-only `/private/tmp/wattnook-charge-prefs-readonly-20261017.m` with administrator-approved read. Host macOS 27.0.1 build 26A434. User and AnyUser scopes empty; root CurrentUser/AnyHost has mclLimitValue=80, MCLFeatureState=1, enabled=false. Other queried flags absent. No synchronization, notification or setter in that diagnostic. `enabled=false` is not evidence native MCL is disabled: independent root PowerUI read returned limit=80, enabled=1.

## Supervised probe prepared, not run

User explicitly approved one temporary below-current limit and restoration, with open lid/saved work; no CHIE operation or automatic mode. Throwaway feasibility source `/private/tmp/wattnook-charge-once-20261017.m`, binary of the same basename. Not product code, not installed, not committed. It reuses WattNook's native bridge only in read mode.

Preconditions: root; confirmed physical AC AND actively charging; valid percentage with >=30% reserve; existing enabled native 80% limit. No MCL enable/disable/set calls. It saves all eight touched/relevant keys (including legacy enabled) to a root-owned 0600 plist under a new 0700 temporary directory. An independently exec'd watchdog validates that snapshot, requires explicit arm/ack after the parent's physical recheck, restores on parent completion/death or 90s deadline, verifies preferences and native limit. Before arming, EOF/timeout does not write. Deadline stops its still-attached probe parent before restoring so a suspended parent cannot later apply stale writes. Sampling is read-only, at most 60 seconds, no retry loop.

Independent review found an unarmed EOF path unnecessarily rewriting settings. Fixed with separate arm/ack protocol; added EOF/arm/timeout socket selftests. Follow-up identified EINTR misclassification and unchecked waitpid; fixed using a monotonic absolute poll deadline, EINTR retry and checked child wait. Added a real SIGALRM-interrupted-poll selftest. Final clang build and `--selftest` passed. This is not SIGKILL/physical-restoration acceptance.

**No live test or power preference mutation performed yet:** repeated IOKit reads reported ExternalConnected=false, IsCharging=false, battery 41→39%, negative current. CHIE read remained 00; no SMC writes. `pmset` reported AC once, but raw adapter details FamilyCode=0 and eight repeated physical-AC reads remained false. Asked user to connect power; do not infer a cable or WattNook root cause from these readings. A pause cannot be demonstrated from an already discharging baseline. Root read confirmed the native 80% limit is still enabled. Session stops pending physical charging; do not consume the authorized single transition on a non-charging baseline.

Next: once physical charging is confirmed, finish probe safety review and run the single authorized transition. Distinguish preference/readback from physical current and sustained AC; restore original state regardless of result. Do not wire defaults readback straight into the policy's synchronous physical-acknowledgement contract. No automated cut/restore loop or overnight experiment.

## Single authorized live probe — completed, negative result

After the user confirmed connecting power, read-only IOKit baseline reported external AC=true, charging=true, battery=38%. Selftests reran successfully. Ran `/private/tmp/wattnook-charge-once-20261017 --apply-once` once under normal administrator authorization; no other apply invocation or retry.

- Original native MCL: 80%, enabled=1. Saved eight-key root preference snapshot to `/private/tmp/wattnook-charge-once.QVv4kz/snapshot.plist` before any mutation (root-owned 0600 in private 0700 directory).
- Independent watchdog acknowledged arming; target=36%. One preferences sequence synchronized successfully and posted the Darwin notification. No SMC/CHIE writes and no native MCL setter/enable/disable calls.
- Twelve samples over approximately 60s: external AC=true and IsCharging=true in every sample; current +2930 to +3399 mA; battery increased to 40%. Thus **no physical pause observed**. This window does not prove no delayed response could ever occur.
- Independent root read during the test found `mclLimitValue=80`, MCLFeatureState=1 and temporary flags isEngaged=1/isManuallyChargeLimited=1. PowerUI also read 80%, enabled=1. The requested lower value did not remain authoritative. Which process restored/clamped it is unresolved; do not attribute that write to macOS or WattNook without tracing it.
- Watchdog restored once on normal parent completion, verified saved preferences, then native limit=80/enabled=1. Process exit 0 means restoration/transport completed, **not** pause success. Separate subsequent root read confirmed mclLimitValue=80, enabled=false (legacy preference), MCLFeatureState=1, temporary flags absent; PowerUI limit=80/enabled=1, actual charging=true. No adapter disconnection observed in sampled telemetry.
- Narrow `powerd` log search over the last four minutes for MCL/topoffprotection produced no matching messages. This is not proof of absence of a powerd action.

Run log: `/private/tmp/wattnook-charge-once-20261017-run.log`, SHA-256 `bc05e4db90b0c37b457be7d8dd0cb0bc0e451ddc5d3b79398e2396dea88aca88`. Probe binary SHA-256 `97bc62b4a3d49ff388e3745bb3184d949d167d3ef8387db4cdd536c4d16bd9cd`. No daemon/GUI install, product backend activation, commit or push. Backup retained for recovery; no cleanup deletion.

Stop condition reached for the authorized single test. Do not repeat mutation, extend into unattended mode, weaken the native advertised limit checks, or describe heat protection as fixed. Next investigation must distinguish the overwritten preference writer/remaining AlDente platform behavior using read-only evidence; a further live experiment needs its own scoped approval.

## Hold-specific CHIE pulse — static follow-up, 2026-10-19

The old temporary artifact and assembly files were no longer present. Restored the **same** official 1.39.4 DMG once, verified the published DMG digest above, and extracted the arm64 main slice again; SHA-256 still `2d5e9e6d099c838e97564ecc18f9c8110b6a9e14eb4abd8aa44fec3bc527bb0c`. Did not install or launch AlDente. Shell evidence (not new REA Evidence IDs): `/private/tmp/aldente-main-arm64-20261019`, `/private/tmp/aldente-main-disasm-20261019.txt`, `/private/tmp/aldente-main-objc-20261019.txt`. Earlier full-main Ghidra failures were not repeated.

- Swift metadata identifies `HeatProtect` at class metadata `0x1004fdc68`, with temperature/hysteresis-related methods around `0x10007efdc`. Its async continuation at `0x10007f5dc–0x10007f66c` passes a hold-shaped intent (`w3=0x41`) to the shared `BackendResolver` entry `0x10021de10`. Which eligible backend is selected on a particular running Mac still needs runtime evidence; class names alone do not establish that choice.
- In `PreferencesBackend`, the hold branch `0x100224dc4–0x100224f10` chooses an explicit target or truncated current percentage, then calls `0x1002255e4` with `w1=1`. The charge/discharge branch passes `w1=0`. That boolean is saved at async state offset `0x138`.
- After the previously documented preferences writes and Darwin notification, `0x100225d50–0x100225d9c` checks that boolean. Hold continues into **`0x10022638c`**, a step omitted from the previous probe. Charge/discharge skips this step.
- This continuation checks helper/platform pointers and the CHIE availability table at `0x100509448` (one entry, string `CHIE`, expected size 1). Its signed relative async pointer at `0x1003fc4b0` resolves to `0x10022ae1c`, which reads/checks expected key data length. On an unavailable key it logs a skipped pulse and returns.
- On success, `0x100226654–0x100226674` bridges the `CHIE` key and sends **`setSMCByteWithKey:value:` with value `8`** through ObjC stub `0x1003e6ea0`. Stub selector reference `0x1004f4a20` resolves to string `0x1004a2766`, confirming the selector rather than inferring it from logging.
- The log literal says **100 ms**, but the actual Swift sleep argument at `0x1002266a4–0x1002266c0` is **`0x1dcd6500` nanoseconds = 500 ms**. Use the instructions, not the stale log wording. This is a requested wait; helper/IPC latency and actual physical interruption duration were not measured.
- Normal continuation `0x100226808–0x100226844` sends the same selector/key with value **`0`**, restoring adapter input. The sleep-error continuation releases its error and reaches the same restoration block through `0x100227978`. This is static normal/error control-flow evidence, not proof of recovery after process death, a confirmed SMC write, or actual paused charging.

**New candidate:** defaults hold + notification + one short CHIE `08`/`00` pulse, with AC retained afterwards. This could explain why the preferences-only probe was insufficient, but it does not yet establish why the requested target returned to 80, that the pulse fixes that rewrite, or that the complete sequence works on this firmware. No license/SIP/entitlement bypass, new hardware mutation, production build/install or automatic mode activation in this follow-up.

**Next gate:** an independently restored, separately authorized one-shot test of this exact sequence. Require an open lid, saved work, stable AC and active charging baseline, a private snapshot of the touched preferences, one pulse only, independent bounded recovery of both adapter and preferences, and post-pulse AC/charging/current observations. Native-limit readback alone is not success. At the latest read-only sample, the Mac was already at 80% on AC with zero current/not charging due to its existing Apple 80% limit; that is **not a usable causal test baseline** and must not be called a successful custom thermal pause. Keep the existing limit and adapter restored pending the new test scope.

Subsequent approved guarded attempt: [complete-hold probe preparation and baseline outcome](thermal-pause-progress.md#complete-hold-probe-preparation-and-guarded-baseline-attempt--2026-10-19). Native 90% was temporarily verified but the Mac did not resume active charging in the 20-second baseline window. Actor aborted before both the preferences hold and CHIE pulse; independent recovery verified original preferences and native 80%. The complete physical hold question is still unresolved, not disproven by this aborted baseline.
