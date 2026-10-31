# Changelog

Changes are grouped by release. Stable releases and previews are listed separately below.

## 1.0.0 preview - 31.10.26

- Check GitHub automatically when About opens; display independent stable and preview release choices.
- Add native Download & Install with exact release-asset/build-receipt verification, safe extraction, atomic replacement, passive startup confirmation and rollback/recovery.
- Preserve settings and the single installed runtime; no Python, Git, Xcode or separate engine is needed for updating.
- Suspend pending brightness writes across system/display sleep and resume with a fresh confirmation window.
- Keep actual clock/Spaces/sleep/hardware reconnect qualification open; Developer ID signing/notarization remains separate work.

## 0.1.7 preview - 31.10.26

- Lead installation with one downloadable app: expand the ZIP, copy Wallpaper Veil.app to Applications and open it. Move developer-only setup into the development guide.
- Consolidate product-owned Lua and native code into core/native directories; remove unused upstream projects, tests, vendored trees and tooling from the active checkout while preserving their history.
- Recover only the exact pinned engine header/legal inputs during builds, retain all required notices and document ownership plus the future upstream-update process.
- Audit internal native-library dependencies, bundle symlinks and the single-app ZIP structure during build and packaging.

## 0.1.6 preview - 31.10.26

- Add **Use macOS defaults** to Desktop widgets: stop the app's widget/clock automation, clear its three choices and reset the one app-managed widget-visibility override to the macOS built-in default.
- Use an app-owned native preferences bridge for widget visibility, replacing asynchronous command-line writes; resets verify the override was removed.
- Keep fresh startup free of widget-preference writes and make re-enabling a custom automation or Show/Hide an explicit choice.

## 0.1.5 preview - 30.10.26

- Separate Startup and Desktop widget controls in App settings, with explicit destinations in System Settings.
- Read current macOS startup and desktop-control permission state each time the menu opens; distinguish enabled startup from a request waiting for approval.
- Open the desktop-control privacy pane for both Enable and Manage actions, including when permission is already granted. Name Device Control and Data Access on macOS 27 and Accessibility on earlier systems.

## 0.1.4 preview - 30.10.26

- Accept a verified universal source-engine build with an explicit archive/manifest receipt and native-source checks. Preserve the official prebuilt input as a separately verified option.
- Keep the native engine build in its own manual workflow and preserve product preview packaging.
- Bind package provenance to signed application metadata and executable hashes.
- Show version, build and release channel in About, with a manual Check for Updates action that links to a newer GitHub release.
- Keep preview and stable update channels distinct; report unavailable checks without changing the installed app.

## 0.1.3 preview - 30.10.26

- Confirm brightness requests by hardware read-back, retry transient writes within a fixed bound, and follow newer source targets without waiting for an obsolete request.
- Separate source-write and follower failures in acceptance; verify both brightness restorations before resuming synchronization.
- Add app-owned launch-at-login controls and explicit approval state under App settings.
- Stop queued app/display callbacks on shutdown and clean up partial startup failures; repeated starts keep a single menu and watcher set.
- Bound Notification Center preservation even when snapshots fail; abort safely when an event tap cannot start.
- Run portable brightness, restoration, widget failure and lifecycle regression suites in source checks.

Verified launch at login after a real reboot on macOS 27.0.1, with one Wallpaper Veil runtime and no separate Hammerspoon process. Focused brightness checks passed on two Studio Displays. Accessibility-granted UI automation and sleep/Spaces/display connection qualification remain tracked separately.

## 0.1.2 preview - 30.10.26

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
