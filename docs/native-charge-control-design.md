# Native Apple charge control in WattNook

Status: implemented, tested and installed locally on 2026-10-16. Scope: charge-control compatibility only; cleanup is a separate task.

## Outcome

On firmware where SMC charging keys are unavailable, WattNook reads and changes Apple's native charge limit instead of silently displaying an unenforced saved limit. Preserve legacy and firmware behavior on supported machines. Never implement automatic adapter toggling as a charging fallback.

The user has approved enabling Apple's 80% setting; independent PowerUI reads confirmed it. Installing a new daemon must preserve that setting. No SIP changes, private-entitlement signing, new dependencies or global sleep changes.

## Approach

Add a native mode to the existing charge-control selection, with an isolated PowerUI adapter. Keep the existing API routes and number-shaped GET /limit response; extend capabilities with optional supported-limit and heat-protection information. Existing clients may ignore the optional fields, but server-side validation remains authoritative.

Alternatives rejected: forcing SMC calls cannot overcome the observed privilege denial; adapter-mode fallback deliberately cuts wall power and conflicts with the user's charging-cycle concerns. Launching System Settings for every operation avoids private API calls but does not provide reliable integrated state/control.

PowerUI is a private framework, not a stable public API. Validate runtime availability and method ABI before dispatch, perform blocking work off the GUI thread, serialize operations and bound RPC waiting. Timeout/failure is unavailable state, never success, zero or a reason to toggle the adapter. A timed-out in-flight write may still complete: do not blindly retry it; require a fresh read before another mutation. No per-request unbounded worker creation.

## State ownership and operations

1. Prefer usable existing SMC modes; otherwise probe native support and advertised values. Failed probes expose unsupported state. Do not assume macOS version or hardcode a writable range solely from research.
2. In native mode, the system setting is authoritative. Startup, shutdown, restart and passive monitoring do not set/disable the limit. Do not periodically reapply stale /etc configuration or overwrite a user's System Settings edit.
3. A native limit change validates membership in the advertised list, writes once, and reads back. Report success only after agreement. A mismatch or readback failure reports uncertainty and triggers refresh, not an automatic rollback or repeated writes.
4. GET /limit and GUI state read the system setting in native mode; propagate read failures as errors/unavailable. Never fall back to the old saved number as though it were enforced. The persisted config remains historical for SMC modes; document that distinction in native mode rather than silently rewriting it on reads.
5. Expose available choices (currently 80/85/90/95/100 on this Mac) through capabilities. Snap UI changes to advertised values, show a native-mode label and reject invalid values server-side, including values submitted by older clients.
6. Native setting 100 means native limiting disabled. Treat an explicit user request for 100 as a mutation; never use it as a shutdown reset or error recovery action.
7. Custom heat protection is unavailable in native mode. Reject activation through the daemon; show "Heat protection unavailable" with an explanation in the UI. Preserve saved preferences for a future compatible backend, but do not show them as active. Apple's own temperature management is distinct.
8. Native mode initially rejects temporary disable schedules, lower-limit delta, calibration and manual forced adapter discharge. Do not silently round, degrade or leave an old schedule armed. Existing scheduled-disable state must be reported as inactive/unsupported and must not write a native value. Native mode does not apply legacy sleep hooks or MagSafe control.
9. On shutdown, native mode does not reset charging or enable/disable the adapter. Existing legacy/firmware cleanup remains as before. Keep Awake and display/lid guards are outside scope.

## Files and boundaries

- New `pkg/powerui/`: narrow read/advertised-values/set interface plus Objective-C runtime bridge, with bounded connection/error handling and mockable Go policy. Do not import upstream wholesale or introduce dependencies.
- `pkg/compatibility/compatibility.go`: native mode and additive capability fields. Preserve old-mode interpretation for old daemons.
- `pkg/daemon/compatibility.go`, `daemon.go`, `handlers.go`, `loop.go`: select backend, expose actual values, gate native-incompatible operations and keep native settings unchanged during lifecycle events. Extend their existing tests; avoid unrelated control-loop refactors.
- `pkg/client/`, `pkg/gui/controller.go` and the narrow native bridge/popover/rail files: consume actual limit, advertised choices and explicit unsupported heat state. Keep the established design and avoid new animations or sampling timers.
- Existing CLI entry points: reject unsupported actions consistently; no new privileged shell commands or authorization bypass.
- README, PRODUCT and native harness notes: document backend differences and verified installation state.

## Verification and installation gate

Write failing tests first for native selection and old-backend precedence; absent framework/ABI/timeout errors; advertised values and invalid requests; read/write/readback failure; changes made externally in System Settings; and unavailable heat state. Native-mode tests must assert zero SMC/adapter writes on startup, passive loops, schedule restoration and shutdown.

Run the full Go suite and native AppKit harness. Extend UI tests for discrete values, stale/unavailable limits and heat capability, without touching host settings. Build before installing. Use the real host only for read-only support/state checks until an explicit installation step; do not cycle actual charge limits to exercise tests.

Installation must preserve separate backups of daemon and GUI, record the existing native state, and use normal macOS authorization for privileged replacement. Verify API native mode, actual 80% readback and no adapter transitions attributable to the install. If authorization fails or state is uncertain, stop and leave the system-managed 80% setting alone. Do not claim a sustained physical cutoff or overnight acceptance from configuration readback alone.

Done: integrated native state/control, truthful heat capability, full tests/build, and a verified install or explicit installation blocker. No Git publication unless requested. Cleanup scanner implementation is not part of this completion criterion.

## Implementation verification — 2026-10-16

- Independent PowerUI bridge, no new dependencies: validates framework/class/method ABI, handles Objective-C errors/exceptions, uses an autorelease pool and a one-time framework load. Native writes have no SMC/adapter fallback.
- Controller allows one in-flight operation and a three-second wait. A stalled call cannot accumulate workers; a late write may still finish, so results are explicitly uncertain and every later change starts with a fresh read. Sequential-read regression and `go test -race ./pkg/powerui` pass.
- Daemon selects native only after SMC modes are unavailable. Native API validation, failed reads, external setting changes, expired legacy timer, passive maintenance, heat rejection and shutdown guards are tested with no SMC connection. Historical config is not rewritten by native limit changes.
- GUI native reads/writes run asynchronously with AppKit-main-thread completion. Unknown state removes the editable marker; choices snap to advertised values, including explicit 100. Hidden heat controls explain unavailability. CLI status reads the effective native limit rather than describing native control as a disabled adapter or legacy charging gate.
- Full `go test ./...` passes (the CLI integration fixture needs host permission for its own temporary Unix socket). AppKit dashboard checks pass without screenshots; they cover discrete choices, unknown state and asynchronous main-queue dispatch. Existing compiler warnings about category implementations, duplicate libraries and deployment targets remain.
- Read-only live smoke tests in user and root contexts: native limit 80, enabled true, available [80 85 90 95 100]. Configuration readback is not proof of a physical stop at 80 or overnight behavior. No host limit cycling used for tests.

## Installed state

- GUI `~/Applications/WattNook.app/Contents/MacOS/WattNook` and daemon `/usr/local/libexec/batt-thermal/batt-thermal` both match SHA-256 `15d85285d0c81d68401828401785cec0e28314acd40ce414316a24f707e0dfdd`. Verified running PIDs 90052 / 89075 (ephemeral).
- GET `/compatibility`: chargingControl true, mode native, adapter/sleep/MagSafe/calibration false, advertised limits [80,85,90,95,100]. GET `/limit`: 80. GET `/heat-protection`: disabled, not paused, explicit unavailable error. No native setter was called during installation.
- Backups: `/private/tmp/wattnook-native-charge-backup.BoC0Ya/daemon`, `WattNook`, `daemon.plist`, `config.json`. Original daemon SHA `8ddac17c0b9338b31bfc5b8f93cabba274c9b7dd00c248c4bac517f8b0b1bc06`; original GUI SHA `5f18c1ce78055930b1bab9f9af8f4b83da26d6dd3f3fe5c17ee84d5f20198b16`.
- Initial service registrations failed because bootout had not completed: launchd logged error 37, Operation already in progress. Restored original binary/service, then completed installation with a bounded six-second teardown interval. This was not a signing/security-policy refusal; no security settings or plist policy were changed. The old daemon's normal shutdown logged an adapter-enable CHIE=0; no adapter-disable command was used. Native daemon startup at 00:33:49 +04:00 reports adapterControl=false and does not reset SMC on shutdown.
- GUI replacement was performed only with lid confirmed open; Keep Awake helper, lid guard and sleep settings were not changed. No physical charge-cutoff/overnight acceptance or live-pointer UI acceptance claimed. Git not committed/pushed.
