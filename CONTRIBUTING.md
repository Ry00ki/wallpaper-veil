# Contributing to Wallpaper Veil

Wallpaper Veil is currently an experimental local prototype. Keep contributions focused on the wallpaper utility and its standalone lifecycle. Discuss a full engine rebuild, distribution changes or a major architecture change before combining it with a small fix.

## Getting started

Read the [README](README.md) for the current architecture and local build recipe. The repository retains Hammerspoon source history, while the prototype builder currently compiles only the Wallpaper Veil launcher and packages a matching prebuilt engine. Do not describe a launcher-only change as a complete engine rebuild.

Useful areas:

- `WallpaperVeil/launcher.m`: native app startup and state-directory handling.
- `WallpaperVeil/build_local.py`: packaging, identity and local signing.
- `WallpaperVeil/app/`: application startup, menus and features.
- `WallpaperVeil/handoff.py`: setup-specific acceptance and recovery tooling.

The handoff helper has fixed local path assumptions. Check them before running it. Do not commit a contributor's absolute home paths, preferences or diagnostic outputs.

## Making a change

Explain the problem, keep the diff scoped and preserve unrelated Hammerspoon behavior. Keep executable runtime dependencies in the finished bundle rather than relying on the source checkout or a user's Hammerspoon configuration.

Preserve the original runtime input and user settings while developing. Do not add permission prompts, login registration, telemetry or update services as incidental changes to another feature.

Include meaningful validation for changed behavior. Documentation-only changes do not need new runtime tests. For app changes, report the relevant build/preflight result and actual feature checks performed; distinguish inspection, simulation and real hardware interaction.

Brightness acceptance tests actively change display brightness. Capture and verify restoration of the original values, retain asynchronous timers and handle cancellation. Test startup/quit and timer cleanup when changing the app lifecycle. Check that menu items appear once and that About Wallpaper Veil remains last when changing menus.

For runtime-path changes, verify the installed app launches without the development source and does not load code from an external user configuration. Do not infer this from a valid signature alone.

## Pull requests

Use the pull request template. Describe the resulting behavior, validation and remaining limits. State whether a build uses the prebuilt engine or recompiles it. Avoid blanket claims such as “fully tested” when a feature or hardware case was not exercised.

Do not include private preferences, palette data, raw display identifiers, receipts, credentials or complete personal logs. Use minimal redacted excerpts where needed.

## Upstream and licensing

Retain upstream history and relevant notices. Record the upstream version when changing the engine input, and check the affected extension interfaces. Keep unrelated upstream merges separate from a feature fix where practical.

Contributions must be compatible with the repository's MIT licence. Retained dependencies keep their own licence terms. Preserve required copyright and acknowledgement files.
