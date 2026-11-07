# Project language

Write all application interface text, project documentation, code comments, and docstrings in English.
Apply this rule when creating or updating any file in this repository.

# Options menu layout

Keep options menu presentation in `OptionsMenuPresentation`. Open it in screen
coordinates with no popover parent view; do not introduce a fixed menu height.
When adding menu items or changing presentation, run `scripts/test.sh`, including
the menu growth checks, and inspect the current menu through its final item.
