-- Wallpaper Veil application entry point. All executable Lua is bundled.
local code = assert(os.getenv("WV_APP_CODE"), "Missing app resource directory")
local support = assert(os.getenv("WV_APPLICATION_SUPPORT"), "Missing app data directory")
local bundleID = "com.ry00ki.wallpaperveil"
local reportPath = support .. "/diagnostics.json"
wallpaperVeilAppTimers = {}
local appActive = true
local function after(seconds, callback)
    local timer = hs.timer.doAfter(seconds, function()
        if appActive then callback() end
    end)
    wallpaperVeilAppTimers[#wallpaperVeilAppTimers+1] = timer
    return timer
end
local function writeReport(value, path)
    local encoded = assert(hs.json.encode(value, true))
    local target = path or reportPath
    local file = assert(io.open(target .. ".tmp", "w"))
    file:write(encoded); file:close()
    assert(os.rename(target .. ".tmp", target))
end
local function process()
    local p = hs.processInfo
    return {bundleID=p.bundleID, executablePath=p.executablePath,
        resourcePath=p.resourcePath, processID=p.processID,
        settingsDomain=hs.settings.bundleID, configdir=hs.configdir,
        packagePath=package.path, packageCPath=package.cpath}
end
local function quit()
    local app = hs.application.applicationForPID(hs.processInfo.processID)
    if app then app:kill() end
end

local function cleanup()
    if not appActive then return end
    appActive = false
    for _, timer in ipairs(wallpaperVeilAppTimers) do pcall(function() timer:stop() end) end
    wallpaperVeilAppTimers = {}
    local acceptance = package.loaded["acceptance"]
    if acceptance and acceptance.cancel then pcall(acceptance.cancel) end
    if displayBrightnessSync then pcall(displayBrightnessSync.stop) end
    if wallpaperVeil then pcall(wallpaperVeil.stop) end
end
-- Install cleanup before any component can partially start.
hs.shutdownCallback = cleanup

hs.uploadCrashData(false)
hs.menuIcon(false)
hs.dockIcon(false)

local ok, failure = xpcall(function()
    assert(hs.processInfo.bundleID == bundleID, "Incorrect application identity")
    assert(hs.settings.bundleID == bundleID, "Incorrect settings domain")
    local openUI = assert(package.loadlib(hs.processInfo.resourcePath ..
        "/../Frameworks/libWallpaperVeilUI.dylib", "luaopen_wallpaperveil_ui"))
    local nativeUI = openUI()
    assert(nativeUI.configure().configured, "App-owned native UI did not configure")
    assert(not package.path:find(".hammerspoon", 1, true), "External configuration search path")
    assert(not package.path:find("/.local/share/", 1, true), "External user module search path")
    for _, name in ipairs({"wallpaper_veil", "display_brightness_sync", "desktop_widgets",
        "desktop_widget_clock", "desktop_widget_panel", "runtime_probe", "acceptance", "app_settings"}) do
        assert(loadfile(code .. "/" .. name .. ".lua"))
    end
    for _, name in ipairs({"wallpaper_veil", "display_brightness_sync", "desktop_widgets",
        "desktop_widget_clock", "desktop_widget_panel"}) do require(name) end
    if os.getenv("WV_VERIFY_ONLY") == "1" then
        writeReport({ok=true, mode="preflight", process=process(),
            codeDirectory=code, verifiedAtUTC=os.date("!%Y-%m-%dT%H:%M:%SZ")})
        after(0.2, quit)
        return
    end
    wallpaperVeil = require("wallpaper_veil")
    wallpaperVeil.loginItemStatus = nativeUI.loginStatus
    wallpaperVeil.start({read=nativeUI.widgetPreferenceRead, write=nativeUI.widgetPreferenceWrite,
        reset=nativeUI.resetWidgetDefaults})
    displayBrightnessSync = require("display_brightness_sync")
    displayBrightnessSync.start(wallpaperVeil)
    local appSettings = require("app_settings")
    local baseMenu = wallpaperVeil.menuItems
    wallpaperVeil.menuItems = function(...)
        local items = baseMenu(...)
        items[#items+1] = {title="-"}
        local settings = appSettings.menuItems(nativeUI)
        items[#items+1] = {title="App settings", menu=settings}
        items[#items+1] = {title="Quit Wallpaper Veil", fn=quit}
        items[#items+1] = {title="About Wallpaper Veil", fn=function()
            nativeUI.showAbout()
        end}
        return items
    end
    wallpaperVeil.menu:setMenu(wallpaperVeil.menuItems)
    -- Recreate after native startup so the standalone status item is registered.
    after(0.2, function()
        wallpaperVeil.menu:removeFromMenuBar():returnToMenuBar()
        wallpaperVeil.menu:autosaveName("WallpaperVeilStandalone")
        wallpaperVeil.menu:setTitle(wallpaperVeil.enabled and "◐ Veil" or "○ Veil")
    end)
    local function diagnostic()
        local probe = require("runtime_probe").collect{
            expectedBundleID=bundleID, expectedModuleRoot=code}
        probe.ok = true
        for _, value in pairs(probe.checks) do if value == false then probe.ok=false end end
        probe.accessibilityGranted = hs.accessibilityState(false)
        local frame=wallpaperVeil.menu:frame()
        probe.menuBar={inMenuBar=wallpaperVeil.menu:isInMenuBar(),
            title=wallpaperVeil.menu:title(),frame=frame and {x=frame.x,y=frame.y,w=frame.w,h=frame.h} or nil}
        -- macOS 27 can remotely host status items; frame is diagnostic only.
        probe.nativeUI = nativeUI.diagnostics()
        probe.appVersion = probe.nativeUI.currentVersion
        probe.appBuild = probe.nativeUI.currentBuild
        probe.releaseTag = probe.nativeUI.currentReleaseTag
        probe.releaseChannel = probe.nativeUI.releaseChannel
        probe.loginItem = nativeUI.loginStatus()
        probe.desktopWidgets = wallpaperVeil.widgets.status()
        probe.prototype = "Bundled upstream native runtime with app-owned launcher and Lua"
        writeReport(probe)
    end
    after(0.5, function()
        local success, err = pcall(diagnostic)
        if not success then writeReport({ok=false,error=tostring(err),process=process()}) end
    end)
    if os.getenv("WV_UI_TEST") == "1" then
        local function failUITest(problem, path, kind)
            -- Receipt writing and native diagnostics can fail independently.
            -- Always stop network work and close our window before retrying either.
            pcall(nativeUI.cancelUpdateCheck)
            pcall(nativeUI.closeAbout)
            local read, result = pcall(nativeUI.diagnostics)
            if not read or type(result) ~= "table" then result = {} end
            result.ok = false
            result.error = tostring(problem)
            result.kind = kind or "native-About-qualification"
            result.observedAtUTC = os.date("!%Y-%m-%dT%H:%M:%SZ")
            local written, failure = pcall(writeReport, result, path)
            if not written then
                pcall(function() hs.printf("Wallpaper Veil UI qualification receipt failed: %s", tostring(failure)) end)
            end
        end
        after(1, function()
            local success, err = xpcall(function()
                nativeUI.showAbout()
                after(0.5, function()
                    local captured, problem = xpcall(function()
                        local saved, why = nativeUI.saveAboutPreview(support .. "/about-preview.png")
                        local ui = nativeUI.diagnostics()
                        ui.previewSaved = saved
                        ui.ok = ui.configured and ui.nativeMainMenuReady and ui.aboutVisible and
                            ui.aboutTitle == "Wallpaper Veil" and not ui.engineWindowsVisible and
                            ui.repositoryActionWired and ui.noticesActionWired and ui.aboutIconPresent and saved and
                            ui.updateActionWired and ui.releaseActionWired and
                            ui.currentVersion ~= "" and ui.currentBuild ~= "" and ui.currentReleaseTag ~= ""
                        ui.captureError = why
                        ui.appSettings = {}
                        for _, item in ipairs(appSettings.menuItems(nativeUI)) do
                            ui.appSettings[#ui.appSettings+1] = {title=item.title, checked=item.checked,
                                disabled=item.disabled, hasAction=type(item.fn)=="function"}
                        end
                        local function release(tag)
                            return {tag_name=tag, draft=false, prerelease=tag:find("-preview.", 1, true) ~= nil,
                                html_url="https://github.com/Ry00ki/wallpaper-veil/releases/tag/" .. tag}
                        end
                        local major = assert(ui.currentVersion:match("^(%d+)%."))
                        local newer = string.format("v%d.0.0", tonumber(major)+1)
                        local checks = {}
                        local current = nativeUI.testUpdateResponse(hs.json.encode({release(ui.currentReleaseTag)}))
                        checks.current = current.updateState == "current" and current.latestTag == ui.currentReleaseTag
                        local available = nativeUI.testUpdateResponse(hs.json.encode({release(newer)}))
                        checks.newer = available.updateState == "available" and available.latestTag == newer and
                            available.latestURL == release(newer).html_url
                        local denied = nativeUI.testUpdateResponse("[]", 403)
                        checks.rateLimit = denied.updateState == "error" and
                            denied.updateMessage:find("rate limit", 1, true) ~= nil
                        local malformed = nativeUI.testUpdateResponse("{", 200)
                        checks.invalidJSON = malformed.updateState == "error"
                        local empty = nativeUI.testUpdateResponse("[]", 200)
                        checks.empty = empty.updateState == "no-release"
                        ui.updateFixtureChecks = checks
                        for _, passed in pairs(checks) do if not passed then ui.ok=false end end
                        writeReport(ui, support .. "/ui-check.json")
                        -- Explicit UI-test mode exercises the same manual action
                        -- after offline fixtures; normal startup never checks.
                        nativeUI.checkForUpdates()
                        local deadline = hs.timer.secondsSinceEpoch() + 65
                        local function pollUpdate()
                            local passed, problem = xpcall(function()
                                local result = nativeUI.diagnostics()
                                if result.updateInProgress and hs.timer.secondsSinceEpoch() < deadline then
                                    after(0.25, pollUpdate)
                                    return
                                end
                                if result.updateInProgress then
                                    nativeUI.cancelUpdateCheck()
                                    result = nativeUI.diagnostics()
                                    result.qualificationTimedOut = true
                                    result.error = "The update-check qualification deadline was reached."
                                end
                                result.ok = not result.qualificationTimedOut and not result.updateInProgress and
                                    (result.updateState == "current" or result.updateState == "ahead" or
                                        result.updateState == "available")
                                result.kind = "live-public-GitHub-release-check"
                                result.observedAtUTC = os.date("!%Y-%m-%dT%H:%M:%SZ")
                                local saved, why = nativeUI.saveAboutPreview(support .. "/about-update-preview.png")
                                assert(saved, why or "The update-check About view could not be captured.")
                                result.previewSaved = true
                                -- Opening this pane is a non-mutating feature check.
                                -- macOS approval remains a separate user action.
                                result.desktopControlSettingsDispatched = nativeUI.openAccessibilitySettings()
                                writeReport(result, support .. "/update-check.json")
                                after(1, function()
                                    local closed, failure = pcall(nativeUI.closeAbout)
                                    if not closed then
                                        failUITest(failure, support .. "/update-check.json", "live-public-GitHub-release-check")
                                    end
                                end)
                            end, debug.traceback)
                            if not passed then
                                failUITest(problem, support .. "/update-check.json", "live-public-GitHub-release-check")
                            end
                        end
                        after(0.25, pollUpdate)
                    end, debug.traceback)
                    if not captured then
                        failUITest(problem, support .. "/ui-check.json")
                    end
                end)
            end, debug.traceback)
            if not success then
                failUITest(err, support .. "/ui-check.json")
            end
        end)
    end
    if os.getenv("WV_SELF_TEST") == "1" then
        after(1, function()
            local passed, err = xpcall(function()
                require("acceptance").run(function(result)
                    writeReport(result, support .. "/acceptance.json")
                    pcall(diagnostic)
                end, {widgetPreferences={read=nativeUI.widgetPreferenceRead,
                    write=nativeUI.widgetPreferenceWrite, restore=nativeUI.widgetPreferenceRestoreForTest}})
            end, debug.traceback)
            if not passed then
                writeReport({ok=false,error=err}, support .. "/acceptance.json")
            end
        end)
    end
end, debug.traceback)
if not ok then
    cleanup()
    writeReport({ok=false, error=failure, process=process()})
    hs.alert.show("Wallpaper Veil could not start. See diagnostics.json.")
end
