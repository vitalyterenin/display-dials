# Usage statistics and privacy

Usage statistics are optional and are sent to TelemetryDeck only after an explicit
choice to allow sharing. The developer uses them to understand feature usage,
version adoption and failed setting changes. No accounts are required in the app.
The first consent prompt also applies to users upgrading from earlier versions.
A quiet login launch defers an undecided prompt until the first manual opening.
Closing the prompt counts as declining. Every feature remains available after declining.

Change the choice in **More options (…) > Usage Statistics…**. Disabling sharing
clears pending events, cancels outstanding requests where possible, and deletes
the local random installation ID. A request already received cannot be recalled.
Enabling sharing again creates a new identity, without replaying earlier actions.

## Exactly what leaves the app

Every event includes the public TelemetryDeck app ID, SHA-256 hash of a random
installation ID scoped to this app, a random session ID, event type and timestamp,
app version/build, the platform name `macOS`, and macOS major/minor version.
These stable installation hashes support counting installations and returning
installations; they are not a count of unique people or a promise of complete anonymity.

| Event | Additional fields and trigger |
| --- | --- |
| `App.launched` | Normal app launch when sharing was already enabled |
| `Statistics.enabled` | Sharing was explicitly enabled; no earlier actions are replayed |
| `Panel.opened` | `source`: `launch`, `menuBar`, or `reopen` |
| `Warmth.changed` | Requested `position` from 1 to 10 (1 is Off; 2–10 are positive warmth levels) and `succeeded` boolean, once on drag completion (final requested position/result), or per keyboard/accessibility action |
| `Updates.preferences` | `automaticChecks` and `automaticInstallation` booleans, on opted-in launch, opt-in, or preference change |
| `Updates.manualCheck` | User requested an available manual update check |

A completed drag emits at most one final slider event, rather than one per live
tick. The removed switch emits no separate on/off event in this version; old
versions may still have sent those events.

There are no events for Night Shift polling, time spent idle, sleep/wake, or
automatic system schedule changes. A running app with no interactions sends no
periodic heartbeat. Active installations in reports therefore mean installations
that emitted events, not all Macs with a resident process.

No names, email addresses, computer names, hardware identifiers, model names,
locale, time zone, screen dimensions, precise location, filenames, file contents,
clipboard content, window titles, screenshots, recordings or raw error messages
are included. No identifiers are shared between the developer's apps.

## Transport and storage

The app uses TelemetryDeck's [documented Ingest API v2](https://telemetrydeck.com/docs/ingest/v2/),
not its SDK, to keep the payload limited to this list. HTTPS requests go directly to
`https://nom.telemetrydeck.com/v2/namespace/in.teren/` with a fixed application
User-Agent. The network service necessarily receives the source IP address.
[TelemetryDeck says it does not store IP addresses](https://telemetrydeck.com/docs/guides/privacy-faq/).
There are no advertising integrations or cross-company advertising identifiers.

Events are held in memory only, with a maximum of 50 pending events. A one-shot
timer batches them after approximately one minute, with 10 seconds of tolerance.
There is no repeating upload timer, on-disk event queue, or automatic retry.
Offline/failed requests and unsent events at app exit are lost. Best-effort
statistics must never affect Night Shift controls or updating.

The local consent choice and, only after opt-in, random installation ID are saved
in app preferences. The ordinary updater operates independently of this choice.
Diagnostics, smoke checks and raw SwiftPM executable runs cannot send statistics.
The local read-only `--status` query does not record or transmit usage events;
it reports only app version, Night Shift, login-item and update-preference state.
Automated tests use isolated preferences and a capturing transport, not the service.

The developer uses a free plan. Event quotas and the accessible reporting window
follow the account's current plan; see the vendor's
[subscription FAQ](https://telemetrydeck.com/faq/subscription/). Reporting retention
is not a deletion deadline: older data is retained in cold storage, with no deletion
schedule promised by this app. Free plans do not automatically upgrade to paid
plans; after their event allowance is exhausted, incoming events can be discarded.
Vendor terms can change. Sources and payload disclosure reviewed on 2026-11-08.
