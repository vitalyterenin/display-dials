# Display Dials

A small macOS menu bar app for adjusting display warmth with Night Shift.
The interface uses native AppKit controls and a system sun symbol.

## Requirements

- An Apple Silicon Mac running macOS 13 or later. Distributed builds are arm64 only.
- Night Shift must be available on the current system for warmth controls to work.
- Building from source requires Swift 6 or later through Xcode or Command Line
  Tools. The first build downloads the pinned Sparkle 2.10.1 dependency.

## Using the app

Open Display Dials, then click the sun in the menu bar to show or hide its panel.
The panel also opens on a normal launch. Automatic launch at login keeps the app
in the menu bar without opening the panel.

- **Night Shift switch:** enables or disables the system setting.
- **Warmth slider:** selects one of 10 positions from Cooler to Warmer. A change
  is applied when you release the slider. The percentage shows system strength,
  not a calibrated color temperature.
- **Status:** shows `On · …%`, `Off`, or `Unavailable`. On reflects the system's
  enabled setting; it is not a measurement of the screen's current color.
- **More options (…):** shows the installed version, **Launch at Login**, update
  commands and preferences, **Usage Statistics…**, and **Quit Display Dials**.
  The version row is informational and cannot be clicked.

The slider is disabled when Night Shift is off. When Night Shift is unavailable,
both controls are disabled; hover over the status for diagnostic details.
An unsuccessful setting change displays an error in the status line.

Changes use macOS Night Shift globally, preserve its schedule, and persist after
Display Dials quits. Display Dials has no independent schedule, brightness control,
or per-monitor settings. Existing strength values between the slider's positions
are not changed just by opening the panel.

## Launch at login

Use **More options (…) > Launch at Login** to start Display Dials automatically
when you sign in to macOS, or turn it off again. The app does not add itself to
Login Items automatically. Turning this setting off leaves the current app
running and prevents its automatic launch on subsequent logins.

The checkmark reflects macOS Login Items rather than a separate saved app setting.
If macOS requires approval, the menu shows **Launch at Login (Approval Required)**
with a mixed mark and provides **Allow in System Settings…**. You can grant approval
in **System Settings > General > Login Items & Extensions**, or turn the setting off
in the app. Names in System Settings can vary with the macOS version.

Install the app on a writable disk before changing this preference. The setting
is unavailable from a read-only DMG or a raw SwiftPM executable. Diagnostics and
smoke checks never register or unregister login items.

## Install or build locally

Download the current release from the permanent [DisplayDials.dmg](https://teren.in/apps/DisplayDials.dmg) link.
Each publication replaces this file; the download name does not include a version.

Open the downloaded DMG, drag **Display Dials.app** onto the **Applications**
shortcut, then eject the disk image and open the installed app. You can instead
copy it to a writable location such as `~/Applications`. Builds currently use ad hoc code
signing and are not notarized. A downloaded copy may require approval through
**System Settings > Privacy & Security > Open Anyway** on its first launch.

To build from a checkout, run these commands in the repository root:

```sh
# Compile, print read-only diagnostics, and initialize the UI without changing Night Shift.
bash scripts/test.sh
# Build an arm64 release bundle, include Sparkle, and verify its code signature.
bash scripts/build-app.sh
# Launch the built application.
open "$HOME/Library/Developer/DisplayDials/Display Dials.app"
```

The build script replaces its existing output bundle. By default, the bundle is at
`~/Library/Developer/DisplayDials/Display Dials.app` and the build cache is at
`~/Library/Developer/DisplayDials/Build`. They live outside Documents to avoid
file-provider metadata invalidating signatures and slowing cache access.
Override them with `DISPLAY_DIALS_OUTPUT_DIR` and `DISPLAY_DIALS_BUILD_DIR`.

## Updates and version

The first row of **More options (…)** displays the running app's version from its
bundle metadata. [release.json](release.json) defines the source version and build
number; it does not prove that a corresponding release has already been published.

Sparkle checks the [stable update feed](https://teren.in/apps/feeds/display-dials.xml).
Automatic checks and automatic installation default to enabled; saved user
preferences take precedence. Use **Check for Updates…** to check manually, or
change the two automatic-update preferences in the same menu. Automatic installation
is unavailable in the menu while automatic checks are off.

Scheduled checks use a four-hour interval while the app is running. Installation
can require quitting the app or granting permission; it is not guaranteed to happen
immediately after a check. Both the appcast and update archives require signatures.
Update requests contact the update host. Sparkle system profiling is disabled.

## Optional usage statistics

On the first launch of a build with statistics support, Display Dials asks whether
to share usage statistics with the developer through TelemetryDeck. This includes
existing users upgrading from a version without statistics. Nothing is collected
or sent before consent, and declining does not affect any app features.

Use **More options (…) > Usage Statistics… > Share Usage Statistics** to change
your choice. Turning sharing off discards unsent events, cancels outstanding
requests where possible, and resets the local random installation identifier.
It does not remove events already received by TelemetryDeck.

The app sends a small explicit set of usage events, selected update preferences,
app/macOS versions, timestamps and random identifiers. It does not use automatic
screen capture, hardware identifiers, or collect file contents or personal contact
details. Read the [complete data and storage disclosure](docs/privacy.md).

## Resource use

The warmth effect is handled by macOS. Display Dials polls Night Shift only while
its panel is visible, every five seconds with one second of timer tolerance.
User actions and reopening refresh immediately. Changes made by another utility
can therefore take several seconds to appear in an already open panel.
Closing the panel stops this polling; Sparkle's update scheduler remains separate.

A short local idle sample recorded about 0.005% of one CPU core and 19.3 MiB of
physical footprint. These measurements predate optional statistics. They are observations on one machine, not a battery-life
promise. See the [measurement details and limitations](docs/implementation.md#local-review-2026-11-07).

## Diagnostics and limitations

After building the bundle, these commands read settings without changing Night Shift
or starting the updater:

```sh
app_binary="$HOME/Library/Developer/DisplayDials/Display Dials.app/Contents/MacOS/DisplayDials"
"$app_binary" --diagnostics
"$app_binary" --smoke-test
"$app_binary" --smoke-test --snapshot /tmp/display-dials-panel.png
```

Night Shift access uses the private CoreBrightness API. macOS changes can break
compatibility; the adapter checks method signatures and status layout before use.
Other Night Shift utilities can compete with setting changes. This is a prototype
for direct distribution and is not ready for Mac App Store submission.

See [implementation and validation](docs/implementation.md) for the code structure,
and [release operations](docs/releases.md) for signing, packaging, and publication.
