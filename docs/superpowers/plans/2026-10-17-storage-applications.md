# Storage Applications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an application-first Storage tab with explicitly confirmed, unprivileged Trash operations and no system-cache cleanup.

**Architecture:** Extend the existing bounded cleanup scanner with trusted application inventory and an independently tested mutation policy. A narrow AppKit adapter supplies bundle/signature/running-state metadata and native Trash; the existing generation/coalescing bridge drives the replacement Storage composition. No charging-daemon changes.

**Tech Stack:** Existing Go, Objective-C/AppKit, macOS 13 deployment floor; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-17-storage-applications-design.md` (approved).

## Global Constraints

- Preserve the 400×532 shell, 24-point content margins, native SF typography and semantic colors; application rows are 44 points.
- Preserve Liquid Glass, palettes, Battery/System, power flow, charge control and Keep Awake.
- Discovery: /Applications and current-user Applications, one vendor-directory level, at most 200 app records. Retain scanner caps: 30 seconds, 100,000 entries, depth 32, 200 results.
- Explicit scans/selections/confirmations only; no background scans, new permissions, root operations, permanent deletion, Trash emptying or destructive CLI flags.
- Only uniquely identified third-party app bundles and exact mapped current-user cache directories; exclusions and partial-coverage rules in the spec are mandatory.
- No real user applications/caches removed in tests. No commits or push without a new request.

## Review Focus

1. Replaced target/root between review and Trash: reject or safely stop; unrelated files survive (Task 2).
2. Duplicate/spoofed identity or unknown signature: never removal-eligible, even when large (Task 1).
3. App starts running after confirmation: no move; normal-quit instruction (Task 2).
4. Cancel/navigation/double click around a pending operation: one actual operation, no stale confirmation or lost outcome (Tasks 2–3).
5. Partial scans, denied/full Trash and long names/TB sizes: truthful eligibility/error/copy and unclipped layout (Tasks 1–3).

### Task 1: Trusted inventory and cache eligibility

**Files:** Create `pkg/cleanup/applications.go`, `pkg/cleanup/applications_test.go`, `pkg/gui/native_cleanup_apps.m`; modify `pkg/gui/native.h`, `pkg/gui/native.go`.

**Interfaces:** Define `AppIdentity { Path, BundleID, Name string; Device, Inode uint64; ThirdParty, Running, Resolved bool }`, `AppEntry { Identity AppIdentity; Size Observation; Eligible bool; Reason string }` and `AppInventory { Entries []AppEntry; Partial bool; Reason string }` in cleanup. Produce `DiscoverApplications(ctx context.Context, home string, limits Limits, inspect func(string) (AppIdentity, error)) AppInventory` and `EligibleCache(apps []AppIdentity, bundleID string, observation Observation) (bool, string)`. Native metadata uses a bounded JSON C bridge `char *WattInspectStorageApplication(const char *path)`; caller frees the result. Cache running state is not a durable authorization.

- [ ] RED: add `TestDiscoverApplicationsBoundaries`, `TestDiscoverApplicationsIdentity` and `TestEligibleCache`; assert max 200, one vendor level, cancellation, malformed bundles, Apple/self/helpers/symlinks/duplicate IDs excluded, partial/unknown sizes never cleanable, unrelated files unchanged.
- [ ] Run `go test ./pkg/cleanup -run 'TestDiscoverApplications|TestEligibleCache'`; expect missing-interface/test assertion failures, not fixture setup failure.
- [ ] Implement inventory with anchored no-follow traversal, existing budgets and off-main-thread metadata inspection; native adapter resolves real bundle identity/signature without guessing from names. Size work remains explicit; logical sizes are not reclaimed bytes.
- [ ] Run the focused tests then `go test ./pkg/cleanup ./pkg/gui`; expect PASS. Preserve existing read-only CLI tests and behavior.

### Task 2: Confirmed Trash boundary

**Files:** Create `pkg/cleanup/trash.go`, `pkg/cleanup/trash_test.go`, `pkg/gui/native_cleanup_trash.m`, `tools/cleanup/TrashTests.m`; modify `pkg/gui/native.h` and `pkg/gui/native.go`.

**Interfaces:** Produce `TrashSelection { ID string; Generation uint64; App AppIdentity; Target Observation; Device, Inode uint64; Cache bool }`, `TrashResult { ID, TrashURL, Error string; Moved bool }`, and `ConfirmTrash(ctx context.Context, selection TrashSelection, currentGeneration uint64, move func(context.Context, TrashSelection) TrashResult) TrashResult`. Native adapter consumes the pinned identity and returns a single native macOS Trash outcome; never accept only a row index/path string as authorization.

- [ ] RED: add `TestConfirmTrashIdentityAndGeneration`, `TestConfirmTrashRunningState`, `TestConfirmTrashSingleFlight` and native `TrashTests` covering concurrent root/target replacement, moved/missing targets, denied/full/unavailable Trash, cancellation, double click and navigation after operation start. Assert no unrelated fixture moved/deleted, no fallback delete and no automatic retry after uncertain outcome.
- [ ] Run `go test ./pkg/cleanup -run TestConfirmTrash`; expect FAIL before implementation. Compile/run the new native harness against temporary fixtures only; establish the attack test fails against a deliberately path-only adapter.
- [ ] Implement final anchored identity/running-state validation and native Trash boundary. **Security stop gate:** demonstrate the final operation cannot recycle a substituted target; preceding lstat/canonicalization alone does not satisfy this. If the native operation cannot meet that boundary, keep mutation disabled with an explicit reason and report the blocker, rather than shipping a race or inventing a guarantee. Do not add privilege/authorization changes.
- [ ] Run focused Go/native tests and `go test -race ./pkg/cleanup ./pkg/gui`; expect PASS. Preserve the OS result/Trash URL even after navigation; expose restoration instructions and state that Trash still occupies disk space.

### Task 3: Application-first native tab and verified handoff

**Files:** Modify `pkg/gui/cleanup.go`, `pkg/gui/cleanup_test.go`, `pkg/gui/native.go`, `pkg/gui/native.h`, `pkg/gui/native_bridge.m`, `pkg/gui/native_cleanup_view.m`, `tools/cleanup/TabTests.m`; update `DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md`, `docs/storage-review-progress.md` from verified output.

**Interfaces:** Preserve `newStorageAdapter` and existing read-only scan actions. Add typed `storageCommand { Generation uint64; Action, SelectionID string }` and `(*storageAdapter).applicationAction(storageCommand)` for discover/scan/select/review/confirm/cancel/back. Bridge stable IDs and generation, not row indices; deliver inventory/detail/confirmation/result snapshots through existing coalesced main-queue delivery. Use Task 1 inventory and Task 2 policy; mutation remains disabled if Task 2's gate fails.

- [ ] RED: extend adapter tests for coalescing, canceled confirmation, stale results and navigation while moving; extend TabTests for initial/list/search/detail/running/confirmation/error/result, large units/names and no automatic scan. Assert 400×532 shell, 24-point margins, 44-point rows, one primary action per state, no separate window or system-cache/logs cleanup.
- [ ] Run `go test ./pkg/gui` and existing TabTests harness; expect new assertions FAIL against the diagnostic table.
- [ ] Read Impeccable craft-floor immediately before edits. Replace only Storage composition with Applications/Application caches, real icons, compact scan state, search and inline detail/back; show exact path and app-only/cache-only consequences at confirmation. Keep partial sizes/coverage truthful and move diagnostics into detail.
- [ ] Run `go test ./...`, `go test -race ./pkg/cleanup ./pkg/gui`, native Storage/dashboard/Keep Awake window/status harnesses and `git diff --check`; expect PASS. Compile harnesses using existing Cocoa/ServiceManagement/IOKit/QuartzCore flags; dashboard requires an explicit output directory even with CHECKS_ONLY.
- [ ] Perform one batched synthetic native state inspection and at most one correction/confirmation round. Complete Impeccable's isolated finish review/documentation; record compositor/runtime limits rather than claiming fixture Glass is live evidence.
- [ ] Build GUI, then install only with a backup, lid-open check and required narrowly scoped filesystem approval. Do not restart daemon or alter Keep Awake/native 80% limit. Record executable hash, tests, installed state and any blocked mutation boundary; no user-file cleanup as a smoke test.

## Handoff

Self-review: spec sections map to Tasks 1 (inventory/exclusions), 2 (mutation/lifecycle) and 3 (composition/verification). Execution approved, Native selected. Task 1 complete; Task 2 blocked at its atomic mutation gate. Task 3's read-only UI subset is implemented, independently reviewed, regression-tested and installed; mutation/confirmation tests and removal are not claimed complete. See `docs/storage-review-progress.md` and `.superpowers/sdd/2026-10-17-storage-applications/progress.md` for exact rulings, RED/GREEN evidence and current runtime state.
