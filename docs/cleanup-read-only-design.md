# Read-only storage review — design for approval

Status: design approved by the user on 2026-10-16. No scanner or cleanup action implemented yet. Implementation-plan review is next.

## Goal and acceptance

Provide an on-demand view of storage occupied by user cache/log directories, with cancelable scanning and understandable results. This is investigation, not a promise that any file is safe to remove. No removal, selection-for-removal, privilege elevation or background scanning in this phase.

Success: open Storage review, explicitly start a scan, see directory/path/observed size/reason, cancel or rescan, and understand incomplete coverage. The existing Battery/System popover, charge control and Keep Awake retain their behavior.

## Options and decision

1. Shared Go scanner with native AppKit review window and a CLI entry point — recommended. One bounded scan implementation, deterministic filesystem tests, existing Go-to-AppKit main-queue bridge. A small native results adapter is required.
2. AppKit-only scanner — fewer bridge additions, but duplicates a future CLI path and moves filesystem rules into the UI layer.
3. CLI-only first release — smallest deliverable, but does not deliver the requested in-app review experience.

Use option 1 without new dependencies. Keep scanning in the unprivileged GUI/CLI process, not the charging daemon. REA informs the review/cancellation direction; no proprietary CleanMyMac code, resources or exact behavior is copied or claimed.

## Initial scope and labels

- Only the current user's `Library/Caches` and `Library/Logs`. No whole-disk scan, user-supplied arbitrary root, external volume or root/admin scan.
- Aggregate each immediate child into one result, including a direct regular file. Read metadata only, never file contents.
- Reason labels identify the source: `User cache directory` / `User log directory`; explanation states that presence or size does not establish disposability. Do not label the sum `reclaimable` or `safe to clean`.
- No Documents/Downloads, browser profiles, mail/Photos databases, backups, swap/VM, APFS snapshots, AI models, Xcode developer trees or OrbStack/Docker disk images. This phase never removes anything, including cache/log data belonging to a running app.
- Roots missing or inaccessible are reported separately. Do not request Full Disk Access or admin access automatically.

## Scanner contract and limits

New `pkg/cleanup` package owns typed scan options, directory observations and summary. Its API accepts a context and trusted root descriptors; production callers supply only the fixed roots above. Tests supply temporary fixtures.

One worker per scan. A session owns cancellation and prevents concurrent start/rescan; no queue of pending scans. No subprocesses, privileged operations, daemon calls, persistent watcher, timer-driven scan, networking or disk report cache.

Stream directory entries in bounded batches; do not collect an entire directory or file tree in memory. Initial defaults: 30-second cooperative deadline, 100,000 visited entries, depth 32 and at most 200 top-level results. Hitting any bound ends traversal with an explicit partial report, not a successful complete total. Each result records its own incomplete state and skipped/error counts. Root/result ordering is deterministic; displayed results sort by observed size descending, then path.

Do not follow symlinks, including a root supplied through a symlink. Use root-anchored traversal where supported to prevent an entry replaced by a symlink from escaping the selected root. Do not cross filesystem devices; skip special files. Count each regular-file identity once across roots to avoid hard-link double counting. Validate size arithmetic against overflow. Zero-length files are valid observations; unreadable files are unknown, not measured zeroes.

Size means the sum of observed regular-file logical lengths, not allocated disk space, APFS exclusive usage or guaranteed recoverable space. Files may change during scanning; state that it is a non-atomic snapshot. Cancellation is checked between bounded filesystem operations; blocked OS I/O may delay cancellation and is not described as instantly interruptible.

Release traversal state when finished/canceled and release retained results when the review window closes. No file list retained by ordinary monitoring.

## Native review UI

New `native_cleanup_window.m` follows the existing independently opened Keep Awake details window pattern, but owns separate state and lifecycle. Entry point: `Storage review…` in Settings; do not add another main popover tab or clutter the Battery summary.

Use existing SF typography, semantic colors, palettes and native controls. Preserve the established Glass popover; the separate review window follows macOS window materials. Apply Impeccable Operate principles: readable hierarchy, one action per state, no decorative statistics or fake scan results.

- Idle: explain the two scan locations and the read-only guarantee; primary `Scan` button.
- Running: progress describes entries visited, not a fabricated percentage; `Cancel` replaces Scan. Other monitoring remains responsive.
- Complete: observed total and timestamp, table with directory, observed size and category; selected row reveals full selectable path and explanation. Rescan is explicit.
- Partial/canceled: retain bounded observations with a visible coverage banner and recovery action; never silently present them as complete.
- Error/empty: distinguish inaccessible roots, genuinely empty roots and no completed observations.
- Close: cancel the session, prevent stale callbacks from updating a closed/new window, release results. Escape/Command-W and keyboard/VoiceOver navigation work.

There is no Delete, Clean, Trash, auto-selection or Finder navigation action in this phase. Reports remain in memory; no automatic export of private paths. Updates enter AppKit only on its main queue, at most five per second, coalesced with a session identifier. The final update is delivered even when progress updates are throttled.

## CLI

Add `storage-review` under the existing Cobra root. Same fixed-root scan engine and budgets; no daemon required. Human-readable output is bounded and includes incomplete coverage, units and snapshot caveat. `--json` emits the typed summary once, without mixing progress on stdout. Ctrl-C cancels and reports partial state. No destructive flags.

## Files and isolation

- New `pkg/cleanup/` scanner/session tests; no SMC/PowerUI imports.
- New `cmd/batt/storage_review.go` and tests, root command registration only in `main.go`.
- New native window file and minimal declarations/callbacks in existing GUI bridge/controller/header; one Settings entry point.
- New focused native fixture harness for review states/lifecycle; preserve the existing dashboard and Keep Awake tests.
- README and PRODUCT handoff updated after verified implementation. No daemon/config/entitlement/dependency changes; no app restart or installation without a separate safe handoff.

## Verification and stop condition

Test first against isolated temporary trees: aggregation; empty/missing/unreadable roots (where host permissions permit); no content reads or writes; symlink roots/children and replacement escape attempts; hard links; device boundary via controlled traversal seam; depth/entry/result/time limits; cancellation; arithmetic overflow; partial results; deterministic ordering; repeated sessions and stale callbacks. Do not scan the user's real cache/log directories as a test fixture.

CLI tests run in-process with injected fixture roots and no daemon. Native tests cover idle/running/complete/partial/canceled/error/empty, long paths, large sizes, scrolling, keyboard actions and close/rescan lifecycle using synthetic data. Run scanner race tests, the full Go suite, native fixtures, GUI build and `git diff --check`. Visually inspect the review window once, with at most one batched correction round.

Stop after a working read-only scanner, native review and CLI, with tests and handoff. Actual removal is a separate feature requiring a threat model, explicit user selection, revalidation and recovery policy; this design does not authorize it.
