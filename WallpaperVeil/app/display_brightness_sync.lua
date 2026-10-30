-- Wallpaper Veil brightness-sync extension, version 1.0.0.
-- Local only. Native hardware brightness; no gamma, overlays or network calls.
local M = { interval = 0.5, tolerance = 0.02, writeTimeout = 2.0 }
local PREFIX = "wallpaperVeil.brightnessSync."

local function valid(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1
end

local function read(screen)
    local ok, value = pcall(function() return screen:getBrightness() end)
    if ok and valid(value) then return value end
end

local function displays()
    local found = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local ok, uuid, name = pcall(function()
            return screen:getUUID(), screen:name()
        end)
        if ok and type(uuid) == "string" and uuid ~= "" then
            found[#found + 1] = {
                screen = screen, uuid = uuid, name = name or "Display",
                brightness = read(screen),
            }
        end
    end
    table.sort(found, function(a, b) return a.uuid < b.uuid end)
    return found
end

local function pair()
    local source, follower
    for _, display in ipairs(displays()) do
        if display.uuid == M.sourceUUID then source = display end
        if display.uuid == M.followerUUID then follower = display end
    end
    if not M.sourceUUID or not M.followerUUID then
        return nil, nil, "Choose two displays in Brightness sync settings"
    end
    if M.sourceUUID == M.followerUUID then
        return nil, nil, "Choose different source and follower displays"
    end
    if not source or not follower then
        return nil, nil, "Paused: waiting for the selected displays"
    end
    if source.brightness == nil or follower.brightness == nil then
        return nil, nil, "Paused: selected display brightness is unavailable"
    end
    return source, follower
end

local function savePair()
    if M.sourceUUID then hs.settings.set(PREFIX .. "sourceUUID", M.sourceUUID)
    else hs.settings.clear(PREFIX .. "sourceUUID") end
    if M.followerUUID then hs.settings.set(PREFIX .. "followerUUID", M.followerUUID)
    else hs.settings.clear(PREFIX .. "followerUUID") end
end

local function automaticPair()
    -- Never apply a generic allScreens()[1] choice to a Dell or an unknown pair.
    if M.sourceUUID or M.followerUUID then return end
    local studio = {}
    for _, display in ipairs(displays()) do
        if display.name:lower():find("studio display", 1, true)
            and display.brightness ~= nil then
            studio[#studio + 1] = display
        end
    end
    if #studio ~= 2 then return end
    local primary = hs.screen.primaryScreen()
    local ok, primaryUUID = pcall(function() return primary:getUUID() end)
    if ok and studio[2].uuid == primaryUUID then
        studio[1], studio[2] = studio[2], studio[1]
    end
    M.sourceUUID, M.followerUUID = studio[1].uuid, studio[2].uuid
    savePair()
end

function M.setEnabled(enabled, quiet)
    if M.timer then M.timer:stop(); M.timer = nil end
    M.pending = nil
    if enabled then
        automaticPair()
        local source, _, reason = pair()
        if not source then
            M.message = reason
            if not quiet then hs.alert.show(reason) end
            -- Keep an already-enabled setting when a display disconnects.
            -- A new enable request with an invalid pair is not saved as enabled.
            if not quiet then
                M.enabled = false
                hs.settings.set(PREFIX .. "enabled", false)
                return false
            end
        end
    end
    M.enabled = enabled == true
    hs.settings.set(PREFIX .. "enabled", M.enabled)
    if M.enabled then
        M.timer = hs.timer.doEvery(M.interval, function() M.tick() end)
        M.tick()
    else
        M.message = "Off: displays can be adjusted independently"
    end
    return M.enabled
end

local function fail(message)
    M.setEnabled(false, true)
    M.message = message
    hs.alert.show("Brightness sync stopped: " .. message)
end

function M.tick()
    if not M.enabled then return end
    automaticPair()
    local source, follower, reason = pair()
    if not source then
        M.pending = nil
        M.message = reason
        return
    end
    local now = hs.timer.secondsSinceEpoch()
    if M.pending then
        if math.abs(follower.brightness - M.pending.value) <= M.tolerance then
            M.pending = nil
        elseif now >= M.pending.deadline then
            fail("The follower did not confirm the requested hardware brightness")
            return
        else
            M.message = "Waiting for hardware brightness confirmation"
            return
        end
    end
    if math.abs(source.brightness - follower.brightness) <= M.tolerance then
        M.message = string.format("On: following source brightness (%d%%)",
            math.floor(source.brightness * 100 + 0.5))
        return
    end
    local value = source.brightness
    local ok, result = pcall(function() return follower.screen:setBrightness(value) end)
    if not ok or not result then
        fail("The follower rejected the hardware brightness request")
        return
    end
    -- setBrightness returns a screen, not an API-success flag. Confirm later.
    M.pending = { value = value, deadline = now + M.writeTimeout }
    M.message = "Waiting for hardware brightness confirmation"
end

function M.choose(which, uuid)
    M.setEnabled(false, true)
    if which == "source" then
        M.sourceUUID = uuid
        if M.followerUUID == uuid then M.followerUUID = nil end
    else
        M.followerUUID = uuid
        if M.sourceUUID == uuid then M.sourceUUID = nil end
    end
    savePair()
    M.message = "Pair updated; enable Synchronise display brightness to start"
end

function M.settingsMenu()
    automaticPair()
    local sourceItems, followerItems = {}, {}
    for _, display in ipairs(displays()) do
        local uuid = display.uuid
        local label = display.name .. " [" .. uuid:sub(-8) .. "]"
        if display.brightness == nil then
            label = label .. " — brightness unavailable"
        end
        sourceItems[#sourceItems + 1] = {
            title = label, checked = uuid == M.sourceUUID,
            disabled = display.brightness == nil,
            fn = function() M.choose("source", uuid) end,
        }
        followerItems[#followerItems + 1] = {
            title = label, checked = uuid == M.followerUUID,
            disabled = display.brightness == nil,
            fn = function() M.choose("follower", uuid) end,
        }
    end
    if #sourceItems == 0 then
        sourceItems[1] = { title = "No displays detected", disabled = true }
        followerItems[1] = { title = "No displays detected", disabled = true }
    end
    local source, follower, reason = pair()
    local status = M.enabled and (M.message or reason or "On")
        or (reason or M.message or "Off")
    return {
        { title = status, disabled = true },
        { title = "Source display (controls both)", menu = sourceItems },
        { title = "Follower display", menu = followerItems },
        { title = "-" },
        { title = "Changes to the source are copied to the follower", disabled = true },
        { title = "Turn sync off to adjust the follower separately", disabled = true },
    }
end

function M.status()
    return {
        enabled = M.enabled == true, sourceUUID = M.sourceUUID,
        followerUUID = M.followerUUID, message = M.message,
        pending = M.pending ~= nil,
    }
end

function M.stop()
    if M.timer then M.timer:stop(); M.timer = nil end
    M.pending = nil
    M.enabled = false -- Deliberately do not overwrite the persisted preference.
    if M.veil and M.veil.menuItems == M.wrapper then
        M.veil.menuItems = M.originalMenu
        if M.veil.menu then M.veil.menu:setMenu(M.originalMenu) end
    end
    M.veil, M.wrapper, M.originalMenu = nil, nil, nil
end

function M.start(veil)
    assert(type(veil) == "table" and type(veil.menuItems) == "function" and veil.menu,
        "Wallpaper Veil must be running before brightness sync is loaded")
    if M.veil then M.stop() end
    M.veil, M.originalMenu = veil, veil.menuItems
    M.sourceUUID = hs.settings.get(PREFIX .. "sourceUUID")
    M.followerUUID = hs.settings.get(PREFIX .. "followerUUID")
    M.enabled = false
    M.message = "Off: displays can be adjusted independently"
    automaticPair()
    M.wrapper = function(...)
        local items = M.originalMenu(...)
        local insertAt = 2
        for index, item in ipairs(items) do
            if item.title == "Wallpaper tint enabled" then insertAt = index + 1; break end
        end
        table.insert(items, insertAt, {
            title = "Synchronise display brightness", checked = M.enabled == true,
            fn = function() M.setEnabled(not M.enabled) end,
        })
        table.insert(items, insertAt + 1, {
            title = "Brightness sync settings", menu = M.settingsMenu(),
        })
        return items
    end
    veil.menuItems = M.wrapper
    veil.menu:setMenu(M.wrapper)
    if hs.settings.get(PREFIX .. "enabled") == true then M.setEnabled(true, true) end
    return M
end

return M
