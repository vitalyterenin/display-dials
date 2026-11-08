# Display Dials release operations

Use the refreshed `app-release` skill and
[shared publishing guide](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/publishing.md).
This app supports Apple Silicon only, macOS 13 or later, with one stable channel.

## Hosting and identity

- Public source: https://github.com/vitalyterenin/display-dials
- Current download: https://github.com/vitalyterenin/display-dials/releases/latest/download/DisplayDials.dmg
- Signed feed: https://vitalyterenin.github.io/display-dials/appcast.xml
- Bundle ID and existing Sparkle Keychain account: `com.vitalyterenin.displaydials`.

`release.json` owns the three-part version, increasing positive build, app name,
repository, URLs and public Ed25519 update key. Keep the bundle ID and update key
unchanged when moving computers or hosting. The project is MIT-licensed; third-party
components retain their original terms. The personal Apps catalog is owned by the separate
`teren-in` repository and is optional for downloading and updating this app.

GitHub Actions retains only the encrypted `SPARKLE_PRIVATE_KEY` secret. Publication
uses GitHub's short-lived token with repository contents, Pages and OIDC write
permissions in the publish job only. Pull-request checks have no signing or
publication secrets. No Yandex/S3 credentials are required.

GitHub Pages must use **GitHub Actions** as its publishing source. The `github-pages`
environment allows release tags matching `v*`. Keep releases mutable so the workflow
can remove old DMG assets after verification; never replace bytes under an existing
published version or move its tag. Other assets, source tags and release records
are preserved. There is one current DMG, with no version suffix in its filename.

## Publish

1. Refresh shared instructions, read this guide and the latest signed feed.
2. Update version and build in `release.json`. Both identify a new published app;
   the build must exceed every published build. Run appropriate checks.
3. Review all maintained documentation against the whole current app and prepare
   any changed Apps card facts. Record the review scope and evidence in the PR.
4. Push a branch, wait for required checks and merge the exact checked revision.
5. Push a new `v<version>` tag on that commit. Tag publication is deployment.
6. Wait for both **build** and **publish** jobs in **Release Display Dials**.
7. Verify the actual public DMG/feed bytes, Ed25519 signatures, version/build,
   length, `arm64` requirement, and both permanent URLs.
8. Reconcile the [Apps card](https://teren.in/apps/) through the
   [catalog workflow](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/catalog.md).
   Commit/deploy changed facts in the website repository and inspect the live card.
   An accurate card needs no cosmetic edit.

From the repository root, after merging the intended source revision:

```sh
set -euo pipefail
python3 scripts/release.py validate
release_tag="$(python3 -c 'import json; print("v" + json.load(open("release.json"))["version"])')"
git tag "$release_tag"
git push origin "$release_tag"
```

Ordinary source pushes do not publish. PRs run tests and an arm64 build without
secrets. A manual workflow on a branch builds/prepares artifacts but does not publish;
a manual run selecting a matching tag does publish. Do not rebuild a published build
with different bytes. If only publication failed, retry the failed publish job with
the same verified artifact. A bad app or changed DMG requires a new version/build.

## Pipeline order and failure handling

The macOS job validates configuration, tests, builds and ad hoc signs the app,
verifies bundle metadata and arm64 executables, and packages an APFS DMG containing
the app, Applications shortcut, LICENSE and THIRD_PARTY_NOTICES.md. It verifies the
previous feed signature and increasing build, then signs and verifies the new archive and single-entry feed.
The internal artifact includes SHA-256 hashes and the previous feed hash; it is
retained for 14 days. The feed and DMG remain authenticated separately from the
app's code signature.

The Linux job verifies hashes, repository/tag/commit identity, publication state
and the previous feed snapshot before creating a draft release. It uploads the
DMG, publishes the release and reads the public bytes back. Only then does it
stage the signed appcast for Pages. Pages deploys the feed; public verification
must pass before older DMG assets are removed. A failed feed deployment preserves
older downloads and must be fixed before declaring the release complete. The
workflow serializes releases rather than cancelling an in-flight publisher.

GitHub controls CDN caching. A cached older feed can briefly disagree with the
current DMG; Sparkle rejects the mismatch and a fresh check can retry. Never disable
signature checks to mask caching or deployment failures. Bounded verification waits
for Pages propagation and fails if the public objects do not converge.

Former feed/download addresses on `teren.in`, including the early Display Dials
`/updates/display-dials/` paths where applicable, remain compatible redirects.
Installed apps with an old feed address must still reach the signed current feed.
Do not remove those redirects after deleting obsolete storage objects. The first
GitHub release can use `legacyFeedURLs` to read the prior signed feed; it must not
silently treat an unreachable established app as a first publication.

## Licenses in released builds

The owner approved MIT for this app. `release.json` records `license: MIT` and
[LICENSE](../LICENSE) contains the complete terms and copyright notice. Do not
change the license, remove notices or regenerate the copyright year during a
routine release without an explicit owner instruction.

[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) includes Sparkle 2.10.1's complete
upstream license and external notices. When upgrading a dependency, review the
new version's actual license and update these notices before packaging.

`scripts/licenses.py` verifies complete MIT terms, the copyright notice and the
pinned Sparkle version. `build-app.sh` compares the notices with the actual SwiftPM
checkout license and copies both documents to `Contents/Resources/Licenses` before
code signing. This keeps notices with the installed app after a drag install or
a Sparkle update. Packaging verifies bundle copies, adds the same files to the DMG
root, mounts the finished image read-only and verifies both copies before update
signing. Missing, incomplete or mismatched notices stop the build/release.

Python regression tests cover notices surviving an app-only install, missing or
modified bundle/image files, incomplete MIT terms, removed copyright, dependency
license changes and an unapproved project-license change.

## Local checks and tools

From the repository root on an Apple Silicon Mac with Swift 6+, Python 3 and
Xcode or Command Line Tools:

```sh
python3 scripts/release.py validate
python3 -m unittest discover -s Tests -p 'test_*.py'
bash scripts/test.sh
bash scripts/build-app.sh
```

Publication tests use fake GitHub/network clients and never upload live files.
They cover artifact tampering, stale feeds, repository/tag boundaries, downgrade
and build reuse rejection, exact-byte retry, and cleanup only after public
verification. All Python publication code uses the standard library.

Build/cache paths stay outside Documents. Overrides: `DISPLAY_DIALS_BUILD_DIR`,
`DISPLAY_DIALS_OUTPUT_DIR`, `DISPLAY_DIALS_TOOLS_DIR`, and `DISPLAY_DIALS_SIGN_IDENTITY`
(default `-`, ad hoc). `build-app.sh` replaces its generated app bundle.
`scripts/sparkle-tools.sh` downloads pinned Sparkle 2.10.1 and checks its archive
hash. Local signing uses the existing Keychain account; CI supplies the private
key to Sparkle tools over stdin, never in command arguments, files or logs.

Only when establishing a new app identity, use Sparkle's `generate_keys` tool.
Never regenerate an existing app's key. Keep a protected backup outside source and
build artifacts. Routine releases on another Mac need GitHub access, not copied
publication credentials.

## Installation and Developer ID

Open the DMG, drag the app to Applications or a writable per-user Applications
folder, eject the image and launch the installed copy. Current builds are ad hoc
signed and not notarized; first downloaded launch may require **System Settings →
Privacy & Security → Open Anyway**. Sparkle defaults to four-hour checks while the
app runs, with saved preferences respected; installation can wait for quit or
permission. The running app displays its own bundle version.

Later, import the Developer ID identity into the CI signing keychain and set
`DISPLAY_DIALS_SIGN_IDENTITY`. Notarize and staple after building and before DMG
packaging/update signing. Preserve bundle ID, update key, URLs and increasing
versions; test an update from an ad hoc release before publishing the transition.
