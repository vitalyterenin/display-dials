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
