# Refactoring review and implementation — 2026-11-08

> Historical review of the earlier implementation. Version 0.6.10 removes usage
> telemetry, its consent window, event tests and build configuration. References to those components and test counts below describe
> the reviewed baseline. Current behavior is documented in `implementation.md`
> and `privacy.md`.

## Result and baseline

R1–R4 from the prepared audit are implemented and locally verified. The changes
fix Off at externally enabled near-zero warmth, introduce a narrow testable Night
Shift boundary, make diagnostic snapshots coherent, and add bounded retries to
public release-byte verification. Native AppKit, the Objective-C bridge, Sparkle,
setting-write order and the existing release integrity checks are retained.

The original audit started from clean `main` at
`3e848b3af3ba3a8ea7cb345ba559ed2bc39fc6ff`, source version 0.6.8/build 18. The
implementation began with only the audit's README/documentation changes present;
those changes were preserved and updated here. The local implementation phase
left version/build, dependencies, the installed app, Night Shift settings, login
registration and publication state unchanged. Version 0.6.9/build 19 was later
published and installed through Sparkle; publication and installation evidence is
recorded in [PR #24](https://github.com/vitalyterenin/display-dials/pull/24) and the
[release workflow](https://github.com/vitalyterenin/display-dials/actions/runs/42501313399).
The installed-app interaction checks below are separate from the local
development-build results.

## Scope and architecture

The baseline audit read all application sources, the Objective-C bridge/header,
telemetry, maintained tests, seven scripts, package/lock files, release
workflow/configuration, privacy manifest, repository instructions and maintained
documentation. Relevant history included the live-drag, single-slider,
menu-placement and signing changes. Historical resource samples were reviewed.
GPT-6 Astra independently reviewed the core and the resulting Swift changes;
publication changes were delegated separately and integrated by the primary agent.

Display Dials is an Apple Silicon macOS 13+ menu-bar utility for global Night Shift
control. macOS owns enabled/active state, remembered strength and the schedule.
The app has ten visual positions, no per-display control and no brightness or
custom scheduling implementation. Quitting leaves macOS settings in place.

The current ownership and execution paths are documented in
[implementation.md](implementation.md). `main.swift` owns application startup,
menu-bar lifecycle and CLI routing. `PanelController.swift` owns the panel/menu,
actions, rendering and visible-only polling. `NightShiftClient.swift` adapts the
existing bridge into a typed `NightShiftSnapshot` and implements the small
`NightShiftControlling` interface. Controller construction accepts that interface
and optional telemetry for isolated tests; normal construction uses the real
client and existing consent gate.

`WarmthAdjustment` remains the write-order helper and `WarmthSlider` remains the
native tracking/deduplication control. The controller keeps its UI-state cache
and final drag event. Login registration still uses system state, telemetry still
requires consent, and Sparkle owns update preferences. No generic dependency
container, replacement framework or additional external dependency was introduced.

## Findings and implemented decisions

| ID | Priority / kind | Baseline evidence | Final status |
| --- | --- | --- | --- |
| R1 | P2 / interaction defect | Production slider/mapping fixture suppressed Off for enabled strengths 0, 0.01 and 0.05 | Fixed; controller regression checks pass |
| R2 | P2 / maintainability refactor | Concrete bridge construction prevented isolated controller scenario coverage | Implemented; typed client injection and 11 new Swift scenario/snapshot tests |
| R3 | P3 / operational robustness | A first `URLError` escaped despite 24 verification attempts | Implemented; both byte-verification gates use one bounded helper; 13 additional Python tests |
| R4 | P3 / diagnostic defect | Report fields were captured before a read could change support/diagnostic values | Fixed; immutable post-read snapshot shared by panel and diagnostic paths |

### R1 — Off is actionable when an enabled state displays at zero

At the baseline, `WarmthAdjustment.sliderValue` passed through externally enabled
strength. Native AppKit snapped 0, 0.01 and 0.05 to the zero visual tick. The
slider seeded its drag deduplication with that same zero, so an explicit Off
mouse action was discarded. A 0.06 source value snapped to 1/9 and did deliver
Off. The user otherwise had to move warmer before returning to Off.

The chosen fix in [WarmthSlider.swift](../Sources/DisplayDials/WarmthSlider.swift)
is state-aware initial delivery, not visual remapping. The controller supplies
`allowsInitialOffAction` from an available, enabled snapshot. When such a gesture
starts at the zero tick, the first action is allowed; subsequent duplicate events
are suppressed normally. A failed disable permits another explicit gesture to
retry. Existing non-drag action dispatch is unchanged.

This preserves the actual displayed percentage, read-only refresh, remembered
warmth, unchanged gestures when already disabled, immediate changed ticks,
reversals and at most one final drag telemetry event. No external strength is
rounded or committed merely because the panel opens. Risk is concentrated at the
tracking/state boundary and is covered by combined controller tests.

### R2 — A narrow typed boundary makes controller scenarios testable

Previously, `PanelController` constructed `DDWarmthClient` directly and repeatedly
interpreted numeric dictionaries. Slider and write-order tests passed independently
but did not exercise their interaction with controller rendering and recovery.

[NightShiftClient.swift](../Sources/DisplayDials/NightShiftClient.swift) now provides
`readSnapshot`, `changeStrength` and `changeEnabled`. Its state decoder requires
all expected fields and finite strength in 0–1. The wrapper retains the bridge's
private-API isolation and defensive write checks. The controller moved out of the
entry-point file to [PanelController.swift](../Sources/DisplayDials/PanelController.swift)
and accepts the client and optional telemetry. Native controls remain internally
accessible to the executable's test target; no public application API was added.

[PanelControllerTests.swift](../Tests/DisplayDialsTests/PanelControllerTests.swift)
uses the real controller and slider with a fake client. It covers:

- Read-only refresh and Off at enabled strengths 0/0.01/0.05/0.06.
- Already-disabled gestures, remembered warmth, tick deduplication and reversals.
- Failed disable/retry, failed strength short-circuiting and partial enable failure.
- Failed reads, unavailable state, recovery and immediate non-drag actions.
- Requested ticks staying in place during a failed drag, followed by readback reconciliation.
- One final successful or failed drag event and immediate non-drag telemetry.
- One visible polling timer after repeated appearances, with no reads after disappearance.

Tests preserve the controller's target/action when substituting a tracking cell
and convert synthetic mouse coordinates into window space. Non-drag tests call
`sendAction`; they are not physical keyboard or accessibility-input tests.
The change adds a useful boundary rather than a new application architecture.

### R3 — Both public verification gates tolerate bounded transient failures

At the baseline, `verify` retried mismatched/missing bytes but propagated a first
transport error. The permanent DMG check in `publish` was a single read. This was
a safe failure requiring manual recovery, not evidence of unsafe publication.

[wait_for_public_bytes](../scripts/publish.py) now serves both gates: before
staging Pages after DMG publication, and before older-DMG cleanup after deployment.
It requires exact expected bytes, at most 24 attempts, a 120-second monotonic
retry/acceptance deadline, and sleeps capped at five seconds or remaining time.
Default requests get a timeout of at most 60 seconds or remaining budget.
Late matching responses are rejected, and nonpositive limits cannot bypass checks.

Missing/cached bytes, HTTP 404/408/429/500/502/503/504, transport failures,
timeouts, connection errors and incomplete reads may retry. Other HTTP errors
and TLS failures propagate immediately. HTTP classification precedes the broader
`URLError` handler. Both feed and archive must match within the same verification
attempt before cleanup proceeds.

The helper never retries GitHub mutations or bypasses artifact, signature,
repository, tag, commit, build or prior-feed checks. Failure blocks the respective
Pages-staging/cleanup gate. The 13 added tests use fake network clients and clocks
to verify retries, cached bytes, exhausted deadlines, permanent errors, request
budget propagation, mutation counts and cleanup prevention.

The deadline bounds retries and acceptance, with timeouts on blocking operations;
Python's socket timeout is not forceful cancellation of an entire slow response.
No socket internals, cancellation threads or extra network library were added.
No production network failure was induced or live publishing performed.

### R4 — Diagnostics describe one completed read

At the baseline, diagnostic dictionaries captured `supported` and `diagnostic`
before `readState`. The bridge can change those fields after a read exception,
producing a stale first response. Ordinary false/invalid reads also returned no
state while leaving the structural API-availability diagnostic unchanged.

The wrapper now reads state once, then captures support and diagnostic fields
into an immutable snapshot. `main.swift` uses that snapshot for `--diagnostics`
and the running app's `--status` response. Existing JSON keys and an empty object
for missing state are preserved. No additional network or usage event is generated.

A failed/invalid read on a supported API gets a read-failure diagnostic; a valid
unavailable state gets a display-configuration diagnostic. Unsupported failures
retain the bridge's diagnostic. Ordinary failed reads do not permanently disable
API support and can recover on the next read.

[NightShiftClientTests.swift](../Tests/DisplayDialsTests/NightShiftClientTests.swift)
injects a bridge double with a first-read support transition, then tests nil,
missing-field, nonfinite/out-of-range, unavailable and recovered responses. These
verify snapshot sequencing and JSON representation. The baseline audit separately
exercised the real Objective-C exception handler with a temporary fake client;
this implementation does not alter that handler.

## Stage completion

| Stage | Status | Evidence |
| --- | --- | --- |
| Baseline and documentation | Completed | Initial checks passed; baseline defects reproduced and ownership documented |
| Off correction | Implemented and verified | Combined near-zero, unchanged, retry, reversal and failure tests |
| Controller seam | Implemented and verified | Real controller with fake system writes, telemetry and timer scenarios |
| Coherent diagnostics | Implemented and verified | Post-read metadata, invalid responses, availability and recovery checks |
| Bounded public verification | Implemented and verified | Both gates, transient/permanent errors, deadline and cleanup tests |

## Local implementation validation

Environment: Apple Silicon, macOS 27.2 (26B123), Apple Swift 6.4.2 and local Command
Line Tools. These results establish behavior on this host, not the entire macOS
13+ compatibility matrix.

| Command / check | Result |
| --- | --- |
| `bash scripts/test.sh` | Passed: debug build; 5 telemetry tests plus 11 controller/snapshot tests; diagnostics/UI smoke; native menu anchor and 8/16/24-row geometry checks; native slider and write-order fixtures |
| `python3 -m unittest discover -s Tests -p 'test_*.py'` | 43 tests passed, including 25 publication tests; no network requests |
| `python3 scripts/release.py validate` | Passed for unchanged 0.6.8/build 18 metadata |
| `DISPLAY_DIALS_OUTPUT_DIR=<fresh directory outside Documents> bash scripts/build-app.sh` | Passed: optimized arm64 app, dependency notices, icon generation, ad hoc development signing |
| Isolated bundle `--diagnostics` and `--smoke-test --snapshot <path>` | Passed; PNG generated and visually inspected |
| `codesign --verify --deep --strict <app>` and `lipo -archs <executable>` | Passed; arm64 executable |
| `git diff --check` and local Markdown target validation | Passed |

The development bundle and screenshot are under
`~/Library/Developer/DisplayDials/refactor-implementation.EWisje/`. The installed
stable copy was not replaced. An ad hoc build is not evidence of persistent
release-signing continuity, notarization or a successful Sparkle installation.

Initial integration-test attempts exposed fixture errors (lost target/action and
incorrect coordinates after placing the slider inside the panel). The fixture
was corrected, then the complete suite passed. No production workaround was
introduced for those fixture failures.

Existing toolchain warnings remain: missing Command Line Tools search paths, and
the Testing framework built for macOS 14 while the package targets 13. Tests ran
successfully on this newer host. Independent Swift review found no production
blocker; its test-scope comments were addressed by documenting non-drag dispatch
and covering final failed-drag telemetry.

## Installed-app interaction verification — 2026-11-08

Tested the running, installed **0.6.9 (build 19)** on Apple Silicon, macOS 27.2,
after the verified Sparkle update. The app's own `--status` confirmed version and
system state. Changes were made through **System Settings → Displays → Night
Shift** and the installed Display Dials panel, without substituting a development
build or a fake Night Shift client.

| Scenario | Observed result |
| --- | --- |
| Set system warmth to 0% while Night Shift is enabled | Panel showed `On · 0%` with the knob at the leftmost tick |
| Click the leftmost knob once at enabled 0% | Panel changed to `Off`; the system switch turned off and `--status` reported `enabled: false` |
| Set system warmth to 5% and enable Night Shift | Panel showed `On · 5%` while the knob remained at the leftmost tick |
| Click the leftmost knob once at enabled 5% | Panel changed to `Off` and the system switch turned off, without first moving warmer |
| Set system warmth to 50% and enable Night Shift | Panel showed `On · 50%`; the knob moved to its snapped visual tick (4/9), while `--status` still reported system strength `0.5` |
| Switch Night Shift off in System Settings | Panel updated automatically to `Off` and moved the knob fully left |
| Switch Night Shift back on in System Settings | Panel returned automatically to `On · 50%` and the same visual tick |
| Restore system warmth to 100% | Panel returned to `On · 100%` with the knob fully right |

External changes appeared on the panel's approximately five-second refresh cycle;
this was a functional observation, not a latency benchmark. Display refresh did
not round or write back the system's 50% strength. The real near-zero checks cover
0% and 5%; the separate automated fixtures also cover 1% and failure/retry paths.

The original state was restored: Night Shift enabled, active and available at
strength `1`, with the unchanged custom schedule **06:00–05:59**. Final `--status`
also confirmed launch at login enabled without approval required, and automatic
update checks and installation enabled. No privacy permissions were requested or
granted. These checks cover this host and its built-in display; they do not extend
the older-macOS, multi-display or keyboard-input coverage.

## Limits and retained decisions

During the local implementation phase, no real Night Shift writes, login/logout,
update installation, signing-key import, publication, multi-display/older-macOS
checks or long-running resource profile were performed. The menu implementation/layout is unchanged and its existing
native growth checks passed. Private CoreBrightness ABI checks still cannot prove
future field-semantic compatibility. Sparkle internals and current vendor terms
were not exhaustively audited.

No CPU, memory or latency improvement is claimed. Existing historical performance
samples predate later work. Repeated bridge availability reads are defensive
around an externally mutable private service; removing them needs measurements.
The bounded telemetry queue and per-event formatting have no demonstrated resource
problem at the documented event frequency.

The old brightness/boost experiments occur in history but no parallel runtime
implementation was found in current sources. Existing menu, tracking, bridge and
release helpers have current consumers and are retained. Sparkle remains pinned
at 2.10.1 with its notices and release checks unchanged.

Two existing product behaviors remain: completing the first statistics prompt
requires another click to open the panel, and an action-error label persists until
a later successful action. `--status` still has no installation selector or
authenticated responder identity; continuity checks should use one running copy.
Release publication and installed-app checks are recorded separately above;
minimum-platform validation remains outside this host's coverage.
