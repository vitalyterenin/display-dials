# Display Dials 0.3.0 implementation

## Goal and current status

Two controls for a MacBook Pro's built-in XDR display: warmth and brightness boost.
The scope excludes application exceptions, advanced monitor management, and telemetry.
The user verified Night Shift in 0.1.0. Brightness boost remains experimental:
**an absolute brightness increase over the original display state has not been confirmed**.

To rename the app, update AppIdentity, Package.swift, and the metadata in build-app.sh.

## Continuous operation in 0.3.0

The user reported no visible flicker in the 0.2.1 retest and requested removal of
the 30-second limit. Ordinary Boost now has no fixed session deadline. It still
starts disabled and must be explicitly enabled again after sleep/wake.

The former unconditional 35-second process exit has been replaced by a renewable
3-second health watchdog running on a separate dispatch queue. Only a completed
worker health/render tick renews it. A blocked main loop exits with status 75;
the parent reports this as an unresponsive worker rather than a session timeout.
The normal heartbeat checks, thermal checks, and gain ceiling are unchanged.
A 30-second deadline exists only with the explicit diagnostic `--bounded-check`
flag. `--stall-check` deliberately blocks the main loop to test the watchdog.

17 state/policy tests passed, including a modeled three-minute session and sleep
without automatic restart. Live EOF, missed-heartbeat, SIGKILL, deliberate main-loop
stall, and bounded diagnostic checks passed. A full-desktop 90-second run stayed
active beyond both former deadlines; gain after startup stayed at 1.1000 and EDR
headroom stayed at 4. This verifies reported software state, not absolute luminance
or long-term thermal stability.

A real system sleep was initiated with `pmset sleepnow`. The worker stopped with
reason `sleeping` before sleep. The diagnostic then received a real NSWorkspace
wake notification and verified that Boost remained off. The explicit restart check
could not complete: the session remained locked for its 120-second waiting period.
The diagnostic exited with Boost off. Manual restart after unlock remains to be
verified; this waiting timeout is diagnostic-only, not a Boost session deadline.

The diagnostic `--sleep-check` enables Boost, waits for an actual NSWorkspace wake
notification, checks that Boost remains off, waits for unlock, and issues a separate
explicit restart action. It writes its result to
`~/Library/Logs/DisplayDials/sleep-check.json`. It does not initiate sleep or change
the ordinary app's resume policy.

The latest-session trace now wraps at approximately 1 MB so a long-running session
can still record its eventual stop reason without unbounded log growth.

## Stability changes in 0.2.1

The user reported intermittent visible brightness gains and flicker in 0.2.0.
The exact physical cause of the flicker has not been established. This patch
addresses three plausible contributors in the rendering/startup path:

- Render keepalive changes from about 1 Hz to about 5 Hz. The HDR marker is kept
  one window level above the multiplying overlay, and window visibility is set only
  after the first completed frame rather than on every frame.
- Preparation requires at least 1 second and 0.6 seconds of settled usable headroom
  before enabling gain. A changing startup value is no longer immediately latched
  as the trial's permanent multiplier ceiling. Preparation remains limited to 5 seconds.
- Gain increases are limited to 0.10 multiplier units per second, with at most
  250 ms credited per update. Headroom reductions and safety stops remain immediate.
  Headroom recovery never restores a multiplier reduced by a headroom drop.

The controller writes a local, owner-readable trace of the latest trial to
`~/Library/Logs/DisplayDials/latest-boost.jsonl`. It captures reports and process exit
status without screen content or uploads. A stalled worker now has a distinct
stop reason rather than a generic rendering error. The 30-second limit is unchanged.

16 automated state/policy tests cover the revised preparation and ramp behavior.
The updated worker passed EOF, missed-heartbeat, SIGKILL, and 30-second timeout
checks with the tiny HDR marker. The release controller integration and startup
smoke checks also passed. The latest trace captured active status, an intentional
manual stop, and an observed rendering cadence of approximately 5 frames/s. A manual
stop can record exit status 15 because the controller explicitly sends SIGTERM;
this is distinct from an unexpected worker failure.
Automated frame counters and tests cannot establish that visible flicker is fixed;
that requires another manual check on the display.

## Rendering path

`BoostController` launches the current executable with `--boost-worker`. The main
app does not own the boost windows. It sends a JSON heartbeat over stdin every
250 ms; the child process returns status over stdout. Invalid messages are rejected.

`HDRRenderer` renders uniform RGBA16Float surfaces in extended linear sRGB. A tiny
HDR marker requests EDR headroom from macOS. The desktop multiplier stays at 1 until
actual headroom becomes available and settles. A separate layer then uses `multiply` compositing.
This relies on experimental macOS compositor behavior, not a documented Apple API
for increasing whole-desktop brightness. Third-party renderer implementations are
not included in the project; this implementation was written independently.

There are no calls that change system brightness, gamma tables, display presets,
or automatic brightness. The windows pass through mouse input, cannot become key
or main windows, participate in all Spaces, and close when their process exits.
Native fullscreen behavior still needs manual verification.

## Experimental limits

- Only a built-in Apple Silicon display with potential EDR > 1, without mirroring.
- No fixed duration limit in normal operation. Preparation is limited to 5 seconds.
- A multiplier of 1.00–1.25, defaulting to 1.10. This is not a percentage of physical nits.
- Output does not exceed current headroom. After headroom decreases, the multiplier
  does not rise automatically when it recovers; increasing it requires another
  slider adjustment. Losing headroom entirely stops the trial.
- Any thermalState above nominal stops the trial. This is a system signal,
  **not a panel temperature sensor**.
- Sleep, session locking/deactivation, wake, display topology/mode changes, GPU
  failure, and launching a known conflicting utility stop the trial.
- BetterDisplay, BrightIntosh, and Vivid are detected through running applications.
  This is conservative: the app cannot determine whether their boost is enabled.
- Missing heartbeats for more than 1.5 seconds terminates the worker. The parent
  terminates the worker if reports stop for more than 2.5 seconds. A timer independent
  of the main run loop exits the worker if health/render progress stops for 3 seconds.
- Restarting, waking, or resolving the stop condition does not resume boost.

The 1.25 multiplier ceiling is not a proven safe value for panel lifespan. System
protections are not bypassed, but zero impact on heat, power consumption, or aging
is not promised. Continuous operation is enabled in 0.3.0 with the same safety stops.

## Night Shift

`NightShiftBridge` isolates the private CoreBrightness API. It checks signatures,
structure size, and alignment. Matching the ABI does not guarantee compatibility
with future macOS versions. Changes apply globally, require user action, and persist
after the app exits. The system schedule is preserved. The 0–100% level does not
represent a calibrated color temperature in kelvin.

## Earlier validation on 2026-10-30 (0.2.0)

Environment: Apple M1 Pro, macOS 27.2, Swift 6.4.2 / Command Line Tools.

- 14 policy and state tests cover limits, NaN/Infinity, timing, heartbeats, GPU
  readiness, thermal state, sleep, display changes, conflicts, headroom loss, and
  prevention of automatic recovery. These tests simulate conditions rather than
  heating the physical display.
- Offscreen GPU check: a floating-point value of 1.10 was stored as 1.099609375
  due to FP16 precision. This check does not change the display.
- Window-free IPC checks: EOF, malformed JSON, and a zero multiplier are rejected
  before renderer creation.
- Integration check, `--controller-check`: the real controller starts a worker with
  one HDR marker, receives active status, stops it after 3 seconds, and receives off.
- The 0.2.0 release bundle passes signature verification and the startup smoke test.
  A PNG rendering of the updated panel was inspected. Boost stays disabled at launch.
- Live tests using one tiny HDR marker, **without a desktop overlay**, cover EOF,
  missing heartbeats with the channel still open, SIGKILL, and the full 30-second
  timeout. Status reports and process exits were checked. Physical luminance after
  SIGKILL was not measured.
- Fullscreen trial at ×1.05: Metal rendered frames; the user did not notice a difference.
- Right-half trial at ×1.20: the user initially saw a brighter right side, then noted
  that this might be dimming of the left side rather than brightening of the right.
  **The initial claim that brightness boost had been demonstrated was withdrawn.**
- In the HDR-marker-only trial, CoreDisplay user/linear/dynamicLinear readbacks
  stayed at 1.0 while current EDR changed from 1 to 4. These getters return software
  values, not photometer measurements. They do not prove that SDR pixel light output
  stayed unchanged.

## Next validation

Compare the same static area before enabling the effect, while it is enabled, and
after disabling the entire effect. A split-screen trial shows only relative contrast.
An objective conclusion requires luminance measurements with a colorimeter or light
meter at a fixed position, or at least an external camera with exposure locked for
a relative comparison. Screenshots, EDR headroom, and float buffers do not measure
physical light output.

Before continuous operation, verify absolute brightness gain, absence of unwanted
SDR dimming, color and HDR video behavior, native fullscreen Spaces, sleep/locking,
and sustained heat and power consumption. Do not raise limits solely to make the
effect more noticeable.

## Developer commands

```sh
bash scripts/test.sh
swift run DisplayDials --renderer-check
python3 scripts/check-worker.py
# Explicit live HDR checks, including a diagnostic-only 30-second deadline:
python3 scripts/check-worker.py --live
# Full-desktop boost for 90 seconds, then stop:
python3 scripts/check-worker.py --sustained
# Actual system sleep/wake diagnostic; sleep must be initiated separately:
swift run DisplayDials --sleep-check
bash scripts/build-app.sh
```

`--boost-worker --compare` limits the diagnostic overlay to the right half of the
screen. `--boost-worker --trigger-only` draws only the HDR marker. Both require
heartbeats over stdin and follow the same restrictions, including conflict and
thermal checks.

## Sources

- [Apple: MacBook Pro 14 (2021)](https://support.apple.com/en-us/111902)
- [Apple: temperature-related XDR brightness limits](https://support.apple.com/en-ie/101865)
- [Apple: EDR rendering, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10161/)
- [Apple: current EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumextendeddynamicrangecolorcomponentvalue)
- [Apple: thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property)
- [BetterDisplay: brightness upscaling methods](https://betterdisplay.pro/guide/tutorials/xdr-and-hdr-brightness-upscaling/)
- [BrightIntosh: Metal compositing reference](https://github.com/niklasr22/BrightIntosh)
- [Shifty: Night Shift ABI](https://github.com/thompsonate/Shifty/blob/master/Shifty/CBBlueLightClient.h)
- [Lunar: read-only CoreDisplay getter signatures](https://github.com/alin23/Lunar/blob/master/Lunar/DDC/Lunar-Bridging-Header.h)
