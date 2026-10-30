# Wallpaper Veil automation

`Wallpaper Veil checks` runs inexpensive Ubuntu checks on pushes and pull requests.
Its stable required-check name is **Source checks**. It compiles the Python files
and parses the application Lua with Lua 5.4; it does not exercise macOS features.

[Wallpaper Veil preview build](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/preview-build.yml)
runs only through **Run workflow**. It downloads the official runtime pinned in
`runtime.json`, checks its SHA-256 and original signature, compiles the native
launcher and UI bridge, and packages the nested application. It verifies the code
signatures again after extracting `wallpaper-veil-preview.zip`, then uploads
Actions artifacts with a 14-day retention period. It never launches the app or
exercises hardware. No release is published and no recurring schedule is enabled.

Treat every preview artifact as public. The package contains the app, a ZIP
checksum, sanitized build provenance, the public runtime pin and a package summary.
It must not contain user preferences, local receipts, private paths, credentials
or diagnostic logs. The workflow has read-only repository access; checkout does
not persist credentials.

This is a binary-runtime prototype: the launcher and native UI bridge are compiled
from source, while the upstream native engine is prebuilt. Preview bundles are ad
hoc signed without Developer ID signing or notarization. Signing and ZIP checks do
not verify menu appearance, real display brightness, Accessibility permissions,
Spaces, sleep or wake. Those require local testing.

The runtime digest was read from the official GitHub release asset metadata:
[runtime 1.1.1 metadata](https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1).

Actions are pinned to the commit IDs behind official release tags, verified on
2026-10-30: checkout v7.0.1, setup-python v7.1.0 and upload-artifact v7.0.2.
When updating an action or runtime, verify the corresponding official metadata
and update the pin deliberately.
