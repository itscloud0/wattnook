# Full native redesign — 2026-10-16

## Compact macOS 27 menu-bar follow-up — 2026-10-18

- Found concrete macOS 27 menu-bar references at https://www.igen.fr/ios/2026/06/apple-uniformise-licone-de-batterie-sur-ios-27-et-macos-golden-gate-156501 . Implemented a compact 25×12 pt filled silhouette on 27+, not the rejected 32 pt capsule. This is a measured reconstruction, **not** an extracted original Apple asset. Earlier systems retain the legacy resource composition. Percentage remains outside the icon to preserve the saved menu-bar configuration.
- Preserve 8 pt metrics spacing and whole-image system template contrast; vertically center the actual glyph height rather than stretching it. Update charge before composing text, fixing the one-poll percentage lag.
- Fresh-context review found no definite new regression; the existing legacy SF fallback's intrinsic size can differ if Control Center resources disappear. Only macOS 27.0.1 is available for live checks here.
- Native checks passed, including 0/1/20/80/100 charge, charging/plugged states, Aqua/Dark Aqua combinations and same-tick percentage regression. Impeccable detector returned no findings (not an AppKit visual acceptance test). Cached fixture batch produced all six icons; inspected Dark Aqua charging. Its subsequent unrelated live CPU sanity assertion failed while the full Go build was compiling, so the fixture run is **not** a full-suite pass. The separate checks-only native run passed without weakening assertions.
- Full `go test ./...` and GUI build passed. After removing a duplicate charge assignment, reran `go test ./pkg/gui`, rebuilt GUI and reran native checks: PASS (CPU sanity 96.7%). Existing deployment-target/linker warnings remain; internal disk counters unavailable in the host harness. `git diff --check` passed. No assertions weakened.
- GUI-only installed SHA-256 `7de9b8bc51af75ce1086179ee3698965c9bc762fe51877013af3f9d771b5c131`, new PID 17156; backup `/private/tmp/wattnook-before-menu27.AfBIO1/WattNook`. Lid open, normal quit/reopen; daemon PID 597 unchanged, SleepDisabled still 1. First install invocation stopped before mutations due to an incorrect rg path, then corrected. No charge-control or thermal policy changes, commit or push. Heat protection remains unavailable on the native backend; see thermal-pause-progress.md. Next acceptance is the user's live icon appearance and separate decision on the supervised thermal actuator test.

## Menu-bar battery follow-up — 2026-10-17

### Correction after user rejection

- User rejected the authored capsule as non-original and oversized. Removed that entire drawing branch; restored the existing Control Center asset composition at 25×14 pt (not 32×14). Do not call this the new macOS 27 icon: the desired pixel-identical new system appearance remains unresolved, pending a visual reference. BatteryUIKit assets and public SF Symbols were rendered independently and still show hollow outlines; names alone do not prove use by the live system menu.
- Regression failed on width 25 before removal, then native dashboard checks passed for empty/full alpha, charge states, template composition and existing behavior. Full Go suite, GUI build and diff checks passed; existing warnings remain. No charging/sleep behavior changed. A screenshot preflight was rejected because it could request Screen Recording access; no bypass or screen capture followed. Artifact comparison only: `/private/tmp/wattnook-battery-assets-20261017.png`.
- Corrected GUI installed, SHA-256 `a6b809ffc2259ac57782dd356d966bf67696b090545fa322406fc6fd1b3787f3`, PID 39885. Backup `/private/tmp/wattnook-before-icon-correction.cbPE6V/WattNook`. Daemon still PID 89075, SleepDisabled still 1; lid open during normal quit/reopen. No commit/push.

### Rejected implementation (historical)

- User clarified the outdated icon is the menu-bar battery, not the application icon. On macOS 26+, replaced the hollow legacy Control Center composition with a locally drawn 32×14 pt filled rounded body, continuous charge fill and negative-space charging/plug marks. This is an authored modern-style glyph, not a claim of pixel-identical Apple artwork. Older systems retain the existing fallback. Combined-image width follows the glyph; the existing 8 pt metrics gap, template contrast, saved choices and sampling remain unchanged.
- Regression first failed on the old 25 pt image, then native checks passed for empty/full alpha, 0/1/20/80/100 charge, plugged/charging states and Aqua/Dark Aqua template composition. Six small cached-button fixtures inspected at `/private/tmp/wattnook-menu-icon-previews`; transparent Aqua cache does not establish live wallpaper contrast. Full Go tests and GUI build passed outside sandbox (sandbox forbids a test Unix-socket bind); existing AppKit/deployment warnings remain. Impeccable detector returned no findings but does not validate AppKit design semantics.
- GUI-only installed SHA-256 `008819e55d52220a42be33082a0b29a8eab3c1960bb47dc0545c8f953b9227f2`; backup `/private/tmp/wattnook-before-menu-icon.5RCtXF/WattNook`. Lid open; normal quit/reopen; new GUI PID 5977. Daemon PID 89075 unchanged, SleepDisabled still 1. No charge-control, thermal-probe, helper, preference or daemon changes; no commit/push. Next acceptance: user's live menu-bar appearance.

## Intent and boundaries

User rejected cosmetic passes and requested a full redesign using Impeccable. Confirmed: preserve Liquid Glass and the animated power flow; everything else may change. Operate mode, existing AppKit architecture and behavior. Make Battery, System, Settings, History and the new Storage Review visually coherent, legible and easy to act on. Preserve six consumers, saved units/palettes/menu metrics, actual unavailable states, Reduce Motion and sampling lifecycle. No dependencies, charging-policy or Keep Awake changes hidden inside design work.

Plan: choose an overall composition, rebuild shared navigation/type/spacing and each existing page, run native regression + full Go tests, inspect one fixture batch, fix material issues once, independent finish review, document actual tokens, then install GUI only with backup and lid open. Stop before any daemon/hardware mutation or unsafe restart.

## Grounded directions

1. Apple printed quick-start guides: restrained SF hierarchy and generous grouping; recognizable, but familiar.
2. Swiss graphic programs: measured type and color roles; risks becoming typographic decoration.
3. Museum collection labels: artifact first, evidence below; risks making actions too quiet.
4. Airline boarding documents: compact aligned identifiers and explicit status; risks over-density.
5. Transit wayfinding: unmistakable destinations, one directional energy trace, clear labels and restrained color roles; fits quick checks during work.
6. Type specimen catalogs: strong hierarchy with precise secondary measurements; risks display type competing with readings.
7. Modern industrial packaging: concise information panels and safety/status distinctions; risks excessive framing.

Impeccable assigned grounded candidate 5. User's Glass and animated-flow commitments override material expression: retain the actual macOS material and existing runtime flow, not a literal map or signage costume. Platform navigation and controls stay native. Signature move: the preserved animated energy path connects source and destination; all reading/action regions use one aligned vertical rhythm.

Catalog comparison (audience identification / product clarity): data-sublime declined (barcode texture weakens both; keep tabular discipline); orienteering declined (map metaphors weaken both; keep strict color-role separation); Metro declined (cropped giant type weakens both in a small Mac utility; keep hierarchy courage); cassette inlay declined (nostalgia weakens both; keep bounded rows); botanical folio declined (life-stage metaphor weakens both; keep fixed reference baselines); streaming catalog declined (posters/focus expansion weaken both; keep clear foreground priority). These are discipline raises, not borrowed visual motifs.

## Heat-protection evidence

Live read-only API check this turn: charge mode `native`, supported limits 80/85/90/95/100, actual limit 80. `/heat-protection` explicitly returns disabled plus `Custom heat protection unavailable with Apple's native charge limit`. `pkg/daemon/compatibility.go` chooses this mode only when the SMC control backend is unavailable; `pkg/daemon/thermal.go` deliberately exposes unavailable status. Do not claim this feature is active, and do not use adapter toggling or changing the native limit in a thermal loop as an unapproved workaround. This is a capability limitation of the current backend, not a design fix.

## Current execution state

User selected `wayfinding` on the local Impeccable decision page. Code-led native implementation completed in `native_popover.m`, with header-only changes to `native_power_flow.m` and fallback palette changes to `native_preferences.m`. Ribbon contours/animation, callbacks, polling cadence, preferences and charging/sleep policies retained. 400×548 shell, full-width destinations, 48 pt charge, two-line 44 pt actions, three System columns and six consumer rows, grouped Settings and separate History. No new dependencies or shipping raster assets.

The installed concept-seed utility emitted a genuine roll but no durable `SEED REFERENCE`; original output `/private/tmp/wattnook-redesign-seed-network.txt`. This legacy-tool limitation is explicit in FORM. No invented reference or claim that the roll was skipped. Decision HTML is a structural sketch, not an approved raster comp or real compositor evidence.

## Verification and independent review

- Native geometry tests failed first on the old 360×480 shell. After implementation, the old fork test's hard-coded center of 180 failed; corrected it to the actual view bounds midpoint rather than changing the preserved ribbon. Logs: `/private/tmp/wattnook-redesign-red.log`, `/private/tmp/wattnook-redesign-checks.log`.
- Dashboard compile and actual execution with its mandatory directory argument passed, including independent units, compact extreme values, six rows, slider/accessibility, Glass lifecycle, animation lifecycle and native unavailable heat. Final log `/private/tmp/wattnook-redesign-confirm.log`. Host internal-drive counters returned unavailable in this harness; no claim of verified live disk throughput.
- One fixture inspection batch and one correction/confirmation batch. Synthetic captures: `/private/tmp/wattnook-redesign-review/` (Battery, System, Settings, History, native heat unavailable and structural Glass variants). `cacheDisplay` omits the native Glass backdrop: those alpha captures establish geometry only, not live compositor appearance or contrast.
- Fresh generic reviewer used the Impeccable finish-review contract because the shipped named role is not exposed by this harness. Initial `fix`: legacy seed limitation, flipped title/subtitle hierarchy and stale heat accessibility name. One correction batch fixed hierarchy, synchronized current availability into accessibility and added supported/unavailable assertions. Final verdict `ship` scores all three fixes resolved, with no introduced regression observed; it is not a claim of live Glass material acceptance.
- `go test ./...` and final `go build` passed: `/private/tmp/wattnook-redesign-go-final.log`, `/private/tmp/wattnook-redesign-build-final.log`. Existing AppKit category and deployment-target warnings remain.
- Recompiled Storage Review, Keep Awake window and status/timeout harnesses against final native sources; all passed: `/private/tmp/wattnook-redesign-cleanup-window.log`, `/private/tmp/wattnook-redesign-awake-window.log`, `/private/tmp/wattnook-redesign-status.log`. Synthetic callbacks only; no sleep/brightness/charging changes or actual user-root scan. These are not overnight Remote acceptance tests.
- Separate documenter extracted the actual built tokens into `DESIGN.md` and `.impeccable/design.json`; no invented CSS Glass implementation. `git diff --check` passed.

## Installation and handoff

Installed GUI only at `~/Applications/WattNook.app/Contents/MacOS/WattNook`, SHA-256 `4d043cce558f59c1e4dba7b275ab67d9a434a1c50441f025d3fd7b32724a3e7c`. Previous Storage Review executable preserved at `/private/tmp/wattnook-before-full-redesign.jgmfV0/WattNook`. Lid confirmed open before normal quit/reopen; new GUI PID 42401, daemon PID 89075 unchanged. Native limit 80 and `SleepDisabled=1` verified before and after. No daemon/helper replacement, preference reset, heat-policy workaround, commit or push.

Stop: implementation, bounded verification, independent scored fixes, design documentation and authorized GUI install complete. Next acceptance: user's live appearance check with saved Glass palette and explicit Storage Review scan. Heat protection remains a separate backend-capability problem; do not present it as enabled. Do not run unattended lid/sleep tests or change hardware policy as part of visual acceptance.

## Follow-up: approved live-screenshot corrections

User approved removing the detached duplicate battery glyph, compacting the header and moving the unavailable heat explanation into Settings. Implemented a 400×532 shell and 220 pt power canvas. Keep Awake expands to 320 pt only when heat is unavailable; supported heat retains its action. Native Glass shapes follow visible actions, including supported↔unsupported transitions. System/History top controls moved 8 pt clear of navigation; all six consumer rows preserved. Rail coordinates/hit targets, ribbon contours, polling and charging/sleep behavior unchanged.

Two isolated layout/source assessments identified potential navigation overlap and stale Glass backing; both covered before capture. New shell requirement failed first (`/private/tmp/wattnook-compact-red.log`). Final native run passed including notice width, supported/unavailable action geometry, Glass child geometry/count across four transitions, rail interactions and existing animation/unit checks: `/private/tmp/wattnook-compact-checks-final.log`. Synthetic Battery, charging split, hybrid merge, System, Settings and History inspected in one batch, then one confirmation after making fixture charging flags agree with synthetic watts. Captures `/private/tmp/wattnook-compact-review/`; no live Glass compositor/overnight Remote claim. Host disk counters remained unavailable in the harness.

`go test ./...` and GUI build passed (`/private/tmp/wattnook-compact-go.log`, `/private/tmp/wattnook-compact-build.log`); existing category/deployment warnings remain. Token/sidecar references and `git diff --check` passed. Current DESIGN/README/surface amendment reflect the compact layout.

Installed SHA-256 `559fae303e7063a86bd39ba24b2cbe30ebd413a7f3d5daf7b17aaad1a9458dc7` into the same app, backup `/private/tmp/wattnook-before-compact.RjsAXr/WattNook`. Lid open, normal GUI quit/reopen; daemon PID 89075 unchanged, native limit 80 and `SleepDisabled=1` preserved. No daemon/helper replacement, actual user-root scan, hardware-policy change, commit or push. This follow-up is a focused correction, not a claim of another full redesign. Stop at user's live appearance acceptance.
