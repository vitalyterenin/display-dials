# Display Dials 0.5.0 implementation

## Scope

Display Dials controls display warmth using macOS Night Shift. The panel contains
an on/off switch, a 10-position warmth slider, and a concise status label.
The More options button opens a native `NSMenu` for updates and Quit. The menu
bar uses the template SF Symbol `sun.max`. The panel uses only stock AppKit
controls, system fonts and colors, and the standard `NSPopover` background. The displayed percentage reflects the current system strength;
reading an intermediate value does not commit a rounded slider position.

To rename the app, update AppIdentity, Package.swift, and the metadata in scripts/release.py.
Version, increasing build number, feed URL, and public update key live in release.json.

## Night Shift

`NightShiftBridge` isolates the private CoreBrightness API. It checks method
signatures, structure size, and alignment before invoking the system client.
Matching the ABI does not guarantee compatibility with future macOS versions.
The ABI reference is [Shifty's CBBlueLightClient header](https://github.com/thompsonate/Shifty/blob/master/Shifty/CBBlueLightClient.h).

All bridge calls run on the main thread. Reads query availability, enabled and
active state, and strength. Invalid or unavailable responses disable the controls.
User actions call `setEnabled:` or `setStrength:commit:`. Changes apply globally,
preserve the system schedule, and persist after the app exits. The 0–100% level
does not represent a calibrated color temperature in kelvin.

`PanelController` refreshes state when opened, after a setting change, and every
five seconds while visible (with one second of timer tolerance). The slider commits once on release. Launch, diagnostics,
and the UI smoke check only read system settings.

## Validation

```sh
# Compile and exercise read-only diagnostics and UI initialization.
bash scripts/test.sh
# Build and verify the signed release bundle.
bash scripts/build-app.sh
# Capture the panel for visual inspection without changing settings.
swift run DisplayDials --smoke-test --snapshot /tmp/display-dials-panel.png
```

The validation script does not toggle Night Shift or change its strength. Manual
checks of setting changes require interacting with the switch and slider.

## Updates

`UpdateController` owns Sparkle's `SPUStandardUpdaterController`. It starts only
inside a configured app bundle, after bypassing the read-only diagnostics and
UI smoke-test paths. Running the raw Swift executable never starts an updater.
The More options menu reads Sparkle's current settings and availability each time
it opens. Both automatic checks and automatic installation default to enabled;
users can disable either. Checks are scheduled every four hours while running.

Only Apple Silicon application binaries are built. Sparkle's signed appcast must
contain the `arm64` hardware requirement. Archives and appcasts are signed with
the same persistent Ed25519 identity; both signatures are checked before release.
Unsigned or incorrectly signed feeds are rejected without an expiration fallback.
The app does not use the optional sandbox XPC services or send system profiles.

Application signing is currently ad hoc. A future Developer ID signing identity
can be supplied through `DISPLAY_DIALS_SIGN_IDENTITY`; notarization and stapling
must then be added before packaging. Feed URL, bundle identifier, Sparkle key and
update code do not need to change for that transition.

## Resource use and lifecycle

The app delegates display warmth to macOS. It does not render an overlay or run
an animation loop. The panel polls Night Shift only while visible, every five
seconds with one second of tolerance so the system can coalesce timer wakeups.
Opening the panel and applying a control change refresh immediately. A change
made in another utility may take roughly six seconds to appear in an open panel,
or longer if the run loop is busy.

Repeated appearance callbacks invalidate the previous timer before installing a
new one. Closing the panel invalidates the timer. A poll executes directly on the
main run loop without spawning a Task. Unchanged state skips UI property writes;
a user action always restores controls from the system response, including
repeated write failures.

Sparkle separately schedules update checks at the configured four-hour interval.
Automatic update downloads and installations can temporarily use CPU, network,
and disk. The application does not prevent system sleep or opt out of App Nap.

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
and 557 interrupt wakeups; transient activity is not zero. RSS includes shared
mapped libraries and is not interchangeable with physical footprint.

[Raw samples and measurement caveats](performance-samples.json) include all
intervals. These short observations are not a battery discharge test, a proof of
long-term leak freedom, or a controlled benchmark of the optimization. Updates
may temporarily consume additional resources. Night Shift still uses a private
macOS API, whose compatibility remains a separate limitation.
