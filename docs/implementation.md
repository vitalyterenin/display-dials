# Implementation and validation

## Code structure

| File | Responsibility |
| --- | --- |
| `Sources/DisplayDials/main.swift` | Menu bar lifecycle, panel opening, and diagnostic entry points |
| `Sources/DisplayDials/PanelController.swift` | Native panel, More options menu, action/readback coordination and visible-only polling |
| `Sources/DisplayDials/NightShiftClient.swift` | Typed, injectable Night Shift interface and coherent post-read snapshots |
| `Sources/NightShiftBridge/` | Objective-C adapter for the private Night Shift API |
| `Sources/DisplayDials/RuntimeStatus.swift` | Read-only local queries of the running app’s own state |
| `Sources/DisplayDials/UpdateController.swift` | Sparkle startup, availability, and preferences |
| `Sources/DisplayDials/WarmthAdjustment.swift` | Off/on mapping, ordered setting writes and failure handling |
| `Sources/DisplayDials/WarmthSlider.swift` | Continuous native slider, tick deduplication and drag completion |
| `Sources/DisplayDials/OptionsMenuPresentation.swift` | Screen-coordinate menu anchor, independent of popover bounds |
| `Sources/DisplayDials/LoginItemController.swift` | Native macOS login-item registration, status, and launch detection |
| `Sources/DisplayDials/AppearanceShortcut.swift` | Fixed global Option–Command–N registration, press dispatch, repeat suppression and conflict reporting |
| `Sources/DisplayDials/AppearanceController.swift` | Asynchronous System Events appearance toggle, readback and Automation errors |
| `Sources/DisplayDials/SystemAppearanceClient.swift` | Typed System Events get/set Apple events and reply validation |
| `Resources/AppIcon.png` | Approved transparent application icon; build generates all standard and Retina ICNS sizes |
| `Resources/PrivacyInfo.xcprivacy` | App privacy manifest, included in release bundles |
| `release.json` | Version, increasing build number, feed/download URLs, application ID, and public update key |
| `scripts/release.py` | Bundle metadata, release validation, and signed archive/appcast preparation |
| `scripts/build-app.sh` | Release build, bundled Sparkle framework, notices, and code signing |
| `scripts/signing.py` | Persistent certificate import, signing preflight and app/updater identity verification |
| `scripts/licenses.py` | Approved MIT terms, dependency notices and app/DMG license verification |

`AppIdentity.version` reads `CFBundleShortVersionString` from the running bundle.
An executable run directly from SwiftPM normally reports `Development`. A bundle
built by `build-app.sh` gets its version and build number from `release.json`.
To rename the product, review `AppIdentity`, `Package.swift`, bundle metadata in
`scripts/release.py`, and paths/names in the build and publication scripts.

### Ownership and execution boundaries

The executable entry point handles `--status` first, then `--diagnostics`, then
the AppKit application path (including `--smoke-test`). `AppDelegate` owns the
status item, transient popover and status responder. The popover owns its
`PanelController`; that controller owns the Night Shift client, updater, login-item
adapter, appearance controller, global shortcut and visible-panel timer. These Swift controllers run on the main actor.
The Objective-C bridge separately rejects invocations off the main thread.

The main control flow is:

```text
Menu bar / reopen / interactive launch
  -> AppDelegate.showPanel
     -> NSPopover -> PanelController.refresh -> DDWarmthClient

Native slider action
  -> PanelController.changeWarmth -> fresh availability read
     -> WarmthAdjustment.apply -> DDWarmthClient writes
     -> record result -> fresh read -> panel update and knob reconciliation

More options -> UpdateController / LoginItemController
Option–Command–N / More options -> AppearanceController -> SystemAppearanceClient -> System Events
--status -> distributed notification -> running app snapshot -> JSON response
```

`WarmthAdjustment` owns write ordering, while `WarmthSlider` owns native tracking
and duplicate-tick suppression. Neither owns system state. `DDWarmthClient` returns
an optional dictionary of numeric values. `NightShiftClient` validates and converts
it into `NightShiftState`, then captures the bridge's support and diagnostic
properties after the read. `NightShiftSnapshot` carries these values together.
`PanelController` accepts `NightShiftControlling` in its initializer; normal
construction uses the real bridge. Controller tests use a fake system client to
exercise the complete read/action/reconciliation path without changing macOS settings.

### State and compatibility contracts

| State | Owner and lifetime | Contract |
| --- | --- | --- |
| Enabled, active, strength and schedule | macOS, beyond the app process | Reads never write; Off preserves remembered strength; the app does not own the schedule |
| Last rendered state and setting error | `PanelController`, process lifetime | Identical state skips label and availability updates. A successful later action clears a setting error |
| Drag deduplication and reconciliation | `WarmthSlider` and `PanelController`, one gesture | Changed ticks apply immediately. The knob reconciles on drag completion and after non-drag actions, even if the last rendered state still matches |
| Login registration | `SMAppService.mainApp` | No duplicate app preference; read OS status each time; change only on explicit menu action |
| Automatic update choices | Sparkle preferences | Generated bundle defaults apply only when no saved user choice overrides them |

For baseline findings, implemented changes and validation evidence, see the
[2026-11-08 refactoring review](refactoring-review.md).

## Native interface

`AppDelegate` creates an accessory application with a menu bar item and no Dock
window. Its template SF Symbol is `sun.max`. A transient `NSPopover` contains the
288 × 116 point panel, which opens on interactive launch and when the menu bar item is clicked.
Login launches stay quiet. The first manual opening shows the panel directly.
Reopening the application also shows the panel if it is hidden.

`PanelController` uses native `NSSlider`, `NSButton`, `NSTextField`, and
`NSStackView` controls with system fonts and colors. The slider has 10 tick positions
including both endpoints: Off at zero and nine positive warmth levels. There is
no separate switch. The slider remains enabled while Night Shift is off, and is
disabled only when the system is unavailable. It applies each new tick immediately
while dragging. Repeated mouse events
within the same tick are suppressed by `WarmthSlider`; returning to an earlier
tick applies it again. If an external enabled state snaps visually to zero,
the first explicit Off action is delivered even though the knob is already there.
Later duplicate events in that gesture are suppressed. A failed disable can be
retried with another Off gesture. System reads do not reposition the knob during tracking.
After tracking ends, the slider reconciles with the system. Keyboard and
accessibility changes apply immediately. The displayed percentage
uses the system strength; reading an intermediate value does not write a rounded
value back to macOS.

More options opens a native `NSMenu`, populated from the running state each time:

1. Toggle Light / Dark Appearance (⌥⌘N), with a shortcut retry row if registration failed.
2. Launch at Login, with a System Settings action when approval is required.
3. Updates, a submenu containing Check for Updates…, Automatically Check for
   Updates, Automatically Install Updates, and the read-only Version row.
4. Quit Display Dials.

`OptionsMenuPresentation` converts the button's bounds through window coordinates
to a screen point and opens the menu with `in: nil`. This disconnects menu sizing
from the 288 × 116 point popover. No fixed menu height or per-item sizing is used;
AppKit places the complete menu within the available screen. A delegate confinement
rectangle alone did not reliably prevent clipping when the button was inside a
popover. Update commands reflect
Sparkle availability; automatic installation is disabled in the menu while automatic
checking is off. The version row is disabled deliberately because it has no action.

## System appearance and global shortcut

`AppearanceShortcut` registers the physical N key with Option and Command through
Carbon's `RegisterEventHotKey`. Exclusive registration reports conflicts rather
than sharing the key with another app. The application event handler accepts only
its own identifier, starts the action on key press and rearms on release. Repeated
press events while held are ignored, giving one action per gesture without waiting
for the user to release N.
Registration starts only on normal launches and is removed on application exit.
It does not monitor general keyboard input or require Accessibility/Input Monitoring.
The menu action deliberately has no separate AppKit key equivalent, avoiding a
second toggle from the same gesture while the app is active.

`AppearanceController` allows one request at a time and runs `SystemAppearanceClient`
in a detached task. The client uses Foundation's public `NSAppleEventDescriptor`
API to read, set and verify `appearance preferences.dark mode` in three Apple events.
Property codes come from System Events' scripting dictionary. Each event has a
15-second timeout; descriptors stay inside the worker so synchronous replies do
not block AppKit. If System Events has exited while idle, the controller launches
the system app without activating it, only on an explicit user action. No shell,
AppleScript interpreter, persistent helper, downloaded code, private appearance
API or preference-file edit is used.
Automation denial produces recovery instructions; other failures show a native
alert. The app's Info.plist includes `NSAppleEventsUsageDescription`, and macOS
requests permission only when a user invokes the action. Diagnostics and smoke
launches do not register the shortcut or invoke System Events.

This path changes system appearance independently of Night Shift. It does not
add appearance scheduling or per-app themes. `--status` reports registration,
registration error, in-progress state and the latest appearance error.

## Night Shift adapter

`NightShiftBridge` loads the private CoreBrightness framework and checks method
signatures, status structure size, and alignment before invoking the system client.
The ABI reference is [Shifty's CBBlueLightClient header](https://github.com/thompsonate/Shifty/blob/master/Shifty/CBBlueLightClient.h).
Matching the ABI does not guarantee compatibility with future macOS versions.

All bridge calls run on the main thread. Reads return availability, enabled and
active state, and strength. The On/Off label reflects the enabled flag, not the
separate active flag. When disabled, the slider reads zero even if macOS remembers
a nonzero strength. Enabled external values are displayed without a setting write;
an external enabled state with zero strength can therefore read On · 0%.
Invalid responses or missing availability disable the slider. Failed or invalid
reads show a read-failure diagnostic while retaining structural API support;
unsupported API failures retain the bridge's diagnostic. A valid state with
`available=false` is reported as unavailable in the current display configuration.
Both CLI paths use the same completed snapshot, preventing stale support metadata
when the first read changes the bridge's support status. Existing JSON keys and
empty-object representation for missing state are preserved.

The native slider snaps its visual value to one of ten ticks even when the source
strength lies between ticks. The percentage still uses the actual source value.
An enabled strength at or near zero can therefore display the knob at Off;
the status still shows On, and an explicit Off gesture disables it. Refreshing
never changes the actual external strength to match a visual tick.

`WarmthAdjustment` maps user-selected zero to `setEnabled(false)` without changing
remembered strength. Positive values call `setStrength:commit:` first and enable
Night Shift only if it was off. A failed strength write prevents enabling an old
value; a failed enable/disable is reported rather than treated as success. The
controller reads fresh availability/enabled state for each action. The adapter
rejects nonfinite or out-of-range strength values. No write occurs just from reading
state or opening the panel.

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
main run loop without creating a Task. An unchanged poll skips UI property writes.
Native actions can move the knob before the controller reads macOS. Refresh can
therefore reconcile the knob independently of the cached label and availability.
During tracking the slider keeps the requested position, and completion reads the
system again to restore the observed position even after repeated write failures.

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
The Updates submenu reflects current preferences and availability each time
More options opens.

Generated bundle defaults enable automatic checks and automatic installation;
existing user preferences may override them. Checks use a four-hour interval while
the app runs. The installation preference maps to Sparkle's
`automaticallyDownloadsUpdates`; Sparkle handles the remaining installation flow,
which can wait for quit or permission.

Release builds contain only arm64 slices, including bundled Sparkle executables.
Releases use a compressed APFS DMG containing the app and an Applications shortcut;
the same image supports manual installation and Sparkle updates.
GitHub Releases hosts `DisplayDials.dmg` at the permanent latest-download URL;
GitHub Pages hosts the signed appcast with only the current release. Older DMG
assets are removed only after the new feed and download are verified.
The packaging script requires an `arm64` appcast hardware requirement, verifies
archive and appcast Ed25519 signatures, and uses one persistent update identity.
Bundle settings require signed feeds with no expiration fallback and verification
before extraction. System profiling is disabled, and optional sandbox XPC services
are removed from the bundle. Application signing uses the persistent per-app certificate pinned in
`release.json`, including all updater executables. The build and finished-image
checks reject a different signer, an ad hoc release or an identifier-only
requirement. Local development can use ad hoc signatures but must not replace the
installed stable app used for continuity checks.
The app bundle and DMG carry the project MIT license and complete third-party
notices; build and packaging verify them before publication.

See [release operations](releases.md) for the publication pipeline and the persistent
code signing and any later Developer ID/notarization transition.

## Launch at login

`LoginItemController` uses `SMAppService.mainApp` on macOS 13 and later. It creates
no helper executable, LaunchAgent, LaunchDaemon, or custom preferences flag.
Normal startup only reads the launch event; registration changes happen solely
in response to the menu action. The status is read again whenever the menu opens,
so changes made in macOS System Settings are reflected without restarting.

Enabled registrations have a checkmark; `requiresApproval` has a mixed mark,
explicit title and a System Settings action. Register/unregister errors appear in
a native alert with an option to open Login Items settings. Asynchronous
unregistration disables the menu action until it finishes. The current app keeps
running when its login registration is removed.

The change action is disabled outside an app bundle, on a read-only volume, and
in diagnostic/smoke modes.

During `applicationDidFinishLaunching`, the Apple open-application event is checked
for `keyAELaunchedAsLogInItem`. An automatic login launch initializes the menu bar
and updater but does not show the panel.
Normal launches and application reopen events still show the app's interface.

Local validation of the ad hoc signed build successfully registered it as an
enabled/allowed main-app login item and unregistered it through the new menu.
The initial off state was restored. The check did not log out or restart macOS.

## Validation and diagnostics

Run from the repository root on an Apple Silicon Mac:

```sh
bash scripts/test.sh
bash scripts/build-app.sh
app_binary="$HOME/Library/Developer/DisplayDials/Display Dials.app/Contents/MacOS/DisplayDials"
"$app_binary" --diagnostics
"$app_binary" --smoke-test --snapshot /tmp/display-dials-panel.png
```

`test.sh` builds a debug executable, runs `DisplayDialsTests`, prints Night Shift
diagnostics and initializes the UI, then exercises native menu geometry, live
slider tracking and the isolated Off/on write-order helper. These checks do not
write Night Shift or system appearance, register login items or start the updater.
Appearance tests briefly register the global shortcut and remove it on completion.
Menu geometry tests
briefly open their own popover/menu. The build script creates and signs the
release bundle and verifies its code signature.

`--status` queries the already running app through local distributed notifications,
reporting its own version/build, Night Shift availability/state, native login-item
status, update preferences and appearance-shortcut/error state. It does not start
another UI or change settings.
A two-second timeout reports that no compatible app is running. This avoids
mistaking a trusted diagnostic caller's context for the app's.

Requests and replies use `com.vitalyterenin.displaydials.status.request` and
`.status.reply` notification names with a per-query UUID as the notification
object. The CLI removes its reply observer on return. The responder is installed
once for the lifetime of the running app. There is no process selector or
authenticated responder identity: if multiple copies run, a received reply is
not guaranteed to identify a particular installation. Use a single running copy
for continuity checks. This channel is diagnostic, not an authorization mechanism.

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
cover moving from Off to a positive position and back, live tick changes, reopening the panel after
external changes, and opening the complete options menu through Quit. Restore the
original Night Shift settings after a manual write check.

### Options menu regression checks

`scripts/test.sh` includes two native checks using the production presenter:

- `MenuPresentationTests.swift` intercepts presentation to require a screen-space
  anchor and a nil parent view, with 8, 16 and 24 items and nested button offsets.
  Returning to a popover-relative view fails this check. It also checks offset
  window origins and an unattached button.
- `MenuLayoutIntegration.swift` opens a real status-item popover, presents menus of
  8, 16 and 24 rows, and inspects their accessibility geometry from inside the app.
  It requires the complete menu height and every row, including the last, to fit
  within the displayed menu. No accessibility permission or system settings change
  is needed. AppKit can still scroll a menu that genuinely exceeds screen space.

When changing menu items, also open More options normally and confirm that all
current commands through Quit are visible without scrolling on a screen with
sufficient space. Do not infer visibility from the accessibility item list alone.

### Live slider regression check

`WarmthSliderTests.swift` exercises the production slider's native mouseDown
lifecycle with an isolated tracking cell. It requires changed-tick actions before
tracking ends, suppresses duplicate events within a tick, verifies reverse movement,
and checks that drag completion happens once. Unchanged gestures and non-drag
keyboard/accessibility action delivery are covered without changing macOS settings.

`WarmthAdjustmentTests.swift` verifies that Off disables without overwriting the
remembered strength, positive positions set strength before enabling, repeated Off
and already-enabled changes avoid redundant toggles, and failures/invalid values
are handled without continuing an unsafe setting sequence. These are simulated
writes, not a claim of compatibility with every macOS/display configuration.

### Controller and snapshot regression checks

`Tests/DisplayDialsTests` imports the executable module without invoking its entry
point. `PanelControllerTests` uses the real panel/slider, a synthetic tracking cell
and a fake Night Shift client. It verifies external near-zero Off, unchanged
disabled gestures, tick deduplication and reversal, failed writes and recovery,
deferred knob reconciliation and immediate non-drag actions. Two consecutive
rejected non-drag moves must each restore the knob even when the error and system
state are identical. Synthetic mouse
coordinates are converted from the slider into window coordinates, and the cell
preserves the controller's action/target.
Non-drag tests call `sendAction`; they do not simulate physical keyboard or
accessibility input. A real run-loop check verifies that repeated appearances
install one polling timer and disappearance stops reads.

`NightShiftClientTests` injects a bridge double whose first read changes support,
and exercises ordinary failures, invalid numbers, unavailable state and recovery.
It verifies post-read metadata and the existing state JSON representation. These
tests do not establish private CoreBrightness compatibility on other macOS versions.

`AppearanceTests` exercises failure recovery and overlapping requests with an
injected runner. It registers a separate Option–Command–F20 test key so the
installed app can keep Option–Command–N, verifies exclusive conflicts, and
dispatches synthetic Carbon press/release events. It checks immediate press
delivery, repeat suppression, rearming and unregister/re-register behavior.
`SystemAppearanceClientTests` verifies the target/property path, get/set/readback
sequence, both toggle directions, invalid/missing state, failed sets and Automation
denials through an injected event transport. These are not physical keyboard,
visual transition timing or Automation-permission continuity tests.

## Privacy

The app collects no usage statistics. The former event module, transport and
statistics window have been removed, along with their package targets and bundle
configuration. The privacy manifest declares no collected data or tracking and
retains the UserDefaults API declaration for local preferences. Sparkle system
profiling remains disabled. See [privacy and network activity](privacy.md).
