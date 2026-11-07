# Stable releases

Display Dials supports Apple Silicon Macs on macOS 13 or later. There is one
stable feed and no beta channel. Only explicit version tags publish updates.
The source repository can remain private; ready-to-install archives are public.

## One-time configuration

The update URL is `https://teren.in/updates/display-dials/appcast.xml`. The existing
`teren.in` Yandex Object Storage bucket hosts the files behind Cloudflare.
Publishing requires these encrypted GitHub Actions repository secrets:

- `SPARKLE_PRIVATE_KEY`: the exported Sparkle signing key for the
  `com.vitalyterenin.displaydials` Keychain account.
- `YC_ACCESS_KEY_ID` and `YC_SECRET_ACCESS_KEY`: a dedicated service account's
  static S3 key, restricted to the `updates/display-dials/` prefix in `teren.in`.

The public Sparkle key is committed in `release.json`. Never put a private signing
key or a cloud credential in the repository, logs, build artifacts, or website.
Keep a separate protected backup of the signing key. Existing installations rely
on this key; do not generate a new key when setting up another computer.

Generate a key only for a new application identity:

```sh
tools="$(bash scripts/sparkle-tools.sh)"
"$tools/bin/generate_keys" --account com.vitalyterenin.displaydials
```

The tools downloader verifies the pinned Sparkle release's SHA-256. Local signing
uses Keychain; CI passes the exported key through stdin to Sparkle's tools.

## Publish a version

1. Update `version` and increase the integer `build` in `release.json`.
2. Commit the application changes, then push a matching tag, such as `v0.5.0`.
3. Wait for the **Release Display Dials** GitHub Actions workflow to finish.

The macOS job runs read-only checks, builds an arm64 app, verifies its code
signature, archives it, and generates a signed appcast. It reads previous release
history directly from Object Storage, avoiding a stale CDN copy. Existing appcast
entries are retained, and downgrades are rejected. Delta updates are disabled.

The publishing job uploads the versioned ZIP without replacing any existing
version, reads it back to verify its contents, then conditionally updates the
appcast last. A concurrent feed change aborts publication rather than overwriting
another release. The appcast uses revalidation cache headers; versioned archives
are immutable. Jobs do not delete objects or change other website files.

The workflow can also be run manually to build and verify an artifact without
publishing it. Tag names must match the version in `release.json`.

If a release is faulty, fix it and publish a higher version/build. Do not replace
an already published ZIP. A failed publication can be retried with the same
verified artifact; a fresh rebuild may produce different archive bytes and then
requires a new version.

## Initial installation and later updates

Install the first updater-enabled version manually on each Mac, copying the app
to a writable location such as `~/Applications`. Without Developer ID/notarization,
the first downloaded launch may require **Privacy & Security > Open Anyway**.
Sparkle then verifies and installs updates from the stable feed. Checks run while
the app is running; installation may wait until the app quits or needs permission.

## Local release preparation

```sh
bash scripts/test.sh
bash scripts/build-app.sh
tools="$(bash scripts/sparkle-tools.sh)"
python3 scripts/release.py previous /tmp/display-dials-previous.xml
# If a previous feed was downloaded, add --previous /tmp/display-dials-previous.xml.
# Use a new, empty output directory for every packaging attempt.
python3 scripts/release.py package \
  --app "$HOME/Library/Developer/DisplayDials/Display Dials.app" \
  --output "$HOME/Library/Developer/DisplayDials/PreparedRelease" \
  --tools "$tools"
```

## Adding Developer ID later

Import the Developer ID certificate and private key into the CI signing keychain,
set `DISPLAY_DIALS_SIGN_IDENTITY`, and add Apple's notarization/stapling stage
after `build-app.sh` and before `release.py package`. Package and Sparkle-sign
the final notarized bundle. Keep the bundle ID, feed URL, update key and increasing
build numbering unchanged. Test an update from the ad hoc release to the new
Developer ID release before publishing it.
