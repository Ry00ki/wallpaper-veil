# Contributing to Wallpaper Veil

Wallpaper Veil is an experimental public preview. Keep contributions focused on the wallpaper utility and its standalone lifecycle. Discuss a full engine rebuild, distribution changes or a major architecture change before combining it with a small fix.

## Issues and pull requests

Use [issues](https://github.com/Ry00ki/wallpaper-veil/issues) for reproducible bugs and feature proposals. You can open a focused fix directly as a pull request.

Fork the repository, create a branch from `main`, make a scoped change, and open a [pull request](https://github.com/Ry00ki/wallpaper-veil/pulls) against `main`. Explain the resulting behavior and checks performed. The Ubuntu source checks run automatically; macOS preview builds are dispatched manually.

`main` requires a pull request and passing `Source checks` from GitHub Actions against an up-to-date base. Conversation threads must be resolved. Force pushes and deletion are blocked, including for repository administrators. A second-person approval is not required for this solo-maintained project.

## Getting started

Read the [README](README.md) for the current architecture and local build recipe. The repository retains Hammerspoon source history. The product builder compiles the Wallpaper Veil launcher and native UI module, and accepts the pinned official engine or a source-engine archive verified against its manifest and native baseline. Record the chosen origin; a launcher-only change does not rebuild the engine.

Useful areas:

- `WallpaperVeil/native_ui.m`: app-owned About, menus and scoped engine-window suppression.
- `WallpaperVeil/launcher.m`: native app startup and state-directory handling.
- `WallpaperVeil/build_local.py`: packaging, identity and local signing.
- `WallpaperVeil/app/`: application startup, menus and features.
- `WallpaperVeil/handoff.py`: setup-specific acceptance and recovery tooling.

The handoff helper has fixed local path assumptions. Check them before running it. Do not commit a contributor's absolute home paths, preferences or diagnostic outputs.

## Making a change

Explain the problem, keep the diff scoped and preserve unrelated Hammerspoon behavior. Keep executable runtime dependencies in the finished bundle rather than relying on the source checkout or a user's Hammerspoon configuration.

Preserve the original runtime input and user settings while developing. Do not add permission prompts, login registration, telemetry or update services as incidental changes to another feature.

Test every new or changed feature and run the existing regression suites for every release. Verify the published download and perform an installed-app smoke check after publication. Keep evidence of the exact source, artifact hash and checks performed.

Include meaningful validation for changed behavior. Documentation-only changes do not need new runtime tests. For app changes, report the relevant build/preflight result and actual feature checks performed; distinguish inspection, simulation and real hardware interaction.

Brightness acceptance tests actively change display brightness. Capture and verify restoration of the original values, retain asynchronous timers and handle cancellation. Test startup/quit and timer cleanup when changing the app lifecycle. Check that menu items appear once and that About Wallpaper Veil remains last when changing menus.

For runtime-path changes, verify the installed app launches without the development source and does not load code from an external user configuration. Do not infer this from a valid signature alone.

## Pull requests

Use the pull request template. Describe the resulting behavior, validation and remaining limits. State whether a build uses the prebuilt engine or recompiles it. Avoid blanket claims such as “fully tested” when a feature or hardware case was not exercised.

Do not include private preferences, palette data, raw display identifiers, receipts, credentials or complete personal logs. Use minimal redacted excerpts where needed.

## Upstream and licensing

Retain upstream history and relevant notices. Record the upstream version when changing the engine input, and check the affected extension interfaces. Keep unrelated upstream merges separate from a feature fix where practical.

Contributions must be compatible with the repository's MIT licence. Retained dependencies keep their own licence terms. Preserve required copyright and acknowledgement files.
