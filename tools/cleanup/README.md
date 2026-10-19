# Storage Review checks

From the repository root on macOS:

```sh
go test -race ./pkg/cleanup ./pkg/gui
go test ./cmd/batt -run TestStorageReview
clang -mmacosx-version-min=13.0 -framework Cocoa -framework ServiceManagement \
  -framework IOKit -framework QuartzCore tools/cleanup/TabTests.m pkg/gui/*.m \
  -o /private/tmp/wattnook-storage-tab-checks
/private/tmp/wattnook-storage-tab-checks
```

AppKit execution requires a normal host session. The harness stubs Go callbacks: it never scans user roots or changes sleep/charging. It checks third-tab navigation without a second window or automatic scan; Scan/Cancel/Rescan, category filtering, no automatic selection, partial/canceled/error/empty states, inline geometry, and stale updates after leaving/reopening or closing the popover. Optional argument `/private/tmp/storage-fixture.png` captures the synthetic 400×532 dashboard, not the desktop. The previous separate-window harness was replaced by this tab integration harness.

Scanner tests use temporary directories only, including metadata-only counting, hard links, skipped FIFO/symlinks, a directory replaced by an outside symlink, injected cross-device metadata, inaccessible paths, cancellation/deadline/limits, sort and escaped paths. Invalid UTF-8 is tested at the lossless presentation boundary because this host refuses the raw invalid-name fixture. These checks do not prove behavior of every network/mounted filesystem or instantaneous cancellation of a blocked OS call.
