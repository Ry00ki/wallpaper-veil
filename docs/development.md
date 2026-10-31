# Building and developing Wallpaper Veil

For normal use, follow the three-step [app installation](../README.md#install-and-use). This document is for contributors building or qualifying the product.

## How it runs

Wallpaper Veil is an experimental public preview based on Hammerspoon 1.1.1. Contributions, bug reports and feature requests are welcome. The product builder compiles Wallpaper Veil's launcher and native UI bridge, and accepts either the pinned official engine or a verified engine compiled from the audited source baseline. The manual source-engine build and product packaging retain separate provenance.

The app has a small Objective-C launcher, an app-owned Cocoa UI module and a nested native runtime app. The UI module provides the About window, repository/notices buttons and native app menu, and keeps inherited engine preferences/console windows outside normal product use. The launcher uses NSWorkspace to start that runtime with controlled app-code and state paths, then exits. It is not a permanent background supervisor.

Executable code and native modules live inside the completed app bundle. Writable state lives in `~/Library/Application Support/Wallpaper Veil`, with an independent macOS preferences domain. Once built, the app does not need the source checkout, Python or a separately installed Hammerspoon to run.

On first normal launch, it can import existing `wallpaperVeil.*` preferences from Hammerspoon into its own domain. It does not replace the original Hammerspoon configuration. Upstream update checks, crash uploads and AppleScript support are disabled in this prototype. Launch at login is available under App settings. Registration targets the outer launcher so login uses the same controlled startup as normal launch; macOS may require approval in Login Items settings.

Relevant source:

- [Launcher](../WallpaperVeil/native/launcher.m)
- [Local builder](../WallpaperVeil/build_local.py)
- [Application Lua](../WallpaperVeil/core)
- [Local handoff helper](../WallpaperVeil/handoff.py)

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

The separate [source-engine build workflow](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/source-engine-build.yml) compiles the pinned native baseline with full Xcode. [CI instructions](../WallpaperVeil/ci/README.md) describe its manifest/archive inputs and product packaging. See [the pinned upstream README](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/README.md) and [upstream contribution guidance](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/CONTRIBUTING.md).

## Development-only canonical handoff

This helper is for the maintainer's development/qualification layout, not customer installation. For its default local layout, close the running Wallpaper Veil, then run:

```sh
python3 WallpaperVeil/handoff.py install
python3 WallpaperVeil/handoff.py preflight
open "$HOME/Applications/Wallpaper Veil.app"
```

The installer preserves an existing app as a verified ZIP, installs the new bundle and removes its expanded development build copy. Use the app in Applications as the canonical installation. Development output belongs under `build.noindex`, and recovery copies remain ZIPs, so app search does not accumulate launchable copies.

## Development-only verification and active acceptance

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

The current `handoff.py` is a local development helper with fixed default development and installation paths. Inspect its constants and recovery behavior before using it on another setup. Its handoff/self-test modes may stop a matching legacy process and make small temporary hardware-brightness changes. They are active acceptance tests, not passive diagnostics. The installed `--self-test` also temporarily exercises Use macOS defaults against the fixed `com.apple.WindowManager/StandardHideWidgets` key, with widget observers stopped. It restores the original key presence/type/value and all five owned widget settings, then verifies recovery; it stores no OS preference snapshot in the result. This does not qualify physical clock or Notification Center interaction. Prefer a verified previous Wallpaper Veil bundle for recovery. Restoring an older Hammerspoon setup requires that app to be present and validated first; do not assume it remains installed. A single successful run does not establish reliability across displays or macOS versions.

## Repository checks and preview builds

Source checks parse the app Lua, compile Python and run deterministic regression suites on every push and pull request. The [Wallpaper Veil preview build](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/preview-build.yml) workflow builds a ZIP only when manually dispatched. Its public preview artifact includes a SHA-256 checksum and verifies the extracted app signature; the workflow does not launch the app or exercise hardware. The artifact is an ad hoc signed, unnotarized preview, not a stable release. See [CI details](../WallpaperVeil/ci/README.md).


## Pinned source inputs

`engine/upstream.json` records the exact upstream commit/tree, three Lua C header objects, 81 component notices, two CocoaPods acknowledgement files and the upstream licence. `WallpaperVeil/upstream.py` verifies and materializes these 87 Git objects into temporary build staging. Current main intentionally has no `Hammerspoon`, `Pods`, `LuaSkin`, `extensions` or upstream Xcode project folders. Fetch and keep the audited upstream `1.1.1` tag; the historical commit is retained in the repository, and source builds compile a temporary checkout of that exact baseline. Both manual build workflows fetch and verify this tag explicitly.

For source-built engine inputs, the builder verifies the qualified native count, bootstrap, full archive inventory, architectures, signatures and notices against the source-engine manifest. The official-release route verifies its pinned main executable/bootstrap and original signatures; it does not apply the source-engine archive manifest to that separate input. The [standalone bundle contract](../WallpaperVeil/standalone_contract.py) checks internal native-library resolution and one-app ZIP layout. These packaging checks do not establish actual hardware, permission, login or lifecycle behavior.

A source ZIP without Git history is not a build checkout. Normal users need only the packaged app; contributors need the pinned Git objects and the chosen verified engine input. See [upstream maintenance](upstream-maintenance.md) before changing the baseline or introducing native patches.
