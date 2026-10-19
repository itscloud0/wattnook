# Read-only Storage Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver on-demand cache/log size inspection through an independent native review window and CLI, without deletion or power-control interaction.

**Architecture:** A shared unprivileged Go scanner reads metadata using descriptor-anchored Darwin traversal. A single-flight session delivers bounded snapshots to a separate AppKit window through the existing main-queue bridge. CLI uses the same scanner and bypasses daemon initialization.

**Tech Stack:** Existing Go 1.24.5, Cobra, golang.org/x/sys/unix, AppKit/Cgo. No new dependencies.

**Spec:** `docs/cleanup-read-only-design.md` (approved).

## Global Constraints

- Only the current user's `Library/Caches` and `Library/Logs`; reject root execution. Production exposes no arbitrary-root flag.
- Metadata only. No Delete/Clean/Trash/Finder action, content reads, admin requests, network, daemon calls, report persistence or background scans.
- One worker; cooperative deadline 30 seconds, 100,000 entries, depth 32, 200 top-level observations. Stream directory entries in batches of 64.
- No symlink traversal or filesystem crossing. Deduplicate regular files by device/inode; reject size overflow. Partial coverage must stay visible.
- Logical lengths are observations, not allocated/exclusive/reclaimable space; scanning is non-atomic.
- AppKit progress at most five times per second, coalesced by session ID; always deliver terminal status. Closing cancels and releases retained results.
- Six consumers, native Glass popover, charge daemon, Keep Awake, permissions, config and entitlements remain unchanged. No app installation/restart or Git commit/push in this plan.

## Review Focus

1. Closing and reopening while a scan exits must never attach stale results to the new window (Task 2/4 tests).
2. Directory names containing invalid UTF-8, newlines or control characters must not break JSON, terminal layout or path identity (Task 1/3/4 tests).
3. Directory replacement during traversal must not follow symlinks, open special files or read outside a root (Task 1 tests).
4. A huge directory or multiple Start clicks must not allocate unbounded entries, workers or queued AppKit callbacks (Task 1/2 tests).
5. Unavailable roots and cancellation must not appear as a complete zero-byte success, including in CLI exit/report semantics (Task 1/3/4 tests).

---

## File boundaries

- `pkg/cleanup/types.go`, `scan_darwin.go`, `session.go` plus matching tests: filesystem observations and lifecycle, no GUI or power imports.
- `cmd/batt/storage_review.go`, `storage_review_test.go`; registration in `main.go`: CLI only.
- `pkg/gui/cleanup.go`, `cleanup_test.go`: Go session adapter. Minimal bridge additions in `native.go`, `native.h`, `native_internal.h`, `native_bridge.m`; teardown hook in `native_menu.m` if needed.
- `pkg/gui/native_cleanup_window.m`: dedicated window, table, path details, explicit actions. One Settings entry in `native_popover.m`.
- `tools/cleanup/WindowTests.m`: fixture-only native acceptance; callback stubs added to existing native test harnesses as required by linking.
- README/PRODUCT: verified user workflow and handoff after checks.

### Task 1: Bounded metadata scanner

**Interfaces:** `Root{Path, Category string}`; `Limits{Timeout time.Duration; MaxEntries, MaxDepth, MaxResults int}`; `Progress{Visited uint64}`; `Observation{Path, Category string; Bytes uint64; Complete bool; Skipped, Errors uint64}`; `RootStatus{Path, State, Reason string}`; `Report{State, Reason string; Observations []Observation; Roots []RootStatus; Bytes, Visited, Skipped, Errors uint64; StartedAt, FinishedAt time.Time}`. JSON fields use lower camel case. States: complete, partial, canceled, error. Root states: complete, missing, inaccessible, rejected, partial.

Produces `DefaultLimits() Limits`, `UserRoots(home string) ([]Root, error)` and `Scan(ctx context.Context, roots []Root, limits Limits, progress func(Progress)) Report`. `Scan` is synchronous and owns no goroutine; callers own scheduling. Zero limit fields mean defaults, negative values are rejected with an error report.

- [ ] Write temporary-tree tests: two files of 3 and 5 bytes aggregate to 8, zero-byte file remains valid, categories/path identities preserved, root missing is not complete. Watch `go test ./pkg/cleanup` fail before implementation.
- [ ] Add tests for root/child symlinks, directory replacement, hard links, special files, unreadable paths and overflow helper. Mutate a temporary child to an outside symlink at the internal directory-open seam; assert no outside bytes counted. Tests must not traverse real user roots.
- [ ] Implement descriptor traversal using existing `unix.Openat`, `unix.Fstatat(..., AT_SYMLINK_NOFOLLOW)`, `unix.Fstat` and `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`. Anchor root ancestry without following symlinks. Read directory metadata in batches of 64, not `WalkDir`/whole-directory `ReadDir`. Open directories only, never regular-file contents. Recheck the opened directory identity/device before descending. Always close descriptors on cancellation/error.
- [ ] Add device-boundary tests through a narrow metadata seam, depth 32 boundary, 100,000-entry bound via small injected limits, 200-result cap, cooperative deadline, pre/mid-scan cancellation and stable final sort (bytes descending, path ascending). If enumeration stops early, document that the retained subset reflects filesystem enumeration order; never imply globally largest directories were found.
- [ ] Preserve exact path bytes internally. Include a lossless base64 path field for invalid UTF-8 paths in JSON, readable escaped display text separately; do not normalize the actual identity. Test control characters and invalid UTF-8 fixtures. Bound error strings/counts, no per-file error list.
- [ ] Run `go test ./pkg/cleanup` and `go test -race ./pkg/cleanup`. Complete reports require every root fully traversed; all unavailable roots produce error, mixed unavailable roots produce partial. Missing/inaccessible entries never become measured zeroes.

### Task 2: Single-flight lifecycle and bounded delivery

**Interfaces:** `Snapshot{ID uint64; Running bool; Progress Progress; Report *Report}`; `NewSession(scan func(context.Context, func(Progress)) Report, notify func(Snapshot)) *Session`; methods `Start() bool`, `Cancel()`, `Close()`. Notify runs off the AppKit thread; adapters dispatch to main. Session generations are monotonically increasing; snapshots are immutable. `Close` is idempotent and permanently ends that session.

- [ ] Write failing tests using a controlled scanner: second Start returns false, Cancel reaches its context, Close cancels, no notification after close, terminal report delivered despite throttled progress. Wait for deterministic channels, not arbitrary sleeps.
- [ ] Implement one worker with no pending-start queue. Throttle ordinary progress to 200 ms using time checks during scanner notifications, not a permanent timer. Keep at most one pending main-thread delivery slot in the GUI adapter; a final state replaces a pending progress snapshot, never the reverse.
- [ ] Add close/reopen and canceled-worker tests: no new worker until the previous one exits, old generation never updates a new view. Closing clears bounded reports; worker completion after close cannot re-retain them in the window/controller.
- [ ] Run session tests with `-race -count=20`. Verify terminal notifications for complete/partial/canceled/error, and no stale result after close.

### Task 3: Daemon-independent CLI

**Interfaces:** `NewStorageReviewCommand() *cobra.Command`, with internal constructor `newStorageReviewCommand(scan func(context.Context) cleanup.Report, uid func() int) *cobra.Command` for fixtures. Flags: `--json` only. Root resolution uses `os.UserHomeDir` plus `UserRoots`; no arbitrary root path or destructive flags.

- [ ] Write command tests with injected reports and buffers: complete output, valid single JSON document, partial/canceled/error state and exit error, root execution rejected before scanner invocation. Newlines/control characters in paths must be escaped in text output, never interpreted as terminal controls.
- [ ] Register command in `main.go`. Override its inherited `PersistentPreRunE` to initialize logging only, not API compatibility/version or hardware. Test through `NewCommand` with a nonexistent daemon socket; scanner fixtures still succeed. Ensure help/capability handling does not hide the command.
- [ ] Implement human output with category, observed size, bounded path display and explicit non-atomic/logical-size caveat. `--json` serializes `Report` once to stdout; diagnostics use stderr. Use signal-derived command context for Ctrl-C, canceling without a second worker. Partial/canceled reports are printed before a nonzero return.
- [ ] Run `go test ./cmd/batt` and scanner tests. No actual user-directory scan in tests.

### Task 4: Native review window and adapter

**Interfaces:** add `batt_menu_show_storage_review(BattMenuRef)`, `batt_menu_storage_update(BattMenuRef, uint64_t generation, const char *json)` and exported Go `battStorageAction(uintptr_t handle, uint64_t generation, int action)`; actions start=1, cancel=2, close=3. Native controller owns window generation; Go adapter owns one worker/session and a coalesced delivery slot, rejecting stale generations on both sides. Reuse existing `runOnMain` for AppKit mutations.

- [ ] Write failing Go adapter tests with controlled scanner/dispatch functions for double Start, delayed callbacks, close/rescan/reopen and final-before-progress ordering. No native handle should be used after controller teardown.
- [ ] Build the isolated AppKit harness with synthetic JSON to assert idle/running/complete/partial/canceled/error/empty, table count, long/selectable path, compact large sizes, missing roots and visible snapshot caveat. Press Scan/Cancel/Rescan and close; assert action IDs/generations, not real filesystem activity.
- [ ] Read Impeccable Operate/craft-floor before UI edits. Implement a separate resizable native window with default 640×480 pt, minimum 520×400, native scrollable table and full path/detail area. Scan only after explicit button activation; no checkbox selection-for-removal. Status banner distinguishes coverage/error/canceled. Use existing semantic SF text, accessibility identifiers/labels and native focus; no new palette or popover redesign.
- [ ] Add `Storage review…` in Settings without overlapping existing controls (adjust only settings geometry). Closing cancels and releases results. Escape/Command-W close; Tab/Return/Space operate buttons. No Delete/Clean/Trash or Finder action.
- [ ] Update all native fixture callback stubs for the new exported symbol; run existing dashboard and Keep Awake harnesses plus new window harness. Inspect one fixture-only capture batch at minimum/default size, then at most one correction round. Do not screenshot the desktop or scan the user's files.

### Task 5: Verify and hand off

- [ ] Run `go test -race ./pkg/cleanup`, full `go test ./...`, all touched native fixture harnesses and `go build -o /private/tmp/WattNook-storage-review ./cmd/batt`. Record existing warnings and any unavailable live counters accurately.
- [ ] Run `git diff --check`; review only this feature's diff against the existing dirty tree. Confirm no daemon/SMC/PowerUI/Keep Awake behavior, permissions, dependencies or file-write/removal path was introduced.
- [ ] One fresh code reviewer checks scanner boundaries/lifecycle and native acceptance against this spec; resolve material findings with tests. Do not launch a second broad design exercise.
- [ ] Update README/PRODUCT with actual commands, exclusions, partial-size semantics, verified tests and install status. No commit/push, real-directory scan, destructive action or app restart. Stop with the tested read-only build and explicit next safe handoff.

## Plan self-review

All spec sections map to Tasks 1–5. Production root restrictions and privileged-process refusal belong to Task 1/3 and GUI adapter. Snapshot and session signatures are shared between Tasks 2/4; only the final native JSON adapter depends on AppKit. Five Review Focus conditions have explicit tests. Exact path identity is separate from display/JSON text. Cooperative I/O cancellation and partial enumeration are limitations, not falsely promised guarantees. No cleanup/removal implementation is authorized.
