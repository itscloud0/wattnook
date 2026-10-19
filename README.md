<p align="center">
  <img src="tools/app/WattNook-Icon.png" width="88" alt="WattNook app icon">
</p>

<h1 align="center">WattNook</h1>

<p align="center"><strong>Know what powers your Mac. See what slows it down.</strong></p>
<p align="center">Battery control · CPU, memory & disk diagnostics · One native menu-bar app</p>

<p align="center">
  <a href="LICENSE"><img alt="GPL-2.0 license" src="https://img.shields.io/badge/license-GPL--2.0-526B80"></a>
  <img alt="macOS 15 and later" src="https://img.shields.io/badge/macOS-15%2B-526B80">
  <img alt="Native AppKit" src="https://img.shields.io/badge/UI-native_AppKit-526B80">
  <img alt="Experimental source build" src="https://img.shields.io/badge/status-experimental-D99A38">
</p>

<p align="center">
  <a href="#your-mac-at-a-glance">Overview</a> ·
  <a href="#make-it-yours">Customize</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#why-this-is-a-fork">Origins & license</a>
</p>

> [!IMPORTANT]
> **Experimental source build — no signed release or one-click installer yet.**
> Charging requires a compatible privileged `batt-thermal` daemon. Do not run a second charging daemon alongside it. Power readings are approximate macOS telemetry, not wall-meter measurements.

## Your Mac at a glance

WattNook answers two questions: **what is happening to my battery?** and **what is using my Mac?** Keep a charging limit, watch temperature, find a resource-heavy app and request a normal Quit without opening several utilities.

<table>
  <tr><th>Battery</th><th>System</th></tr>
  <tr>
    <td><img src="docs/images/battery.png" width="360" alt="WattNook Battery view with charge limit, animated power ribbon, system summary and storage bar"></td>
    <td><img src="docs/images/system.png" width="360" alt="WattNook System view with CPU, memory and disk metrics and sortable app list"></td>
  </tr>
</table>

<sub>Native AppKit renders of the implemented UI. Values are illustrative, not live measurements. The screenshots are static; power-flow highlights animate in the app.</sub>

Power flows use a continuous rounded split/merge and a traveling highlight, active only on the visible Battery page and disabled by Reduce Motion. System metrics still switch units on click; their captions now omit the decorative arrows.

- **Control charging.** Supported SMC backends offer custom limits and thermal pause/resume thresholds. On Macs where macOS blocks those keys, WattNook uses Apple's native charge limit: the rail snaps to the system's available choices (currently 80/85/90/95/100). Custom charge-only Heat Protection on gated macOS 27 firmware is still being verified; adapter disconnection is not a substitute for stopping battery charging while retaining AC power.
- **Follow the power.** Adapter, battery and Mac have distinct paths for charging, held, battery-only and hybrid power. Labels stay outside the ribbons. One local battery snapshot refreshes every ten seconds and when opening the menu; daemon power readings no longer overwrite it. Charging status uses the system charging flag when available, not just the sign of sampled current. Transitions show “updating” instead of fabricated zero-watt loads. This does not establish or fix the cause of intermittent adapter reconnections.
- **Find the heavy app.** System shows six consumers sorted by CPU, resident memory or disk read + write rate. Attributed helpers are grouped with their apps; accessible background processes and WattNook itself are included. Normal Quit requires confirmation and is available only for eligible apps, not background processes or WattNook.
- **See pressure and recent trends.** System shows macOS memory pressure separately from RAM occupancy. Optional 15-minute history tracks CPU, memory, estimated Mac power and disk throughput, entirely in memory.
- **Understand storage.** Battery shows used/free space and a capacity bar. System separates internal-drive read/write MB/s from storage occupancy.
- **Keep work running with the lid closed.** Keep Awake toggles macOS system sleep. While WattNook runs, its lid guard dims the built-in display on closure and restores brightness on opening. This is not guaranteed electrical panel shutdown. No input monitoring or repeated screen-sleep requests.

Charge-control reads with an unexpected SMC payload length return an error instead of being interpreted as “disabled”; the affected control cycle stops before making a decision from that reading. At the daemon's Debug log level, SMC write attempts and their success/failure include the key and requested value. Reads remain at Trace level, so ordinary monitoring does not add a continuous debug log stream. These checks improve diagnostics and error handling; they do not establish that intermittent USB-C reconnections are fixed.

### Native charging limits

Apple native mode reads the actual system setting, not the historical limit in the daemon's config file. It never reapplies that file on startup, polling or shutdown. Setting 100 explicitly disables native limiting. Temporary disable timers, custom charge-limit hysteresis, forced discharge and calibration are unavailable in this mode. macOS may occasionally charge fully for battery estimation; this is not an unconditional hard cutoff. The integration validates a private PowerUI API at runtime and can become unavailable after a macOS update. Changes run off the UI thread, are serialized and require readback; uncertain results are not silently retried.

Heat Protection is offered only by the legacy backend that actually runs the battery-charge thermal gate. Native and firmware limit backends must not advertise it. The former experimental thermal-adapter mode cuts AC input and uses the battery while hot, which does **not** meet the charge-only requirement: new native Enable requests are rejected, saved activation flags are retired, and the native loop can only recover a previously owned adapter hold. Clients no longer opt into adapter disconnection. That controller's source remains for recovery and investigation, not as a working charge-only feature. A separate one-shot investigation of a preferences hold plus a short adapter pulse has not yet established a physical charge-only pause on this firmware. Apple's native 80% limit remains usable independently. See the [current thermal status and installation limits](docs/thermal-pause-progress.md). Keep Awake controls sleep separately.

## Make it yours

Open the gear in the popover:

- Choose **Blue, Mint, Violet or Amber**. The accent, ribbon and graphite surface update together.
- On **macOS 26 or later**, choose **Glass** for system Liquid Glass behind the navigation and primary actions, with the system accent color. Older macOS versions keep the existing palettes. Based on [Egor's contribution (#2)](https://github.com/itscloud0/wattnook/pull/2), adapted to Keep Awake and older build SDKs.
- The 400×532-point overview uses Battery/System/Storage navigation, an unboxed charge reading without a duplicate battery glyph, and separate charge-limit, energy-flow and action lanes. Unavailable Heat protection is explained in Settings instead of occupying a disabled Battery tile; Keep Awake expands into that space. System captions sit above values, with processes, swap and free storage beneath their respective columns; full-width CPU/Memory/Disk filters lead to six consumer rows. Settings groups Appearance, Menu bar and Monitoring. Native Glass and the animated power flow remain; Quit stays secondary with hover and keyboard-focus feedback. Menu-bar text and battery use system-adaptive monochrome template rendering, independently of the popover theme.
- Show any combination of **CPU load, RAM used, SSD space used and battery percentage** in the menu bar. **SSD used** means occupied disk space as a percentage. Read/write throughput remains available in System.
- Keep or hide the battery icon. CPU-only, CPU + RAM, battery percentage-only and other combinations are supported.
- On macOS 27, the battery glyph uses Apple's installed BatteryUIKit renderer at its native size, including charging, AC/not charging, low battery, Low Power Mode and service/missing-battery states. This private renderer is runtime-checked; older or incompatible systems fall back to installed Control Center artwork, then an unavailable symbol. No copied Apple artwork is bundled.
- Click each headline metric on **System** to independently cycle its saved units: CPU percentage/core equivalents, RAM percentage/used bytes, disk throughput/space-used percentage/used bytes. One aligned row adds context: **process count under CPU**, **swap used under Memory**, and **free space under Disk**. Consumer rows pair CPU percentages with core equivalents, RSS bytes with physical-RAM percentage, or separate disk read/write rates.
- Choices persist across restarts. Turning everything off retains the battery icon so the app stays reachable.
- Under **Monitoring**, disable **System monitoring** to stop its timer, process scans and history collection. Battery controls and Keep Awake remain independent. **Keep 15-minute history** is opt-in; disabling it releases the history buffer.
- Advanced battery controls remain one click away.

<details>
<summary>Preview settings</summary>

<img src="docs/images/settings.png" width="360" alt="WattNook palette and menu-bar customization settings">

</details>

## What the numbers mean

| Metric | Meaning |
| --- | --- |
| CPU load | Whole-system CPU busy percentage |
| App CPU | Percentage of total CPU capacity, on the same scale as CPU load; second line shows occupied / available core equivalents |
| Memory used | Physical memory usage estimate, not memory pressure |
| Memory pressure | macOS pressure level: Normal, Elevated or Critical; Unavailable when unsupported or inaccessible |
| App memory | Resident memory (RSS), including attributed helpers |
| Swap used | Current system swap occupancy from `vm.swapusage`; separate from RAM used and swap-file capacity |
| Disk MB/s | Internal-drive read + write throughput, decimal MB/s |
| App Disk | Per-process disk I/O rate across volumes, aggregated with attributed helpers; best-effort |
| SSD used / free | Storage occupancy, **not** an SSD utilization percentage |

Disk counters are sampled every two seconds. Unavailable or reset counters are shown as unavailable until a valid delta arrives; they do not become traffic spikes. Some apps' disk activity may not be attributable, and app totals need not match whole-drive totals.

Process scans run every two seconds only while the System app list is visible, or on an explicit diagnostics-menu request. They stop when the popover closes or another page is selected. CPU deltas convert Mach ticks using the host timebase; PID reuse resets the baseline. Both headline and consumer percentages use total CPU capacity as their denominator. For example, 2.34 occupied cores out of 10 means 23.4% CPU, with `2.34 / 10 cores` shown below. These are time-based core equivalents, not performance/efficiency-core-weighted computing power. The list is not a complete accounting of kernel/system CPU: macOS may deny access to some processes.

**System → History** uses a fixed 90-sample ring buffer (3.6 KB of sample data), sampled no more often than every ten seconds using the existing monitoring timer. It shows a 15-minute window, breaks lines across unavailable readings or long gaps, and does not store telemetry on disk. CPU/RAM charts use a 0–100% scale; power and throughput scale to the visible maximum. Memory pressure comes from macOS's `kern.memorystatus_vm_pressure_level`, not a fabricated RAM-percentage threshold; this is not a stable public API, so unsupported readings stay unavailable. Elevated pressure is indicated in the view; background workload notifications are not implemented.

## Read-only storage review

Open **Storage** and click **Scan**. The native page has **Applications** and **App caches** segments plus a case- and diacritic-insensitive name search. It inventories `/Applications` and `~/Applications` (one vendor-folder level, up to 200 results). App caches are limited to exact `~/Library/Caches/<bundle-id>` directories uniquely mapped to a third-party app, and are listed only after complete application discovery. Identity classification uses metadata and basic code-signing checks; it does not fully validate bundle resources.

Rows use macOS application icons and show observed logical size: partial measurements have a `+`, while unknown sizes say **Not measured**. Sizes are not guaranteed reclaimable space. Select an app and choose **Review** for its details, a selectable full path, and **Show in Finder**; **Back** returns to the list. The UI states **Read-only · Removal unavailable**. There is no automatic scan, automatic selection, Trash action, or system-cache cleanup. Scan/Cancel/Rescan run on demand; leaving Storage or closing the popover cancels and clears results.

The separate, legacy read-only CLI storage review is also available without the charging daemon. It still inspects only `~/Library/Caches` and `~/Library/Logs`; it is not the Applications/App caches GUI scan:

```sh
WattNook storage-review
WattNook storage-review --json
```

Run as your normal user, not root. File contents are never opened. Symlinks and special files are skipped; directory traversal stays on each root's device, and hard-linked files are counted once. Logical size is **not** allocated or reclaimable APFS space, nor a recommendation to delete anything.

CLI scans are bounded to 30 seconds, 100,000 entries, depth 32 and 200 result rows. Partial/canceled results are labeled; unavailable roots are not reported as empty. A capped result subset follows filesystem enumeration order and is then sorted by observed size—not a guaranteed global top-200. Files may change during the snapshot; cancellation waits for any blocking OS call. JSON includes a lossless `pathBase64` when a path contains invalid UTF-8. Incomplete CLI reports are printed before a nonzero exit.

## How it works

```mermaid
flowchart LR
    UI["WattNook · native AppKit"] --> OS["macOS · power & process counters"]
    UI <-->|"local Unix socket"| D["batt daemon"]
    D --> SMC["SMC · charging control"]
    UI --> H["Bundled Keep Awake helper"]
    H --> Sleep["System sleep setting"]
    UI --> Lid["Lid events · built-in brightness"]
```

The interface, local monitoring and Keep Awake helper live in one app bundle. The charging daemon remains separate because it needs privileges. No Electron UI and no new third-party UI dependencies.

## Why this is a fork

WattNook began as a public fork of [Charlie Chiang's batt](https://github.com/charlie0129/batt). Its charging control and daemon remain the foundation; the menu-bar UI, heat protection, system diagnostics, and Keep Awake controls are additions here. Git history and the original [GPL-2.0 license](LICENSE) are retained. This project is independent of AlDente and CleanMyMac; neither their branding nor proprietary UI code is included.

The CLI and daemon retain the `batt-thermal` name during this transition so existing charge-limit installations do not break. **WattNook** is the user-facing app name, and the repository is [`itscloud0/wattnook`](https://github.com/itscloud0/wattnook). It remains a fork of `charlie0129/batt` with the original Git history and GPL-2.0 license.

## Build from source

Requirements: Apple Silicon Mac, macOS 15+, Go, Swift compiler/Xcode command-line tools. Build a fresh app bundle from this checkout:

```sh
chmod +x tools/build-wattnook-app.sh
tools/build-wattnook-app.sh /tmp/WattNook.app
```

The script builds the UI, bundles the Keep Awake helper, and packages the app icon from [`tools/app/WattNook-Icon.png`](tools/app/WattNook-Icon.png). It **does not install or modify the privileged daemon**, create a login item, or change a charge limit. Those remain manual, machine-specific setup steps. The app expects the compatible daemon at `/var/run/batt-thermal.sock`; without it the UI cannot control charging. Do not use the upstream release links below as WattNook installers.

## Keep Awake and closed-lid work

The old Screen off / Dark Work feature has been removed after repeated re-sleep during unlocking. Keep Awake instead uses the macOS `pmset -a disablesleep` setting, the same mechanism documented for [Vorssaint's closed-lid mode](https://github.com/vorssaint/vorssaint-utils/blob/main/docs/PERMISSIONS.md). Implementation is independent; no Vorssaint source is copied. The helper first tries non-interactive `sudo` for exactly `/usr/bin/pmset -a disablesleep 1` or `0`. Without a matching permission, it falls back to normal macOS administrator authorization. On this development Mac the user explicitly approved a root-owned, mode-0440 `/etc/sudoers.d/wattnook-keep-awake` rule for those two commands only; this machine-specific rule is not bundled or automatically installed on other Macs. Any process running as the authorized user can execute those two sleep toggles, not just WattNook. No privileged daemon is installed. The button reads the actual system setting rather than a saved app flag, and a failed/cancelled request does not report success. The transport warning is acknowledged once rather than on every enable.

**This is system-wide, not a per-app assertion or timed session. It remains enabled after quitting WattNook. Turn it off explicitly before transport, especially before putting the Mac in a bag.** Keep the Mac ventilated, preferably connected to power. Do not toggle the same setting concurrently in another utility such as Vorssaint. Recovery from Terminal: `sudo pmset -a disablesleep 0`. WattNook does not automatically override other utilities' settings on launch or exit.

While Keep Awake and WattNook are running, an IOKit lid notification observer dims only the built-in display through hardware brightness control when the lid closes, then restores the saved level on opening or disabling the mode. It never sleeps the display repeatedly or intercepts keyboard input. A saved level survives a crash for recovery on the next launch; an already-restored/user-changed brightness is not overwritten. Notifications are removed when Keep Awake ends; no extra polling timer or separate watcher is added. Keep WattNook running for this lid behavior. The bridge uses private DisplayServices APIs and must be tested on your hardware: zero hardware brightness is **not a guarantee that the panel is electrically powered off**. External displays and keyboard lighting are untouched. WattNook does not change your display-idle timeout.

Local CLI tasks can continue while macOS remains awake, but remote desktop/computer-use workflows may depend on an unlocked session or an available display. Closed-lid behavior, administrator cancellation and actual remote workflows require manual testing on your Mac; unit tests do not prove those hardware conditions. Keep Awake does not unlock the Mac or change charging settings. Existing screenshot images predate this button replacement. Removing the optional rule requires administrator authorization; first turn Keep Awake off, then remove only `/etc/sudoers.d/wattnook-keep-awake` (for example with `sudo rm /etc/sudoers.d/wattnook-keep-awake`).

Use **ⓘ beside Keep Awake** on Battery for a separate, nonmodal details window; the main button still toggles the mode with one click. It separates sleep prevention, the closed-lid display guard and **Remote access: Not monitored**, with errors shown directly. **Refresh** (⌘R) takes a new sleep-blocker snapshot; **Copy report** (⇧⌘C) includes the last 64 local state/lid/sleep/wake/error events. Escape or ⌘W closes the window. The same window is available through **Advanced controls → Diagnostics → Keep Awake diagnostics**.

While the guard runs, a checkpoint is recorded at most once every 15 minutes through the existing timer; no separate watcher is started. This bounded journal persists locally in app preferences and contains no keyboard input, network addresses or app names. Failed sleep-status reads preserve the last display-guard state rather than treating an unknown status as Off; missing lid subscriptions are retried. Status/brightness failures appear on the Keep Awake button and in details. The report does **not** monitor or guarantee a Codex Remote connection, and absence of sleep events is not proof that the network/session stayed available.

Sleep-status checks run off the UI thread, directly reading `pmset -g`, with a two-second timeout and a 16 KiB output cap. Only one status read can run at a time. A toggle waits for a fresh successful read; cancellation, timeout or unreadable status never becomes an assumed On/Off command. Status reads are paused during authorization/change requests. A timed-out read kills only its own read-only `pmset` child, never the authorization helper or another app.

The details window includes an **on-demand sleep-blocker snapshot** from macOS's public [`IOPMCopyAssertionsByProcess`](https://developer.apple.com/documentation/iokit/1557130-iopmcopyassertionsbyprocess) API. It groups active requests by process and distinguishes display, idle-system and system sleep. Up to 50 rows are shown; process names and counts are included only in the view or explicitly copied report, never in the event journal. Activity reasons, URLs and command lines are omitted. A snapshot is collected off-main on opening or explicit Refresh, with no background assertion watcher. Reopening an already-visible window does not query again; closing releases its snapshot and late results never reopen it. This list excludes kernel blockers and the global sleep setting; an assertion is not proof that closed-lid operation or a Remote connection will work.

The charge-limit label is non-interactive and sits below the rail on the left, so it cannot intercept dragging. Use the marker (or keyboard arrows with the rail focused) to adjust the limit; exact presets remain in Advanced controls.

## Status and limits

- Charging controls depend on the Mac's SMC/firmware support. Check the original compatibility details below before installing a daemon.
- The flow view shows approximate direction and magnitude, not a calibrated electrical measurement; transient readings may be unavailable.
- “Quit” asks an app to exit normally after confirmation. WattNook does not force-quit processes.
- There is no signed/notarized downloadable release or one-click installer yet.

---

## Original batt documentation (upstream reference)

The following material documents the original `batt` CLI, compatibility, and upstream installation. Links and badges in this section refer to **upstream**, not a WattNook release.

<details>
<summary>Expand the original batt manual</summary>


> [!TIP]
> Feb 17, 2026 UPDATE: Finally, after more than 5 years, macOS 26.4 and later supports charge limiting natively (adjustable from 80% to 100%), so **`batt` is not needed if the built-in range meets your needs**. `batt` remains useful on older releases and when you want a limit below 80%. On macOS 27-era firmware, `batt` programs the firmware's charge-limit facility directly.

Note: Use table of contents of quickly navigate to the section you want, e.g., `Installation`. 👆↗

### batt

[![Go Checks](https://github.com/charlie0129/batt/actions/workflows/gochecks.yml/badge.svg)](https://github.com/charlie0129/batt/actions/workflows/gochecks.yml)[![Buind Test Binary](https://github.com/charlie0129/batt/actions/workflows/build-test-binary.yml/badge.svg)](https://github.com/charlie0129/batt/actions/workflows/build-test-binary.yml)![GitHub Downloads](https://img.shields.io/github/downloads/charlie0129/batt/total)


`batt` is a tool to control battery charging on Apple Silicon MacBooks.

## Why do you need this?

[This article](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries) might be helpful. TL;DR: keep your battery at 80% or lower when plugged in, and discharge it as shallowly as feasible.

Previously, before optimized battery charging is introduced, MacBooks are known to suffer from battery swelling when they are kept at 100% all the time, especially the 2015s. Even with optimized battery charging, the effect is not optimal (described [below](#but-macos-have-similar-features-built-in-is-it)).

`batt` can effectively alleviate this problem by limiting the battery charge level. It can be used to set a maximum charge level. For example, you can set it to 80%, and it will stop charging when the battery reaches 80%.

On older firmware, the computer then runs from wall power and the battery percentage remains steady. On macOS 27-era firmware, Apple changed the mechanism: the firmware may run the Mac from the battery when it is above the limit, so the percentage can drop until it returns to the configured range.

Quick link to [installation guide](#installation).

## Features

`batt` tried to keep as simple as possible. Charging limiting is the only thing to care about for most users:

- Limit battery charge, with a lower and upper bound, like ThinkPads. [Docs](#limit-battery-charge)

However, if you are nerdy and want to dive into the details, it does have some advanced features for power users. These are shown only when the current Mac's SMC keys support them.

- Control MagSafe LED (if present) according to charge status. [Docs](#control-magsafe-led)
- Cut power from the wall (even if the adapter is physically plugged in) to use battery power. [Docs](#enabledisable-power-adapter)
- On firmware < `20xxx`, it solves common sleep-related issues when controlling charging. [Docs1](#preventing-idle-sleep) [Docs2](#disabling-charging-before-sleep)
- Calibrate battery automatically. [Docs](#auto-calibration-experimental)

## How is it different from XXX?

**It is free and opensource**. It even comes with some features (like idle sleep preventions and pre-sleep stop charging) that are only available in paid counterparts. It comes with no ads, no tracking, no telemetry, no analytics, no bullshit. It is open source, so you can read the code and verify that it does what it says it does.

**It is simple but well-thought.** It only does charge limiting and does it well. On firmware < `20xxx`, `batt` handles sleep edge cases that can otherwise let a MacBook charge to 100%. On newer firmware, it delegates the range to Apple SMC so enforcement continues during sleep. Other features are intentionally limited to keep it simple. If you encounter a problem or want an additional feature, please raise an issue.

**It is light-weight.** No electron GUIs hogging your system resources like some other tools. You can use batt on the command-line, or use the native macOS menubar app if you prefer a GUI. The GUI is written using native macOS APIs, so it is light-weight and fast.

## But macOS have similar features built-in, is it?

Yes, macOS have optimized battery charging. It will try to find out your charging and working schedule and prohibits charging above 80% for a couple of hours overnight. However, if you have an un-regular schedule, this will simply not work. Also, you lose predictability (which I value a lot) about your computer's behavior, i.e., by letting macOS decide for you, you, the one who knows your schedule the best, cannot control when to charge or when not to charge.

`batt` can make sure your computer does exactly what you want. You can set a maximum charge level, and it will stop charging when the battery reaches that level. Therefore, it is recommended to disable macOS's optimized charging when using `batt`.

## Compatibility Matrix

Check your firmware version by running `system_profiler SPHardwareDataType | grep -i firmware` in Terminal. Do NOT rely on macOS version.

| Firmware Version          | First macOS release  | GUI | CLI (Prebuilt) | CLI (Build from Source) | Note                               |
| ------------------------- | -------------------- | --- | -------------- | ----------------------- | ---------------------------------- |
| `6723.x.x`                | macOS 11 Big Sur     | ❌   | ❌              | ⚠️                       |                                    |
| `7429.x.x` / `7459.x.x`   | macOS 12 Monterey    | ❌   | ⚠️              | ✅                       |                                    |
| `8419.x.x` / `8422.x.x`   | macOS 13 Ventura     | ⚠️   | ⚠️              | ✅                       |                                    |
| `101xx.x.x`               | macOS 14 Sonoma      | ⚠️   | ⚠️              | ✅                       |                                    |
| `118xx.x.x`               | macOS 15 Sequoia     | ✅   | ✅              | ✅                       |                                    |
| `138xx.x.x` / `18xxx.x.x` | macOS 26 Tahoe       | ✅   | ✅              | ✅                       |                                    |
| `20356.0.0.0.15` ~ `20457.0.77.0.2`               | macOS 27 Golden Gate Developer Beta 1~3 | ✅   | ✅              | ✅                       | Firmware-managed limits; see below |
| `20457.0.125.0.2`+ | macOS 27 Golden Gate Developer Beta 4 | ❌   | ❌     | ❌       |  |
| Other                     | Unknown              | ❓   | ❓              | ❓                       |                                    |

- ❌: Unsupported
- ✅: Supported
- ⚠️: Not verified, but expected to work.
- ❓: Unknown, please raise an issue if you have tested it.

> [!NOTE]
> Firmware version is different from macOS version. Old macOS versions may have newer firmware, e.g. macOS 15 with firmware `138xx.x.x` (macOS Tahoe version).

`batt` does not branch on the reported macOS or firmware version. It probes usable SMC keys at runtime (mainly tied to the firmware version, not the macOS version). This also handles an older macOS installation receiving newer firmware.

If you want to know which MacBooks I personally developed it on, I am using it on all my personal MacBooks every single day, including MacBook Air M1 2020 (A2337), MacBook Air M2 2022 (A2681), MacBook Pro 14' M1 Pro 2021 (A2442), MacBook Pro 16' M1 Max 2021 (A2485).

If you encounter any incompatibility, please raise an issue with your MacBook model, firmware version, batt version, macOS version, and batt logs (`/tmp/batt.log`, or `/var/log/batt.log` if installed v0.7.5+ using Homebrew).

### macOS 27 / 20xxx firmware behavior

On firmware exposing `bfF0`, `batt` writes the upper and lower percentages to `bfD0` and `bfE0`, activates the limit, and periodically verifies that all three values are still correct. Apple firmware then decides when charging starts and stops. The limit continues to work while macOS and the `batt` daemon are asleep, so `batt` does not register sleep notifications or run pre-sleep/post-wake charging hooks in this mode.

This mode has several intentional differences and current limitations:

- If the battery is above the upper limit, firmware can stop drawing wall power and use the battery to run the Mac. Unlike legacy control, the percentage may therefore fall.
- MagSafe LED control is unavailable because `batt` no longer owns or reliably knows the charging-enabled state.
- Legacy sleep options are unavailable and unnecessary. Incompatible values left in the configuration after an upgrade are disabled by the daemon.

The daemon reports these capabilities to current CLI and GUI clients. Older daemons that do not provide detailed compatibility data retain the previous permissive client behavior.

## Installation (GUI Version)

GUI version is a native macOS menubar app. It's not as feature-complete as the command-line version, but it is a good choice if you are not comfortable with the command-line. The command-line version is also included if you have the GUI version.

1. Download `.dmg` file from [Releases](https://github.com/charlie0129/batt/releases) and open it (right-click open if macOS says it's damaged)
2. Drag `batt.app` to `Applications`
3. macOS may say it's damaged when you try to run it (it's NOT) and wants you to move it to trash. To fix it, run this in Terminal: `sudo xattr -r -d com.apple.quarantine /Applications/batt.app`.
4. Run `batt.app`.
5. Follow the MenuBar UI to install or upgrade.
6. It is _highly_ recommended to disable macOS's optimized charging when using `batt`. To do so, open `System Settings` -> `Battery` -> `Battery Health` -> `i` -> Turn OFF `Optimized Battery Charging`. Built-in charge limit also need to be disabled if you are on macOS 26.4 or later.

<img width="191" alt="SCR-20250624-lbmb-3" src="https://github.com/user-attachments/assets/4bef52d7-8483-49bd-b579-736b87c81a52" />
<img width="206" alt="SCR-20250624-lbmb-2" src="https://github.com/user-attachments/assets/f3731a00-d973-4d67-8b4a-d57595e3842f" />
<img width="450" alt="SCR-20250624-lbmb-4" src="https://github.com/user-attachments/assets/a9d3c2eb-5d41-400e-b042-b79f6e8decd0" />

> [!TIP]
> There are 3rd-party GUI versions built around `batt` by some amazing opensource developers:
> 1. [BattGUI](https://github.com/clzoc/BattGUI) by [@clzoc](https://github.com/clzoc)
> 2. [batt-helper](https://github.com/zxw5775/batt-helper) by [@zxw5775](https://github.com/zxw5775)

## Installation (Command-Line Version)

> [!NOTE]
> Command-Line version is already included if you have installed the GUI version. You can run `batt` in Terminal to use it.

You have two choices to install the CLI version of `batt`:

1. Homebrew [Docs](#homebrew)
2. Installation Script (Recommended) [Docs](#installation-script)

You can choose either one. Please do not use both at the same time to avoid conflicts.

### Homebrew

> [!IMPORTANT]
> If you previously ran `batt` v0.7.3 or earlier with `sudo brew services`, follow the [one-time service-label migration](#homebrew-service-label-migration) before starting the service. When the Homebrew formula moved from v0.7.3 to v0.7.5, its service label changed from `cc.chlc.batt` to `homebrew.mxcl.batt`.

1. `brew install batt`
2. `sudo brew services start batt`
3. Please read [Notes](#notes).

> Thank you, [@Jerry1144](https://github.com/charlie0129/batt/issues/9#issuecomment-2165493285), for bootstrapping the Homebrew formula.

### Installation Script

1. (Optional) There is an installation script to help you quickly install batt (Internet connection required). Put this in your terminal: `bash <(curl -fsSL https://github.com/charlie0129/batt/raw/master/hack/install.sh)`. You may need to provide your login password (to control charging). This will download and install the latest _stable_ version for you. Follow the on-screen instructions, then you can skip to step 5.
<details>
<summary>Manual installation steps</summary>

2. Get the binary. For _stable_ and _beta_ releases, you can find the download link in the [release page](https://github.com/charlie0129/batt/releases). If you want development versions with the latest features and bug fixes, you can download prebuilt binaries from [GitHub Actions](https://github.com/charlie0129/batt/actions/workflows/build-test-binary.yml) (has a retention period of 3 months and you need to `chmod +x batt` after extracting the archive) or [build it yourself](#building) .
3. Put the binary somewhere safe. You don't want to move it after installation :). It is recommended to save it in your `$PATH`, e.g., `/usr/local/bin`, so you can directly call `batt` on the command-line. In this case, the binary location will be `/usr/local/bin/batt`.
4. Install daemon using `sudo batt install`. If you do not want to use `sudo` every time after installation, add the `--allow-non-root-access` flag: `sudo batt install --allow-non-root-access`. To uninstall: please refer to [How to uninstall?](#how-to-uninstall)
</details>

5. In case you have GateKeeper turned on, you will see something like _"batt is can't be opened because it was not downloaded from the App Store"_ or _"batt cannot be opened because the developer cannot be verified"_. If you don't see it, you can skip this step. To solve this, you can either 1. (recommended) Go to *System Settings* -> *Privacy & Security* --scroll-down--> *Security* -> *Open Anyway*; or 2. run `sudo spctl --master-disable` to disable GateKeeper entirely.

### Notes

- Test if it works by running `sudo batt status`. If you see your battery status, you are good to go!
- Time to customize. By default `batt` will set a charge limit to 60%. For example, to set the charge limit to 80%, run `sudo batt limit 80`.
- As said before, it is _highly_ recommended to disable macOS's optimized charging when using `batt`. To do so, open `System Settings` -> `Battery` -> `Battery Health` -> `i` -> Turn OFF `Optimized Battery Charging`. Built-in charge limit also need to be disabled if you are on macOS 26.4 or later.
- If your current charge is above the limit, behavior depends on the detected backend. Firmwares < `20xxx` stops charging and keeps running from the wall, so the percentage stays steady. `20xxx` firmware may run from the battery until it falls back into the configured range.
- You can refer to [Usage](#usage) for additional configurations. Don't know what a command does? Run `batt help` to see all available commands. To see help for a specific command, run `batt help <command>`.
- To disable the charge limit, run `batt disable` or `batt limit 100`.
- [How to uninstall?](#how-to-uninstall) [How to upgrade?](#how-to-upgrade)

> Finally, if you find `batt` helpful, stars ⭐️ are much appreciated!

## Usage

### Limit battery charge

Make sure your computer doesn't charge beyond what you said.

Setting the limit to 10-99 will enable the battery charge limit, limiting the maximum charge to _somewhere around_ your setting. However, setting the limit to 100 will disable the battery charge limit.

By default, `batt` will set a 60% charge limit.

To customize charge limit, see `batt limit`. For example,to set the limit to 80%, run `batt limit 80`. To disable the limit, run `batt disable` or `batt limit 100`.

To disable the limit only temporarily, use `batt disable --for=1d`. Your current limit is restored automatically once the duration has elapsed, even if your Mac reboots in the meantime. Durations accept minutes, hours, days and weeks, e.g. `30m`, `2h`, `1d`, `1w`. Setting a limit with `batt limit` before the duration elapses cancels the scheduled restore. `batt status` shows when the limit will be restored.

### Enable/disable power adapter

Cut or restore power from the wall. This has the same effect as unplugging/plugging the power adapter, even if the adapter is physically plugged in.

This is useful when you want to use your battery to lower the battery charge, but you don't want to unplug the power adapter.

NOTE: if you are using Clamshell mode (using a Mac laptop with an external monitor and the lid closed), *cutting power will cause your Mac to go to sleep*. This is a limitation of macOS. There are ways to prevent this, but it is not recommended for most users.

To enable/disable the power adapter, see `batt adapter`. For example, to disable the power adapter, run `sudo batt adapter disable`. To enable the power adapter, run `sudo batt adapter enable`.

To run from the battery only temporarily, use `sudo batt adapter disable --for=2h`. The adapter is enabled automatically after the duration elapses, and the deadline survives daemon restarts and reboots. Durations accept minutes, hours, days and weeks, e.g. `30m`, `2h`, `1d`, `1w`. Running `batt adapter enable` or `batt adapter disable` before the duration elapses cancels the scheduled enable. `batt status` shows when the adapter will be enabled.

The GUI exposes the same behavior under **Advanced → Force Discharge...**, with regular-user presets of 1, 2, 4, or 8 hours and a separate indefinite option.

### Check status

> [!NOTE]
> This feature is CLI-only and is not available in the GUI version.

Check the current config, battery info, and charging status.

To do so, run `sudo batt status`. Example output:

```
Charging status:
  Allow charging: ✘ (refreshes can take up to 2 minutes)
    Your Mac will not charge, because your current charge is above the limit.
  Use power adapter: ✔

Battery status:
  Current charge: 65%
  State: not charging
  Full capacity: 8648 mAh / 8694 mAh (99%)
  Charge rate: +0.0 W
  Voltage: 11.89 V

Battery configuration:
  Upper limit: 60%
  Lower limit: 58%
  Prevent idle-sleep when charging: ✔
  Disable charging before sleep if charge limit is enabled: ✔
  Prevent system-sleep when charging: ✘
  Allow non-root users to access the daemon: ✔
  Control MagSafe LED: ✔

Hardware compatibility:
  Charge control mode: legacy
  Sleep hooks: ✔
  MagSafe LED control: ✔
  Power adapter control: ✔
  Auto calibration: ✔

Calibration status:
  Phase: Idle
  Schedule: disabled
```

## Advanced

These advanced features are not for most users. Using the default setting for these options should work the best.

### Auto Calibration (experimental)

> Thanks @brookqin for implementing the initial version of this feature.

Automatically performs a full charging cycle to help calibrate reported battery percentage.

Phases: `Idle → DischargeToThreshold → ChargeToFull → HoldAfterFull → DischargeAfterHold → RestoreAndFinish → Idle`.

Flow:
1. Discharge below configured threshold (defaults to 15%). Charging is forced off.
2. Charge to 100%. Upper limit temporarily set to 100.
3. Hold at 100% for the configured duration (defaults to 120 minutes unless changed).
4. After hold, charging is disabled again and the battery is allowed to naturally discharge back down to the original upper limit snapshot.
5. Restore original upper/lower limits and adapter/charging states and return to Idle.

`batt` prevents idle system sleep for the entire calibration session, including while paused, and releases the assertion on completion, cancellation, or error. macOS can still force sleep when you close the lid or explicitly choose Sleep, so keep the lid open during calibration.

You can start, pause, resume, cancel via the GUI (Advanced → Auto Calibration) or CLI (`batt calibration start|pause|resume|cancel|status`) or HTTP API. Cancel restores original settings immediately.

To change the discharge threshold (defaults to 15%), run `batt calibration discharge-threshold <percentage>`.
To change the hold duration (defaults to 120 minutes), run `batt calibration hold-duration <minutes>`.

#### Scheduling automatic calibration

> [!NOTE]
> This feature is CLI-only and is not available in the GUI version.

Use `batt schedule` to let the daemon trigger calibration runs on a cron cadence. Examples:

```bash
batt schedule '0 10 * * 0'   # every Sunday at 10:00 (quote * so the shell doesn't expand it)
batt schedule '0 10 1 * *'   # At 10:00 on the first day of every month
batt schedule '0 10 1 */2 *' # At 10:00 on the first day of every two months
batt schedule disable        # remove the schedule and stop future runs
batt schedule postpone 90m   # push the next run back by 90 minutes (defaults to 1h if omitted)
batt schedule skip           # skip only the upcoming run and keep the schedule
```

After setting a cron expression, the CLI prints the next few run times returned by the daemon so you can verify the schedule. `postpone` and `skip` operate on the next scheduled execution only; `disable` clears the stored cron configuration.

Before a scheduled calibration actually begins, `batt` checks that the Mac is plugged into wall power. If it is not, the scheduler posts a reminder notification (GUI) and keeps waiting for roughly five minutes. If power is still unavailable after that grace period, the pending run is skipped automatically so later schedules are not blocked.

### Preventing idle sleep

> [!NOTE]
> This is a legacy-control option for older firmware < `20xxx`. It is unavailable and unnecessary with `20xxx` firmware, where the firmware enforces limits during sleep.

Set whether to prevent idle sleep during a charging session.

Due to macOS limitations, `batt` will be paused when your computer goes to sleep. As a result, when you are in a charging session and your computer goes to sleep, there is no way for batt to stop charging (since batt is paused by macOS) and the battery will charge to 100%. This option, together with disable-charging-pre-sleep, will prevent this from happening.

This option tells macOS NOT to go to sleep when the computer is in a charging session, so batt can continue to work until charging is finished. Note that it will only prevent **idle** sleep, when 1) charging is active 2) battery charge limit is enabled. So your computer can go to sleep as soon as a charging session is completed.

However, this options does not prevent manual sleep (limitation of macOS). For example, if you manually put your computer to sleep (by choosing the Sleep option in the top-left Apple menu) or close the lid, batt will still be paused and the issue mentioned above will still happen. This is where disable-charging-pre-sleep comes in. See [Disabling charging before sleep](#disabling-charging-before-sleep).

To enable this feature, run `sudo batt prevent-idle-sleep enable`. To disable, run `sudo batt prevent-idle-sleep disable`.

### Disabling charging before sleep

> [!NOTE]
> This is a legacy-control option for older firmware < `20xxx`. It is unavailable and unnecessary with `20xxx` firmware, where the firmware enforces limits during sleep.

Set whether to disable charging before sleep if charge limit is enabled.

As described in [Preventing idle sleep](#preventing-idle-sleep), batt will be paused by macOS when your computer goes to sleep, and there is no way for batt to continue controlling battery charging. This option will disable charging just before sleep, so your computer will not overcharge during sleep, even if the battery charge is below the limit.

To enable this feature, run `sudo batt disable-charging-pre-sleep enable`. To disable, run `sudo batt disable-charging-pre-sleep disable`.

### Prevent system sleep

> [!NOTE]
> This is a legacy-control option for older firmware < `20xxx`. It is unavailable with `20xxx` firmware.

Set whether to prevent system sleep during a charging session (experimental).

This option tells macOS to create power assertion, which prevents sleep, when all conditions are met:

1) charging is active
2) battery charge limit is enabled
3) computer is connected to charger.

So your computer can go to sleep as soon as a charging session is completed / charger disconnected.

Does similar thing to [Preventing idle sleep](#preventing-idle-sleep), but works for manual sleep too.

*Note*: Please disable [Preventing idle sleep](#preventing-idle-sleep) and [Disabling charging before sleep](#disabling-charging-before-sleep), while this feature is in use.

To enable this feature, run `sudo batt prevent-system-sleep enable`. To disable, run `sudo batt prevent-system-sleep disable`.

### Upper and lower charge limit

> [!NOTE]
> This feature is CLI-only and is not available in the GUI version.

When you set a charge limit, for example, on a Lenovo ThinkPad, you can set two percentages. The first one is the upper limit, and the second one is the lower limit. When the battery charge is above the upper limit, the computer will stop charging. When the battery charge is below the lower limit, the computer will start charging. If the battery charge is between the two limits, the computer will keep whatever charging state it is in.

`batt` have similar features built-in. The charge limit you have set (using `batt limit`) will be used as the upper limit. By default, The lower limit will be set to 2% less than the upper limit. To customize the lower limit, use `batt lower-limit-delta`.

For example, if you want to set the lower limit to be 5% less than the upper limit, run `sudo batt lower-limit-delta 5`. So, if you have your charge (upper) limit set to 60%, the lower limit will be 55%.

### Control MagSafe LED

> Acknowledgement: [@exidler](https://github.com/exidler)

This option makes the MagSafe LED reflect the charging state of your MacBook (or force it off).

- Green: charge limit is reached and charging is stopped.
- Orange: charging is in progress.
- Off: just woken up from sleep, charing is disabled and batt is waiting before controlling charging.

Note that you must have a MagSafe LED on your MacBook to use this feature.

This also requires legacy direct charging control. It is unavailable on macOS 27 / 20xxx firmware even if the Mac has a physical MagSafe LED, because firmware owns the charging decision and `batt` cannot reliably mirror its state.

To enable MagSafe LED control, run `sudo batt magsafe-led enable`.

To force the MagSafe LED to stay off, run `sudo batt magsafe-led always-off`.

### Check logs

Logs are directed to `/tmp/batt.log`, or `/var/log/batt.log` if installed v0.7.5+ using Homebrew. If something goes wrong, you can check the logs to see what happened. Raise an issue with the logs attached.

## Building

You need to install command line developer tools (by running `xcode-select --install`) and Go (follow the official instructions [here](https://go.dev/doc/install)).

### CLI

```shell
make
```

Simply running `make` in this repo should build the binary into `./bin/batt`. You can then follow [the upgrade guide](#how-to-upgrade) to install it (you just use the binary you have built, not downloading a new one, of course).

### GUI

```shell
make app
```

This will build the GUI version of `batt` into `./bin/batt.app`. Drag it to `/Applications` and run it.

## Architecture

You can think of `batt` like `docker`. It has a daemon that runs in the background, and a client (CLI or GUI) that communicates with the daemon. They communicate through unix domain socket as a way of IPC. The daemon does the actual heavy-lifting, and is responsible for controlling battery charging. The client is responsible for sending users' requirements to the daemon.

For example, when you run `sudo batt limit 80`, the client will send the requirement to the daemon, and the daemon will do its job to keep the charge limit to 80%.

The daemon selects one of two control backends from SMC key presence. The legacy backend continuously reads battery percentage and toggles charging itself. The firmware backend writes lower/upper limits and periodically reconciles them while Apple firmware enforces the range, including during sleep. The same capability data is exposed to CLI and GUI clients so unsupported features are not offered.

## Motivation

I created this tool simply because I am not satisfied with existing tools 😐.

I have written and using similar utils (to limit charging) on Intel MacBooks for years. Finally I got hands on an Apple Silicon MacBook (yes, 2 years later since it is introduced 😅 and I just got my first one). The old BCLM way to limit charging doesn't work anymore. I was looking for a tool to limit charging on M1 MacBooks.

I have tried some alternatives, both closed source and open source, but I kept none of them. Some paid alternatives' licensing options are just too limited 🤔, a bit bloated, require periodic Internet connection (hmm?) and are closed source. It doesn't seem a good option for me. Some open source alternatives just don't handle edge cases well and I encountered issues regularly especially when sleeping (as of Apr 2023).

I want a _simple_ tool that does just one thing, and **does it well** -- limiting charging, just like the [Unix philosophy](https://en.wikipedia.org/wiki/Unix_philosophy). It seems I don't have any options but to develop by myself. So I spent a weekend developing an MVP, so here we are! `batt` is here!

## FAQ

### How to uninstall?

#### GUI version

Click `Uninstall Daemon...` to uninstall. After the daemon is uninstalled, you can remove the `batt.app` from your `Applications` folder.

<img width="528" alt="SCR-20250710-mjrd" src="https://github.com/user-attachments/assets/901c7840-bae7-4111-af07-4fc1b39444d0" />


#### CLI version

Note that you should choose the same method as you used to install `batt` to uninstall it.

If you don't remember how you installed it, you can check the binary location by running `which batt`. If it is in `/usr/local/bin`, you probably used the installation script. If it is in `/opt/homebrew/bin`, you probably used Homebrew.

Script-installed:

1. Run `sudo batt uninstall` to remove the daemon.
2. Remove the config by `sudo rm -f /etc/batt*`.
3. Remove the `batt` binary itself by `sudo rm $(which batt)`.

Homebrew-installed:

1. Run `sudo batt disable` to restore the default charge limit.
2. Run `sudo brew services stop batt` to stop the daemon.
3. Run `brew uninstall batt` to uninstall the binary.
4. Remove the config by `sudo rm -f /opt/homebrew/etc/batt.json && sudo rm -f /etc/batt*`.

### How to upgrade?

#### GUI version

Just follow the installation steps again. After you open the new version of batt.app, click `Upgrade Daemon...` upgrade to the new daemon.

<img width="206" alt="SCR-20250624-lbmb-2" src="https://github.com/user-attachments/assets/f3731a00-d973-4d67-8b4a-d57595e3842f" />

#### CLI version

Note that you should choose the same method as you used to install `batt` to upgrade it.

If you don't remember how you installed it, you can check the binary location by running `which batt`. If it is in `/usr/local/bin`, you probably used the installation script. If it is in `/opt/homebrew/bin`, you probably used Homebrew.

**Script-installed:**

```bash
bash <(curl -fsSL https://github.com/charlie0129/batt/raw/master/hack/install.sh)
```

**Homebrew-installed:**

##### Homebrew service-label migration

If you previously ran `batt` v0.7.3 or earlier with `sudo brew services`, use the following commands once. When the Homebrew formula moved from v0.7.3 to v0.7.5, its service label changed from `cc.chlc.batt` to `homebrew.mxcl.batt`, and `brew services stop batt` may not stop the job registered under the old label. The old job must be booted out before its plist is removed; deleting the plist alone does not unregister a running job from `launchd`.

```bash
sudo brew services stop batt
if sudo launchctl print system/cc.chlc.batt >/dev/null 2>&1; then
  sudo launchctl bootout system/cc.chlc.batt
fi
sudo rm -f /Library/LaunchDaemons/cc.chlc.batt.plist
brew upgrade batt
sudo brew services start batt
```

No uninstall or reinstall is needed. For later Homebrew upgrades, use the normal procedure:

```bash
sudo brew services stop batt
brew upgrade batt
sudo brew services start batt
```

**Manual:**

1. Run `sudo batt uninstall` to remove the old daemon.
2. Download the new binary. For _stable_ and _beta_ releases, you can find the download link in the [release page](https://github.com/charlie0129/batt/releases). If you want development versions with the latest features and bug fixes, you can download prebuilt binaries from [GitHub Actions](https://github.com/charlie0129/batt/actions/workflows/build-test-binary.yml) (has a retention period of 3 months and you need to `chmod +x batt` after extracting the archive) or [build it yourself](#building) .
3. Replace the old `batt` binary with the downloaded new one. `sudo cp ./batt $(where batt)`
4. Run `sudo batt install` to install the daemon again. Although most config is preserved, some security related config is intentionally reset during re-installation. For example, if you used `--allow-non-root-access` when installing previously, you will need to use it again like this `sudo batt install --allow-non-root-access`.

### Why is it Apple Silicon only?

You probably don't need this on Intel :p

On Intel MacBooks, you can control battery charging in a much, much easier way, simply setting the `BCLM` key in Apple SMC to the limit you need, and you are all done. There are many tools available. For example, you can use [smc-command](https://github.com/hholtmann/smcFanControl/tree/master/smc-command) to set SMC keys. Of course, you will lose some advanced features like upper and lower limit.

However, on Apple Silicon, the way how charging is controlled changed. There is no such key. Therefore, we have to use a much more complicated way to achieve the same goal, and handle more edge cases, hence `batt`.

### Will there be an Intel version?

Probably not. `batt` was made Apple-Silicon-only after some early development. I have tested batt on Intel during development (you can probably find some traces from the code :). Even though some features in batt are known to work on Intel, some are not. Development and testing on Intel requires additional effort, especially those feature that are not working. Considering the fact that Intel MacBooks are going to be obsolete in a few years and some similar tools already exist (without some advanced features), I don't think it is worth the effort.

### Why does my MacBook stop charging after I close the lid?

> [!NOTE]
> This FAQ applies only to older firmware < `20xxx` using direct charging control. On `20xxx` firmware, the charge limit persists through sleep and `batt` does not disable charging before sleep.

TL,DR; This is intended, and is the default behavior. It is described [here](#disabling-charging-before-sleep). You can turn this feature off by running `sudo batt disable-charging-pre-sleep disable` (not recommended, keep reading).

But it is suggested to keep the default behavior to make your charge limit work as intended. Why? Because when you close the lid, your MacBook will go into **forced sleep**, and `batt` will be paused by macOS. As a result, `batt` can no longer control battery charging. It will be whatever state it was before you close the lid. This is the problem. Let's say, if you close the lid when your MacBook is charging, since `batt` is paused by macOS, it will keep charging, ignoring the charge limit you have set. There is no way to prevent **forced sleep**. Therefore, the only way to solve this problem is to disable charging before sleep. This is what `batt` does. It will disable charging just before your MacBook goes to sleep, and re-enable it when it wakes up. This way, your Mac will not overcharge during sleep.

Not that you will encounter this **forced sleep** only if you, the user, forced the Mac to sleep, either by closing the lid or selecting the Sleep option in the Apple menu. If your Mac decide to sleep by itself, called **idle sleep**, i.e. when it is idle for a while, in this case, you will not experience this stop-charging-before-sleep situation.

So it is suggested to keep this feature on. But _What if I MUST let my Mac charge during a **forced sleep** without turing off `disable-charging-pre-sleep`, even if it may charge beyond the charge limit?_ This is simple, just disable charge limit `batt disable`. This way, when you DO want to enable charge limit again, `disable-charging-pre-sleep` will still be there to prevent overcharging. The rationale is: when you want to charge during a **forced sleep**, you actually want heavy use of your battery and don't want ANY charge limit at all, e.g. when you are on a long outside-event, and you want to charge your Mac when it is sitting in your bag, lid closed. Setting the charge limit to 100% is equivalent to disabling charge limit. Therefore, most `batt` features will be turned off and your Mac can charge as if `batt` is not installed.

### Why does it require root privilege?

It writes to SMC to control battery charging. This does changes to your hardware, and is a highly privileged operation. Therefore, it requires root privilege.

If you are concerned about security, you can check the source code [here](https://github.com/charlie0129/batt) to make sure it does not do anything funny.

### Why is it written in Go and C?

Since it is a hobby project, I want to balance effort and the final outcome. Go seems a good choice for me. However, C is required to register sleep and wake notifications using Apple's IOKit framework. Also, Go don't have any library to r/w SMC, so I have to write it myself ([charlie0129/gosmc](https://github.com/charlie0129/gosmc)). This part is also mainly written in C as it interacts with the hardware and uses OS capabilities. Thankfully, writing a library didn't slow down development too much.

### Why is there so many logs?

By default, `batt` daemon will have its log level set to `debug` for easy debugging. The `debug` logs are helpful when reporting problems since it contains useful information. So it is recommended to keep it as `debug`. You may find a lot of logs in `/tmp/batt.log` after you use your Mac for a few days. However, there is no need to worry about this. The logs will be cleaned by macOS on reboot. It will not grow indefinitely.

If you believe you will not encounter any problem in the future and still want to set a higher log level, you can achieve this by:

1. Stop batt: `sudo launchctl unload /Library/LaunchDaemons/cc.chlc.batt.plist` (batt must be stopped to change config so you can't skip this step)
2. Use your preferred editor to edit `/Library/LaunchDaemons/cc.chlc.batt.plist` and change the value of `-l=debug` to your preferred level. The default value is `debug`.
3. Start batt again: `sudo launchctl load /Library/LaunchDaemons/cc.chlc.batt.plist`

### Why does my Mac go to sleep when I disable the power adapter?

You are probably using Clamshell mode, i.e., using a Mac laptop with an external monitor and the lid closed. This is a limitation of macOS. Clamshell mode MUST have power connected, otherwise, the Mac will go to sleep.

If you want to prevent this, you need to disable sleep globally using pmset, or you can use a third-party app like [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) to prevent sleep.

### My Mac does not start charging after waking up from sleep

> [!NOTE]
> This FAQ applies only to older firmware < `20xxx` using legacy direct charging control. `20xxx` firmware has no `batt` post-wake delay.

This is expected. batt will prevent your Mac from charging temporarily if your Mac has just woken up from sleep. This is to prevent overcharging during sleep. Your Mac will start charging soon (at most 2 minutes).

If you absolutely need to charge your Mac _immediately_ after waking up from sleep, you can disable this feature by running `sudo batt disable-charging-pre-sleep disable`. However, this is not recommended (see [Disabling charging before sleep](#disabling-charging-before-sleep)).

### Why does my Mac starts charging after entering sleep?

> [!NOTE]
> This FAQ applies only to older firmware < `20xxx` using legacy direct charging control. `20xxx` firmware continues enforcing the configured range during sleep.

If you are using the default batt settings (i.e., `prevent-idle-sleep` and `disable-charging-pre-sleep` are both enabled), this should not happen.

However, there are some cases like [#101](https://github.com/charlie0129/batt/issues/101) where hibernation mode is unexpectedly changed by the user. Your Mac may enter hibernation immediately instead of sleep, and Mac firmware resets SMC keys after hibernation, causing batt to lose control of charging.

To see if you are in always-hibernate mode, run `pmset -g | grep hibernatemode`. If the value is not `0` nor `3`, you are in always-hibernate mode. To change it back to sleep mode, run `sudo pmset -a hibernatemode 3` (factory default for MacBooks, hibernates after several hours) or `sudo pmset -a hibernatemode 0` (never hibernate). After changing the mode, reboot your Mac for the change to take effect.

### Can I quit the GUI app?

Yes.

As in [#62](https://github.com/charlie0129/batt/issues/62), you can quit the GUI app and expect batt to continue working, provided that you have installed the daemon during the first run.

You may also want to remove the GUI app from *System Settings* -> *General* -> *Login Items & Extensions* to prevent it from starting automatically on login. Important: only remove the GUI app from *Open at Login*, do NOT remove the daemon from *Allow in Background*.

The reason behind is that the GUI app does not do the actual battery charge controlling. The daemon does. As long as the daemon is not uninstalled, charging control will work. The GUI app is just a client to communicate with the daemon. Quitting the GUI app will not affect the daemon. You can save some menu bar space if you rarely change settings.

### Will batt work after shutdown?

No. batt only works when macOS is running. After shutdown, there is no way to control battery charging until macOS boots up again.

## Acknowledgements

- [actuallymentor/battery](https://github.com/actuallymentor/battery) for various SMC keys.
- [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl) for its C code to read/write SMC, which inspires [charlie0129/gosmc](https://github.com/charlie0129/gosmc).
- [Apple](https://developer.apple.com/library/archive/qa/qa1340/_index.html) for its guide to register and unregister sleep and wake notifications.
- [@exidler](https://github.com/exidler) for building the MagSafe LED controlling logic.
- [@pichxyaponn](https://github.com/pichxyaponn) for the initial version of GUI.
- [@MabaKalox](https://github.com/MabaKalox) for prevent-system-sleep feature.
- [@peterneutron](https://github.com/peterneutron) for refactoring the power metrics code and the power flow feature.
- [@invisiblepixel](https://github.com/invisiblepixel) for app icon design.
- [@brookqin](https://github.com/brookqin) for implementing auto calibration.
- [@ashwinr64](https://github.com/ashwinr64) for investigating SMC keys on macOS 27 [#140 comment](https://github.com/charlie0129/batt/pull/140#issuecomment-4950731214) [actuallymentor/battery#469](https://github.com/actuallymentor/battery/pull/469), also [@lilianmoraru](https://github.com/lilianmoraru) for the initial PR.

## Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=charlie0129/batt&type=Date)](https://star-history.dera.page/#charlie0129/batt&Date)

</details>
