-- Wallpaper Veil application entry point. All executable Lua is bundled.
local code = assert(os.getenv("WV_APP_CODE"), "Missing app resource directory")
local support = assert(os.getenv("WV_APPLICATION_SUPPORT"), "Missing app data directory")
local bundleID = "com.ry00ki.wallpaperveil"
local reportPath = support .. "/diagnostics.json"
wallpaperVeilAppTimers = {}
local function after(seconds, callback)
    local timer = hs.timer.doAfter(seconds, callback)
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
        "desktop_widget_clock", "desktop_widget_panel", "runtime_probe", "acceptance"}) do
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
    wallpaperVeil = require("wallpaper_veil").start()
    displayBrightnessSync = require("display_brightness_sync").start(wallpaperVeil)
    local baseMenu = wallpaperVeil.menuItems
    wallpaperVeil.menuItems = function(...)
        local items = baseMenu(...)
        items[#items+1] = {title="-"}
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
    hs.shutdownCallback = function()
        local acceptance=package.loaded["acceptance"]
        if acceptance and acceptance.cancel then pcall(acceptance.cancel) end
        if displayBrightnessSync then pcall(displayBrightnessSync.stop) end
        if wallpaperVeil then pcall(wallpaperVeil.stop) end
    end
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
        probe.appVersion = "0.1.2"
        probe.nativeUI = nativeUI.diagnostics()
        probe.prototype = "Bundled upstream native runtime with app-owned launcher and Lua"
        writeReport(probe)
    end
    after(0.5, function()
        local success, err = pcall(diagnostic)
        if not success then writeReport({ok=false,error=tostring(err),process=process()}) end
    end)
    if os.getenv("WV_UI_TEST") == "1" then
        after(1, function()
            local success, err = xpcall(function()
                nativeUI.showAbout()
                after(3, function() pcall(nativeUI.closeAbout) end)
                after(0.5, function()
                    local captured, problem = xpcall(function()
                        local saved, why = nativeUI.saveAboutPreview(support .. "/about-preview.png")
                        local ui = nativeUI.diagnostics()
                        ui.previewSaved = saved
                        ui.ok = ui.configured and ui.nativeMainMenuReady and ui.aboutVisible and
                            ui.aboutTitle == "Wallpaper Veil" and not ui.engineWindowsVisible and
                            ui.repositoryActionWired and ui.noticesActionWired and ui.aboutIconPresent and saved
                        ui.captureError = why
                        writeReport(ui, support .. "/ui-check.json")
                    end, debug.traceback)
                    if not captured then
                        pcall(nativeUI.closeAbout)
                        writeReport({ok=false,error=problem}, support .. "/ui-check.json")
                    end
                end)
            end, debug.traceback)
            if not success then
                pcall(nativeUI.closeAbout)
                writeReport({ok=false,error=err}, support .. "/ui-check.json")
            end
        end)
    end
    if os.getenv("WV_SELF_TEST") == "1" then
        after(1, function()
            local passed, err = xpcall(function()
                require("acceptance").run(function(result)
                    writeReport(result, support .. "/acceptance.json")
                    pcall(diagnostic)
                end)
            end, debug.traceback)
            if not passed then
                writeReport({ok=false,error=err}, support .. "/acceptance.json")
            end
        end)
    end
end, debug.traceback)
if not ok then
    writeReport({ok=false, error=failure, process=process()})
    hs.alert.show("Wallpaper Veil could not start. See diagnostics.json.")
end
