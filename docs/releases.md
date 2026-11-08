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
components retain their original terms.

GitHub Actions retains encrypted `SPARKLE_PRIVATE_KEY`, `DISPLAY_DIALS_SIGNING_P12`
and `DISPLAY_DIALS_SIGNING_PASSWORD` secrets. The first signs updater archives and
feeds; the other two restore this app's persistent code signing identity. Publication
uses GitHub's short-lived token with repository contents, Pages and OIDC write
permissions in the publish job only. Pull-request checks have no signing or
publication secrets.

GitHub Pages must use **GitHub Actions** as its publishing source. The `github-pages`
environment allows release tags matching `v*`. Keep releases mutable so the workflow
can remove old DMG assets after verification; never replace bytes under an existing
published version or move its tag. Other assets, source tags and release records
are preserved. There is one current DMG, with no version suffix in its filename.

## Publish

Build and package release artifacts only in GitHub Actions; publish the DMG on
GitHub Releases and the signed feed on GitHub Pages. Local checks and development
builds are not release artifacts. The personal website is outside this workflow;
do not inspect or change its content, listings, redirects or infrastructure.

1. Refresh shared instructions, read this guide and the latest signed feed.
2. Update version and build in `release.json`. Both identify a new published app;
   the build must exceed every published build. Run appropriate checks.
3. Review all maintained documentation against the whole current app. Record the
   review scope and evidence in the PR.
4. Push a branch, wait for required checks and merge the exact checked revision.
5. Push a new `v<version>` tag on that commit. Tag publication is deployment.
6. Wait for both **build** and **publish** jobs in **Release Display Dials**.
7. Verify the actual public DMG/feed bytes, Ed25519 signatures, version/build,
   length, `arm64` requirement, and both permanent URLs.

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

The macOS job validates configuration and imports the pinned signing identity
into an isolated temporary keychain. A native signing preflight runs before tests
and compilation. It builds/signs the app and updater executables,
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

Public byte verification uses the same bounded polling helper before staging
Pages and before old-DMG cleanup: at most 24 attempts, with a 120-second monotonic
retry/acceptance deadline and waits of at most five seconds. Missing or cached
bytes and selected transient HTTP/transport errors can retry; other HTTP errors
and TLS failures stop immediately. Each default HTTP request receives at most
60 seconds or the remaining budget, whichever is smaller. Responses completing
after the deadline are rejected. Python's socket timeout applies to blocking
operations, so it is not a forceful whole-response cancellation deadline.
GitHub mutations and identity/signature/build checks are not retried by this
helper. Failure prevents Pages staging or old-DMG cleanup at the respective gate.

GitHub controls CDN caching. A cached older feed can briefly disagree with the
current DMG; Sparkle rejects the mismatch and a fresh check can retry. Never disable
signature checks to mask caching or deployment failures. Bounded verification waits
for Pages propagation and fails if the public objects do not converge.

The previous signed feed is read only from this repository's GitHub Pages URL.
An unavailable feed stops the release; no alternate host or first-release reset is used.
Verify the prior signature and increasing build before packaging.

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
verification. Public-read tests also cover transient errors, HTTP classification,
cached responses, deadline exhaustion and propagation of remaining request timeouts.
All Python publication code uses the standard library.

Build/cache paths stay outside Documents. Overrides: `DISPLAY_DIALS_BUILD_DIR`,
`DISPLAY_DIALS_OUTPUT_DIR`, `DISPLAY_DIALS_TOOLS_DIR`, `DISPLAY_DIALS_SIGN_KEYCHAIN`,
and `DISPLAY_DIALS_REQUIRE_RELEASE_SIGNING`. A build without a signing keychain
is a local ad hoc development build; packaging rejects it. Setting
`DISPLAY_DIALS_REQUIRE_RELEASE_SIGNING=1` also stops the build for a missing
keychain. Do not replace an installed stable copy with an ad hoc development build.
`build-app.sh` replaces its generated app bundle.
`scripts/sparkle-tools.sh` downloads pinned Sparkle 2.10.1 and checks its archive
hash. Local signing uses the existing Keychain account; CI supplies the private
key to Sparkle tools over stdin, never in command arguments, files or logs.

Only when establishing a new app identity, use Sparkle's `generate_keys` tool.
Never regenerate an existing app's key. Keep a protected backup outside source and
build artifacts. Routine releases on another Mac need GitHub access, not copied
publication credentials.

## Installation and persistent signing

Open the DMG, drag the app to Applications or a writable per-user location, eject
the image and launch the installed copy. From **0.6.8**, the app and every updater
executable use the same dedicated self-signed certificate. The public DER is
`Resources/ReleaseSigning.cer`, pinned by `codeSigningCertificateSHA256` in
`release.json`. This certificate and private key are distinct from Awake's and
from the unchanged Sparkle update key. Keep the bundle ID and exact certificate
stable; generating another certificate with the same name changes identity.

`scripts/signing.py` imports the encrypted PKCS#12 identity into a disposable CI
keychain. The keychain temporarily joins the certificate-chain search path during
signing; the original list is restored on success or failure. A preflight verifies
private-key access before compilation. Neither users nor CI install a trusted
root or reduce macOS security protections. PR builds have no signing secrets.
The encrypted identity has an owner-only backup outside source; never regenerate
it, print private material or commit it during routine builds.

Release build/package checks verify the pinned certificate, certificate-bound
designated requirement and bundle identifier for the app and updater components,
including the finished DMG. Missing secrets, an ad hoc fallback, a different
certificate or an identifier-only requirement block publication. The app remains
not Developer ID signed or notarized; first downloaded launch may require
**System Settings → Privacy & Security → Open Anyway**. Sparkle defaults to
four-hour checks while running and respects saved update preferences.

Display Dials does not request Accessibility, Input Monitoring or Screen Recording.
Do not add those permissions as a signing workaround or claim their persistence
was tested. Night Shift uses CoreBrightness and startup uses optional
`SMAppService.mainApp` registration. During a legacy identity transition, handle
any native login-item approval through the existing Login Items UI; do not
silently register, disable or re-enable the service. A later certificate or
Developer ID migration must be planned and tested explicitly.

## Live update continuity checks

Use `--status` to query an already running 0.6.8-or-later app. It reports the app's
own version/build, Night Shift support/state, native login-item state and updater
preferences without starting another app, changing Night Shift or collecting
statistics. A diagnostic executable launched by a trusted development tool is
not evidence about another app process's permissions.

Compare two different executable builds signed with this certificate at the same
writable installation path. Preserve the current Night Shift settings and login
choice. Exercise the real Sparkle download/install flow, then confirm the exact
public executable is running, Night Shift remains available and native login-item
status has not changed. Do not enable launch at login merely to manufacture a
grant test. If no privacy grant exists, record that fact rather than claiming a
TCC permission test passed.
