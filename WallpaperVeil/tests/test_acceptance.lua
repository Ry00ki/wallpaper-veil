local here = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local create = dofile(here .. "brightness_mock.lua")
local app = os.getenv("WV_TEST_APP_DIR") or "WallpaperVeil/app"
local cases = 0
local function test(name, callback)
    callback(); cases = cases + 1; print("PASS acceptance: " .. name)
end
local function run(options)
    local e = create(options).load(app)
    local result
    e.acceptance.run(function(value) result = value end)
    e.advance(24, function() return result ~= nil end)
    assert(result, "Acceptance failed to produce a bounded report")
    assert(e.activeAcceptanceTimers() == 0, "Acceptance timer leaked")
    return e, result
end

test("source retry must confirm a real change before enabling follower sync", function()
    local e, report = run{source = {ignore = function(_, n) return n == 1 end}}
    assert(report.ok)
    assert(#report.brightness.source.attempts == 2 and report.brightness.source.confirmed)
    local firstEnable
    for _, call in ipairs(e.syncCalls) do if call.enabled then firstEnable = call.time; break end end
    assert(firstEnable and firstEnable >= 0.5)
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("unchanged source is explicitly not a successful follower test", function()
    local e, report = run{source = {ignore = function() return true end}}
    assert(not report.ok and #report.brightness.source.attempts == 3)
    assert(not e.check(report, "source hardware brightness accepts changed target").passed)
    local follower = e.check(report, "hardware follower tracks changed source")
    assert(not follower.passed and follower.detail.skipped and follower.detail.cause == "source-write-unconfirmed")
    for _, call in ipairs(e.syncCalls) do assert(not call.enabled, "Sync enabled before a confirmed source change") end
    assert(e.check(report, "source brightness restored").passed)
end)

test("source success and follower no-op have distinct failure evidence", function()
    local e, report = run{follower = {ignore = function() return true end}}
    assert(not report.ok and e.check(report, "source hardware brightness accepts changed target").passed)
    local follower = e.check(report, "hardware follower tracks changed source")
    assert(not follower.passed and follower.detail.cause == "follower-write-unconfirmed")
    assert(e.check(report, "sync off permits independent brightness").passed)
    assert(e.check(report, "source brightness restored").passed and e.check(report, "follower brightness restored").passed)
end)

test("delayed native writes restore both values before resuming original sync", function()
    local e, report = run{syncEnabled = true, source = {delay = 0.35}, follower = {delay = 0.35, quantum = 1 / 64}}
    assert(report.ok and e.sync.enabled)
    assert(report.brightness.restoreSource.confirmed and report.brightness.restoreFollower.confirmed)
    local resumed = e.syncCalls[#e.syncCalls]
    assert(resumed.enabled and resumed.time >= report.brightness.restoreSource.confirmedAt
        and resumed.time >= report.brightness.restoreFollower.confirmedAt)
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("shutdown cancellation overrides in-flight test requests and reports its limit", function()
    local e = create{source = {delay = 0.5}, follower = {delay = 0.5}}.load(app)
    local report, calls
    calls = 0
    e.acceptance.run(function(value) report = value; calls = calls + 1 end)
    e.advance(0.2); assert(e.acceptance.cancel); e.acceptance.cancel()
    assert(report and not report.ok and report.recoveryRequired)
    assert(e.activeAcceptanceTimers() == 0 and not e.sync.enabled)
    e.advance(10)
    assert(calls == 1 and e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("restoration failure still attempts the other display and leaves sync disabled", function()
    local e, report = run{syncEnabled = true, source = {ignore = function(value, n) return value == 0.5 and n > 1 end}}
    assert(not report.ok and report.recoveryRequired and not e.sync.enabled)
    assert(not e.check(report, "source brightness restored").passed)
    assert(e.check(report, "follower brightness restored").passed)
    assert(not e.check(report, "sync setting restored").passed)
end)

test("cancelling during restoration cannot leave stale callbacks or duplicate results", function()
    local e = create{source = {delay = 0.35}, follower = {delay = 0.35}}.load(app)
    local report, calls = nil, 0
    e.acceptance.run(function(value) report = value; calls = calls + 1 end)
    e.advance(10, function()
        for _, write in ipairs(e.source.writes) do if write.value == 0.5 then return true end end
    end)
    assert(e.acceptance.active and e.acceptance.cancel)
    e.acceptance.cancel()
    assert(report and not report.ok and e.activeAcceptanceTimers() == 0)
    local names = {}
    for _, entry in ipairs(report.checks) do assert(not names[entry.name]); names[entry.name] = true end
    e.advance(20)
    assert(calls == 1 and e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("source drift during follower restoration fails the final pair gate", function()
    local e
    e = create{syncEnabled = true, follower = {ignore = function(value, count)
        if value == 0.5 and count == 3 then
            -- Source restoration has already confirmed. Drift before the next
            -- follower read would be missed by earlier per-display booleans.
            e.schedule(0.05, function() e.source.value = 0.625 end)
        end
        return false
    end}}.load(app)
    local report
    e.acceptance.run(function(value) report = value end)
    e.advance(24, function() return report ~= nil end)
    assert(report and not report.ok and report.recoveryRequired)
    assert(not e.sync.enabled, "Sync resumed despite a stale source restoration result")
    local sourceResult = e.check(report, "source brightness restored")
    assert(not sourceResult.passed and sourceResult.detail.finalObserved == 0.625)
    assert(sourceResult.detail.confirmed and not sourceResult.detail.finalConfirmed)
    assert(e.check(report, "follower brightness restored").passed)
    assert(not e.check(report, "sync setting restored").passed)
    assert(e.activeAcceptanceTimers() == 0)
end)

test("unaligned initial pair is rejected before a large hardware adjustment", function()
    local e, report = run{sourceValue = 0.8, followerValue = 0.2}
    assert(not report.ok and #e.source.writes == 0 and #e.follower.writes == 0)
end)

test("invalid requested delta is rejected before changing settings or hardware", function()
    local e = create{}.load(app)
    local ok = pcall(e.acceptance.run, function() end, {delta = 0.25})
    assert(not ok and #e.source.writes == 0 and #e.follower.writes == 0)
    assert(e.veil.enabled and e.veil.opacity == 0.6)
end)

test("report callback exceptions cannot bypass cleanup or leak timers", function()
    local e = create{}.load(app)
    local calls = 0
    e.acceptance.run(function() calls = calls + 1; error("Injected report failure") end)
    e.advance(24)
    assert(calls == 1 and not e.acceptance.active and e.activeAcceptanceTimers() == 0)
    assert(e.acceptance.lastReport.callbackError:find("Injected report failure", 1, true))
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

-- Widget transaction fixture: only one fake native key and five app-owned
-- settings. It tests acceptance recovery, not the controller/native feature.
local function widgetEnvironment(options)
    options = options or {}
    local e = create(options.brightness or {}).load(app)
    local prefix = "wallpaperVeil.widgets."
    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}; for key, item in pairs(value) do result[key] = copy(item) end
        return result
    end
    local function equal(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
        for key in pairs(b) do if a[key] == nil then return false end end
        return true
    end
    local state = {running=options.running ~= false, mode=options.mode or "managed",
        showOnOpen=options.mode ~= "macOS", hideOnClose=false, showOnClockClick=false}
    local canonical = {schema=1, mode=state.mode, showOnOpen=state.showOnOpen,
        hideOnClose=false, showOnClockClick=false, resetVerified=options.mode == "macOS",
        testMarker="transient-widget-original-not-for-report"}
    e.settings[prefix .. "controlState"] = copy(canonical)
    e.settings[prefix .. "resetPending"] = copy(options.resetPending)
    if not options.legacyAbsent then
        e.settings[prefix .. "showOnOpen"] = state.showOnOpen
        e.settings[prefix .. "hideOnClose"] = false
        e.settings[prefix .. "showOnClockClick"] = false
    end
    local originalSettings = {}
    for _, key in ipairs({"controlState", "showOnOpen", "hideOnClose", "showOnClockClick", "resetPending"}) do
        originalSettings[key] = copy(e.settings[prefix .. key])
    end
    e.preference = copy(options.preference or {ok=true, present=true, type="integer", value=0})
    e.preference.domain = e.preference.domain or "com.apple.WindowManager"
    e.preference.key = e.preference.key or "StandardHideWidgets"
    local originalPreference = copy(e.preference)
    e.nativeWrites, e.nativeRestores, e.nativeResets, e.widgetSettingWrites = 0, 0, 0, 0
    local set = hs.settings.set
    hs.settings.set = function(key, value)
        if key:sub(1, #prefix) == prefix then
            e.widgetSettingWrites = e.widgetSettingWrites + 1
            if options.settingsRestoreFailure and type(value) == "table" and value.testMarker
                and e.nativeResets > 0 then error("Injected widget setting restoration failure") end
        end
        return set(key, value)
    end
    local function save()
        e.settings[prefix .. "controlState"] = {schema=1,mode=state.mode,showOnOpen=state.showOnOpen,
            hideOnClose=state.hideOnClose,showOnClockClick=state.showOnClockClick,
            resetVerified=state.mode == "macOS"}
        for _, key in ipairs({"showOnOpen", "hideOnClose", "showOnClockClick"}) do
            e.settings[prefix .. key] = state[key]
        end
    end
    local widgets = {}
    function widgets.stop() state.running = false end
    function widgets.start()
        local saved = e.settings[prefix .. "controlState"]
        state.running, state.mode = true, saved.mode
        state.showOnOpen, state.hideOnClose, state.showOnClockClick = saved.showOnOpen, saved.hideOnClose, saved.showOnClockClick
        -- Model a synchronous initial managed write: exact original key recovery
        -- must happen AFTER restarting the controller.
        if state.mode == "managed" and state.showOnOpen then
            e.preference = {ok=true,present=true,type="integer",value=0}
        end
    end
    for name, setter in pairs({showOnOpen="setShowOnOpen",hideOnClose="setHideOnClose",
                               showOnClockClick="setShowOnClockClick"}) do
        widgets[setter] = function(value)
            state[name] = value; state.mode = "managed"; save()
            e.settings[prefix .. "resetPending"] = nil
            return true
        end
    end
    function widgets.status()
        return {running=state.running,mode=state.mode,showOnOpen=state.showOnOpen,
            hideOnClose=state.hideOnClose,showOnClockClick=state.showOnClockClick,
            tracking=state.running and state.mode == "managed",changingVisibility=false,preservingPanel=false,
            macOSDefaults=state.mode == "macOS",resetVerified=state.mode == "macOS"}
    end
    function widgets.useMacOSDefaults()
        e.settings[prefix .. "resetPending"] = true
        e.nativeResets = e.nativeResets + 1
        state.mode = options.resetFailure and "resetFailed" or "macOS"
        state.showOnOpen,state.hideOnClose,state.showOnClockClick = false,false,false
        save()
        if options.resetFailure then return false end
        e.preference = {ok=true,present=false}
        e.settings[prefix .. "resetPending"] = nil
        return true
    end
    e.veil.widgets = widgets
    local reads = 0
    e.adapter = {
        read=function()
            reads = reads + 1
            if options.captureFailure and reads == 1 then return {ok=false,error="Injected read failure"} end
            local result = copy(e.preference)
            result.domain = result.domain or "com.apple.WindowManager"
            result.key = result.key or "StandardHideWidgets"
            return result
        end,
        write=function(value)
            assert(value == 1, "Acceptance wrote an out-of-scope value")
            e.nativeWrites = e.nativeWrites + 1
            e.preference = {ok=true,present=true,type="integer",value=value}
            if options.cancelDuringSeed then e.acceptance.cancel() end
            return {ok=not options.seedFailure}
        end,
        restore=function(snapshot)
            e.nativeRestores = e.nativeRestores + 1
            assert(type(snapshot) == "table" and snapshot.ok == true)
            if options.restoreFailure or (options.restoreFirstFailure and e.nativeRestores == 1) then
                return {ok=false,error="Injected restore failure"}
            end
            e.preference = copy(snapshot)
            return {ok=true}
        end,
    }
    function e.widgetOriginalsRestored()
        for key, value in pairs(originalSettings) do if not equal(value, e.settings[prefix .. key]) then return false end end
        for _, key in ipairs({"controlState", "showOnOpen", "hideOnClose", "showOnClockClick", "resetPending"}) do
            if not equal(e.settings[prefix .. key], originalSettings[key]) then return false end
        end
        return equal(e.preference, originalPreference)
    end
    function e.startWidgetAcceptance(done)
        e.acceptance.run(done, {widgetPreferences=e.adapter})
    end
    function e.runWidgetAcceptance()
        local report
        e.startWidgetAcceptance(function(value) report = value end)
        e.advance(24, function() return report ~= nil end)
        assert(report and e.activeAcceptanceTimers() == 0)
        return report
    end
    e.widgetState = state
    return e
end

test("real-widget adapter acceptance retains all fifteen original checks and restores typed state", function()
    local e = widgetEnvironment{preference={ok=true,present=true,type="boolean",value=1},legacyAbsent=true}
    local report = e.runWidgetAcceptance()
    assert(report.ok and #report.checks == 20 and report.widgetDefaults.tested)
    assert(report.widgetDefaults.keyRemovalVerified and report.widgetDefaults.automationStopped)
    assert(report.widgetDefaults.restorationVerified and not report.widgetDefaults.physicalUIQualified)
    for _, name in ipairs({"tint disabled removes canvases", "tint enabled covers displays", "opacity updates all canvases",
        "colour setter", "standalone quit action present once", "About Wallpaper Veil is the final item",
        "standalone menu has no engine icon toggle", "source hardware brightness accepts changed target",
        "hardware follower tracks changed source", "sync off permits independent brightness",
        "source brightness restored", "follower brightness restored", "restoration calls completed",
        "tint settings restored", "sync setting restored"}) do assert(e.check(report,name).passed) end
    assert(e.widgetOriginalsRestored() and e.preference.type == "boolean" and e.preference.value == 1)
    assert(e.nativeRestores == 1 and e.nativeResets == 1 and e.nativeWrites == 1)
    assert(e.widgetState.running and e.widgetState.mode == "managed")
    local function noSnapshot(value)
        if type(value) == "table" then for _, item in pairs(value) do noSnapshot(item) end
        else assert(value ~= "transient-widget-original-not-for-report", "Original widget snapshot leaked into receipt") end
    end
    noSnapshot(report)
end)

test("absent original key and original macOS mode are restored without another defaults action", function()
    local e = widgetEnvironment{preference={ok=true,present=false},mode="macOS",running=false}
    local report = e.runWidgetAcceptance()
    assert(report.ok and e.widgetOriginalsRestored() and not e.preference.present)
    assert(not e.widgetState.running and e.widgetState.mode == "macOS" and e.nativeResets == 1)
end)

test("failed defaults action still restores the exact OS key and all owned settings", function()
    local e = widgetEnvironment{resetFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and report.widgetDefaults.restorationVerified and e.widgetOriginalsRestored())
    assert(not e.check(report,"macOS widget defaults key removal verified").passed)
    assert(#e.source.writes == 0 and #e.follower.writes == 0)
end)

test("failed initial native capture performs no widget mutation", function()
    local e = widgetEnvironment{captureFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and e.nativeWrites == 0 and e.nativeResets == 0 and e.nativeRestores == 0)
    assert(e.widgetSettingWrites == 0 and e.widgetOriginalsRestored())
end)

test("wrong native domain or key metadata is rejected before any widget mutation", function()
    for _, preference in ipairs({
        {ok=true,present=false,domain="another.domain"},
        {ok=true,present=false,key="AnotherKey"},
    }) do
        local e = widgetEnvironment{preference=preference}
        local report = e.runWidgetAcceptance()
        assert(not report.ok and e.nativeWrites == 0 and e.nativeResets == 0 and e.nativeRestores == 0)
        assert(e.widgetSettingWrites == 0 and e.widgetOriginalsRestored())
    end
end)

test("unconfirmed test seed restores its partial write rather than leaving it behind", function()
    local e = widgetEnvironment{seedFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and e.nativeResets == 0 and e.nativeRestores == 1)
    assert(e.widgetOriginalsRestored() and report.widgetDefaults.restorationVerified)
end)

test("cancellation during a bounded brightness write restores widget state synchronously", function()
    local e = widgetEnvironment{brightness={source={delay=0.5},follower={delay=0.5}}}
    local report, calls = nil, 0
    e.startWidgetAcceptance(function(value) report = value; calls = calls + 1 end)
    e.advance(0.2); e.acceptance.cancel()
    assert(report and not report.ok and report.widgetDefaults.restorationVerified and e.widgetOriginalsRestored())
    local mutations = e.nativeWrites + e.nativeResets + e.nativeRestores
    e.advance(10)
    assert(calls == 1 and e.activeAcceptanceTimers() == 0 and mutations == e.nativeWrites + e.nativeResets + e.nativeRestores)
end)

test("cancellation inside native seed cannot resume test mutations after recovery", function()
    local e = widgetEnvironment{cancelDuringSeed=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and e.widgetOriginalsRestored() and e.nativeResets == 0 and e.nativeRestores == 1)
end)

test("native restoration failure is bounded and leaves observers stopped with explicit recovery", function()
    local e = widgetEnvironment{restoreFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and report.recoveryRequired and e.nativeRestores == 2)
    assert(not e.check(report,"widget visibility preference restored").passed and not e.widgetState.running)
    assert(not e.check(report,"widget control settings restored").passed)
end)

test("one native restore retry may recover the key but never conceals incomplete controller recovery", function()
    local e = widgetEnvironment{restoreFirstFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and report.recoveryRequired and e.nativeRestores == 2)
    assert(e.check(report,"widget visibility preference restored").passed and not e.widgetState.running)
    assert(not e.check(report,"widget control settings restored").passed)
end)

test("one app-setting recovery error still attempts the OS key and stops mismatched automation", function()
    local e = widgetEnvironment{settingsRestoreFailure=true}
    local report = e.runWidgetAcceptance()
    assert(not report.ok and report.recoveryRequired and not e.widgetState.running)
    assert(e.check(report,"widget visibility preference restored").passed)
    assert(not e.check(report,"widget control settings restored").passed)
end)

test("report callback failure cannot retain a widget transaction snapshot or skip recovery", function()
    local e = widgetEnvironment{}
    local calls = 0
    e.startWidgetAcceptance(function() calls = calls + 1; error("Injected widget report failure") end)
    e.advance(24)
    assert(calls == 1 and e.widgetOriginalsRestored() and not e.acceptance.active)
    assert(e.acceptance.lastReport.callbackError and e.acceptance.lastReport.widgetDefaults.restorationVerified)
end)

test("acceptance integrates with the actual widget controller and preserves legacy absence", function()
    local e = create{}.load(app)
    hs.timer.absoluteTime = function() return e.time * 1e9 end
    local originalPanel = package.loaded.desktop_widget_panel
    package.loaded.desktop_widget_panel = {snapshot=function() return {open=false} end, clearCache=function() end}
    local prefix = "wallpaperVeil.widgets."
    e.settings[prefix .. "showOnOpen"] = true
    e.settings[prefix .. "hideOnClose"] = false
    e.settings[prefix .. "showOnClockClick"] = false
    local preference = {ok=true,present=true,type="boolean",value=1}
    local function copyPreference(value)
        return {ok=value.ok,present=value.present,type=value.type,value=value.value,
            domain="com.apple.WindowManager",key="StandardHideWidgets"}
    end
    local resets = 0
    local native = {
        read=function() return copyPreference(preference) end,
        write=function(value) preference={ok=true,present=true,type="integer",value=value};return {ok=true} end,
        reset=function() resets=resets+1;preference={ok=true,present=false};return {ok=true,present=false,resetVerified=true} end,
    }
    local widgets = assert(loadfile(app .. "/desktop_widgets.lua"))().start(native)
    e.veil.widgets = widgets
    local report
    e.acceptance.run(function(value) report = value end, {widgetPreferences={
        read=native.read,write=native.write,
        restore=function(value) preference=copyPreference(value);return {ok=true} end,
    }})
    e.advance(24, function() return report ~= nil end)
    assert(report and report.ok and #report.checks == 20 and report.widgetDefaults.restorationVerified)
    assert(preference.present and preference.type == "boolean" and preference.value == 1)
    assert(resets == 1 and e.settings[prefix .. "controlState"] == nil and e.settings[prefix .. "resetPending"] == nil)
    local state = widgets.status()
    assert(state.running and state.mode == "managed" and state.showOnOpen and not state.hideOnClose and not state.showOnClockClick)
    widgets.stop()
    package.loaded.desktop_widget_panel = originalPanel
end)


test("acceptance restores a pending guard without re-enabling a stale managed record", function()
    for _, originalGuard in ipairs({true, {invalid="guard-still-blocks"}}) do
        local e = create{}.load(app)
        hs.timer.absoluteTime = function() return e.time * 1e9 end
        local originalPanel = package.loaded.desktop_widget_panel
        package.loaded.desktop_widget_panel = {snapshot=function() return {open=false} end, clearCache=function() end}
        local prefix = "wallpaperVeil.widgets."
        local originalControl = {schema=1,mode="managed",showOnOpen=true,hideOnClose=true,showOnClockClick=true}
        e.settings[prefix .. "controlState"] = originalControl
        e.settings[prefix .. "resetPending"] = originalGuard
        local preference = {ok=true,present=true,type="boolean",value=1,
            domain="com.apple.WindowManager",key="StandardHideWidgets"}
        local resets, writes = 0, 0
        local native = {
            read=function() return preference end,
            write=function(value)
                writes=writes+1
                preference={ok=true,present=true,type="integer",value=value,
                    domain="com.apple.WindowManager",key="StandardHideWidgets"}
                return {ok=true}
            end,
            reset=function()
                resets=resets+1
                preference={ok=true,present=false,domain="com.apple.WindowManager",key="StandardHideWidgets"}
                return {ok=true,present=false,resetVerified=true}
            end,
        }
        local widgets = assert(loadfile(app .. "/desktop_widgets.lua"))().start(native)
        e.veil.widgets = widgets
        assert(widgets.status().mode == "resetFailed" and not widgets.status().tracking and writes == 0)
        local report
        e.acceptance.run(function(value) report = value end, {widgetPreferences={
            read=native.read,write=native.write,
            restore=function(value) preference=value;return {ok=true} end,
        }})
        e.advance(24, function() return report ~= nil end)
        assert(report and report.ok and #report.checks == 20 and report.widgetDefaults.restorationVerified)
        assert(preference.present and preference.type == "boolean" and preference.value == 1)
        assert(resets == 1 and writes == 1)
        local restoredGuard = e.settings[prefix .. "resetPending"]
        assert(type(restoredGuard) == type(originalGuard))
        if type(originalGuard) == "table" then assert(restoredGuard.invalid == originalGuard.invalid)
        else assert(restoredGuard == originalGuard) end
        local restoredControl = e.settings[prefix .. "controlState"]
        assert(restoredControl.mode == "managed" and restoredControl.showOnOpen and restoredControl.hideOnClose
            and restoredControl.showOnClockClick)
        local state = widgets.status()
        assert(state.running and state.mode == "resetFailed" and not state.tracking
            and not state.showOnOpen and not state.hideOnClose and not state.showOnClockClick)
        widgets.stop()
        package.loaded.desktop_widget_panel = originalPanel
    end
end)

print(string.format("Acceptance: %d focused cases passed", cases))
