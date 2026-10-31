# Wallpaper Veil

User installation is in the [repository README](../README.md). Maintained architecture, build and developer launch instructions are in the [development guide](../docs/development.md). [CI instructions](ci/README.md) cover verified runtime downloads and manual preview builds.

The default development checkout is `~/Developer/Wallpaper Veil/wallpaper-veil`. The native About window includes the GitHub repository link and bundled licence access. The installed app can live at `~/Applications/Wallpaper Veil.app` and stores state under `~/Library/Application Support/Wallpaper Veil`. It does not load executable code from the source checkout or a separate Hammerspoon installation.

`handoff.py` uses `~/Developer/Wallpaper Veil/build.noindex/Wallpaper Veil.app` as its build input and `~/Applications/Wallpaper Veil.app` as its installation target. Match these paths when using that setup helper. Close Wallpaper Veil before installation or verification. The active acceptance test changes and restores tint settings and hardware brightness; read its behavior before running it.

Recovery must validate the intended backup first. `handoff.py rollback` only opens an existing `/Applications/Hammerspoon.app` with the expected identity; if it is absent, the helper leaves Wallpaper Veil running. It does not restore archived app/config/preferences automatically. Preserve your own protected backup and avoid running two wallpaper overlays together.

Development output uses `build.noindex`, and installed-app backups are verified ZIPs so app search has one canonical installed app. Launch at login is available under App settings and targets the outer launcher. Automatic startup after a real reboot was verified on macOS 27.0.1; other systems still need qualification. Accessibility-dependent automation, sleep/wake and longer use require separate acceptance checks. Bundled code is ad hoc signed and is not notarized.

About includes the installed version/build/channel and a manual Check for Updates action. The checker uses public GitHub release metadata and opens the selected release page. Source-engine builds and the pinned official input retain distinct, verified provenance; see [CI instructions](ci/README.md).
