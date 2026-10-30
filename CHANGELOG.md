# Changelog

Changes are grouped by release. This project has not published a stable release.

## Unreleased

### Added

- Public issue and pull-request contribution links, plus a manually dispatched preview-build workflow.

- An app-owned About window with GitHub repository link and licence access.
- An original Wallpaper Veil icon and app-owned native menu.
- Verified ZIP recovery backups and unindexed development build output to avoid duplicate app-search entries.
- Explicit MIT licensing for Wallpaper Veil code, preserved upstream MIT notice and bundled third-party licence notices.
- Wallpaper Veil standalone local prototype based on Hammerspoon 1.1.1.
- Compiled Objective-C launcher using NSWorkspace to start a bundled native runtime app.
- App-owned Lua startup, independent preferences and native Application Support state.
- Wallpaper tint, colour/strength controls and saved custom colours.
- Selected source/follower hardware-brightness sync.
- Optional desktop-widget and clock/Notification Center controls.
- Local build, verification, acceptance and recovery tooling.

### Changed

- The app uses its own menu with Quit Wallpaper Veil and About Wallpaper Veil.
- About Wallpaper Veil is the final menu item.
- The standalone menu omits the Hammerspoon-icon toggle.
- The local prototype disables upstream update checks, crash uploads and AppleScript support.
- Copied upstream login helpers are removed; standalone login startup remains unimplemented.

### Known limitations

- The builder packages the matching prebuilt Hammerspoon engine; a complete native engine rebuild is not part of this prototype.
- Local bundles are ad hoc signed without Developer ID signing or notarization.
- Hardware-brightness writes can be intermittent or unsupported; reliability needs testing on the target displays.
- Automatic widget/clock behavior requires macOS permissions and real interaction testing.
- Sleep/wake, login startup and a broader compatibility matrix are not yet qualified.
- The local handoff helper has setup-specific path assumptions.
