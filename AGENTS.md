# Project language

Write all application interface text, project documentation, code comments, and docstrings in English.
Apply this rule when creating or updating any file in this repository.
Write GitHub descriptions, commits, PRs and release notes in English as well.
Describe functions, requirements and usage concisely, without advertising or slogans.

# Options menu layout

Keep options menu presentation in `OptionsMenuPresentation`. Open it in screen
coordinates with no popover parent view; do not introduce a fixed menu height.
When adding menu items or changing presentation, run `scripts/test.sh`, including
the menu growth checks, and inspect the current menu through its final item.

# Shared release workflow

For release setup and publication, use the `app-release` skill and the
[shared publishing guide](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/references/publishing.md).
If the skill is unavailable, read the private repository's README for its one-time
installation, or fetch the shared guide directly. Refresh shared instructions
before publishing. Keep this app's implementation details in `docs/releases.md`.

Publish the current DisplayDials.dmg through this repository's GitHub Releases and
the signed appcast through its GitHub Pages deployment. Never add cloud storage keys.

Release apps and updater executables must use the persistent certificate in
Resources/ReleaseSigning.cer, pinned in release.json. Never regenerate it during
builds, publish an ad hoc fallback, change the bundle ID or use an identifier-only
requirement. Keep private signing material outside source and in encrypted repo
Secrets. Do not alter system certificate trust or reuse another app's private key.
Use --status for the installed app's own Night Shift and login-item context.
Display Dials does not request Accessibility, Input Monitoring or Screen Recording;
do not invent permission requests or claim those grants were tested.

MIT is approved for this app. Preserve LICENSE and complete third-party notices
in both the app bundle and DMG; use the build/package license checks before release.
Do not change licensing or copyright notices by inference.
