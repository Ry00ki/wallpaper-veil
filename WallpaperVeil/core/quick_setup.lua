local M = {}
local seenKey = "wallpaperVeil.quickSetupSeen"
local prefix = "wallpaperVeil."

function M.shouldOffer(settings, previousRun)
    if previousRun then return false end
    local ok, keys = pcall(settings.getKeys)
    if not ok or type(keys) ~= "table" then return false end
    for _, key in ipairs(keys) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix then return false end
    end
    return true
end

function M.open(nativeUI, veil, onClose)
    if veil.picker then return "Close the custom colour picker to start Quick Setup." end
    local choices = veil.settingsColors()
    local encoded = hs.json.encode({
        colors = choices,
        color = veil.colorHex(veil.color),
        strength = math.floor(veil.opacity * 100 + 0.5),
    })
    if type(encoded) ~= "string" then return "Quick Setup could not read your wallpaper settings." end
    local function perform(action, color, percent)
        if action == "done" then
            if onClose then onClose() end
            return
        end
        if action == "cancel" then
            local ok, result = pcall(veil.cancelSetup)
            if not ok or result ~= true then return "The preview could not be restored. Try Cancel again." end
            if onClose then onClose() end
            return
        end
        if action ~= "preview" and action ~= "apply" then return "That Quick Setup action is unavailable." end
        local available = false
        for _, choice in ipairs(choices) do if color == choice.value then available = true; break end end
        if not available then return "Choose an available colour." end
        local fn = action == "preview" and veil.previewSetup or veil.applySetup
        local ok, result, problem = pcall(fn, color, percent)
        if not ok or result ~= true then
            return problem or (action == "preview" and "The wallpaper preview could not be shown."
                or "The tint could not be saved. Try Apply again.")
        end
    end
    local ok, opened, problem = pcall(nativeUI.showSetupWizard, encoded, perform)
    if not ok or opened ~= true then return problem or "Quick Setup could not be opened." end
    -- Remember offering it even if the user cancels. Preview changes themselves
    -- never write preferences, and existing users can always open it manually.
    pcall(hs.settings.set, seenKey, true)
end

return M
