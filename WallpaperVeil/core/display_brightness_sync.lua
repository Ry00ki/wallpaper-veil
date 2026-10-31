-- Wallpaper Veil brightness-sync extension, version 1.0.0.
-- Local only. Native hardware brightness; no gamma, overlays or network calls.
local M = { interval = 0.5, tolerance = 0.02, writeTimeout = 2.0,
    retryInterval = 0.5, maxWriteAttempts = 3, suspended = false }
local PREFIX = "wallpaperVeil.brightnessSync."
local suspensionReasons = {}

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
        M.lastFailure = nil
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
    if M.enabled and not M.suspended then
        M.timer = hs.timer.doEvery(M.interval, function() M.tick() end)
        M.tick()
    elseif M.enabled then
        M.message = "Paused: waiting for wake"
    else
        M.message = "Off: displays can be adjusted independently"
    end
    return M.enabled
end

-- Lifecycle suspension is separate from the user's saved enabled choice.
-- The application forwards paired system/display sleep notifications here.
function M.suspend(reason)
    reason = reason or "system"
    assert(type(reason) == "string" and reason ~= "", "A suspension reason is required")
    suspensionReasons[reason] = true
    M.suspended = true
    if M.timer then M.timer:stop(); M.timer = nil end
    M.pending = nil
    if M.enabled then M.message = "Paused: waiting for wake" end
    return M
end

function M.resume(reason)
    reason = reason or "system"
    assert(type(reason) == "string" and reason ~= "", "A suspension reason is required")
    suspensionReasons[reason] = nil
    if not M.suspended or next(suspensionReasons) ~= nil then return M end
    M.suspended = false
    -- Wall-clock deadlines from before sleep must never fail a resumed pair.
    -- New writes still have the same bounded attempts and read-back requirement.
    M.pending = nil
    if M.enabled then
        M.timer = hs.timer.doEvery(M.interval, function() M.tick() end)
        M.tick()
    end
    return M
end

local function fail(message, cause)
    local lastWrite = M.lastWrite
    M.setEnabled(false, true)
    M.lastFailure = { cause = cause, message = message, write = lastWrite }
    M.message = message
    hs.alert.show("Brightness sync stopped: " .. message)
end

local function requestFollower(screen, pending, now)
    pending.attempts = pending.attempts + 1
    pending.lastRequestedAt = now
    pending.nextRetry = now + M.retryInterval
    local ok, result = pcall(function() return screen:setBrightness(pending.value) end)
    -- The native API returns a screen even when the hardware write is ignored.
    -- A returned object is only an attempted request; a later read must confirm it.
    pending.requestReturned = ok and result ~= nil and result ~= false
    pending.requestError = not ok and tostring(result)
        or (not pending.requestReturned and "Hardware request returned no screen" or nil)
    M.lastWrite = pending
end

function M.tick()
    if not M.enabled or M.suspended then return end
    automaticPair()
    local source, follower, reason = pair()
    if not source then
        M.pending = nil
        M.message = reason
        return
    end
    local now = hs.timer.secondsSinceEpoch()
    if M.pending and math.abs(source.brightness - M.pending.value) > M.tolerance then
        -- Source changes supersede an unconfirmed older request. Waiting for the
        -- obsolete value could otherwise disable healthy sync at its deadline.
        M.pending.superseded = true
        M.pending = nil
    end
    if math.abs(source.brightness - follower.brightness) <= M.tolerance then
        if M.pending then
            M.pending.confirmed = true
            M.pending.observed = follower.brightness
            M.lastWrite = M.pending
        end
        M.pending = nil
        M.message = string.format("On: following source brightness (%d%%)",
            math.floor(source.brightness * 100 + 0.5))
        return
    end
    if not M.pending then
        M.pending = { value = source.brightness, deadline = now + M.writeTimeout,
            attempts = 0, observed = follower.brightness, confirmed = false }
        requestFollower(follower.screen, M.pending, now)
    else
        M.pending.observed = follower.brightness
        if now >= M.pending.deadline then
            local cause = M.pending.requestError and "follower-request-error" or "follower-write-unconfirmed"
            fail("The follower did not confirm the requested hardware brightness", cause)
            return
        elseif M.pending.attempts < M.maxWriteAttempts and now >= M.pending.nextRetry then
            requestFollower(follower.screen, M.pending, now)
        end
    end
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
        enabled = M.enabled == true, suspended = M.suspended, sourceUUID = M.sourceUUID,
        followerUUID = M.followerUUID, message = M.message,
        pending = M.pending ~= nil, lastWrite = M.lastWrite, lastFailure = M.lastFailure,
    }
end

function M.stop()
    if M.timer then M.timer:stop(); M.timer = nil end
    M.pending = nil
    M.suspended, suspensionReasons = false, {}
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
    local originalMenu = veil.menuItems
    M.veil, M.originalMenu = veil, originalMenu
    M.sourceUUID = hs.settings.get(PREFIX .. "sourceUUID")
    M.followerUUID = hs.settings.get(PREFIX .. "followerUUID")
    M.enabled = false
    M.message = "Off: displays can be adjusted independently"
    automaticPair()
    local wrapper
    wrapper = function(...)
        local items = originalMenu(...)
        -- An outer app menu may retain this closure after stop/restart. Old
        -- generations pass through their captured menu without adding controls.
        if M.wrapper ~= wrapper or M.veil ~= veil then return items end
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
    M.wrapper = wrapper
    veil.menuItems = wrapper
    veil.menu:setMenu(wrapper)
    if hs.settings.get(PREFIX .. "enabled") == true then M.setEnabled(true, true) end
    return M
end

return M
