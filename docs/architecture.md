# Wallpaper Veil architecture and ownership

## The installed product

A user copies one `Wallpaper Veil.app` to Applications. The outer Objective-C launcher discovers its own bundle and the nested runtime by relative path. It supplies the bundled application-code path and a writable Application Support path, then exits. The nested app owns the menu bar, app Lua and native libraries. Source, Git, Python, Xcode and a separately installed Hammerspoon are not runtime requirements.

```text
Wallpaper Veil.app/
  Contents/MacOS/WallpaperVeil                  outer launcher
  Contents/Helpers/Wallpaper Veil Runtime.app/
    Contents/MacOS/WallpaperVeilRuntime         bundled native engine
    Contents/Frameworks/                        LuaSkin and native modules
    Contents/Resources/WallpaperVeil/           product Lua and identity
    Contents/Resources/Acknowledgements/        retained project/component terms
```

The existing two-process startup arrangement is retained. A single `.app` can contain helper executables and libraries; it does not imply a single executable or a native-engine rewrite.

## The maintained source

| Area | Owner and role |
|---|---|
| `WallpaperVeil/core/` | Product Lua: wallpaper canvas, brightness-following logic, settings, lifecycle and optional desktop automation. Relocated from `WallpaperVeil/app/`; includes the released `0.1.6` widget defaults/cancellation behavior. |
| `WallpaperVeil/native/` | App-owned launcher, Cocoa About/settings/update UI, update-feed parser and the narrow CFPreferences widget bridge. Relocated from the product directory's root. |
| `WallpaperVeil/assets/` | Product icon and its source/render helpers. |
| `WallpaperVeil/build_local.py` | Builds the app-owned native code, copies the verified engine/core, patches its bootstrap, retains notices, signs and audits the completed app. |
| `WallpaperVeil/upstream.py` | One implementation for qualified pin validation and recovery of immutable upstream build inputs. |
| `WallpaperVeil/standalone_contract.py` | Relocatability/native-dependency and one-app archive contract, used by the builder and packager. |
| `WallpaperVeil/ci/` | Verified runtime fetch, historical source-engine compilation and product packaging. |
| `engine/upstream.json` | Qualified source identity, input Git objects, baseline counts, allowed engine policy and feature integration map. |
| `WallpaperVeil/tests/` | Product regressions, including provenance rejection and standalone-package contracts. |

`Hammerspoon`, its Xcode projects/tests, `LuaSkin`, `Pods`, `extensions` and upstream tooling are absent from current main. Their exact original commit remains in repository history. Build checkouts fetch and verify the original upstream `1.1.1` tag; a source-engine build checks out that audited history into temporary staging. The product builder recovers only three C headers and the complete legal input set from verified Git objects; it does not require a second editable native tree in the maintained checkout.

This removes 2,603 tracked legacy files, about 52.16 MB, from the active source checkout. Git history is intentionally preserved, so a full historical clone can still contain the old objects. It does not reduce the qualified native runtime's 95-component inventory or claim that all upstream code is now app-owned.

## State and lifecycle

Executable resources remain in the finished bundle. Writable diagnostics and app data belong in `~/Library/Application Support/Wallpaper Veil`; `hs.settings` uses the app's independent preferences domain, `com.ry00ki.wallpaperveil`. A first-run import of legacy `wallpaperVeil.*` values is data migration, not a dependency on a Hammerspoon installation or user Lua configuration.

The existing login route targets the outer launcher. Existing cancellation, timer ownership, source/follower read-back and restoration behavior remain in the core. Optional Accessibility-dependent widget/clock behavior still needs its platform permission and the existing real-device qualification; a packaging audit establishes neither permission nor hardware behavior.

## Native widget preference boundary

`core/desktop_widgets.lua` receives a narrow adapter from `core/init.lua`. Its read/write/reset operations cross `native/native_ui.m` into `native/widget_preferences.h`, which uses Apple CFPreferences directly. Production wrappers select only `com.apple.WindowManager` / `StandardHideWidgets`; there are no domain/key arguments and no command-line `defaults` or `hs.task` calls in product code. Native writes synchronize and verify their result before returning. The old task binding remains in the unchanged bundled engine.

**Use macOS defaults** cancels owned pollers, clock permission/deferred timers, event taps and panel repair before resetting anything. It clears the three choices, verifies an app-owned `resetPending` stop guard, removes the one OS override and verifies absence. It never resets a whole OS domain, kills WindowManager or restores a previous user snapshot. New-user/default-mode startup creates no clock/Notification Center automation and performs no widget preference operations; selecting a custom option or Show now/Hide now opts in.

`wallpaperVeil.widgets.controlState`, `resetPending` and the three flags are app settings, not OS preference backups. The pending guard blocks stale managed records on restart after a partial failure; a reset error leaves automation stopped and the defaults item unchecked with a retry. Complete app-settings failure is explicitly session-only, since no durable stop choice can then be established. Settings read-back checks API acceptance, not hard-disk flush guarantees.

Clock/Notification Center geometry checks, AX inspection/AXPress, event taps, permission tracking and timer scheduling still rely on retained upstream modules. Brightness remains product-owned following/read-back logic over upstream `hs.screen` hardware APIs. The native widget bridge is original app code and does not change the pinned 95-component engine or 81-component legal inventory. Its function-level origin map and upstream comparison process are in the maintenance document.

The native `widgetPreferenceRestoreForTest` entry accepts only the same fixed key and rejects normal launches; bounded `--self-test` uses it for transient typed cleanup. This acceptance recovery is separate from production defaults behavior and is not a stored snapshot feature.

See [upstream maintenance](upstream-maintenance.md) for origin/adaptation details and [development](development.md) for build-only tools.
