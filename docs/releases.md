# Release operations

Display Dials ships arm64 builds for Apple Silicon Macs on macOS 13 or later.
There is one stable update feed and no beta channel. Source changes pushed to
`main` do not publish an application update. The workflow publishes for tag refs;
a normal release uses a pushed `v*` tag matching `release.json`.

The workflow stores prepared artifacts in GitHub Actions and publishes archives
to Object Storage. It does not create a GitHub Release or attach GitHub Release
assets. A source version in this repository does not establish publication status;
check the workflow result and published appcast for that.

## Configuration and signing identity

[release.json](../release.json) is the source of truth for:

| Field | Meaning |
| --- | --- |
| `version` | Three-part user-facing version, copied to `CFBundleShortVersionString` |
| `build` | Positive, increasing integer string, copied to `CFBundleVersion` |
| `id` | Permanent application slug (`display-dials`) |
| `feedURL` | Signed feed at `/apps/feeds/<id>.xml` |
| `downloadURL` | Permanent app-named DMG directly under `/apps/` |
| `legacyFeedURLs` | Former feed addresses used only to bootstrap a migration |
| `publicEDKey` | Base64-encoded 32-byte public Sparkle Ed25519 key |
| `telemetryDeckAppID` | Public UUID for Display Dials in TelemetryDeck; not an account credential |

The feed is `https://teren.in/apps/feeds/display-dials.xml`. Files are hosted
in the existing `teren.in` Yandex Object Storage bucket behind Cloudflare. The previous
feed is read directly from the Object Storage origin to avoid CDN staleness.
The repository can remain private. The application owns only two objects: `apps/DisplayDials.dmg` and
`apps/feeds/display-dials.xml`. Releases replace these two objects. The `/apps/`
catalog belongs to the separate `teren-in` website repository. This release
repository must not publish site pages or list other private repositories.
The permanent download URL is `https://teren.in/apps/DisplayDials.dmg`.
The version/build inside the app and feed still increase so Sparkle can detect updates.

GitHub Actions needs these encrypted repository secrets:

- `SPARKLE_PRIVATE_KEY`: the exported private Sparkle signing key for the
  `com.vitalyterenin.displaydials` Keychain account.
- `YC_ACCESS_KEY_ID` and `YC_SECRET_ACCESS_KEY`: the dedicated publisher's static
  S3 credentials, restricted to the two exact release object keys in `teren.in`.

The public key belongs in `release.json`; private keys and cloud credentials do
not belong in source, logs, artifacts, or the website. Keep a protected backup of
the signing key. Existing installations trust this identity; setting up another
computer is not a reason to generate a replacement key.

TelemetryDeck uses the organization's free plan and namespace `in.teren`. Its
public App ID is copied into bundle metadata; publishing requires no TelemetryDeck
account token or new GitHub secret. Release bundles include the app privacy
manifest. See [usage statistics and privacy](privacy.md) before changing events
or the consent wording.

Only for a new application identity, generate a key with:

```sh
tools="$(bash scripts/sparkle-tools.sh)"
"$tools/bin/generate_keys" --account com.vitalyterenin.displaydials
```

The downloader pins Sparkle 2.10.1 and verifies its archive's SHA-256. Local
packaging uses Keychain unless `SPARKLE_PRIVATE_KEY` is supplied in the environment.
CI passes that secret to Sparkle tools through stdin.

[deployment/teren-in-policy.json](../deployment/teren-in-policy.json) records the
bucket policy for preserving public reads and existing access while limiting the
dedicated publisher to GetObject/PutObject on its two exact release keys. Committing
that file does not apply cloud permissions. The publisher's uploader role must be
assigned on this bucket, rather than granting access across the cloud folder.

## Publish a version

1. Update `version` and increase `build` in `release.json`. Use a new version and a
   build greater than every build already in the published feed.
2. Run validation and local checks, then commit and push the source changes.
3. Push a new tag equal to `v` plus the configured version.
4. Wait for **Release Display Dials** to finish both build and publish jobs.

For example, after committing and pushing the intended source revision:

```sh
set -euo pipefail
python3 scripts/release.py validate
release_tag="$(python3 -c 'import json; print("v" + json.load(open("release.json"))["version"])')"
git tag "$release_tag"
git push origin "$release_tag"
```

Creating and pushing the tag starts publication, not just a source backup. Do not
reuse an existing release tag or app build number for changed app bytes. Each release
replaces the permanent disk image. If a released app is faulty, publish a corrected
version with a higher build number.

## Workflow behavior

[.github/workflows/release.yml](../.github/workflows/release.yml) defines these paths:

| Trigger | Build and read-only checks | Signed artifact | Publish to Object Storage |
| --- | --- | --- | --- |
| Pull request | Yes | No | No |
| Push to `main` or another ordinary branch | No workflow run | No | No |
| Push a matching `v*` tag | Yes | Yes | Yes |
| Manual run on a branch (default inputs) | Yes | Yes | No |
| Manual run on `main`, `republish_current: true` | Yes | Yes, reusing published DMG | Yes |
| Manual run on a tag | Yes | Yes | Yes, because the selected ref is a tag |

Manual runs require the signing secret too. A tag ref must match `release.json`.
To migrate the current release to the permanent name without rebuilding the DMG
or incrementing the app version, dispatch on `main` with `republish_current: true`.
This path verifies the published feed and archive signatures, reuses the exact
archive bytes, and generates a signed feed containing only that release. Its
version must match `release.json`. Ordinary new releases still require a higher build.
Prepared artifacts are named `display-dials-release` and retained for 14 days.
Pull requests do not access signing or publication secrets. Workflow runs share
one concurrency group and are queued rather than cancelling an existing release.

The macOS job validates metadata, runs `scripts/test.sh`, builds the arm64 app,
and checks the bundled executable. Packaging then:

- Verifies the app's code signature, version/build/feed/key, and arm64 architecture.
- Reads the previous feed and rejects a non-increasing build number.
- Creates a compressed APFS DMG containing the app and an Applications shortcut,
  verifies the disk image, and generates a fresh appcast containing only the current release.
  The archive is always named `DisplayDials.dmg`.
  Delta updates are disabled.
- Requires the generated entry to specify the `arm64` hardware requirement.
- Verifies the appcast and archive signatures and records their SHA-256 hashes
  with the previous feed's ETag in `publication.json`.

The Linux publisher uses the pinned `boto3` version from the workflow. It verifies
artifact hashes and checks that its credential is denied access outside the app's
objects using non-mutating conditional requests against site pages and other apps. Before replacing the download, it verifies that the feed still matches the
expected ETag and rejects downgrades or reuse of a build for different bytes.
It conditionally replaces the archive first, reads it back to verify the bytes,
then conditionally replaces the appcast using the previous ETag. First publication
uses create-only conditions.

Both the DMG and feed use `Cache-Control: no-store, max-age=0`; the permanent
download must not be served from an immutable cache. A concurrent feed change
aborts publication unless the existing feed already matches this artifact. The
publisher writes only these two objects and does not modify other website files.
Former download and feed paths under `/updates/display-dials/` redirect permanently
to the new locations through Cloudflare. Remove the corresponding old storage
objects only after both redirects are active. Keep the old feed redirect because
installed 0.6.0 apps still contain that address; future rebuilt releases get the
new feed URL from configuration. Redirects retain compatibility without duplicated
DMG/feed objects. The first publication can read the signed legacy feed at the
Object Storage origin when the new feed is absent; its ETag is not used as a
condition for creating the new feed key.

Two separate storage objects cannot be replaced atomically. A client that retained
the preceding feed can race a publication and receive a different signed archive.
Sparkle must reject that mismatch; a subsequent fresh update check can retry. Never
disable signature verification to hide this failure. Keeping only the current
release also means there is no historical download or automatic fallback for older
OS/hardware support branches.

A failed publication may be retried with the same verified artifact. Rebuilding
can change disk-image bytes; for an already published build, reuse the existing
verified DMG or publish a new app build instead.

## Local build and release preparation

Run from the repository root on an Apple Silicon Mac with Swift 6+, Python 3,
Xcode or Command Line Tools, and access to the existing signing identity:

```sh
python3 scripts/release.py validate
bash scripts/test.sh
bash scripts/build-app.sh
```

The scripts use these optional environment overrides:

| Variable | Default / purpose |
| --- | --- |
| `DISPLAY_DIALS_BUILD_DIR` | `~/Library/Developer/DisplayDials/Build`; SwiftPM cache |
| `DISPLAY_DIALS_OUTPUT_DIR` | `~/Library/Developer/DisplayDials`; parent of the output app bundle |
| `DISPLAY_DIALS_TOOLS_DIR` | `~/Library/Developer/DisplayDials/Sparkle-2.10.1`; Sparkle tool cache |
| `DISPLAY_DIALS_SIGN_IDENTITY` | `-`; ad hoc app code signing, separate from Sparkle update signing |

The output bundle is replaced by `build-app.sh`; release packaging requires a new,
empty artifact directory. The following prepares a signed update locally without
uploading it. It handles both an existing feed and a first-release 404:

```sh
set -euo pipefail
tools="$(bash scripts/sparkle-tools.sh)"
release_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/display-dials-release.XXXXXX")"
python3 scripts/release.py previous "$release_work_dir/previous.xml"
previous_args=()
if [[ -f "$release_work_dir/previous.xml" ]]; then
    previous_args+=(--previous "$release_work_dir/previous.xml")
fi
python3 scripts/release.py package \
  --app "$HOME/Library/Developer/DisplayDials/Display Dials.app" \
  --output "$release_work_dir/artifacts" \
  --tools "$tools" "${previous_args[@]}"
```

This shell example works in Bash and Zsh. If the app output directory was
overridden, pass that bundle's actual path to `--app`. Keep `previous.xml` together
with its generated `previous.state.json`: the latter supplies the ETag used by
publication. The prepared artifact directory contains the DMG, signed appcast and
`publication.json`. `scripts/publish.py` is the separate upload step used by CI;
it needs the S3 credentials and the workflow's Python dependencies.

## Installation and update behavior

Open the DMG and drag the app onto its Applications shortcut, then eject the image
and launch the installed copy. The same signed DMG is used for Sparkle updates.
Do not run the app directly from the read-only disk image. A writable location
such as `~/Applications` can be used instead when installing for one user.
Already installed copies can install current DMG updates without reinstallation.
Current bundles use ad hoc app code signing and
are not notarized; the first downloaded launch may require approval through
**System Settings > Privacy & Security > Open Anyway**.

Sparkle checks while Display Dials runs, on a four-hour scheduled interval by
default. Automatic checks and automatic installation default to enabled, with
saved user preferences taking precedence. Both preferences and a manual check
are available in More options. Installation may wait for quit or permission.
The UI's installed version comes from the running bundle, not the latest appcast.

Archive and appcast Ed25519 signatures authenticate updates separately from the
app's code signature. Bundle settings require signed feeds, disable the signed-feed
expiration fallback, and request update verification before extraction. Sparkle
system profiling is disabled.

## Adding Developer ID later

Import the Developer ID certificate and private key into the CI signing keychain,
set `DISPLAY_DIALS_SIGN_IDENTITY`, and add Apple's notarization/stapling stage
after `build-app.sh` and before `release.py package`. Package and Sparkle-sign
the final notarized bundle. Keep the bundle ID, feed URL, update key and increasing
build numbering unchanged. Test an update from the ad hoc release to the new
Developer ID release before publishing it.
