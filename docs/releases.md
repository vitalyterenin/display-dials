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
| `feedURL` | Stable appcast URL |
| `downloadURLPrefix` | HTTPS prefix for versioned archives; `feedURL` must equal this plus `appcast.xml` |
| `publicEDKey` | Base64-encoded 32-byte public Sparkle Ed25519 key |

The feed is `https://teren.in/updates/display-dials/appcast.xml`. Files are hosted
in the existing `teren.in` Yandex Object Storage bucket behind Cloudflare. Previous
feed history is read directly from the Object Storage origin to avoid CDN staleness.
The repository can remain private; installation archives and the feed are public.

GitHub Actions needs these encrypted repository secrets:

- `SPARKLE_PRIVATE_KEY`: the exported private Sparkle signing key for the
  `com.vitalyterenin.displaydials` Keychain account.
- `YC_ACCESS_KEY_ID` and `YC_SECRET_ACCESS_KEY`: the dedicated publisher's static
  S3 credentials, restricted to `updates/display-dials/` in `teren.in`.

The public key belongs in `release.json`; private keys and cloud credentials do
not belong in source, logs, artifacts, or the website. Keep a protected backup of
the signing key. Existing installations trust this identity; setting up another
computer is not a reason to generate a replacement key.

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
dedicated publisher to GetObject/PutObject on the application prefix. Committing
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
reuse an existing release tag or replace an already published disk image. If a released
app is faulty, publish a corrected version with a higher build number.

## Workflow behavior

[.github/workflows/release.yml](../.github/workflows/release.yml) defines these paths:

| Trigger | Build and read-only checks | Signed artifact | Publish to Object Storage |
| --- | --- | --- | --- |
| Pull request | Yes | No | No |
| Push to `main` or another ordinary branch | No workflow run | No | No |
| Push a matching `v*` tag | Yes | Yes | Yes |
| Manual run on a branch | Yes | Yes | No |
| Manual run on a tag | Yes | Yes | Yes, because the selected ref is a tag |

Manual runs require the signing secret too. A tag ref must match `release.json`.
Prepared artifacts are named `display-dials-release` and retained for 14 days.
Pull requests do not access signing or publication secrets. Workflow runs share
one concurrency group and are queued rather than cancelling an existing release.

The macOS job validates metadata, runs `scripts/test.sh`, builds the arm64 app,
and checks the bundled executable. Packaging then:

- Verifies the app's code signature, version/build/feed/key, and arm64 architecture.
- Reads the previous feed and rejects a non-increasing build number.
- Creates a compressed APFS DMG containing the app and an Applications shortcut,
  verifies the disk image, and generates an appcast retaining previous DMG entries.
  Only DMG release entries are carried into the next signed feed.
  Delta updates are disabled.
- Requires the generated entry to specify the `arm64` hardware requirement.
- Verifies the appcast and archive signatures and records their SHA-256 hashes
  with the previous feed's ETag in `publication.json`.

The Linux publisher uses the pinned `boto3` version from the workflow. It verifies
artifact hashes and checks that its credential is denied access outside the app's
prefix using a non-mutating conditional request. It uploads the archive first,
reads it back to verify the bytes, then conditionally writes the appcast using the
previous ETag (or a create-only condition for the first feed).

An existing archive is accepted only if its bytes match. A concurrent feed change
aborts publication unless the existing feed already matches this artifact. Feed
responses request cache revalidation; versioned disk images are immutable. The publisher
does not delete objects or modify other website files.

A failed publication may be retried with the same verified artifact. Rebuilding
can change disk-image bytes; if the versioned DMG already exists with different bytes,
prepare a new version instead of overwriting it.

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
