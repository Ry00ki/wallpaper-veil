# Wallpaper Veil automation

`Wallpaper Veil checks` runs inexpensive Ubuntu checks on pushes and pull requests.
Its stable required-check name is **Source checks**. It compiles the Python files
and parses the application Lua with Lua 5.4; it does not exercise macOS features.

`Wallpaper Veil private preview` runs only through **Run workflow**. The workflow
is restricted to a private repository. It downloads the official runtime pinned
in `runtime.json`, checks its SHA-256 and original signature, compiles the native
launcher, and packages the nested application. It verifies the code signatures
again after extracting the preview ZIP, then uploads private Actions artifacts
with a 14-day retention period. It never launches the app or changes account or
repository access. No release is published and no recurring schedule is enabled.

This is a binary-runtime prototype: the launcher is compiled from source, while
the upstream native engine is prebuilt. Signing and ZIP checks do not verify menu
appearance, real display brightness, Accessibility permissions, Spaces, sleep or
wake. Those require local testing.

The runtime digest was read from the official GitHub release asset metadata:
[runtime 1.1.1 metadata](https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1).

Actions are pinned to the commit IDs behind official release tags, verified on
2026-10-30: checkout v7.0.1, setup-python v7.1.0 and upload-artifact v7.0.2.
When updating an action or runtime, verify the corresponding official metadata
and update the pin deliberately.
