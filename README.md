# Wallpaper Veil

[![Source checks](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/checks.yml/badge.svg)](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/checks.yml)
![Experimental preview](https://img.shields.io/badge/status-experimental%20preview-orange)

Wallpaper Veil is a macOS menu-bar app that places a configurable colour tint above rotating photo wallpapers and below desktop icons. It also includes display-brightness sync and optional desktop-widget controls.

Wallpaper Veil is an experimental public preview based on Hammerspoon 1.1.1. Contributions, bug reports and feature requests are welcome. The product builder compiles Wallpaper Veil's launcher and native UI bridge, and accepts either the pinned official engine or a verified engine compiled from the audited source baseline. The manual source-engine build and product packaging retain separate provenance.

## Features and status

- Adjust tint colour and strength, with saved custom colours.
- Keep normal wallpaper rotation and desktop interaction.
- Select a source and follower for hardware-brightness sync.
- Use optional desktop-widget and clock/Notification Center controls.
- Access Quit and About Wallpaper Veil from the app's menu.
- Check the installed version against GitHub releases and open a newer release for manual updating.

The preview is for evaluation and development. Hardware-brightness changes can fail or be unsupported, and widget automation depends on macOS behavior and permissions. A local two-display test passed brightness synchronization, independent adjustment and restoration. Actual launch at login was verified after reboot on macOS 27.0.1. Sleep/wake and compatibility across different systems remain ongoing acceptance work. There is no published stable release or supported-hardware matrix yet.

## Download and update

Download `wallpaper-veil-preview.zip` from [Releases](https://github.com/Ry00ki/wallpaper-veil/releases). Expand it and keep one installed `Wallpaper Veil.app` in your Applications folder. Quit the running app before replacing it, and retain the previous release ZIP for recovery. These experimental previews are ad hoc signed and not notarized.

About Wallpaper Veil shows the version, build and release channel. **Check for Updates** runs when clicked, compares published GitHub versions and offers a link to the newer release. Preview builds can see preview and stable releases; stable builds see stable releases. You download and replace the app yourself.

For release notifications, choose **Watch → Custom → Releases** on GitHub. See [GitHub notification settings](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications).

## How it runs

The app has a small Objective-C launcher, an app-owned Cocoa UI module and a nested native runtime app. The UI module provides the About window, repository/notices buttons and native app menu, and keeps inherited engine preferences/console windows outside normal product use. The launcher uses NSWorkspace to start that runtime with controlled app-code and state paths, then exits. It is not a permanent background supervisor.

Executable code and native modules live inside the completed app bundle. Writable state lives in `~/Library/Application Support/Wallpaper Veil`, with an independent macOS preferences domain. Once built, the app does not need the source checkout, Python or a separately installed Hammerspoon to run.

On first normal launch, it can import existing `wallpaperVeil.*` preferences from Hammerspoon into its own domain. It does not replace the original Hammerspoon configuration. Upstream update checks, crash uploads and AppleScript support are disabled in this prototype. Launch at login is available under App settings. Registration targets the outer launcher so login uses the same controlled startup as normal launch; macOS may require approval in Login Items settings.

Relevant source:

- [Launcher](WallpaperVeil/launcher.m)
- [Local builder](WallpaperVeil/build_local.py)
- [Application Lua](WallpaperVeil/app)
- [Local handoff helper](WallpaperVeil/handoff.py)

## Build a preview

Requirements:

- macOS with Xcode Command Line Tools, Clang and the macOS SDK.
- Python 3.10 or later and Git.
- A checkout retaining the upstream `1.1.1` tag and its history.
- The pinned official Hammerspoon **1.1.1, build 6936** engine, or its verified source-engine archive and manifest.
- A full Xcode installation is needed to compile the source engine; the manual GitHub Actions workflow provides that environment.

The builder validates that the upstream tag resolves to commit `1469832361b4c3687ec7d589c1b4efe4d3b742ee`. It rejects a different engine version. Obtain the matching engine from [Hammerspoon's official release](https://github.com/Hammerspoon/hammerspoon/releases/tag/1.1.1); it is a build input, not an installed runtime dependency of the finished app.

The default local checkout is `~/Developer/Wallpaper Veil/wallpaper-veil`. The build command is portable and can be run from the repository root at another location:

```sh
git fetch --no-tags https://github.com/Hammerspoon/hammerspoon.git refs/tags/1.1.1:refs/tags/1.1.1
python3 WallpaperVeil/ci/fetch_runtime.py --destination "$TMPDIR/wallpaper-veil-runtime"
python3 WallpaperVeil/build_local.py \
  --runtime "$TMPDIR/wallpaper-veil-runtime/Hammerspoon.app" \
  --output "$HOME/Developer/Wallpaper Veil/build.noindex/Wallpaper Veil.app"
```

Supply `--runtime` explicitly. It can point to the matching bundle elsewhere; the repository's pinned runtime-fetch helper is `WallpaperVeil/ci/fetch_runtime.py`. Check that helper's options before choosing a download location. The builder compiles the launcher and native UI module, packages the engine and Lua, retains acknowledgements, signs the bundle ad hoc and verifies its signature. It does not launch the app or change the source engine installation.

**Ad hoc signed** means locally signed without a Developer ID identity. This build is not notarized and is not a distribution-ready release.

The separate [source-engine build workflow](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/source-engine-build.yml) compiles the pinned native baseline with full Xcode. [CI instructions](WallpaperVeil/ci/README.md) describe its manifest/archive inputs and product packaging. See [the preserved upstream README](UPSTREAM_README.md) and [upstream contribution guidance](https://github.com/Hammerspoon/hammerspoon/blob/master/CONTRIBUTING.md).

## Install one canonical app

For the helper's default local layout, close the running Wallpaper Veil, then run:

```sh
python3 WallpaperVeil/handoff.py install
python3 WallpaperVeil/handoff.py preflight
open "$HOME/Applications/Wallpaper Veil.app"
```

The installer preserves an existing app as a verified ZIP, installs the new bundle and removes its expanded development build copy. Use the app in Applications as the canonical installation. Development output belongs under `build.noindex`, and recovery copies remain ZIPs, so app search does not accumulate launchable copies.

## Launch and check

Close any other Wallpaper Veil copy before verification:

```sh
open "$HOME/Applications/Wallpaper Veil.app" --args --verify-only
```

Verification-only checks identity, isolated settings/code paths and application Lua syntax, then exits. It does not run the hardware-brightness acceptance sequence.

Before normal launch, stop an existing Hammerspoon-based veil to avoid duplicate overlays. Then open the canonical installed app:

```sh
open "$HOME/Applications/Wallpaper Veil.app"
```

Use its menu-bar item to adjust the tint or quit. App settings includes Launch at login, Login Items settings and the Accessibility permission entry for optional automation. Enabling a pending login registration requires approval in System Settings; registering it is separate from qualifying a real later login. About Wallpaper Veil is the final menu item and opens an app-owned window with an Open GitHub Repository button pointing to this repository, plus access to bundled licence notices. macOS Accessibility approval is needed for the optional widget/clock automation; tint controls do not require that approval.

The current `handoff.py` is a local development helper with fixed default development and installation paths. Inspect its constants and recovery behavior before using it on another setup. Its handoff/self-test modes may stop a matching legacy process and make small temporary hardware-brightness changes. They are active acceptance tests, not passive diagnostics. Prefer a verified previous Wallpaper Veil bundle for recovery. Restoring an older Hammerspoon setup requires that app to be present and validated first; do not assume it remains installed. A single successful run does not establish reliability across displays or macOS versions.

## Repository checks and preview builds

Source checks parse the app Lua, compile Python and run deterministic regression suites on every push and pull request. The [Wallpaper Veil preview build](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/preview-build.yml) workflow builds a ZIP only when manually dispatched. Its public preview artifact includes a SHA-256 checksum and verifies the extracted app signature; the workflow does not launch the app or exercise hardware. The artifact is an ad hoc signed, unnotarized preview, not a stable release. See [CI details](WallpaperVeil/ci/README.md).

## Contributing and reporting problems

[Report a bug](https://github.com/Ry00ki/wallpaper-veil/issues/new?template=bug_report.yml), [suggest a feature](https://github.com/Ry00ki/wallpaper-veil/issues/new?template=feature_request.yml), or [open a pull request](https://github.com/Ry00ki/wallpaper-veil/compare). See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md). Include reproducible steps and a minimal, redacted error excerpt when reporting a problem. Do not upload personal preferences, diagnostic receipts, display identifiers or complete private logs.

## Credits and licence

Wallpaper Veil builds on [Hammerspoon](https://github.com/Hammerspoon/hammerspoon), LuaSkin, Lua and the contributors to Hammerspoon and its dependencies. The source fork begins at Hammerspoon 1.1.1.

Wallpaper Veil's original code is licensed under the [MIT licence](LICENSE). Hammerspoon's MIT copyright and permission notice are preserved. Bundled third-party components retain their own licences and acknowledgements. See [third-party notices](THIRD_PARTY_NOTICES.md). Preserve them when modifying or distributing a build; see [CREDITS.md](CREDITS.md) and the built runtime's `Contents/Resources/Acknowledgements`.
