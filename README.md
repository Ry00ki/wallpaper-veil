# Wallpaper Veil

Wallpaper Veil is a macOS menu-bar app that places a configurable colour tint above rotating photo wallpapers and below desktop icons. It also includes display-brightness sync and optional desktop-widget controls.

This repository contains an experimental standalone-app prototype based on Hammerspoon 1.1.1. The current build compiles Wallpaper Veil's launcher and bundles the matching prebuilt Hammerspoon engine with app-owned Lua code. It does not yet rebuild the complete native engine from this source fork.

## Features and status

- Adjust tint colour and strength, with saved custom colours.
- Keep normal wallpaper rotation and desktop interaction.
- Select a source and follower for hardware-brightness sync.
- Use optional desktop-widget and clock/Notification Center controls.
- Access Quit and About Wallpaper Veil from the app's menu.

The prototype is for local evaluation. Hardware-brightness changes can fail or be unsupported, and widget automation depends on macOS behavior and permissions. Sleep/wake, login startup and compatibility across different systems remain ongoing acceptance work. There is no published stable release or supported-hardware matrix yet.

## How it runs

The app has a small Objective-C launcher and a nested native runtime app. The launcher uses NSWorkspace to start that runtime with controlled app-code and state paths, then exits. It is not a permanent background supervisor.

Executable code and native modules live inside the completed app bundle. Writable state lives in `~/Library/Application Support/Wallpaper Veil`, with an independent macOS preferences domain. Once built, the app does not need the source checkout, Python or a separately installed Hammerspoon to run.

On first normal launch, it can import existing `wallpaperVeil.*` preferences from Hammerspoon into its own domain. It does not replace the original Hammerspoon configuration. Upstream update checks, crash uploads and AppleScript support are disabled in this prototype. Login registration is not implemented by the prototype.

Relevant source:

- [Launcher](WallpaperVeil/launcher.m)
- [Local builder](WallpaperVeil/build_local.py)
- [Application Lua](WallpaperVeil/app)
- [Local handoff helper](WallpaperVeil/handoff.py)

## Build a local prototype

Requirements:

- macOS with Xcode Command Line Tools, Clang and the macOS SDK.
- Python 3.10 or later and Git.
- A checkout retaining the upstream `1.1.1` tag and its history.
- An official Hammerspoon **1.1.1, build 6936** app bundle as the engine input.

The build validates that the upstream tag resolves to commit `1469832361b4c3687ec7d589c1b4efe4d3b742ee`. It rejects a different engine version. Obtain the matching engine from [Hammerspoon's official release](https://github.com/Hammerspoon/hammerspoon/releases/tag/1.1.1); it is a build input, not an installed runtime dependency of the finished app.

The default local checkout is `~/Developer/Wallpaper Veil/wallpaper-veil`. The build command is portable and can be run from the repository root at another location:

```sh
git fetch --no-tags https://github.com/Hammerspoon/hammerspoon.git refs/tags/1.1.1:refs/tags/1.1.1
python3 WallpaperVeil/ci/fetch_runtime.py --destination "$TMPDIR/wallpaper-veil-runtime"
python3 WallpaperVeil/build_local.py \
  --runtime "$TMPDIR/wallpaper-veil-runtime/Hammerspoon.app" \
  --output "$PWD/build/Wallpaper Veil.app"
```

Supply `--runtime` explicitly. It can point to the matching bundle elsewhere; the repository's pinned runtime-fetch helper is `WallpaperVeil/ci/fetch_runtime.py`. Check that helper's options before choosing a download location. The builder compiles the launcher, packages the engine and Lua, retains acknowledgements, signs the bundle ad hoc and verifies its signature. It does not launch the app or change the source engine installation.

**Ad hoc signed** means locally signed without a Developer ID identity. This build is not notarized and is not a distribution-ready release.

A complete engine rebuild is a separate workflow requiring the upstream Xcode workspace and dependencies. See [the preserved upstream README](UPSTREAM_README.md) and [upstream contribution guidance](https://github.com/Hammerspoon/hammerspoon/blob/master/CONTRIBUTING.md).

## Launch and check

Close any other Wallpaper Veil copy before verification:

```sh
open "$PWD/build/Wallpaper Veil.app" --args --verify-only
```

Verification-only checks identity, isolated settings/code paths and application Lua syntax, then exits. It does not run the hardware-brightness acceptance sequence.

Before normal launch, stop an existing Hammerspoon-based veil to avoid duplicate overlays. Then open the built app:

```sh
open "$PWD/build/Wallpaper Veil.app"
```

Use its menu-bar item to adjust the tint or quit. About Wallpaper Veil is the final menu item. macOS Accessibility approval is needed for the optional widget/clock automation; tint controls do not require that approval.

The current `handoff.py` is a local development helper with fixed default development and installation paths. Inspect its constants and recovery behavior before using it on another setup. Its handoff/self-test modes may stop a matching legacy process and make small temporary hardware-brightness changes. They are active acceptance tests, not passive diagnostics. Prefer a verified previous Wallpaper Veil bundle for recovery. Restoring an older Hammerspoon setup requires that app to be present and validated first; do not assume it remains installed. A single successful run does not establish reliability across displays or macOS versions.

## Repository checks and private builds

Source checks parse the app Lua and compile Python on every push and pull request. The **Wallpaper Veil private preview** workflow builds a ZIP only when manually dispatched in a private repository. Its artifact includes a SHA256 checksum and verifies the extracted app signature; it does not launch the app or exercise hardware. See [CI details](WallpaperVeil/ci/README.md).

## Contributing and reporting problems

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md). Include reproducible steps and a minimal, redacted error excerpt when reporting a problem. Do not upload personal preferences, diagnostic receipts, display identifiers or complete private logs.

## Credits and licence

Wallpaper Veil builds on [Hammerspoon](https://github.com/Hammerspoon/hammerspoon), LuaSkin, Lua and the contributors to Hammerspoon and its dependencies. The source fork begins at Hammerspoon 1.1.1.

Wallpaper Veil's original code is licensed under the [MIT licence](LICENSE). Hammerspoon's MIT copyright and permission notice are preserved. Bundled third-party components retain their own licences and acknowledgements. See [third-party notices](THIRD_PARTY_NOTICES.md). Preserve them when modifying or distributing a build; see [CREDITS.md](CREDITS.md) and the built runtime's `Contents/Resources/Acknowledgements`.
