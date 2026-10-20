<p align="center">
  <img src="tools/app/WattNook-Icon.png" width="96" alt="WattNook app icon">
</p>

<h1 align="center">WattNook</h1>

<p align="center"><strong>Free battery care for Apple Silicon Macs — and it works on macOS 27.</strong><br>
Heat Protection, charge limits from 50%, and a live view of where every watt goes.</p>

<p align="center">
  <a href="LICENSE"><img alt="GPL-2.0" src="https://img.shields.io/badge/license-GPL--2.0-526B80"></a>
  <img alt="macOS 15+ incl. 27" src="https://img.shields.io/badge/macOS-15%2B%20·%2027-526B80">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-526B80">
  <img alt="Native AppKit" src="https://img.shields.io/badge/UI-native%20AppKit-526B80">
  <img alt="~25 MB RAM" src="https://img.shields.io/badge/RAM-~25%20MB-526B80">
</p>

<p align="center">
  <img src="docs/images/wattnook-states.gif" width="420" alt="WattNook switching between charging, heat-paused and adapter-plus-battery states">
</p>

## Why WattNook

macOS 27 removed the SMC keys that charge limiters relied on, so most of them quietly stopped working. WattNook drives charging through the same top-off-protection path macOS uses itself, and verifies the result on real hardware.

- **Heat Protection that keeps you on AC.** When the battery gets hot, charging pauses at the current level while the adapter keeps powering the Mac. It resumes once the battery cools. A low battery whose adapter can't keep up is never left draining.
- **Charge limits from 50% to 100%.** Apple's built-in setting stops at 80%. WattNook adds 50–75%, never discharges on the adapter to reach a lower limit, and keeps Apple's 80% underneath as a safety net.
- **Sailing, Top Up and Discharge, free.** Sailing stops micro-charging: once the limit is reached the battery drifts 5–10% before charging again. Top Up charges to 100% once for a trip and restores your limit when you unplug. Discharge runs down to a lower limit while the charger stays plugged in.
- **See where the power goes.** A live flow shows adapter, battery and Mac watts as they split and merge, plus battery *and* CPU temperature, so you know whether the battery or the processor is the hot part.
- **Find what's heating your Mac.** Top apps by CPU, memory or disk, memory pressure, a 15-minute history, and a normal Quit one hover away.
- **Keep Awake with the lid closed.** Run long jobs or remote sessions without sleep; WattNook dims the panel when the lid closes.
- **Light and native.** AppKit, no Electron, about 25 MB of memory when idle. Keyboard shortcuts ⌘1 / ⌘2 / ⌘3 and ⌘,.

<table>
  <tr><th>Heat Protection</th><th>System</th><th>Settings</th></tr>
  <tr>
    <td><img src="docs/images/battery-heat.png" width="260" alt="Battery view with charging paused for heat while the adapter powers the Mac"></td>
    <td><img src="docs/images/system.png" width="260" alt="System view with CPU load, CPU temperature, memory, disk and top apps"></td>
    <td><img src="docs/images/settings.png" width="260" alt="Settings with color palette, menu-bar items and monitoring options"></td>
  </tr>
</table>

<sub>Renders of the real AppKit UI with illustrative values.</sub>

## Install

1. Download the **WattNook-x.y.z.zip** from the [latest release](https://github.com/itscloud0/wattnook/releases/latest), unzip it and move **WattNook.app** to Applications.
2. The app is not notarized yet, so macOS blocks the first launch. Either right-click the app → **Open** → **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/WattNook.app
   ```
3. Open WattNook, click the menu-bar icon and choose **Install Daemon…**. macOS asks for your administrator password once to install the charging helper.

Updating later: replace the app, open it and choose **Upgrade Daemon…** when offered. Run only one charging tool at a time: quit AlDente, batt or similar apps first.

<details>
<summary>Build from source</summary>

Requirements: Apple Silicon, macOS 15 or later, Go and the Xcode command-line tools.

```sh
git clone https://github.com/itscloud0/wattnook.git && cd wattnook
WATTNOOK_VERSION=0.4.0 tools/build-wattnook-app.sh /tmp/WattNook.app
mv /tmp/WattNook.app ~/Applications/ && open ~/Applications/WattNook.app
```

Or install the helper from the command line: `sudo ~/Applications/WattNook.app/Contents/MacOS/WattNook install-helper` (remove it with `uninstall-helper`).
</details>

## How it works on macOS 27

On M-series Macs running macOS 27 the classic charge-inhibit keys (`CH0B`, `CH0C`, `CHTE`) are gone. To pause charging, WattNook's helper writes a top-off-protection hold for the target level, posts the system's defaults-changed notification and briefly pulses the adapter input (500 ms) so power management re-evaluates. The original settings are snapshotted first and restored when the hold ends, when the helper stops, or on the next start after a crash. After every pulse WattNook checks that the USB-C charger renegotiated its full voltage and tells you to reconnect the cable if it stayed at 5 V.

Verified on a MacBook Air (M4) running macOS 27: [measurements and design notes](docs/heat-protection-charge-hold.md).

## Status

WattNook is young and evolving fast. It changes your Mac's charging behaviour through private macOS interfaces that a future update may change; it validates what it can at runtime and turns features off rather than guessing. Power readings come from macOS telemetry, not a wall meter.

## Credits

WattNook is a fork of [batt](https://github.com/charlie0129/batt) by Charlie Chiang and keeps its history and [GPL-2.0 license](LICENSE). It is not affiliated with AlDente or Apple.

**If WattNook keeps your battery cooler, please ⭐ the repo — it helps other macOS 27 users find it.**

More: [detailed documentation](docs/DETAILS.md) · [product notes](PRODUCT.md) · [design system](DESIGN.md)
