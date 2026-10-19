# Native dashboard checks

Native-charge checks additionally verify advertised 80/85/90/95/100 snapping, explicit 100, unavailable-state editability, and deferred main-thread completion. Fixture menu items are installed explicitly; the harness does not call PowerUI setters. Go tests cover rejected values, readback mismatch, failed reads, timeout single-flight behavior, sequential reads and disabled/native-100 semantics. The optional `WATTNOOK_NATIVE_READ_ONLY=1` PowerUI smoke test only reads actual host settings.

From the repository root, on macOS with Xcode command-line tools:

```sh
clang -mmacosx-version-min=13.0 \
  -framework Cocoa -framework ServiceManagement -framework IOKit -framework QuartzCore -framework Security \
  tools/power-flow-preview/dashboard.m pkg/gui/*.m \
  -o /tmp/wattnook-dashboard-preview
/tmp/wattnook-dashboard-preview /tmp/wattnook-dashboard-renders
```

The harness uses illustrative app/power values, not the daemon. It renders Battery in seven power states, unplug/updating transitions, SSD used/free storage, System sorted by CPU, memory and disk, empty telemetry, settings and all four palettes. It checks tab changes, the keyboard charge-limit callback, saved menu-bar combinations (including the reachable-icon guard), coherent unplug snapshots, rate-counter resets, invalid timing, idle traffic, and Core Animation start/stop (respecting Reduce Motion). It also reads real internal-drive counters through IOKit and samples per-process diagnostics. It never sends daemon commands or quits another app. A test window briefly opens for the animation check.

On macOS 27, menu-bar checks compare 54 rendered level/state combinations pixel-for-pixel with the installed Apple BatteryUIKit renderer and retain its natural 26×14 pt size. Additional checks cover unknown versus absent battery, service status without watt telemetry, persistent VoiceOver state, passive colored-image hit testing, vibrancy opt-in, and overlay bounds across metric/icon settings and both appearances. Set `WATTNOOK_MENU_ICON_PREVIEW=1 WATTNOOK_CAPTURE_PREFIX=menu-icon` to capture eight fixture states in each appearance without toggling host charging or Low Power Mode. Cached status-button captures prove geometry/artwork, not the live menu-bar compositor's wallpaper contrast. Incompatible private APIs fall back; this host check intentionally requires the expected renderer on macOS 27.

`main.m` is the older isolated power-canvas renderer. Link it with `native_power_flow.m`, `native_preferences.m`, Cocoa and QuartzCore; do not compile both harness main files into one executable.

AppKit execution needs a normal host session. In a restrictive automation sandbox, compile there but launch the test with narrowly scoped host permission.

Current fixtures use a 400×532-point shell and 220 pt power canvas. Checks cover full-width destinations, six consumer rows, independent diagnostic hit areas, column centers, hidden unavailable heat/Settings explanation, and Keep Awake/Glass geometry across supported↔unsupported transitions. `WATTNOOK_CHECKS_ONLY=1` skips captures but still requires the directory argument; missing it exits 2 and an empty log is not a passing test. `WATTNOOK_CAPTURE_PREFIX=compact` limits captures to Battery, split/merge, System, Settings, History and unavailable heat; `redesign` retains the previous capture set. Native Glass cached images have transparent backgrounds and prove layout only, not live compositor contrast.

System checks additionally cover independently saved CPU/RAM/disk units, compact byte formatting through TB, unit promotion on rounding, unavailable swap, actual host swap sampling, and metric/app-row width assertions for 3 TB. CPU absolute values are core equivalents, not byte counts; app disk rates do not claim device utilization percentages.

Stability checks regress the CPU button's former -1 tag (NSRangeException), perform 300 CPU/Memory/Disk switches, reject invalid sort indices, and assert six consumer rows with a readable Swap line. Pure CPU conversion checks cover Apple Silicon and 1:1 timebases plus reset/zero-duration samples; a 250 ms single-thread busy loop checks live process CPU near one full core. The monitor includes its own PID without a Quit action. This short smoke test is not a long-term leak or energy test.

CPU presentation checks normalize raw per-core usage by the logical processor count (234 → 23.4% on ten cores), while preserving 2.34 occupied core equivalents. Tests cover single/multiple-core hosts, unavailable counts, zero usage and invalid values, and assert both displayed lines in a native consumer row. Sampling/sorting still use raw per-core usage internally.

Context-row checks assert column alignment (processes under CPU, swap under Memory, free storage under Disk), unchanged six-row consumer list and compact free-space values in GB/TB.

Set `WATTNOOK_CHECKS_ONLY=1` to run assertions without generating preview images. Label checks cycle every saved unit mode and assert arrow-free captions with the Change units tooltip preserved.

Design-polish checks assert quiet Quit controls retain their hit areas, initial consumer detail text is at least 10.5 pt, and System captions align centrally. `WATTNOOK_CAPTURE_PREFIX=polish-` limits captures to four fixture-only Battery/System views in graphite and Glass. Cached Glass renders do not reproduce the system compositor backdrop; actual material appearance needs host visual acceptance.

Monitoring checks cover the 90-sample history bound, ten-second throttling, invalid readings and clock rollback; pressure labels; history navigation; and off/on/off lifecycle (timer, history and process counters released). The harness draws the chart without generating artifacts in checks-only mode. Keep Awake tests also assert that unknown status preserves an active display guard and that the local event journal evicts older entries after 64 events. Test executables have no bundled helper and cannot activate the real lid guard. Sleep/wake delivery, overnight Remote access and sustained energy/memory use still require host acceptance.

For a narrow visual review, `WATTNOOK_CAPTURE_PREFIX=monitoring-` (without checks-only) writes just settings and illustrative four-series history renders. Pressure/History controls also have non-overlap assertions. No full desktop screenshots are captured.

The harness also checks rail hit-testing beneath the static Limit label at 20% and 80%, the battery-percentage gap and the SSD used setting. Screen off / Dark Work has been removed. Keep Awake policy checks (without changing sleep settings):

Battery fixtures also cover `IsCharging=false` with positive sampled current and `IsCharging=true` with zero sampled current. The system flag controls the charging icon/status, independently of estimated watt-flow geometry. GUI power snapshots now refresh every ten seconds and on menu open, not on the two-second System stats timer. These fixtures do not prove the cause of real AC/Battery reconnections.

```sh
swiftc -parse-as-library -Onone tools/keep-awake/Policy.swift tools/keep-awake/Tests.swift -o /tmp/wattnook-keep-awake-tests
/tmp/wattnook-keep-awake-tests
clang -framework Cocoa -framework IOKit tools/keep-awake/LidTests.m pkg/gui/native_lid.m -o /tmp/wattnook-lid-tests
/tmp/wattnook-lid-tests
```

These check valid, missing, malformed and duplicate SleepDisabled telemetry, the fixed non-interactive sudo command boundary, saving/restoring brightness, duplicate close handling, unavailable/invalid readings and preserving already-restored brightness. They do not write hardware brightness. The packaged helper's `--status` reads macOS without changing settings or asking for permission. Administrator cancellation, actual closed-lid brightness/CLI continuation and remote desktop availability require manual acceptance; never infer those from policy tests.

Async status and sleep-blocker checks:

```sh
clang -mmacosx-version-min=13.0 -framework Cocoa -framework ServiceManagement \
  -framework IOKit -framework QuartzCore tools/keep-awake/StatusTests.m pkg/gui/*.m \
  -o /tmp/wattnook-status-checks
/tmp/wattnook-status-checks
clang -fno-objc-arc -framework Cocoa -framework IOKit \
  tools/keep-awake/AssertionTests.m pkg/gui/native_assertions.m -o /tmp/wattnook-assertion-checks
/tmp/wattnook-assertion-checks
```

The status harness launches controlled copies of itself to test nonblocking UI, single-flight reads, freshness before toggling, timeout (including a child that closes stdout but keeps running), oversized/invalid output, and unknown-state guard retention. Simulated toggle/guard effects never change host sleep/brightness. Add `--live` for a separate read-only host smoke test of actual `pmset -g` and the public assertion API. Assertion fixtures cover filtering, aggregation, deterministic ordering, report bounds, real newlines and omission of private activity details. These tests do not prove overnight availability.

Keep Awake detail-window checks:

```sh
clang -mmacosx-version-min=13.0 -framework Cocoa -framework ServiceManagement \
  -framework IOKit -framework QuartzCore tools/keep-awake/WindowTests.m pkg/gui/*.m \
  -o /tmp/wattnook-window-checks
/tmp/wattnook-window-checks
```

The dashboard harness checks the direct info button, its independent action/hit area and the width of the On label. The window harness checks nonmodal reuse, cached status/errors, real minimum-size layout, report scrolling/selection, keyboard bindings, owner teardown and late asynchronous snapshot cleanup without changing sleep, brightness or clipboard contents. It invokes the read-only public assertion API for lifecycle checks but never prints process details. Set `WATTNOOK_WINDOW_PREVIEW_DIR=/tmp/wattnook-window-preview` to render fixture-only light, dark and minimum-size error content for visual acceptance. Tests are not a substitute for real overnight Remote acceptance.
