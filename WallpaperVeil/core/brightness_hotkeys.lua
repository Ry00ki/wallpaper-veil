local M = {}
local key = "wallpaperVeil.brightnessHotkeys"
local directions = {"up", "down"}
local settings, installed, adjust, paused, active, message, generation

local function chord(value)
    if type(value) ~= "string" then return end
    local mask, code = value:match("^(%d+):(%d+)$")
    mask, code = tonumber(mask), tonumber(code)
    if not mask or mask > 15 or mask & 11 == 0 or not code or code > 127 then return end
    if code >= 54 and code <= 63 then return end
    local mods = {}
    for _, item in ipairs({{1, "ctrl"}, {2, "alt"}, {4, "shift"}, {8, "cmd"}}) do
        if mask & item[1] ~= 0 then mods[#mods + 1] = item[2] end
    end
    return string.format("%d:%d", mask, code), mods, code
end

local function label(value)
    local _, mods, code = chord(value)
    if not code then return "" end
    local names = {ctrl = "Control", alt = "Option", shift = "Shift", cmd = "Command"}
    for index, mod in ipairs(mods) do mods[index] = names[mod] end
    local named = {[116] = "Page Up", [121] = "Page Down", [123] = "Left Arrow",
        [124] = "Right Arrow", [125] = "Down Arrow", [126] = "Up Arrow",
        [36] = "Return", [48] = "Tab", [49] = "Space", [51] = "Delete", [53] = "Escape"}
    local mapped = hs.keycodes.map[code]
    mods[#mods + 1] = named[code] or (type(mapped) == "string" and mapped:upper()) or ("Key " .. code)
    return table.concat(mods, "–")
end

local function release()
    generation = (generation or 0) + 1
    for _, hotkey in ipairs(installed or {}) do pcall(hotkey.delete, hotkey) end
    installed, active = {}, false
end

local function register(value, handler, repeated)
    local _, mods, code = chord(value)
    if not code then return end
    local made, item = pcall(function() return hs.hotkey.new(mods, code, handler, nil, repeated) end)
    if not made or not item then return end
    local enabled, result = pcall(item.enable, item)
    if enabled and result then return item end
    pcall(item.delete, item)
end

local function install(config)
    release()
    if paused or not config.enabled then return true end
    local current = generation
    for _, direction in ipairs(directions) do
        local value = config[direction]
        if value then
            local lastRequest = -math.huge
            local function step(isRepeat)
                if generation ~= current or not active or not adjust then return end
                local now = hs.timer.secondsSinceEpoch()
                if isRepeat and now - lastRequest < 0.12 then return end
                lastRequest = now
                local ok, problem = adjust(direction == "up" and 1 or -1)
                if not ok and not isRepeat and problem then hs.alert.show(problem) end
            end
            local item = register(value, function() step(false) end, function() step(true) end)
            if not item then
                release()
                return false, label(value) .. " is unavailable. It may be used by macOS or another app."
            end
            installed[#installed + 1] = item
        end
    end
    active = #installed > 0
    return true
end

local function save(candidate)
    local ok, problem = install(candidate)
    if ok then
        local written, result = pcall(hs.settings.set, key, candidate)
        if written and result ~= false then
            settings, message = candidate, nil
            return true
        end
        problem = "Brightness shortcuts could not be saved. Try again."
    end
    local restored, failure = install(settings)
    message = restored and problem or failure
    return false, message
end

function M.start(callback)
    M.stop()
    adjust, paused = callback, false
    local saved = hs.settings.get(key)
    if saved == nil then
        settings = {enabled = false, up = "3:116", down = "3:121"}
    elseif type(saved) == "table" then
        local up, down = chord(saved.up), chord(saved.down)
        if up == down then down = nil end
        settings = {enabled = saved.enabled == true and (up ~= nil or down ~= nil), up = up, down = down}
    else
        settings = {enabled = false}
    end
    local _, problem = install(settings)
    message = problem
    return M
end

function M.stop()
    release()
    settings, adjust, paused, message = nil, nil, false, nil
end

function M.status()
    local current = settings or {}
    return {enabled = active == true, upLabel = label(current.up), downLabel = label(current.down),
        message = message, recording = paused == true}
end

function M.setEnabled(value)
    if not settings or type(value) ~= "boolean" or paused then return false, "Brightness shortcuts are unavailable." end
    if value and not (settings.up or settings.down) then return false, "Set a brightness shortcut in App settings first." end
    return save({enabled = value, up = settings.up, down = settings.down})
end

function M.setBinding(direction, value)
    if not settings or (direction ~= "up" and direction ~= "down") then
        return false, "That brightness shortcut is unavailable."
    end
    local candidate = {enabled = settings.enabled, up = settings.up, down = settings.down}
    local normalized = chord(value)
    if value ~= nil and not normalized then return false, "Use Control, Option or Command with a key." end
    if normalized and normalized == candidate[direction == "up" and "down" or "up"] then
        return false, "The Up and Down shortcuts need different keys."
    end
    if normalized == candidate[direction] then return true end
    if normalized and (paused or not candidate.enabled) then
        local probe = register(normalized, function() end)
        if not probe then return false, label(normalized) .. " is unavailable. Choose different keys." end
        probe:delete()
    end
    candidate[direction] = normalized
    if not (candidate.up or candidate.down) then candidate.enabled = false end
    return save(candidate)
end

function M.pauseRecording(recording)
    if not settings or type(recording) ~= "boolean" then return false, "Brightness shortcuts are unavailable." end
    if recording == paused then return true end
    paused = recording
    local ok, problem = install(settings)
    message = problem
    return ok, problem
end

function M.menuItem()
    return {title = "Enable brightness hotkeys", checked = active == true, disabled = paused == true,
        fn = function()
            local ok, problem = M.setEnabled(not active)
            if not ok then hs.alert.show(problem) end
        end}
end

return M
