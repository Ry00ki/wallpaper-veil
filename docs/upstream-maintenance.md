# Upstream integration and maintenance

## Retained source identity

The qualified engine is Hammerspoon **1.1.1 / build 6936**, commit `1469832361b4c3687ec7d589c1b4efe4d3b742ee`. Its source and history are retained at tag `1.1.1`; `engine/upstream.json` records its exact tree, original bootstrap and the Git identities of build/legal inputs. No native engine patches are qualified by this policy.

The source-engine builder compiles that historical checkout, not the current product tree. The active checkout no longer duplicates the upstream implementation. [Retired-tree inventory](upstream-retired-tree.json) records each removed root's former Git object, file count and bytes, including old tests, tooling and the unused crash-upload CLI. The objects remain available from their recorded historical commits. Original upstream [README](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/README.md), [contribution guidance](https://github.com/Hammerspoon/hammerspoon/blob/1.1.1/CONTRIBUTING.md) and all applicable terms remain authoritative for that source.

## What was integrated, adapted or retained

The machine-readable feature map is `engine/upstream.json` → `integration`. The following table adds the relevant function-level boundaries; it is not a claim that every upstream native module has been ported or removed.

| Product capability | Product implementation | Original upstream paths/API | Integration status and update focus |
|---|---|---|---|
| Wallpaper tint | `WallpaperVeil/core/wallpaper_veil.lua` | `extensions/canvas`, `screen`, `dialog`, `drawing/color`; `hs.canvas`, `hs.screen` | Product-owned colour/opacity/menu logic calls retained bindings. Check drawing levels, screen/Spaces behavior and colour APIs when updating. |
| Brightness sync | `core/display_brightness_sync.lua` | `extensions/screen/libscreen.m`, `timer`, `settings`; `getBrightness` / `setBrightness` | Product-owned following/read-back/restoration logic; native brightness implementation remains upstream. Native API availability, not display manufacturer, determines support. |
| Menu and settings | `core/wallpaper_veil.lua`, `core/app_settings.lua` | `extensions/menubar`, `settings`, `application` | Product-owned menu choices and preference names over retained engine APIs. Preserve the app's independent identity/domain. |
| Lifecycle | `core/init.lua` and owned modules | `extensions/timer`, `extensions/screen/libscreen_watcher.m`, `caffeinate`, engine process APIs | Product owns startup/cancellation/generation cleanup; scheduling/watchers are retained. Review hotplug/sleep/Spaces behavior independently. |
| Widgets and clock | `core/desktop_widgets.lua`, `desktop_widget_clock.lua`, `desktop_widget_panel.lua` | `extensions/axuielement`, `eventtap`, `window`, `task`, `application` | Product-owned automation over retained bindings. Preserve permissions, actual-state checks and cleanup; mocks do not qualify OS interaction. |
| Native app shell and updater | `native/launcher.m`, `native/native_ui.m`, `native/update_check.h` | Bundled Lua C API headers in `LuaSkin/lua-5.4.7/src` | Original Wallpaper Veil Objective-C/Apple-framework code, not renamed Hammerspoon source. Lua C linkage remains internal to the bundle. |
| Bundle-only Lua bootstrap | `build_local.py: bundled_setup()` | `Hammerspoon/setup.lua` and `extensions/_coresetup` | A deliberate build-time adaptation: assert app identity and bundle resource path, load product `init.lua`, and use Application Support only for state. Original tail/preloads are retained. The expected marker and setup-call shape are checked; unfamiliar upstream bootstrap text is rejected. |
| Legal/header inputs | `upstream.py`, `build_local.py` | Three Lua headers, 81 component documents, two Pods acknowledgement files and upstream MIT licence | 87 exact Git objects materialized only in temporary build staging; original paths/modes/hashes are checked and notices are bundled. |

Bindings have transitive dependencies beyond direct calls, including image, styled text, geometry, fnutils, logger, host, sharing and osascript support. The qualified engine still contains its broad native inventory. Namespace changes or deleting current source folders do not prove those runtime dependencies disappear.

## Reviewing a useful upstream update

1. Start from the qualified policy and choose the proposed upstream tag/commit. Fetch it under a distinct ref; never move the retained `1.1.1` tag or reuse an existing release identity.
2. Compare the original upstream paths in the integration map, bootstrap/core setup, LuaSkin ABI and transitive bindings. Review build-project/Podfile changes and legal notices as well as feature code. Keep unrelated upstream work separate.
3. Record each relevant change as **retained unchanged**, **adapted at build time**, **implemented in owned core**, **not used**, or **pending qualification**. Link both original and current product path/function. A copied or translated implementation retains its applicable copyright/terms; new owned behavior is not automatically an upstream port.
4. Decide whether to update the whole qualified baseline or implement a focused owned change. The current policy permits no native patches. A patch/reduced-runtime recipe needs an explicit policy/schema, source/object identities and separate native qualification; do not hide an override in a retired root.
5. Update the policy and its reviewed SHA-256 anchor in `WallpaperVeil/upstream.py` together. Review all header/legal/bootstrap objects, required architectures and native-component/notice inventories. Rebuild the engine when its baseline or recipe changes, then qualify the product using normal tests and protected PR/release gates. Reuse a verified engine artifact when its native baseline and recipe are unchanged.
6. Update this map, architecture/build documentation, README high-level behavior and relevant visuals when affected. Keep installed/released identities and new candidates distinct.

For inspection, Git can compare paths even though neither revision is the current working tree:

```sh
# Set this to a separately fetched, reviewed upstream ref.
wv_candidate="CANDIDATE_REF"
git diff --stat 1.1.1 "$wv_candidate" -- Hammerspoon/setup.lua LuaSkin extensions/screen extensions/canvas extensions/menubar
git diff 1.1.1 "$wv_candidate" -- extensions/screen/libscreen.m
git log --oneline 1.1.1.."$wv_candidate" -- extensions/screen
```

The qualified policy deliberately fails closed on changed policy bytes, wrong tag/tree or input identities, incomplete notices, undeclared native trees/patches, and engine/archive/signature mismatches. That is the update boundary, not a reason to keep the duplicated upstream source in main.

## Further consolidation

A smaller native runtime or direct native replacement of a binding is a separate engineering change. Use the map above to select one worthwhile boundary, preserve its actual behavior/tests, record the original-to-owned translation, and qualify a new engine/product artifact. The present cleanup keeps the proven engine behavior and removes source-maintenance duplication; it does not advertise an unqualified rewrite.
