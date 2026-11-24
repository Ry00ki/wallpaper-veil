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

local function options(object, name)
    local result, seen = {}, {}
    local values = read(object, name, {})
    if type(values) ~= "table" then return result end
    for _, item in ipairs(values) do
        if type(item) == "table" and type(item.value) == "string" and item.value ~= ""
            and type(item.title) == "string" and not seen[item.value] then
            result[#result+1] = {value=item.value, title=item.title, enabled=item.enabled == true}
            seen[item.value] = true
        end
    end
    return result
end

local function permits(values, value)
    if type(value) ~= "string" then return false end
    for _, item in ipairs(values) do
        if item.value == value then return item.enabled == true end
    end
    return false
end

local function available(values)
    for _, item in ipairs(values) do if item.enabled then return true end end
    return false
end

local function displayOptions(sync, current)
    local values = options(sync, "settingsChoices")
    for _, uuid in ipairs({type(current.sourceUUID) == "string" and current.sourceUUID or "",
        type(current.followerUUID) == "string" and current.followerUUID or ""}) do
        local found = uuid == ""
        for _, item in ipairs(values) do if item.value == uuid then found=true; break end end
        if not found then
            values[#values+1] = {value=uuid, title="Previously selected display (disconnected)", enabled=false}
        end
    end
    if #values == 0 then values[1] = {value="unavailable", title="No displays found", enabled=false} end
    return values
end

local function strengths(opacity)
    local values, selected = {}, type(opacity) == "number" and tostring(opacity) or ""
    local found = false
    for percent=10,80,10 do
        local value = tostring(percent / 100)
        values[#values+1] = {value=value, title=tostring(percent).."%"..(percent == 40 and " (default)" or ""), enabled=true}
        if value == selected then found=true end
    end
    if not found and type(opacity) == "number" and opacity >= 0.1 and opacity <= 0.8 then
        values[#values+1] = {value=selected, title=string.format("%.6g%% (current)", opacity*100), enabled=true}
        table.sort(values, function(a,b) return tonumber(a.value) < tonumber(b.value) end)
    end
    return values, selected
end

local function paneName(nativeUI)
    local info = read(nativeUI, "accessibilitySettingsInfo", {})
    return type(info) == "table" and type(info.paneName) == "string" and info.paneName or "Accessibility"
end

local function snapshot(nativeUI, veil, sync, startSetup, hotkeys)
    local login, currentSync, widgets = loginStatus(nativeUI), status(sync), status(veil.widgets)
    local running, granted = veil.running == true, trusted()
    local shortcuts = status(hotkeys)
    local shortcutsAvailable = running and type(hotkeys) == "table" and type(hotkeys.setBinding) == "function"
    local checks = read(nativeUI, "startupChecksEnabled", nil)
    local colors = options(veil, "settingsColors")
    if #colors == 0 then colors[1] = {value="unavailable", title="No colours available", enabled=false} end
    local strengthOptions, strength = strengths(veil.opacity)
    local displays = displayOptions(sync, currentSync)
    local supported = 0
    for _, display in ipairs(displays) do if display.enabled then supported=supported+1 end end
    local colorHex = read(veil, "colorHex", "", veil.color)
    if type(colorHex) ~= "string" then colorHex="" end
    local loginDetail = login.requiresApproval and "Waiting for macOS approval in Login Items; startup is not active."
        or login.ok ~= true and "The startup setting is unavailable."
        or "Open Wallpaper Veil automatically after sign-in."
    local general = {
        {id="general.quickSetup", type="button", title="Start Quick Setup…", enabled=type(startSetup) == "function"},
        {id="general.login", type="toggle", title="Start Wallpaper Veil when I sign in",
            value=login.ok == true and login.enabled == true and not login.requiresApproval,
            enabled=login.ok == true, detail=loginDetail},
        {id="general.loginSettings", type="button", title="Open Login Items…", enabled=type(nativeUI.openLoginSettings) == "function"},
        {id="general.startupChecks", type="toggle", title="Check for updates when Wallpaper Veil starts",
            value=checks == true, enabled=type(checks) == "boolean", detail=type(checks) == "boolean"
                and "Notify about a newer version. About can still check manually."
                or "The update startup preference is unavailable."},
    }
    local wallpaper = {
        {id="wallpaper.enabled", type="toggle", title="Wallpaper tint", value=veil.enabled == true, enabled=running},
        {id="wallpaper.color", type="choice", title="Colour", value=colorHex, options=colors,
            enabled=running and available(colors)},
        {id="wallpaper.strength", type="choice", title="Strength", value=strength, options=strengthOptions,
            enabled=running},
        {id="wallpaper.picker", type="button", title="New custom colour…", enabled=running},
        {id="wallpaper.refresh", type="button", title="Refresh wallpaper tint", enabled=running},
        {id="wallpaper.explanation", type="note", text="No macOS permission is needed for the tint."},
    }
    local brightness = {
        {id="brightness.enabled", type="toggle", title="Synchronise display brightness", value=currentSync.enabled == true,
            enabled=running and (currentSync.enabled == true or supported >= 2),
            detail="Copies the source display's hardware brightness to the follower. Enabling can change the follower immediately."},
        {id="brightness.source", type="choice", title="Source display (controls both)", value=type(currentSync.sourceUUID) == "string" and currentSync.sourceUUID or "",
            options=displays, enabled=running and available(displays)},
        {id="brightness.follower", type="choice", title="Follower display", value=type(currentSync.followerUUID) == "string" and currentSync.followerUUID or "",
            options=displays, enabled=running and available(displays)},
        {id="brightness.status", type="note", text=currentSync.message or (currentSync.enabled and "On" or "Off: displays can be adjusted independently")},
        {id="brightness.explanation", type="note", text="Requires native brightness support. No Desktop Control access needed."},
    }
    if supported < 2 then
        brightness[#brightness+1] = {id="brightness.availability", type="note", text="Two supported displays are needed. Changing displays turns sync off."}
    end
    brightness[#brightness+1] = {id="brightness.shortcutsEnabled", type="toggle", title="Brightness keyboard shortcuts",
        value=shortcuts.enabled == true, enabled=shortcutsAvailable,
        detail="No Accessibility or Input Monitoring access is needed."}
    brightness[#brightness+1] = {id="brightness.shortcutUp", type="shortcut", title="Increase brightness",
        value=type(shortcuts.upLabel) == "string" and shortcuts.upLabel or "", enabled=shortcutsAvailable}
    brightness[#brightness+1] = {id="brightness.clearShortcutUp", type="button", title="Clear increase shortcut",
        enabled=shortcutsAvailable and type(shortcuts.upLabel) == "string" and shortcuts.upLabel ~= ""}
    brightness[#brightness+1] = {id="brightness.shortcutDown", type="shortcut", title="Decrease brightness",
        value=type(shortcuts.downLabel) == "string" and shortcuts.downLabel or "", enabled=shortcutsAvailable}
    brightness[#brightness+1] = {id="brightness.clearShortcutDown", type="button", title="Clear decrease shortcut",
        enabled=shortcutsAvailable and type(shortcuts.downLabel) == "string" and shortcuts.downLabel ~= ""}
    if type(shortcuts.message) == "string" and shortcuts.message ~= "" then
        brightness[#brightness+1] = {id="brightness.shortcutStatus", type="note", text=shortcuts.message}
    end
    local widgetRunning = running and widgets.running == true
    local miscellaneous = {
        {id="misc.defaults", type="button", title="Use macOS defaults", enabled=widgetRunning,
            detail=widgets.mode == "macOS" and "macOS manages desktop widgets; automatic controls are off."
                or "Stop widget automation and remove its visibility override."},
        {id="misc.showNow", type="button", title="Show desktop widgets now", enabled=widgetRunning,
            detail="Uses custom controls; keeps automatic choices."},
        {id="misc.hideNow", type="button", title="Hide desktop widgets now", enabled=widgetRunning},
        {id="misc.showOnClockClick", type="toggle", title="Show when the clock is clicked", value=widgets.showOnClockClick == true,
            enabled=widgetRunning, detail=granted and "Desktop access enabled. Clock detection also needs an active event tap."
                or "Needs desktop access for clock-click detection. Enable access below."},
        {id="misc.showOnOpen", type="toggle", title="Show when Notification Center opens", value=widgets.showOnOpen == true,
            enabled=widgetRunning, detail="Needs desktop access to reveal widgets while keeping Notification Center open."},
        {id="misc.desktopAccess", type="button", title=granted and "Manage Desktop Control Access…" or "Enable Desktop Control Access…",
            enabled=type(nativeUI.openAccessibilitySettings) == "function",
            detail="System Settings → Privacy & Security → "..paneName(nativeUI)},
        {id="misc.hideOnClose", type="toggle", title="Hide when Notification Center closes", value=widgets.hideOnClose == true,
            enabled=widgetRunning, detail="No desktop access permission needed."},
    }
    if widgets.error then
        miscellaneous[#miscellaneous+1] = {id="misc.error", type="note", text=tostring(widgets.error)}
        miscellaneous[#miscellaneous+1] = {id="misc.retry", type="button",
            title=(widgets.mode == "resetFailed" or widgets.mode == "resetting") and "Retry macOS defaults" or "Retry widget controls",
            enabled=widgetRunning}
    end
    if widgets.clock and widgets.clock.error and widgets.clock.error ~= widgets.error then
        miscellaneous[#miscellaneous+1] = {id="misc.clockStatus", type="note", text=tostring(widgets.clock.error)}
    end
    return {sections={
        {id="wallpaper", title="Wallpaper", rows=wallpaper},
        {id="general", title="General", rows=general},
        {id="brightness", title="Brightness", rows=brightness},
        {id="misc", title="Miscellaneous", rows=miscellaneous},
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

local function dispatch(nativeUI, veil, sync, startSetup, hotkeys, action, value)
    if action == "general.quickSetup" then
        if type(startSetup) ~= "function" then return "Quick Setup is unavailable." end
        return startSetup()
    elseif action == "general.login" then
        if type(value) ~= "boolean" then return "Choose whether to start Wallpaper Veil when signing in." end
        local current = loginStatus(nativeUI)
        if current.ok ~= true then return "The startup setting is unavailable." end
        if current.requiresApproval then return call(nativeUI, "openLoginSettings", "Could not open Login Items.") end
        return call(nativeUI, "setLaunchAtLogin", "Could not change the startup setting.", value)
    elseif action == "general.loginSettings" then
        return call(nativeUI, "openLoginSettings", "Could not open Login Items.")
    elseif action == "general.startupChecks" then
        if type(value) ~= "boolean" then return "Choose whether to check for updates at startup." end
        return call(nativeUI, "setStartupChecksEnabled", "Could not save the update startup preference.", value)
    elseif action == "misc.desktopAccess" then
        -- Request only from this explicit action. A request never implies grant.
        if not trusted() then pcall(hs.accessibilityState, true) end
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
    elseif action == "brightness.shortcutsEnabled" then
        if type(value) ~= "boolean" then return "Choose whether to enable brightness shortcuts." end
        return call(hotkeys, "setEnabled", "Could not change brightness shortcuts.", value)
    elseif action == "brightness.shortcutUp" or action == "brightness.shortcutDown" then
        if type(value) ~= "string" or value == "" then return "Record a shortcut with Control, Option or Command and a key." end
        return call(hotkeys, "setBinding", "Could not save that brightness shortcut.", action == "brightness.shortcutUp" and "up" or "down", value)
    elseif action == "brightness.clearShortcutUp" or action == "brightness.clearShortcutDown" then
        return call(hotkeys, "setBinding", "Could not clear that brightness shortcut.", action == "brightness.clearShortcutUp" and "up" or "down", nil)
    elseif action == "wallpaper.enabled" then
        if type(value) ~= "boolean" then return "Choose whether to enable the wallpaper tint." end
        return call(veil, "setEnabled", "Could not change the wallpaper tint.", value)
    elseif action == "wallpaper.color" then
        if not permits(options(veil, "settingsColors"), value) then return "That colour is no longer available. Choose another colour." end
        return call(veil, "setColor", "Could not apply the colour.", value)
    elseif action == "wallpaper.picker" then
        return call(veil, "openPicker", "Could not open the colour picker.")
    elseif action == "wallpaper.strength" then
        local choices = strengths(veil.opacity)
        if not permits(choices, value) then return "Choose an available strength between 10% and 80%." end
        return call(veil, "setOpacity", "Could not change the tint strength.", tonumber(value))
    elseif action == "wallpaper.refresh" then
        return call(veil, "rebuild", "Could not refresh wallpaper tint.")
    elseif action == "brightness.enabled" then
        if type(value) ~= "boolean" then return "Choose whether to synchronise display brightness." end
        if type(sync) ~= "table" or type(sync.setEnabled) ~= "function" then return "Brightness sync is unavailable." end
        -- Off returns false by design. Only an unsuccessful enable is an error.
        local ok, enabled = pcall(sync.setEnabled, value)
        if not ok or (value and enabled ~= true) then
            return status(sync).message or "Could not enable brightness sync. Choose two supported displays."
        end
        return nil
    elseif action == "brightness.source" or action == "brightness.follower" then
        if not permits(options(sync, "settingsChoices"), value) then return "That display is unavailable or does not support hardware brightness." end
        return call(sync, "choose", "Could not select the display.", action == "brightness.source" and "source" or "follower", value)
    end
    local widgets = veil.widgets
    if not action:match("^misc%.") then return "That setting is unavailable." end
    if status(widgets).running ~= true then return "Desktop widget controls are unavailable." end
    local toggles = { ["misc.showOnClockClick"]="setShowOnClockClick", ["misc.showOnOpen"]="setShowOnOpen", ["misc.hideOnClose"]="setHideOnClose" }
    local buttons = { ["misc.defaults"]="useMacOSDefaults", ["misc.showNow"]="showNow", ["misc.hideNow"]="hideNow", ["misc.retry"]="retry" }
    local method = toggles[action] or buttons[action]
    if not method then return "That setting is unavailable." end
    if toggles[action] and type(value) ~= "boolean" then return "Choose whether to enable this widget option." end
    local problem = call(widgets, method, "Could not change desktop widget controls.", value)
    if problem then return status(widgets).error or problem end
    return nil
end

function M.open(nativeUI, veil, sync, startSetup, hotkeys)
    if type(nativeUI) ~= "table" or type(nativeUI.showSettings) ~= "function" or type(veil) ~= "table" then
        return false, "The settings window is unavailable."
    end
    local function current()
        return hs.json.encode(snapshot(nativeUI, veil, sync, startSetup, hotkeys))
    end
    local function perform(action, value)
        local ok, problem = pcall(dispatch, nativeUI, veil, sync, startSetup, hotkeys, action, value)
        if not ok then return "Could not change that setting. Reopen Settings and try again." end
        return problem
    end
    return nativeUI.showSettings(current, perform)
end

return M
