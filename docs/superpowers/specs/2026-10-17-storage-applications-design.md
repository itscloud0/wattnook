# Storage: applications and third-party caches

Status: specification and [implementation plan](../plans/2026-10-17-storage-applications.md) approved; Native execution selected. Application-first read-only review implemented and installed; Trash blocked at the atomic identity/operation boundary, not claimed complete. Verified state: [Storage ledger](../../storage-review-progress.md).

## Goal

Replace the rejected diagnostic-looking Storage page with an application-first native interface. Let the user review third-party application caches and move explicitly selected applications to Trash without touching macOS caches, personal documents or application databases.

## Approved direction and boundaries

- Storage remains the third top-level destination in the existing popover. No second Storage window. Preserve Liquid Glass, palettes, Battery/System, power flow, charge control and Keep Awake.
- Application list is the content: actual application icons, names and tabular sizes, readable 44-point rows, search and inline detail/back navigation. No raw-path table header, diagnostic paragraph stack or empty oversized preview area.
- Within Storage, two destinations: Applications and Application caches. No global "clean everything" button or automatically selected entries. Logs are not a separate cleanup category in this version.
- Preserve the 400×532 shell, 24-point content margins, native SF typography and semantic colors. On a normal desk/night-use Mac, match the existing dark/Glass popover rather than introducing a marketing-site visual language. Use Impeccable Operate conventions; Taste's website-specific layout/motion rules do not apply to AppKit.
- Each state has one clear primary action: Scan, Cancel, Review selected, or Move to Trash. Scan status is compact; technical paths/errors/coverage are available in inline detail, not permanently occupying the main list.

## Applications

- Discover app bundles only within /Applications and the current user's Applications directory. Bounded traversal: immediate app bundles and one vendor-directory level, at most 200 app records. No whole-disk scan or symlink traversal. Report partial discovery explicitly.
- Recognize bundles by metadata, not filename alone. Exclude Apple-signed/system applications, symlinks, unresolved identity, embedded helpers and WattNook itself from removal. Do not treat a third-party-looking display name as evidence of ownership.
- Opening Storage does not recursively calculate sizes. An explicit scan performs bounded metadata-only size observations using the existing cancellation/budget patterns; unknown/partial sizes remain unknown/partial. Read-only discovery and scanning run off the AppKit thread with one worker and bounded main-queue updates.
- A row shows icon, display name and measured/unknown size. Detail shows exact application path and a clear statement: only this application bundle will be moved; its settings, documents and databases stay in place.
- The user selects a specific app and confirms its name and exact path. Revalidate root, bundle identity and running state immediately before moving it. If running, ask the user to quit normally and retry; never force quit.
- Use the macOS Trash operation in the unprivileged GUI process. No recursive rm, root helper, silent authorization, permanent deletion or automatic emptying of Trash. If access is denied or Trash is unavailable, fail visibly; do not fall back to deleting. Applications requiring a vendor uninstaller can retain helpers: do not claim complete uninstallation.

## Application caches

- Scan only exact current-user Library/Caches children mapped to a uniquely identified installed third-party app. Do not expose all Library/Caches children as cleanable.
- Exclude Apple/system-service identities, ambiguous or duplicate bundle identifiers, unknown directories, symlinks, shared/group containers and paths outside the anchored cache root. Exclusions remain excluded even if large.
- No /System, /Library, system caches, browser profiles, Application Support, Preferences, Containers/Group Containers, Documents, Downloads, mail/Photos databases, backups, swap, APFS snapshots, development assets, models or VM/container disk images.
- Cache presence or size is not proof of disposability. Detail identifies the app and path and warns that caches may need rebuilding. A running app's cache cannot be cleaned; ask the user to close it normally first.
- Cleaning is a separate explicit selection and confirmation, then Trash. Do not bundle cache removal with app removal. Incomplete or inaccessible cache observations are review-only, never automatically eligible for cleanup.
- First version does not find "leftovers" by fuzzy application-name matching or delete configuration/data. These are separate future features, not hidden defaults.

## Mutation, lifecycle and failure safety

- The charging daemon has no role in discovery, scanning or Trash. No extra permissions, dependencies, persistent reports, watchers or periodic/background scans.
- A confirmation pins target path plus device/inode identity, app identity and scan generation. Cancel, selection changes, rescan or navigation invalidate pending mutations. Reject changed identities, symlink/root substitutions and running-state changes; never execute an old UI selection by row index.
- Canonicalization alone is not a safe delete primitive. Implementation must define the final identity/anchoring check at the Trash boundary and test concurrent replacement. Do not claim an atomic scan-to-Trash guarantee from a preceding lstat; any unresolved race blocks that mutation path from shipping.
- One operation at a time. After a Trash request has started, report its actual outcome even if navigation changes; never reissue an uncertain operation automatically. Record only a bounded in-memory result including resulting Trash URL where macOS supplies it.
- Report per-target success/failure, refresh the list, and explain restoration from Trash. Do not promise recovered disk bytes: Trash still occupies storage, and APFS shared/purgeable space differs from observed logical sizes.

## Implementation boundaries

- Extend pkg/cleanup with typed trusted-app inventory, eligibility and selection/revalidation policy. Keep existing read-only CLI behavior; do not add destructive CLI flags.
- Keep AppKit bundle/signature/running-app/Trash APIs in a narrow native adapter; policy and filesystem tests use temporary fixtures. No new external dependency.
- Update pkg/gui/cleanup.go and its native bridge for inventory, selected stable IDs and explicit review/confirm actions. Preserve coalescing, cancellation and stale-generation rejection.
- Replace the composition in native_cleanup_view.m rather than touching Battery/System behavior. Refresh actual design documentation from the verified result, not from intended appearance.

## Verification and stop condition

Test first: Apple/system/unknown exclusion; duplicate identity; non-bundle .app name; nested bundle/helper; self-removal; symlink roots/children and replacements; replaced inode; moved/missing targets; app begins running after selection; denied access; full/unavailable Trash; canceled confirmation; double click; navigation during a pending operation; partial sizes; large names/units; cancellation and stale results. Real fixtures must prove unrelated files survive. No real user's apps or caches are removed for testing.

Run the full Go suite, cleanup/GUI race checks and native dashboard/Storage/Keep Awake harnesses. One batched native inspection of initial/list/detail/running/error/confirmation states, at most one correction/confirmation round, then independent Impeccable finish review and truthful documentation. Build and install only verified GUI code with backup and lid-open checks; do not restart the charge daemon.

Done means a working, truthful application-first Storage UI with tested selection/Trash safety, or a clearly named boundary blocking mutation. It does not mean a mock cleanup button, full vendor uninstallation, guaranteed recovered space or a fixed heat backend.
