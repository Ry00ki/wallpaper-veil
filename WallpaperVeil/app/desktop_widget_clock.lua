-- Optional clock-click observer. Accessibility permission is user controlled.
-- Input always passes through; only the actual topmost Apple clock item matches.
local M = {}
local running, generation = false, 0
local onClick, tap, permissionTimer, press
local pendingTimers = {}
local permissionGranted, lastError, lastIdentifier = false, nil, nil
local ALLOWED_OWNERS = {
    ["com.apple.controlcenter"] = true,
    ["com.apple.MenuBarAgent"] = true,
    ["com.apple.systemuiserver"] = true,
}
local CLOCK_IDS = {
    ["com.apple.menuextra.clock"] = true,
    ["com.apple.controlcenter.clock"] = true,
    ["clock"] = true,
}

local function stopTap()
    if tap then pcall(function() tap:stop() end) end
    tap, press = nil, nil
end

local function cancelPending()
    for timer in pairs(pendingTimers) do pcall(function() timer:stop() end) end
    pendingTimers = {}
    press = nil
end

local function tapEnabled()
    if not tap then return false end
    local ok, enabled = pcall(function() return tap:isEnabled() end)
    return ok and enabled == true
end

local function nearMenuBar(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local frame = screen:fullFrame()
        if point.x >= frame.x and point.x < frame.x + frame.w
            and point.y >= frame.y and point.y < frame.y + math.min(80, frame.h) then
            return true
        end
    end
    return false
end

local function clockAt(point)
    -- Deferred outside the event tap. Do not set the system-wide AX timeout:
    -- that would change unrelated Hammerspoon accessibility queries globally.
    local element = hs.axuielement.systemElementAtPosition(point)
    if not element then return nil end
    local application = hs.application.applicationForPID(element:pid())
    local owner = application and application:bundleID()
    if not ALLOWED_OWNERS[owner] then return nil end
    local identifier
    for _ = 1, 5 do
        if not element then break end
        -- Timeout belongs to this element only, not the global AX system.
        if not element:setTimeout(0.02) then return nil end
        local candidate = element:attributeValue("AXIdentifier")
        if CLOCK_IDS[candidate] then identifier = candidate end
        local role = element:attributeValue("AXRole")
        if role == "AXMenuBarItem" then return identifier end
        if role == "AXApplication" or role == "AXMenuBar" then break end
        element = element:attributeValue("AXParent")
    end
    return nil
end

local function finishPress(candidate)
    if not running or candidate.generation ~= generation or press ~= candidate
        or not candidate.released or not candidate.inspected then return end
    press = nil
    if candidate.identifier and onClick then
        lastIdentifier = candidate.identifier
        local token = generation
        local timer
        timer = hs.timer.doAfter(0, function()
            pendingTimers[timer] = nil
            if not running or token ~= generation or not onClick then return end
            local ok = pcall(onClick)
            if not ok then lastError = "The clock click action could not run" end
        end)
        pendingTimers[timer] = true
    end
end

local function scheduleInspection(candidate)
    local timer
    timer = hs.timer.doAfter(0, function()
        pendingTimers[timer] = nil
        if not running or candidate.generation ~= generation or press ~= candidate then return end
        local ok, identifier = pcall(clockAt, candidate.point)
        candidate.inspected = true
        candidate.identifier = ok and identifier or nil
        finishPress(candidate)
    end)
    pendingTimers[timer] = true
end

local function observe(event)
    if not running or not permissionGranted then return false end
    local kind, point = event:getType(), event:location()
    if kind == hs.eventtap.event.types.leftMouseDown then
        cancelPending()
        if nearMenuBar(point) then
            press = {point = {x=point.x,y=point.y}, generation=generation,
                timestamp=event:timestamp()}
            scheduleInspection(press)
        end
    elseif kind == hs.eventtap.event.types.leftMouseUp and press then
        local candidate = press
        local dx, dy = point.x-candidate.point.x, point.y-candidate.point.y
        local elapsed = event:timestamp()-candidate.timestamp
        if dx*dx+dy*dy > 36 or elapsed < 0 or elapsed > 2000000000 or not nearMenuBar(point) then
            cancelPending()
        else
            candidate.released = true
            finishPress(candidate)
        end
    end
    return false
end

local function updatePermission()
    if not running then return end
    local ok, granted = pcall(hs.accessibilityState, false)
    permissionGranted = ok and granted == true
    if not permissionGranted then
        stopTap()
        cancelPending()
        lastError = nil
        return
    end
    if tapEnabled() then return end
    stopTap()
    local created, newTap = pcall(hs.eventtap.new,
        {hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseUp},
        function(event)
            -- Errors must never consume or modify the user's mouse event.
            local succeeded = pcall(observe, event)
            if not succeeded then
                press = nil
                lastError = "The clock click could not be inspected"
            end
            return false
        end)
    tap = created and newTap or nil
    if tap then pcall(function() tap:start() end) end
    if tapEnabled() then lastError = nil
    else lastError = "Clock click monitoring could not start" end
end

function M.start(callback)
    if type(callback) ~= "function" then error("A clock click callback is required") end
    if running then onClick=callback; return M end
    running, onClick, lastError = true, callback, nil
    generation = generation + 1
    updatePermission()
    permissionTimer = hs.timer.doEvery(3, updatePermission)
    return M
end

function M.stop()
    running, onClick = false, nil
    generation = generation + 1
    if permissionTimer then permissionTimer:stop(); permissionTimer=nil end
    stopTap()
    cancelPending()
    return M
end

function M.requestPermission()
    local ok, granted = pcall(hs.accessibilityState, true)
    if running then updatePermission() end
    return ok and granted == true
end

function M.status()
    return {
        running = running,
        watching = running and permissionGranted and tapEnabled(),
        permissionGranted = permissionGranted,
        waitingForPermission = running and not permissionGranted,
        error = lastError,
        lastMatchedIdentifier = lastIdentifier,
    }
end

return M
