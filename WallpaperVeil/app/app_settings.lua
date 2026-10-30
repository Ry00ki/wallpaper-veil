-- App-owned settings menu. Read current OS state on every menu opening.
local M = {}

local function loginStatus(nativeUI)
    local ok, value = pcall(nativeUI.loginStatus)
    if ok and type(value) == "table" then return value end
    return {ok=false, enabled=false, requiresApproval=false}
end

local function trusted()
    local ok, value = pcall(hs.accessibilityState, false)
    return ok and value == true
end

function M.menuItems(nativeUI)
    local login = loginStatus(nativeUI)
    local granted = trusted()
    local pane = "Accessibility"
    if nativeUI.accessibilitySettingsInfo then
        local ok, info = pcall(nativeUI.accessibilitySettingsInfo)
        if ok and type(info) == "table" and type(info.paneName) == "string" then pane=info.paneName end
    end
    local enabled = login.ok == true and login.enabled == true and not login.requiresApproval
    local items = {
        {title="Startup", disabled=true},
        {title="Start Wallpaper Veil when I sign in", checked=enabled, disabled=login.ok ~= true,
            fn=function()
                local current = loginStatus(nativeUI)
                if current.ok ~= true then return false end
                if current.requiresApproval then return nativeUI.openLoginSettings() end
                return nativeUI.setLaunchAtLogin(current.enabled ~= true)
            end},
    }
    if login.requiresApproval then
        items[#items+1] = {title="Waiting for macOS approval; startup is not active", disabled=true}
    elseif login.ok ~= true then
        items[#items+1] = {title="Startup setting is unavailable", disabled=true}
    end
    items[#items+1] = {title="Open System Settings → General → Login Items…", fn=nativeUI.openLoginSettings}
    items[#items+1] = {title="-"}
    items[#items+1] = {title="Desktop widget controls", disabled=true}
    items[#items+1] = {title=granted and "Desktop control access enabled" or "Desktop control access not enabled",
        checked=granted, disabled=true}
    items[#items+1] = {title=granted and "Manage Desktop Control Access…" or "Enable Desktop Control Access…",
        fn=function()
            -- A prompt is user initiated and applies to this running native app.
            -- Always open the pane; prompting alone is a no-op once allowed.
            if not trusted() then pcall(hs.accessibilityState, true) end
            return nativeUI.openAccessibilitySettings()
        end}
    items[#items+1] = {title="Privacy & Security → " .. pane, disabled=true}
    if not granted then
        items[#items+1] = {title="macOS has not granted access to this running copy.", disabled=true}
    end
    return items
end

return M
