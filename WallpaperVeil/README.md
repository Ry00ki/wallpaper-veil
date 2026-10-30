# Wallpaper Veil

The maintained architecture, build and launch instructions are in the [repository README](../README.md). [CI instructions](ci/README.md) cover verified runtime downloads and manual preview builds.

The default development checkout is `~/Developer/Wallpaper Veil/wallpaper-veil`. The native About window includes the GitHub repository link and bundled licence access. The installed app can live at `~/Applications/Wallpaper Veil.app` and stores state under `~/Library/Application Support/Wallpaper Veil`. It does not load executable code from the source checkout or a separate Hammerspoon installation.

`handoff.py` uses `~/Developer/Wallpaper Veil/build.noindex/Wallpaper Veil.app` as its build input and `~/Applications/Wallpaper Veil.app` as its installation target. Match these paths when using that setup helper. Close Wallpaper Veil before installation or verification. The active acceptance test changes and restores tint settings and hardware brightness; read its behavior before running it.

Recovery must validate the intended backup first. `handoff.py rollback` only opens an existing `/Applications/Hammerspoon.app` with the expected identity; if it is absent, the helper leaves Wallpaper Veil running. It does not restore archived app/config/preferences automatically. Preserve your own protected backup and avoid running two wallpaper overlays together.

Development output uses `build.noindex`, and installed-app backups are verified ZIPs so app search has one canonical installed app. Launch at login is available under App settings and targets the outer launcher. A real later login remains a separate qualification step. Accessibility-dependent automation, sleep/wake and longer use require separate acceptance checks. Bundled code is ad hoc signed and is not notarized.
