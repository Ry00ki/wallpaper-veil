# Wallpaper Veil

[![Source checks](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/checks.yml/badge.svg)](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/checks.yml)
![Release](https://img.shields.io/badge/release-1.0-blue)

Wallpaper Veil is a macOS menu-bar app that places a configurable colour tint above rotating photo wallpapers and below desktop icons. It also includes display-brightness sync and optional desktop-widget controls.

<p align="center">
  <img src="docs/images/wallpaper-veil-cover.jpg" alt="The same mountain photograph without a veil on the left and with a 50% black veil on the right, alongside the Wallpaper Veil app icon" width="840">
</p>

## Install and use

Wallpaper Veil is distributed as **one self-contained `Wallpaper Veil.app`** for macOS 13 or later, on Apple Silicon and Intel Macs.

1. Download **`wallpaper-veil.zip`** from the [latest stable release](https://github.com/Ry00ki/wallpaper-veil/releases/latest). Preview builds use `wallpaper-veil-preview.zip` and are listed separately in [Releases](https://github.com/Ry00ki/wallpaper-veil/releases).
2. Expand the ZIP and drag **`Wallpaper Veil.app` into Applications**. Your personal `~/Applications` folder is also supported. Keep one installed copy.
3. Open the app and use **◐ Veil** in the menu bar.

That is the user installation. Python, Git, Xcode and a separate Hammerspoon installation are **not required to run the app**. Its native engine, Lua code and libraries travel inside the `.app`; writable app data lives in Application Support, with settings in its own macOS preferences domain. The release's checksum and JSON files are optional verification/provenance material, not extra items to install.

Current builds are ad hoc signed and not notarized. The stable label describes the project release channel, not Apple signing or certification. macOS may block a downloaded app; see [Apple's documented Open Anyway process](https://support.apple.com/en-us/102445). Optional desktop-widget/clock automation requires macOS Accessibility approval; tint controls do not require that permission. Developer ID signing/notarization remains separate distribution work.

[Report a bug](https://github.com/Ry00ki/wallpaper-veil/issues/new?template=bug_report.yml) · [Portfolio overview](https://www.vincent-ry00ki.com/wallpaper-veil)

*The visuals below reuse the portfolio's photographs and simplified interface illustrations. They are not live application screenshots.*

## Features and current status

### Keep your wallpaper, choose its strength

Adjust tint colour and strength, save custom colours, and switch the veil on or off. The original photo stays in place and normal wallpaper rotation continues. Desktop icons and windows remain above the veil.

<details>
<summary>See colour and strength examples</summary>

![The same photograph with the veil off, a 20% black veil, a 50% black veil and a 30% warm custom-colour veil](docs/images/colour-and-strength.png)

</details>

### One adjustment, two displays

Choose a source display and a follower for hardware-brightness sync. When the source brightness changes, the paired display follows. This is separate from the wallpaper tint and strength controls.

![Two illustrated displays showing matching sun icons and 50% brightness: adjust the primary display and the paired display follows automatically](docs/images/brightness-sync.png)

Brightness sync requires native macOS brightness control. Third-party monitor support is not guaranteed; the preview does not yet have a supported-hardware matrix.

### Quietly in the menu bar

Look for **◐ Veil** in the menu bar; **○ Veil** indicates that the wallpaper tint is off. Open the menu for tint settings, display sync, optional desktop-widget and clock/Notification Center controls, and App settings. Quit and About Wallpaper Veil are available there too.

**Desktop widgets → Use macOS defaults** stops Wallpaper Veil's widget/clock automation and resets its widget-visibility preference to the macOS built-in default. It clears the three automation choices. Select a clock/Notification Center option, or Show now/Hide now, to opt back into custom behaviour; compatible automation choices can be combined.

![Illustration of the Wallpaper Veil menu-bar item beside the battery and clock](docs/images/menu-bar.png)

<details>
<summary>See the simplified app menu</summary>

![Simplified Wallpaper Veil menu with tint, brightness sync, colour, strength, desktop widgets, app settings, Quit and About controls](docs/images/menu-controls.png)

</details>

Wallpaper Veil makes one background update check per real startup, and About checks again when you open it. A newer eligible version opens About; closing that startup notice or choosing Skip This Version remembers the version, so it is not repeatedly shown. You can turn off Check for updates at startup; manual About checks and installation remain available. About also includes the repository and third-party notices. Separate **Stable release** and **Preview** choices show the newest version in each channel; **Download & Install** verifies the download, replaces the app and restarts it. Stable is the recommended choice. Downloads and installation start only when you choose them.

The 1.0 release is tested on macOS 27.2 with Apple silicon and two native-brightness-capable Apple displays. Bundles target macOS 13+ and contain Apple silicon/Intel executables; other hardware/OS combinations are not yet covered by a supported-hardware matrix. Tint, brightness following, default widget mode and the update flow have release checks. Optional clock/Notification Center automation and actual sleep/Spaces/physical display-reconnect qualification remain open in [#3](https://github.com/Ry00ki/wallpaper-veil/issues/3) and [#4](https://github.com/Ry00ki/wallpaper-veil/issues/4). Launch at login was verified after reboot on macOS 27.0.1. Hardware brightness changes may be unsupported or fail; the app confirms them by read-back.

## Updating

Open **About Wallpaper Veil**. It checks published GitHub releases automatically and shows stable releases separately from early-access previews. Startup checks happen once per actual app launch, not on menu clicks or other interactions. Skip This Version persists across restarts; skipped updates remain manually installable in About, and a newer version can notify again. The Check for updates at startup checkbox disables automatic startup checks entirely. Choose **Download & Install** beside a newer version. Settings are kept; the old app is retained until the new app confirms normal startup, with recovery if it cannot start. No developer tools are required. Nothing is downloaded or installed merely by opening About.

Stable releases have tags such as `v1.0.0`; previews use `v1.0.1-preview.1` and GitHub's prerelease flag. Preview installation is an explicit choice, and the updater does not silently install an older/current version. The updater verifies the exact GitHub asset SHA-256, bound build receipt, safe package paths and nested code signatures. Current ad hoc builds trust this repository over HTTPS; independent publisher authentication via Developer ID/notarization remains [#7](https://github.com/Ry00ki/wallpaper-veil/issues/7).

Versions before 1.0 need one manual replacement to gain the installer: quit the old copy, replace its `.app` with the new one and reopen it. Manual replacement also remains available when the installed folder is not writable. Keep the previous release ZIP for recovery and avoid running copies from both Downloads and Applications. macOS may request renewed approval for optional desktop automation after an ad hoc update.

[Update verification and recovery](docs/updating.md) explains the native installation flow.

For release notifications, choose **Watch → Custom → Releases** on GitHub. See [GitHub notification settings](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications).

## Source and maintenance

The maintained checkout contains Wallpaper Veil's own code and an explicit engine integration policy:

```text
WallpaperVeil/
  core/       application behaviour and lifecycle
  native/     launcher, UI and macOS integration
  assets/     application identity
  ci/         build and package tooling
  tests/      product regression tests
engine/       pinned upstream policy and integration map
docs/         development and upstream-maintenance guides
```

The app still bundles an engine derived from Hammerspoon 1.1.1. The unused upstream working-tree folders are removed from current main, while their original history, licence and qualified engine-build source remain available. Builds fetch and verify the pinned upstream tag. This is a smaller maintained checkout, not a claim that the underlying native engine has been replaced.

- [Build and development](docs/development.md): Python/Xcode requirements and local acceptance tools, for contributors.
- [Architecture and ownership](docs/architecture.md): what is app-owned, adapted or retained.
- [Upstream integration and updates](docs/upstream-maintenance.md): original paths, transformations and review procedure.
- [CI and source-engine builds](WallpaperVeil/ci/README.md).

## Contributing and reporting problems

[Report a bug](https://github.com/Ry00ki/wallpaper-veil/issues/new?template=bug_report.yml), [suggest a feature](https://github.com/Ry00ki/wallpaper-veil/issues/new?template=feature_request.yml), or [open a pull request](https://github.com/Ry00ki/wallpaper-veil/compare). See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md). Include reproducible steps and a minimal, redacted error excerpt. Keep personal settings, display identifiers and complete private logs out of reports.

## Credits and licence

Wallpaper Veil builds on [Hammerspoon](https://github.com/Hammerspoon/hammerspoon), LuaSkin, Lua and the contributors to Hammerspoon and its dependencies. The source fork begins at Hammerspoon 1.1.1.

Wallpaper Veil's original code is licensed under the [MIT licence](LICENSE). Hammerspoon's MIT copyright and permission notice are preserved. Bundled third-party components retain their own licences and acknowledgements. See [third-party notices](THIRD_PARTY_NOTICES.md). Preserve them when modifying or distributing a build; see [CREDITS.md](CREDITS.md) and the built runtime's `Contents/Resources/Acknowledgements`.
