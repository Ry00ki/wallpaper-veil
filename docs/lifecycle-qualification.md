# Real-hardware lifecycle qualification

[Issue #4](https://github.com/Ry00ki/wallpaper-veil/issues/4) owns physical acceptance. [Issue #19](https://github.com/Ry00ki/wallpaper-veil/issues/19) owns this helper. Merging the helper does not close #4. No physical test results are supplied by this document or by the helper's fixture tests.

`WallpaperVeil/qualify_lifecycle.py` is an optional Python 3.10+ command for a Mac operator. Run it from a checkout against the existing installed app. It does not rebuild, install, launch, quit, inject code into or update that app. It does not change brightness, sleep settings, display layouts, permissions, login registration, app preferences or the release channel. It writes only a new evidence directory and later records/reports in that directory. It has no background service and uses no third-party Python packages.

## What it records (and what it cannot establish)

| Evidence | Scope and limitation |
| --- | --- |
| Host | macOS version/build, architecture, model identifier; no host name or hardware serial. |
| App | Selected bundle identity/version/build, recorded source commit, SHA-256 of build manifest, launcher and runtime. This is not a complete bundle/signature verification. |
| Processes | PID/role only for executables at the selected app's exact canonical paths; a count of other Wallpaper Veil/Hammerspoon candidates, without their paths or arguments. A successful zero-runtime sample is process-absence evidence only. |
| Displays | Allowlisted resolution/connection fields, count and session-specific identity tokens from `system_profiler`. Tokens can change on reconnect and do not map automatically to the app's source/follower UUIDs. |
| Persisted settings | HMAC fingerprints of typed `wallpaperVeil.*` keys/values from the fixed app domain via `defaults export`. Raw values and key names are not saved. Reports compare counts of added/removed/changed keys against the baseline; login items and OS preferences are outside that comparison. |
| Startup receipt | File age, reported startup result and whether its PID matches the sampled runtime. Even a matching PID does **not** make `diagnostics.json` a live post-event observation. Raw receipt contents are not saved. |
| Observations | Explicit operator result (`pass`, `fail`, `blocked`), action/outcome notes and referenced checkpoint IDs. All attempts are retained; later results do not erase failures. |

The commands run sequentially with a 20-second timeout **per command**. Start/end UTC timestamps delimit each checkpoint; it is not instantaneous. Unsupported/missing data or a failed/timeout command is `unavailable`, not an empty display inventory, an absent process or unchanged settings. A failing component does not discard the other evidence. Missing preferences are `unknown`, not an assumed empty domain.

There is no continuous sleep/Spaces event observer and no live app-status channel. The helper cannot measure brightness read-back, catch a transient pending confirmation, see pixels or clicks, inspect watchers/timers, or prove that sleep really occurred. A gap between timestamps is not sleep evidence. Use explicit observations and, where useful, separately reviewed screenshots/video or narrowly scoped macOS event evidence. Do not attach complete system logs or the app's raw diagnostics.

## Prepare on the actual Mac

1. Save ongoing work. Use the intended Mac and both physical displays, with their normal cables/docks. Keep the stable installed app; do not invoke an update or a hardware-changing self-test during this session.
2. Launch that app normally yourself. Confirm one menu item/runtime, both displays, the chosen source/follower roles and a working baseline. Inspect `other_candidate_count` for competing copies/controllers. A zero count does not identify every possible third-party brightness tool; record any known competitors.
3. Record the Mac/display models (no serials), source/follower physical positions, cables/ports/docks, current macOS Spaces configuration (including separate Spaces), tint state, brightness-sync state, chosen pair, normal brightness levels and optional widget/clock settings. Record current permissions/login state if relevant; do not change them for the helper. Do not assume the setup from an earlier issue comment is still current.
4. Use a new session per app build/setup/baseline. Check `app_matches_baseline`; if the installed app changes during the run, stop and begin a new session. The script refuses an existing session at `start` and refuses evidence inside the app or its state directory.

From the repository root (replace the app path if installed in `/Applications`):

```sh
python3 WallpaperVeil/qualify_lifecycle.py start \
  --app "$HOME/Applications/Wallpaper Veil.app" \
  --session lifecycle-evidence/run-01 \
  --setup "Mac/display models; left/right source/follower; ports/dock; Spaces; baseline settings and brightness"
```

The helper prints checkpoint IDs. Inspect the private event JSON for diagnostic availability and baseline process/display counts before continuing. Start captures what is there; it does not repair a missing runtime or enable synchronisation. Resolve an invalid baseline manually, or record a blocked result. `lifecycle-evidence/` is ignored by Git. Directories are created with mode 0700 and data files with mode 0600; keep them on a local filesystem supporting file locks/hard links.

## Repeat each case

For each attempt, capture `before`, perform the action yourself, capture `during` when appropriate, then `after` and a later `recheck`. Run consecutive commands yourself; the helper does not wait, sleep, unplug, relaunch or press any controls for you.

```sh
python3 WallpaperVeil/qualify_lifecycle.py checkpoint \
  --session lifecycle-evidence/run-01 --case sleep-wake --phase before

# Perform the physical sleep/wake action, then:
python3 WallpaperVeil/qualify_lifecycle.py checkpoint \
  --session lifecycle-evidence/run-01 --case sleep-wake --phase after

# Substitute the IDs printed above. Choose the result you actually observed.
python3 WallpaperVeil/qualify_lifecycle.py observe \
  --session lifecycle-evidence/run-01 --case sleep-wake --result pass \
  --checkpoints BEFORE_ID AFTER_ID \
  --note "Actual action/time/duration; source/follower response; sync state; tint; delays; restoration; limitations"
```

An operator-reported pass requires that case's own before/after checkpoints. This is a recording guard, not validation that the action happened or the diagnostics succeeded. For unavailable diagnostics, distinguish what was directly observed from what could not be checked; use `blocked` where the acceptance criterion cannot be judged. `fail` and `blocked` may reference the baseline alone. Repeat attempts are separate observations; do not turn an intermittent failure into an unconditional pass.

## Physical case matrix — all still require execution

Use a visible tint and supported brightness pair. For brightness recovery, manually make a small source adjustment and observe the follower responding, then restore the original source level and check both displays. Equal values at rest alone do not prove response. With sync disabled, confirm a small source change does not move the follower; restore both levels manually. Record approximate or measured levels honestly; the helper provides no numerical brightness read-back. If a display cannot reconnect, stop that test and restore the normal physical connection before proceeding.

| Case ID | Operator action and checkpoints | Required observations |
| --- | --- | --- |
| `sleep-wake` | `before`; Apple menu → Sleep, wait at least 30 seconds, wake/unlock normally; `after`, then `recheck` after 10–30 seconds. Repeat at least three cycles. Also test display-only sleep separately using the setup's normal idle/sleep mechanism; record how system sleep was distinguished. Use separate baselines for sync enabled and disabled. | No unexpected sync disable after wake; saved pair/choice retained; small manual source change follows when enabled and remains independent when disabled; tint/menu recover on both displays without duplicates. Record real wake delays/alerts. A pending-write-at-sleep race remains unqualified unless it was actually observed; do not claim it from the timing fixture. Overlapping system/display notification ordering is not measured by this helper. |
| `spaces` | `before`; switch at least two desktop Spaces on each display, use Mission Control and enter/leave a full-screen app; `during`/`after`. Use existing Spaces settings; do not reconfigure them solely for the helper. | Tint stays behind desktop icons and application windows; select/open/drag an icon and click empty desktop on both displays; no click interception, stuck tint, duplicates or inappropriate full-screen overlay. Record which Spaces/full-screen configurations were exercised. |
| `source-reconnect` | `before`; physically unplug only the selected source connection, retain the follower, capture `during`; reconnect the same source/port; `after`/`recheck`. If it is also the main display, expect macOS to rearrange windows temporarily. Repeat, and separately test wake while the source remains disconnected before reconnecting. | Sync waits without losing the saved enable choice or swapping the pair; reconnect resumes following without a stale-request failure; tint is correct on remaining/reconnected displays. Verify a manual source change and restoration. |
| `follower-reconnect` | Same sequence for only the follower, with source connected. Separately wake while follower is disconnected, then reconnect. | Same recovery conditions; the original follower resumes following. Record actual disconnected/connected inventory counts, pair/menu state and source-change response. |
| `persistence` | Fresh baseline for each intended configuration; `before`; complete the events, quit normally and relaunch the same installed app yourself; `after`/`recheck`. | Tint enable/colour/strength, saved palette, sync enable/pair and configured widget options remain as intended in UI and behavior. Compare settings fingerprints, investigate unexpected changes and explain intentional ones. Manually inspect login/permission state if claimed; hashes do not cover those systems. |
| `quit` | `before`; Quit Wallpaper Veil from its menu; `after`, then `recheck` after at least 10 seconds. Switch Spaces or reconnect a display while the app remains quit, then take another `recheck`. Only then relaunch manually and record a new checkpoint. | Menu and all overlays disappear across tested Spaces/displays; selected runtime stays absent in successful process samples; no app overlay returns or brightness following occurs while quit. Inspect other process candidates. Process exit plus visual observations supports external quit behavior; internal callback/timer cancellation is still source-test evidence, not directly inspected by this helper. |

Do not force kernel/display failures to prove bounded post-wake failure handling. Record natural failures if encountered; simulated bounded-failure checks remain a separate evidence class. Installed-app source/build independence has earlier evidence with its own limited scope in #4. This helper does not move source paths, test fresh accounts, reboot or alter login items to expand that evidence.

## Evidence and review

```sh
python3 WallpaperVeil/qualify_lifecycle.py report --session lifecycle-evidence/run-01
# Only after reviewing the operator text for private details:
python3 WallpaperVeil/qualify_lifecycle.py report --session lifecycle-evidence/run-01 --include-notes
```

`report` and `observe` can also run offline on another platform with the session directory. Live `start`/`checkpoint` refuse non-macOS hosts. `report.json` contains schema version 1, helper hash, host metadata, timestamped checkpoint IDs, app fingerprints, scoped samples, preference comparisons, all operator observations, unrecorded cases and limitations. `report.md` is a short index of all reported results. Neither produces an overall physical PASS.

| File | Purpose | Publication |
| --- | --- | --- |
| `session.json` | Private app path, operator setup, session HMAC key, host/helper identity | Do not publish. |
| `events/<id>.json` | Immutable checkpoint or observation. Checkpoint has case/phase/sample; observation has case/result/checkpoint IDs/note. Writes become visible only when complete. | Keep private; raw text may identify the setup/person. |
| `report.json` | Derived structured evidence; no local paths, HMAC key, raw preferences/IDs, or operator text by default | Review before sharing. `--include-notes` explicitly includes private setup/notes. |
| `report.md` | Derived case/result index and limitations | Share with the reviewed detailed evidence, not alone as proof. |

Copy a reviewed report and minimal supporting visual/event evidence into #4. Explicitly state the app build, macOS version/build, Mac/display models, role/connection setup, scenarios/repetition counts, failures, restored state and anything untested. Leave #4 open until the physical acceptance evidence is reviewed. Do not infer coverage for another macOS release, display type, fresh account, notification order or pending-write race.

Stop/cancel by ending the current command; the helper leaves completed records in place and has no persistent process to remove. It cannot roll back physical actions or deliberate UI changes. Restore original cables, brightness and any settings changed by the operator; record unsuccessful restoration as a failure. Removing only the evidence directory later removes the helper's records, not the application or its preferences.

## Source verification

Run the normal Python and Lua suites from [development](development.md#repository-checks-and-preview-builds). `test_qualify_lifecycle.py` covers read-only command selection, redaction, stale receipt scope, process matching, typed preference comparisons, unavailable diagnostics, immutable records and CLI/report behavior with fixtures. Those tests do not execute macOS commands, connect displays, sleep a Mac or qualify the helper on the target hardware.
