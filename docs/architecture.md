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
| `WallpaperVeil/core/` | Product Lua: wallpaper canvas, brightness-following logic, settings, lifecycle and optional desktop automation. Moved from `WallpaperVeil/app/` with the module contents preserved. |
| `WallpaperVeil/native/` | App-owned launcher, Cocoa About/settings/update UI and update-feed parser. Moved from the product directory's root. |
| `WallpaperVeil/assets/` | Product icon and its source/render helpers. |
| `WallpaperVeil/build_local.py` | Builds the app-owned native code, copies the verified engine/core, patches its bootstrap, retains notices, signs and audits the completed app. |
| `WallpaperVeil/upstream.py` | One implementation for qualified pin validation and recovery of immutable upstream build inputs. |
| `WallpaperVeil/standalone_contract.py` | Relocatability/native-dependency and one-app archive contract, used by the builder and packager. |
| `WallpaperVeil/ci/` | Verified runtime fetch, historical source-engine compilation and product packaging. |
| `engine/upstream.json` | Qualified source identity, input Git objects, baseline counts, allowed engine policy and feature integration map. |
| `WallpaperVeil/tests/` | Product regressions, including provenance rejection and standalone-package contracts. |

`Hammerspoon`, its Xcode projects/tests, `LuaSkin`, `Pods`, `extensions` and upstream tooling are absent from current main. Their exact original source remains in the retained `1.1.1` tag/history. A source-engine build checks out that audited history into temporary build staging. The product builder recovers only three C headers and the complete legal input set from verified Git objects; it does not require a second editable native tree in the maintained checkout.

This removes 2,603 tracked legacy files, about 52.16 MB, from the active source checkout. Git history is intentionally preserved, so a full historical clone can still contain the old objects. It does not reduce the qualified native runtime's 95-component inventory or claim that all upstream code is now app-owned.

## State and lifecycle

Executable resources remain in the finished bundle. Writable settings/diagnostics belong in `~/Library/Application Support/Wallpaper Veil`, with the app's own preferences domain. A first-run import of legacy `wallpaperVeil.*` values is data migration, not a dependency on a Hammerspoon installation or user Lua configuration.

The existing login route targets the outer launcher. Existing cancellation, timer ownership, source/follower read-back and restoration behavior remain in the core. Optional Accessibility-dependent widget/clock behavior still needs its platform permission and the existing real-device qualification; a packaging audit establishes neither permission nor hardware behavior.

See [upstream maintenance](upstream-maintenance.md) for origin/adaptation details and [development](development.md) for build-only tools.
