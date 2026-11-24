-- Data and explicit actions for the native settings window. Snapshots never
-- build menus, request permission, select displays or change preferences.
local M = {}

local function read(object, name, fallback, ...)
    if type(object) ~= "table" or type(object[name]) ~= "function" then return fallback end
    local ok, value = pcall(object[name], ...)
    if ok then return value end
    return fallback
end

local function loginStatus(nativeUI)
    local value = read(nativeUI, "loginStatus", nil)
    return type(value) == "table" and value or {ok=false}
end

local function trusted()
    local ok, value = pcall(hs.accessibilityState, false)
    return ok and value == true
end

local function status(object)
    local value = read(object, "status", nil)
    return type(value) == "table" and value or {}
end

local function paneName(nativeUI)
    local info = read(nativeUI, "accessibilitySettingsInfo", {})
    return type(info) == "table" and type(info.paneName) == "string" and info.paneName or "Accessibility"
end

local function snapshot(nativeUI, veil, startSetup, hotkeys)
    local login = loginStatus(nativeUI)
    local running, granted = veil.running == true, trusted()
    local shortcuts = status(hotkeys)
    local shortcutsAvailable = running and type(hotkeys) == "table" and type(hotkeys.setBinding) == "function"
    local checks = read(nativeUI, "startupChecksEnabled", nil)
    local strength = math.floor(veil.opacity * 100 + 0.5)
    local loginDetail = login.requiresApproval and "Waiting for macOS approval. Open Login Items from App permissions."
        or login.ok ~= true and "The startup setting is unavailable."
        or "Open Wallpaper Veil automatically after sign-in."
    local general = {
        {id="general.quickSetup", type="button", title="Start Quick Setup…", enabled=type(startSetup) == "function"},
        {id="general.login", type="toggle", title="Start Wallpaper Veil when I sign in",
            value=login.ok == true and login.enabled == true and not login.requiresApproval,
            enabled=login.ok == true and not login.requiresApproval, detail=loginDetail},
        {id="general.startupChecks", type="toggle", title="Check for updates when Wallpaper Veil starts",
            value=checks == true, enabled=type(checks) == "boolean", detail=type(checks) == "boolean"
                and "Notify about a newer version. About can still check manually."
                or "The update startup preference is unavailable."},
    }
    local wallpaper = {
        {id="wallpaper.strength", type="range", title="Fine-tune strength", value=strength, enabled=running,
            detail="0% leaves the photo unchanged. 100% covers it with your selected colour."},
        {id="wallpaper.refresh", type="button", title="Refresh wallpaper tint", enabled=running},
    }
    local brightness = {
        {id="brightness.shortcutUp", type="shortcut", title="Increase brightness",
            value=type(shortcuts.upLabel) == "string" and shortcuts.upLabel or "", enabled=shortcutsAvailable},
        {id="brightness.clearShortcutUp", type="button", title="Clear increase shortcut",
            enabled=shortcutsAvailable and type(shortcuts.upLabel) == "string" and shortcuts.upLabel ~= ""},
        {id="brightness.shortcutDown", type="shortcut", title="Decrease brightness",
            value=type(shortcuts.downLabel) == "string" and shortcuts.downLabel or "", enabled=shortcutsAvailable},
        {id="brightness.clearShortcutDown", type="button", title="Clear decrease shortcut",
            enabled=shortcutsAvailable and type(shortcuts.downLabel) == "string" and shortcuts.downLabel ~= ""},
    }
    if type(shortcuts.message) == "string" and shortcuts.message ~= "" then
        brightness[#brightness+1] = {id="brightness.shortcutStatus", type="note", text=shortcuts.message}
    end
    local permissions = {
        {id="permissions.overview", type="note",
            text="Wallpaper tint, display brightness and its shortcuts work without Accessibility or Input Monitoring."},
        {id="permissions.desktopAccess", type="button",
            title=granted and "Manage Desktop Control Access…" or "Enable Desktop Control Access…",
            enabled=type(nativeUI.openAccessibilitySettings) == "function",
            detail="System Settings → Privacy & Security → "..paneName(nativeUI)},
        {id="permissions.desktopUse", type="note",
            text="This access lets Wallpaper Veil detect clock clicks and reveal desktop widgets while keeping Notification Center open."},
    }
    if type(nativeUI.openLoginSettings) == "function" then
        permissions[#permissions+1] = {id="permissions.loginSettings", type="button", title="Open Login Items…",
            enabled=true, detail="macOS may ask you to approve starting Wallpaper Veil when you sign in."}
    end
    return {sections={
        {id="wallpaper", title="Wallpaper", rows=wallpaper},
        {id="general", title="General", rows=general},
        {id="brightness", title="Brightness", rows=brightness},
        {id="permissions", title="App permissions", rows=permissions},
    }}
end

local function call(object, name, failure, ...)
    if type(object) ~= "table" or type(object[name]) ~= "function" then return failure end
    local ok, result, problem = pcall(object[name], ...)
    if not ok then return failure end
    if result == false then return type(problem) == "string" and problem or failure end
    if result == nil and type(problem) == "string" then return problem end
    if type(result) == "table" and result.ok == false then
        return type(result.error) == "string" and result.error or failure
    end
    return nil
end

local function dispatch(nativeUI, veil, startSetup, hotkeys, action, value)
    if action == "general.quickSetup" then
        if type(startSetup) ~= "function" then return "Quick Setup is unavailable." end
        return startSetup()
    elseif action == "general.login" then
        if type(value) ~= "boolean" then return "Choose whether to start Wallpaper Veil when signing in." end
        local current = loginStatus(nativeUI)
        if current.ok ~= true then return "The startup setting is unavailable." end
        if current.requiresApproval then return "Open Login Items from App permissions to approve startup." end
        return call(nativeUI, "setLaunchAtLogin", "Could not change the startup setting.", value)
    elseif action == "permissions.loginSettings" then
        return call(nativeUI, "openLoginSettings", "Could not open Login Items.")
    elseif action == "general.startupChecks" then
        if type(value) ~= "boolean" then return "Choose whether to check for updates at startup." end
        return call(nativeUI, "setStartupChecksEnabled", "Could not save the update startup preference.", value)
    elseif action == "permissions.desktopAccess" then
        -- Request only from this explicit action. A request never implies grant.
        if type(nativeUI.openAccessibilitySettings) == "function" and not trusted() then
            pcall(hs.accessibilityState, true)
        end
        return call(nativeUI, "openAccessibilitySettings", "Could not open desktop access settings.")
    end
    if type(action) ~= "string" then return "That setting is unavailable." end
    if action == "brightness.shortcutUp.end" or action == "brightness.shortcutDown.end" then
        -- Parent-window close/rebind/shutdown ends recording before releasing
        -- the Lua callback, even if the wallpaper module has already stopped.
        return call(hotkeys, "pauseRecording", "Could not restore brightness shortcuts.", false)
    end
    if veil.running ~= true then return "Wallpaper Veil is no longer running." end
    if action == "brightness.shortcutUp.begin" or action == "brightness.shortcutDown.begin" then
        return call(hotkeys, "pauseRecording", "Could not pause brightness shortcuts for recording.", true)
    elseif action == "brightness.shortcutUp" or action == "brightness.shortcutDown" then
        if type(value) ~= "string" or value == "" then return "Record a shortcut with Control, Option or Command and a key." end
        return call(hotkeys, "setBinding", "Could not save that brightness shortcut.", action == "brightness.shortcutUp" and "up" or "down", value)
    elseif action == "brightness.clearShortcutUp" or action == "brightness.clearShortcutDown" then
        return call(hotkeys, "setBinding", "Could not clear that brightness shortcut.", action == "brightness.clearShortcutUp" and "up" or "down", nil)
    elseif action == "wallpaper.strength" then
        if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 100 then
            return "Choose a whole percentage between 0% and 100%."
        end
        return call(veil, "setOpacity", "Could not change the tint strength.", value / 100)
    elseif action == "wallpaper.refresh" then
        return call(veil, "rebuild", "Could not refresh wallpaper tint.")
    end
    return "That setting is unavailable."
end

function M.open(nativeUI, veil, startSetup, hotkeys, section)
    if type(nativeUI) ~= "table" or type(nativeUI.showSettings) ~= "function" or type(veil) ~= "table" then
        return false, "The settings window is unavailable."
    end
    local function current()
        return hs.json.encode(snapshot(nativeUI, veil, startSetup, hotkeys))
    end
    local function perform(action, value)
        local ok, problem = pcall(dispatch, nativeUI, veil, startSetup, hotkeys, action, value)
        if not ok then return "Could not change that setting. Reopen Settings and try again." end
        return problem
    end
    return nativeUI.showSettings(current, perform, section)
end

return M
