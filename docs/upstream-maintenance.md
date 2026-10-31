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
| Widget visibility/defaults | `core/desktop_widgets.lua`, `native/native_ui.m`, `native/widget_preferences.h` | Previous product adapter used `extensions/task/libtask.m` through `hs.task`; new bridge uses the bundled Lua C API and Apple CFPreferences | Product subprocess adapter replaced with app-owned native preference code. The engine's task component remains bundled; no engine module was removed or patched. See the function map below. |
| Clock and Notification Center | `core/desktop_widget_clock.lua`, `desktop_widget_panel.lua`, `desktop_widgets.lua` | `extensions/axuielement`, `eventtap`, `window`, `application`, `screen`, `timer`, `settings` | Product-owned clock identification, geometry checks, bounded AXPress and cancellation over retained bindings. Preserve permissions and actual-state checks; mocks do not qualify OS interaction. |
| Native app shell and updater | `native/launcher.m`, `native/native_ui.m`, `native/update_check.h` | Bundled Lua C API headers in `LuaSkin/lua-5.4.7/src` | Original Wallpaper Veil Objective-C/Apple-framework code, not renamed Hammerspoon source. Lua C linkage remains internal to the bundle. |
| Bundle-only Lua bootstrap | `build_local.py: bundled_setup()` | `Hammerspoon/setup.lua` and `extensions/_coresetup` | A deliberate build-time adaptation: assert app identity and bundle resource path, load product `init.lua`, and use Application Support only for state. Original tail/preloads are retained. The expected marker and setup-call shape are checked; unfamiliar upstream bootstrap text is rejected. |
| Legal/header inputs | `upstream.py`, `build_local.py` | Three Lua headers, 81 component documents, two Pods acknowledgement files and upstream MIT licence | 87 exact Git objects materialized only in temporary build staging; original paths/modes/hashes are checked and notices are bundled. |

Bindings have transitive dependencies beyond direct calls, including image, styled text, geometry, fnutils, logger, host, sharing and osascript support. The qualified engine still contains its broad native inventory. Namespace changes or deleting current source folders do not prove those runtime dependencies disappear.

## Widget preference translation: product adapter to owned native code

The former implementation is preserved at product commit [`aa4d8c7`](https://github.com/Ry00ki/wallpaper-veil/blob/aa4d8c7b65856d533b9b5fafdeb5d1ad78504b4a/WallpaperVeil/app/desktop_widgets.lua). This is Wallpaper Veil's earlier adapter code, separate from the pinned Hammerspoon `1.1.1` engine source. The replacement was introduced in product `0.1.6`; the maintenance layout places its files under `core/` and `native/`.

| Earlier product function or behavior | Current owned function boundary | What changed and what remains |
|---|---|---|
| `startTask()`, `stopTask()`, `drain()` spawned `/usr/bin/defaults` using `hs.task` and handled asynchronous completion | `desktop_widgets.lua: preferenceCall()` and `request()` → `native_ui.m: WVReadWidgetPreference()` / `WVWriteWidgetPreference()` → `widget_preferences.h: WVReadWidgetPreferenceInDomain()` / `WVWriteWidgetPreferenceInDomain()` | New native code calls CFPreferences synchronously and reads back each result. It accepts absence or integer/boolean visibility values; there is no pending subprocess write that can outlive a reset. This replaces the product adapter, not the internals of upstream `libtask.m`. |
| No master defaults choice | `useMacOSDefaults()`, `quiesce()`, `saveState()`, `clearResetGuard()` → `WVResetWidgetDefaults()` → `WVResetWidgetPreferenceInDomain()` | Stop owned automation first, clear three choices, save/read-verify the app's stop intent, delete the one OS override, synchronize and verify absence. Repeated explicit resets are safe. Startup does not perform an OS reset. |
| Automatic visibility and bounded Notification Center preservation | `request()`, `beginRepair()`, `poll()`, `stop()`; `desktop_widget_panel.lua: snapshot()`, `findClock()`, `reopen()` | Product policy and cancellation remain owned Lua. Observation, AX lookup/AXPress and event taps still use retained upstream bindings; cancellation tokens prevent old work from acting after default mode or restart. |
| Clock click identification and permission retry | `desktop_widget_clock.lua: clockAt()`, `observe()`, `scheduleInspection()`, `updatePermission()`, `stop()` | Still uses upstream AX/eventtap/timer/screen/application bindings. It passes input through and does not change persistent clock settings. |

The production preference wrappers accept no domain/key arguments. Their only OS preference is **`com.apple.WindowManager` / `StandardHideWidgets`** at current-user/any-host scope. Showing/hiding writes `0`/`1`; the defaults action removes the override rather than guessing version-specific factory values. It does not reset the WindowManager domain, kill its process or restore a user's previous settings snapshot.

The five app-owned settings are `wallpaperVeil.widgets.controlState`, `resetPending`, `showOnOpen`, `hideOnClose` and `showOnClockClick`, all within Wallpaper Veil's preferences domain. The normally absent `resetPending` guard blocks stale managed state after an incomplete save/reset. A fresh user starts with no automation or OS preference operations. Explicit legacy choices migrate; a custom checkbox or Show now/Hide now opts back into managed behavior. Failed reset keeps automation off and defaults unchecked. If no app setting can be saved, the error explicitly limits protection to the current session; a cached settings read-back is not a hard-disk durability guarantee.

`WVRestoreWidgetPreferenceForTest()` / `WVRestoreWidgetPreferenceForTestInDomain()` exist solely for bounded acceptance cleanup of that same key, preserving absent/integer/boolean type. The Lua entry rejects calls outside `WV_SELF_TEST=1`. Acceptance keeps its original state transiently in memory and restores it after the test; the normal defaults feature never takes or restores an OS snapshot. Native unit tests inject a memory backend; Lua tests cover defaults, migration, failures, fresh-module restart guards and stale callbacks. The active acceptance additionally checks preference removal and cleanup, while physical clock/Notification Center interaction remains a separate device check.

The machine-readable map and its SHA anchor change to describe this boundary. The qualified engine tag/commit/tree, bootstrap, 87 header/legal objects, 95 native components, 81 component notices, architectures and empty patch list remain unchanged. No new native-engine baseline is implied.

## Reviewing a useful upstream update

1. Start from the qualified policy and choose the proposed upstream tag/commit. Fetch it under a distinct ref; never move the retained `1.1.1` tag or reuse an existing release identity.
2. Compare the original upstream paths in the integration map, bootstrap/core setup, LuaSkin ABI and transitive bindings. For retained observations inspect AX identifier/owner rules, per-element timeouts, event-tap pass-through and cancellation, window enumeration/geometry and screen APIs. For brightness compare `libscreen.m` against `display_brightness_sync.lua: read()`, `requestFollower()` and `tick()`; product read-back/following logic does not replace the upstream hardware API. Review build-project/Podfile changes and legal notices as well as feature code. Keep unrelated upstream work separate.
3. Record each relevant change as **retained unchanged**, **adapted at build time**, **implemented in owned core**, **not used**, or **pending qualification**. Link both original and current product path/function. A copied or translated implementation retains its applicable copyright/terms; new owned behavior is not automatically an upstream port.
4. For the removed widget task dependency, review any upstream `extensions/task` update for relevance without copying it automatically: no current product function calls that binding. Changes affecting widget preference semantics belong at the fixed CFPreferences boundary and require its own tests. Keep the retained task component/notices until a reduced engine is explicitly qualified. Decide whether to update the whole qualified baseline or implement a focused owned change. The current policy permits no native patches. A patch/reduced-runtime recipe needs an explicit policy/schema, source/object identities and separate native qualification; do not hide an override in a retired root.
5. Update the policy and its reviewed SHA-256 anchor in `WallpaperVeil/upstream.py` together. Review all header/legal/bootstrap objects, required architectures and native-component/notice inventories. Rebuild the engine when its baseline or recipe changes, then qualify the product using normal tests and protected PR/release gates. Reuse a verified engine artifact when its native baseline and recipe are unchanged. A descriptive integration-map edit requires the reviewed digest to match, but does not by itself requalify a different engine; verify that every non-integration policy field is unchanged.
6. Update this map, architecture/build documentation, README high-level behavior and relevant visuals when affected. Keep installed/released identities and new candidates distinct.

For inspection, Git can compare paths even though neither revision is the current working tree:

```sh
# Set this to a separately fetched, reviewed upstream ref.
wv_candidate="CANDIDATE_REF"
git diff --stat 1.1.1 "$wv_candidate" -- Hammerspoon/setup.lua LuaSkin extensions/screen extensions/canvas extensions/menubar
git diff 1.1.1 "$wv_candidate" -- extensions/screen/libscreen.m extensions/axuielement extensions/eventtap extensions/window extensions/timer
git log --oneline 1.1.1.."$wv_candidate" -- extensions/screen
```

The qualified policy deliberately fails closed on changed policy bytes, wrong tag/tree or input identities, incomplete notices, undeclared native trees/patches, and engine/archive/signature mismatches. That is the update boundary, not a reason to keep the duplicated upstream source in main.

## Further consolidation

A smaller native runtime or direct native replacement of a binding is a separate engineering change. Use the map above to select one worthwhile boundary, preserve its actual behavior/tests, record the original-to-owned translation, and qualify a new engine/product artifact. The present cleanup keeps the proven engine behavior and removes source-maintenance duplication; it does not advertise an unqualified rewrite.
