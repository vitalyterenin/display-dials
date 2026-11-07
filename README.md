# Display Dials

A compact macOS menu bar app for display warmth through Night Shift.

## Prototype status: 0.5.0

- A compact native AppKit panel with a system sun symbol in the menu bar.
- Night Shift status and controls stay in the panel; updates and Quit are in the
  standard More options menu. Layout, controls, and symbols use macOS components.
- A Night Shift on/off switch and a warmth slider with exactly 10 selectable
  positions, including both endpoints. An existing strength between positions
  remains unchanged until adjusted.
- The macOS Night Shift schedule is preserved. Changes apply globally through macOS
  and persist after the app quits.
- At launch, the app only reads settings. Changes require user action.
- One stable update feed hosted at `https://teren.in/updates/display-dials/appcast.xml`.
- Automatic update checks and installation can be changed in More options.
- There is no analytics or system profiling. Update requests contact the update host.

## Build and validate

Requires an Apple Silicon Mac, macOS 13+, and Swift 6+ through Xcode or Command Line
Tools. Intel Macs are not supported. Sparkle 2.10.1 is pinned through Swift Package
Manager; the first build needs network access to download it.

```sh
# Build and run read-only diagnostics and a UI smoke check.
bash scripts/test.sh
# Build and sign the local app bundle.
bash scripts/build-app.sh
```

The local app bundle is built at `~/Library/Developer/DisplayDials/Display Dials.app`.
It is built outside Documents because that directory's file provider adds metadata
that invalidates the app signature. Override the destination with
`DISPLAY_DIALS_OUTPUT_DIR`. Build scripts keep their cache at
`~/Library/Developer/DisplayDials/Build` to avoid the same file-provider delays;
override it with `DISPLAY_DIALS_BUILD_DIR`. The bundle includes Sparkle and uses a
free ad hoc code signature, without Apple notarization. The first downloaded
installation may require **System Settings > Privacy & Security > Open Anyway**.
Automatic updates are authenticated with the app's Ed25519 key.

```sh
# Read-only Night Shift diagnostics; no display changes.
swift run DisplayDials --diagnostics
# Initialize the UI and exit without writing display settings.
swift run DisplayDials --smoke-test
# Optionally save a PNG of the panel during the smoke check.
swift run DisplayDials --smoke-test --snapshot /tmp/display-dials-panel.png
# Open the panel from the built app.
open "$HOME/Library/Developer/DisplayDials/Display Dials.app"
```

## Limitations

Night Shift uses the private CoreBrightness API. Apple may change it in any macOS
release. The adapter checks method availability and data formats, disabling controls
when incompatible. This is a prototype for direct distribution, not a ready-to-submit
Mac App Store app. Changing settings simultaneously in Shifty or other utilities
can cause competing updates; Display Dials rereads the system state.

See [docs/implementation.md](docs/implementation.md) for implementation details.
See [docs/releases.md](docs/releases.md) for publishing and signing-key setup.
