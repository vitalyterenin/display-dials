# Display Dials

A compact macOS menu bar app for display warmth and experimental brightness boost.

## Prototype status: 0.2.1

- A native menu bar panel with no Dock window.
- Night Shift status, an on/off switch, and a warmth slider.
- The macOS Night Shift schedule is preserved. Changes apply globally through macOS,
  rather than per monitor, and persist after the app quits.
- Read-only queries for built-in display capabilities and current EDR headroom.
- **Brightness boost is an experimental 30-second trial**, started manually.
  A Metal overlay runs in a separate process. The multiplier ranges from 1.00 to 1.25
  and defaults to 1.10. Selecting 1.00 stops the trial.
- The multiplier is capped by current EDR headroom. If available headroom decreases,
  the app does not automatically raise the multiplier when headroom recovers.
- The trial stops when thermal state rises above nominal, the display sleeps, the
  session locks, display configuration changes, the GPU fails, or communication with
  the panel is lost. It does not resume automatically.
- BetterDisplay, BrightIntosh, and Vivid must be closed before a trial. This checks
  for conflicting utilities; it does not implement application exclusions.
- System brightness, gamma tables, and display presets are not overwritten.

Manual testing has shown a visible effect, but brightness flicker was reported in
0.2.0. Version 0.2.1 adds a steady rendering cadence, settled-headroom preparation,
and gradual gain increases. These changes still need visual confirmation on the
display. Absolute luminance gain has not been measured with an external instrument.

At launch, the app only reads settings. Night Shift changes require user action.
Brightness boost always starts disabled. There are no servers or analytics.

## Build

Requires macOS 13+ and Swift 6+ through Xcode or Command Line Tools. There are no
third-party dependencies.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
# IPC checks without windows or display changes:
python3 scripts/check-worker.py
```

The local app bundle is built at `~/Library/Developer/DisplayDials/Display Dials.app`.
It is built outside Documents because that directory's file provider adds metadata
that invalidates the app signature. Override the destination with
`DISPLAY_DIALS_OUTPUT_DIR`. The bundle is ad hoc signed for local use, without
notarization or automatic updates. The test script works around Swift Testing macro
plugin discovery in Command Line Tools 27.2.

```sh
# Read-only diagnostics; no display changes.
swift run DisplayDials --diagnostics
# Initialize the UI and exit immediately without writing display settings.
swift run DisplayDials --smoke-test
# Check floating-point GPU rendering without displaying the result.
swift run DisplayDials --renderer-check
# Open the panel from the built app.
"$HOME/Library/Developer/DisplayDials/Display Dials.app/Contents/MacOS/DisplayDials"
```

## Trial diagnostics

The latest trial is recorded locally at
`~/Library/Logs/DisplayDials/latest-boost.jsonl`. It contains status, headroom,
frame counts, brightness readbacks, and the stop reason/exit status. It records no
screen content and is not uploaded. Each trial replaces the previous trace; the
file is capped at approximately 1 MB and readable only by the current user.

## Limitations

Night Shift uses the private CoreBrightness API. Apple may change it in any macOS
release. The adapter checks method availability and data formats, disabling controls
when incompatible. This is a prototype for direct distribution, not a ready-to-submit
Mac App Store app. Changing settings simultaneously in Shifty or other utilities
can cause competing updates; Display Dials rereads the system state.

EDR headroom is relative HDR rendering capacity, **not a measurement in nits or a
guarantee of panel safety**. Increased brightness may affect heat and display aging.
The 1.25 multiplier and 30-second limit are experimental parameters, not certified
safe operating values. A continuous mode is not available yet.

See [docs/implementation.md](docs/implementation.md) for implementation details,
validation results, sources, and the remaining brightness-boost checks.
