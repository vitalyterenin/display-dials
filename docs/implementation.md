# Implementation and validation

## Code structure

| File | Responsibility |
| --- | --- |
| `Sources/DisplayDials/main.swift` | Menu bar item, panel, More options menu, and diagnostic entry points |
| `Sources/NightShiftBridge/` | Objective-C adapter for the private Night Shift API |
| `Sources/DisplayDials/UpdateController.swift` | Sparkle startup, availability, and preferences |
| `release.json` | Version, increasing build number, feed URL, archive URL prefix, and public update key |
| `scripts/release.py` | Bundle metadata, release validation, and signed archive/appcast preparation |
| `scripts/build-app.sh` | Release build, bundled Sparkle framework, and code signing |

`AppIdentity.version` reads `CFBundleShortVersionString` from the running bundle.
An executable run directly from SwiftPM normally reports `Development`. A bundle
built by `build-app.sh` gets its version and build number from `release.json`.
To rename the product, review `AppIdentity`, `Package.swift`, bundle metadata in
`scripts/release.py`, and paths/names in the build and publication scripts.

## Native interface

`AppDelegate` creates an accessory application with a menu bar item and no Dock
window. Its template SF Symbol is `sun.max`. A transient `NSPopover` contains the
288 × 116 point panel, which opens at launch and when the menu bar item is clicked.
Reopening the application also shows the panel if it is hidden.

`PanelController` uses stock `NSSwitch`, `NSSlider`, `NSButton`, `NSTextField`, and
`NSStackView` controls with system fonts and colors. The slider has 10 tick positions
including both endpoints. It commits once on release. The displayed percentage
uses the system strength; reading an intermediate value does not write a rounded
value back to macOS.

More options opens a native `NSMenu`, populated from the running state each time:

1. An informational app name/version row.
2. Check for Updates…
3. Check for Updates Automatically.
4. Install Updates Automatically.
5. Quit Display Dials.

The menu delegate returns the screen's visible frame as its confinement rectangle.
The small popover must not constrain the menu's height. Update commands reflect
Sparkle availability; automatic installation is disabled in the menu while automatic
checking is off. The version row is disabled deliberately because it has no action.

## Night Shift adapter

`NightShiftBridge` loads the private CoreBrightness framework and checks method
signatures, status structure size, and alignment before invoking the system client.
The ABI reference is [Shifty's CBBlueLightClient header](https://github.com/thompsonate/Shifty/blob/master/Shifty/CBBlueLightClient.h).
Matching the ABI does not guarantee compatibility with future macOS versions.

All bridge calls run on the main thread. Reads return availability, enabled and
active state, and strength. The UI uses the enabled flag for its switch and On/Off
label; it does not display the separate active flag. Invalid responses or missing
availability disable the controls. User actions invoke `setEnabled:` or
`setStrength:commit:`. The adapter rejects nonfinite or out-of-range strength values.

Changes apply through macOS globally, preserve its schedule, and persist after
Display Dials exits. The app does not implement per-monitor controls or render a
display overlay. Strength is a normalized 0–1 setting, not calibrated kelvin.

## Resource use and lifecycle

The panel reads state on opening, after a user action, and every five seconds while
visible. The timer has one second of tolerance to allow wakeup coalescing. Changes
made elsewhere may take roughly six seconds to appear, or longer if the run loop
is busy. Own control actions refresh immediately.

Before installing a visibility timer, the controller invalidates the previous one.
Closing the panel invalidates it and clears its reference. Polls execute on the
main run loop without creating a Task. An unchanged state skips UI property writes.
After user actions, cached state is invalidated so controls are restored from the
system even if the same write error occurs repeatedly.

The app has no continuous animation/rendering loop, sleep-prevention assertion,
or explicit App Nap opt-out. Sparkle's scheduler is independent of the panel timer;
update checking, downloading and installation can temporarily use resources.
Timer policy follows [Apple's energy-efficiency guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html).

### Local review, 2026-11-07

The installed release passed build, signature verification and read-only UI smoke
checks. A three-second stack sample found the main thread predominantly waiting
in the system event loop. No Display Dials power assertion or persistent helper
process was observed.

After the panel was closed and settled, a 45-second sample recorded 0.00229 CPU
seconds (0.0051% of one core), 19.3 MiB physical footprint, 84.1 MiB RSS, no physical
disk reads/writes, no package-idle wakeups and one interrupt wakeup. An earlier
45-second interval immediately after closing included 0.126% CPU, 12 KiB of reads
and 557 interrupt wakeups. Transient activity is not zero. RSS includes shared
mapped libraries and is not interchangeable with physical footprint.

[Raw samples and measurement caveats](performance-samples.json) include all
intervals. They are short observations, not a battery discharge test, proof of
long-term leak freedom, or a controlled before/after benchmark. Updates were not
downloaded or installed during these samples. The measurements predate the later
version-row and menu-confinement changes and are not a profile of every revision.

## Updates

`UpdateController` owns Sparkle's `SPUStandardUpdaterController`. It starts only
inside an app bundle containing the feed URL and public key, outside the diagnostics
and smoke-test paths. Running the raw SwiftPM executable does not start the updater.
The More options menu reads current preferences and availability whenever it opens.

Generated bundle defaults enable automatic checks and automatic installation;
existing user preferences may override them. Checks use a four-hour interval while
the app runs. The installation preference maps to Sparkle's
`automaticallyDownloadsUpdates`; Sparkle handles the remaining installation flow,
which can wait for quit or permission.

Release builds contain only arm64 slices, including bundled Sparkle executables.
The packaging script requires an `arm64` appcast hardware requirement, verifies
archive and appcast Ed25519 signatures, and uses one persistent update identity.
Bundle settings require signed feeds with no expiration fallback and verification
before extraction. System profiling is disabled, and optional sandbox XPC services
are removed from the bundle. Application signing is currently ad hoc.

See [release operations](releases.md) for the publication pipeline and the future
Developer ID/notarization transition.

## Validation and diagnostics

Run from the repository root on an Apple Silicon Mac:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
app_binary="$HOME/Library/Developer/DisplayDials/Display Dials.app/Contents/MacOS/DisplayDials"
"$app_binary" --diagnostics
"$app_binary" --smoke-test --snapshot /tmp/display-dials-panel.png
```

`test.sh` builds a debug executable, prints Night Shift diagnostics, then initializes
the UI and exits. It is an integration smoke check, not a unit-test suite. Neither
path writes Night Shift settings or starts the updater. The build script creates
and signs the release bundle and verifies its code signature.

`--diagnostics` emits JSON containing app name/version, Night Shift support,
diagnostic text, and current state. `--smoke-test` initializes the panel and exits;
`--snapshot PATH` optionally saves its PNG rendering when used with that flag.
Snapshot output is best-effort: the smoke path does not fail if writing the PNG
fails, so check that the file exists before using it for visual review.

For a raw SwiftPM run using the same cache as the scripts:

```sh
build_dir="${DISPLAY_DIALS_BUILD_DIR:-$HOME/Library/Developer/DisplayDials/Build}"
swift run --scratch-path "$build_dir" --arch arm64 DisplayDials --diagnostics
```

Read-only checks do not validate setting writes, updater installation, every display
configuration, or compatibility with future macOS releases. Manual checks should
cover switching Night Shift, selecting slider positions, reopening the panel after
external changes, and opening the complete options menu through Quit. Restore the
original Night Shift settings after a manual write check.
