-- Bounded active acceptance. Confirm hardware writes; report restoration failures.
local M = {}

local function valid(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1
end

local function read(screen)
    local ok, value = pcall(function() return screen:getBrightness() end)
    if ok and valid(value) then return value end
    return nil, ok and "Brightness unavailable" or tostring(value)
end

function M.run(done, options)
    assert(type(done) == "function", "Acceptance needs a completion callback")
    assert(not M.active, "An acceptance transaction is already active")
    options = options or {}
    local veil, sync = assert(wallpaperVeil), assert(displayBrightnessSync)
    local config = {
        delta = options.delta or 0.0625,
        tolerance = options.tolerance or sync.tolerance or 0.02,
        poll = options.pollInterval or 0.1,
        retry = options.retryInterval or 0.5,
        attempts = options.maxWriteAttempts or 3,
        writeTimeout = options.writeTimeout or 2.5,
        followerTimeout = options.followerTimeout or ((sync.writeTimeout or 2) + (sync.interval or 0.5) * 2),
        testTimeout = options.testTimeout or 12,
    }
    assert(valid(config.delta) and config.delta <= 0.0625, "Acceptance delta must be at most 0.0625")
    assert(valid(config.tolerance) and config.tolerance > 0 and config.tolerance <= 0.02,
        "Acceptance tolerance must be positive and no greater than 0.02")
    assert(config.delta > 2 * config.tolerance, "Delta must exceed twice the read-back tolerance")
    assert(config.poll >= 0.05 and config.poll <= 0.5, "Poll interval must be 0.05..0.5 seconds")
    assert(config.retry >= config.poll and config.retry <= 1, "Retry interval must be bounded")
    assert(config.attempts >= 1 and config.attempts <= 3 and config.attempts % 1 == 0,
        "At most three requests are allowed per write phase")
    assert(config.writeTimeout > config.retry and config.writeTimeout <= 5, "Write timeout must be bounded")
    assert(config.followerTimeout > 0 and config.followerTimeout <= 5, "Follower timeout must be bounded")
    assert(config.testTimeout > 0 and config.testTimeout <= 20, "Test timeout must be bounded")

    local report = {schema = 2, observedAtUTC = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        checks = {}, brightness = {}, configuration = config,
        limitations = {"Sleep/wake and visual feel require normal user testing.",
            "Native brightness requests do not return hardware success; only subsequent reads confirm them."}}
    local old = {enabled = veil.enabled, opacity = veil.opacity, color = veil.color,
        syncEnabled = sync.enabled == true}
    local source, follower, sourceBrightness, followerBrightness
    local hardwareTouched = false
    local phase, generation = "testing", 1
    local restoreErrors = {}
    local checkByName = {}
    local finish, complete
    M.active, M.timers = true, {}

    local function now() return hs.timer.secondsSinceEpoch() end
    local function check(name, passed, detail)
        local entry = checkByName[name]
        if not entry then
            entry = {name = name}
            checkByName[name] = entry
            report.checks[#report.checks + 1] = entry
        end
        entry.passed, entry.detail = passed == true, detail
    end
    local function cancelTimers()
        for _, timer in ipairs(M.timers) do pcall(function() timer:stop() end) end
        M.timers = {}
    end
    local function later(seconds, callback)
        local epoch = generation
        local timer = hs.timer.doAfter(seconds, function()
            if phase == "complete" or generation ~= epoch then return end
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then finish(err, phase == "restoring") end
        end)
        M.timers[#M.timers + 1] = timer
        return timer
    end
    local function restoreCall(name, fn)
        local ok, err = pcall(fn)
        if not ok then restoreErrors[#restoreErrors + 1] = name .. ": " .. tostring(err) end
        return ok
    end
    local function request(screen, state)
        local ok, value = pcall(function() return screen:setBrightness(state.target) end)
        state.attempts[#state.attempts + 1] = {
            elapsed = now() - state.started,
            returned = ok and value ~= nil and value ~= false,
            error = not ok and tostring(value) or nil,
        }
        state.nextRetry = now() + config.retry
    end
    local function writeAndConfirm(role, screen, target, callback, changedFrom, synchronous)
        local state = {role = role, target = target, started = now(), attempts = {}, reads = {}, confirmed = false}
        local forceRestore = hardwareTouched and role:sub(1, 8) == "restore-"
        local function observe()
            state.observed, state.readError = read(screen)
            state.reads[#state.reads + 1] = {elapsed = now() - state.started,
                value = state.observed, error = state.readError}
        end
        local function confirmed(value)
            return valid(value) and math.abs(value - target) <= config.tolerance
                and (changedFrom == nil or math.abs(value - changedFrom) > config.tolerance)
        end
        if synchronous then
            -- Shutdown cannot wait on another timer. Attempt both roles and
            -- report any unconfirmed read-back instead of promising restoration.
            state.synchronous = true
            if forceRestore then request(screen, state) end
            for _ = 1, config.attempts do
                observe()
                if confirmed(state.observed) then break end
                if #state.attempts < config.attempts then request(screen, state) end
            end
            observe()
            state.confirmed = confirmed(state.observed)
            state.confirmedAt = state.confirmed and now() or nil
            state.cause = not state.confirmed and role .. "-write-unconfirmed" or nil
            callback(state.confirmed, state)
            return
        end
        local deadline = state.started + config.writeTimeout
        local function poll()
            if forceRestore and #state.attempts == 0 then
                -- Override a possibly in-flight test request even if today's
                -- read is still the original value. A no-op read is not proof
                -- that an earlier asynchronous request cannot arrive later.
                request(screen, state)
                later(config.poll, poll)
                return
            end
            observe()
            if confirmed(state.observed) then
                state.confirmed = true
                state.confirmedAt = now()
                callback(true, state)
            elseif now() >= deadline then
                state.cause = role .. "-write-unconfirmed"
                callback(false, state)
            else
                if #state.attempts < config.attempts and
                    (state.nextRetry == nil or now() >= state.nextRetry) then request(screen, state) end
                later(config.poll, poll)
            end
        end
        poll()
    end

    complete = function(sourceRestored, followerRestored)
        -- The source may have drifted while follower restoration was waiting.
        -- Check the current pair together before trusting earlier phase results
        -- or allowing sync to copy a changed source over the restored follower.
        local final = {checkedAt = now()}
        if source and sourceBrightness ~= nil then
            local value, err = read(source)
            local matches = valid(value) and math.abs(value - sourceBrightness) <= config.tolerance
            local detail = report.brightness.restoreSource or {target = sourceBrightness}
            detail.finalObserved, detail.finalReadError, detail.finalConfirmed = value, err, matches
            report.brightness.restoreSource = detail
            final.source, final.sourceReadError, final.sourceMatchesInitial = value, err, matches
            sourceRestored = sourceRestored and matches
            check("source brightness restored", sourceRestored, detail)
        end
        if follower and followerBrightness ~= nil then
            local value, err = read(follower)
            local matches = valid(value) and math.abs(value - followerBrightness) <= config.tolerance
            local detail = report.brightness.restoreFollower or {target = followerBrightness}
            detail.finalObserved, detail.finalReadError, detail.finalConfirmed = value, err, matches
            report.brightness.restoreFollower = detail
            final.follower, final.followerReadError, final.followerMatchesInitial = value, err, matches
            followerRestored = followerRestored and matches
            check("follower brightness restored", followerRestored, detail)
        end
        report.brightness.finalRestoration = final
        -- Never restart sync while restoration writes are still unconfirmed.
        if sourceRestored and followerRestored then
            restoreCall("sync setting", function() sync.setEnabled(old.syncEnabled, true) end)
        else
            report.recoveryRequired = true
        end
        check("restoration calls completed", #restoreErrors == 0, restoreErrors)
        check("tint settings restored", veil.enabled == old.enabled
            and math.abs(veil.opacity - old.opacity) < 0.0001
            and veil.colorHex(veil.color) == veil.colorHex(old.color))
        check("sync setting restored", sync.enabled == old.syncEnabled)
        report.accessibilityGranted = hs.accessibilityState(false)
        report.widgets = veil.widgets and veil.widgets.status() or nil
        report.ok = true
        for _, entry in ipairs(report.checks) do if not entry.passed then report.ok = false end end
        phase = "complete"
        cancelTimers()
        M.active, M.cancel = false, nil
        -- A reporting failure must not bypass cleanup or invoke done twice.
        local ok, err = pcall(done, report)
        if not ok then report.callbackError = tostring(err) end
        M.lastReport = report
    end

    finish = function(reason, synchronous)
        if phase == "complete" then return end
        if phase == "restoring" and not synchronous then return end
        phase = "restoring"
        generation = generation + 1
        cancelTimers()
        if reason then check("test execution", false, tostring(reason)) end
        if synchronous and hardwareTouched then report.recoveryRequired = true end
        restoreCall("disable sync", function() sync.setEnabled(false, true) end)
        restoreCall("tint colour", function() veil.setColor(old.color) end)
        restoreCall("tint opacity", function() veil.setOpacity(old.opacity) end)
        restoreCall("tint enabled", function() veil.setEnabled(old.enabled) end)
        local function restoreFollower(sourceRestored)
            if not follower or followerBrightness == nil then complete(sourceRestored, true); return end
            writeAndConfirm("restore-follower", follower, followerBrightness, function(passed, detail)
                report.brightness.restoreFollower = detail
                check("follower brightness restored", passed, detail)
                complete(sourceRestored, passed)
            end, nil, synchronous)
        end
        if not source or sourceBrightness == nil then restoreFollower(true); return end
        writeAndConfirm("restore-source", source, sourceBrightness, function(passed, detail)
            report.brightness.restoreSource = detail
            check("source brightness restored", passed, detail)
            restoreFollower(passed)
        end, nil, synchronous)
    end
    M.cancel = function() finish("Acceptance cancelled; synchronous restoration requested", true) end

    local function independent(sourceExpected)
        if phase ~= "testing" then return end
        sync.setEnabled(false, true)
        -- Returning the follower to its original value proves independence
        -- without adding another excursion beyond the bounded source test.
        writeAndConfirm("independent-follower", follower, followerBrightness, function(passed, detail)
            report.brightness.independent = detail
            later((sync.interval or 0.5) * 2 + config.poll, function()
                local a, b = read(source), read(follower)
                check("sync off permits independent brightness", passed and valid(a) and valid(b)
                    and math.abs(a - sourceExpected) <= config.tolerance
                    and math.abs(b - followerBrightness) <= config.tolerance
                    and math.abs(a - b) > config.tolerance,
                    {source = a, follower = b, write = detail})
                finish()
            end)
        end)
    end
    local function follow(sourceExpected)
        local enabled = sync.setEnabled(true, true)
        local deadline = now() + config.followerTimeout
        local function poll()
            local a, b = read(source), read(follower)
            if not valid(a) or math.abs(a - sourceExpected) > config.tolerance then
                check("hardware follower tracks changed source", false,
                    {cause = "source-changed-during-follow", source = a, expectedSource = sourceExpected})
                finish("Source read-back changed during follower confirmation")
            elseif valid(b) and math.abs(b - a) <= config.tolerance then
                check("hardware follower tracks changed source", true,
                    {source = a, follower = b, sync = sync.status()})
                independent(sourceExpected)
            elseif not enabled or not sync.enabled or now() >= deadline then
                check("hardware follower tracks changed source", false,
                    {cause = "follower-write-unconfirmed", source = a, follower = b, sync = sync.status()})
                independent(sourceExpected)
            else later(config.poll, poll) end
        end
        poll()
    end

    local ok, err = xpcall(function()
        veil.setEnabled(false)
        check("tint disabled removes canvases", #veil.canvases == 0)
        veil.setEnabled(true)
        check("tint enabled covers displays", #veil.canvases == #hs.screen.allScreens())
        local opacity = old.opacity >= 0.75 and old.opacity - 0.05 or old.opacity + 0.05
        veil.setOpacity(opacity)
        local opacityMatches = true
        for _, canvas in ipairs(veil.canvases) do
            if math.abs(canvas:alpha() - opacity) > 0.0001 then opacityMatches = false end
        end
        check("opacity updates all canvases", opacityMatches)
        veil.setColor("#101820")
        check("colour setter", veil.colorHex(veil.color) == "#101820")
        veil.setColor(old.color); veil.setOpacity(old.opacity); veil.setEnabled(old.enabled)
        local items, quitCount, noEngineToggle = veil.menuItems(), 0, true
        for _, item in ipairs(items) do
            if item.title == "Quit Wallpaper Veil" then quitCount = quitCount + 1 end
            if item.title:find("Hammerspoon", 1, true) or item.title == "Show troubleshooting menu" then
                noEngineToggle = false
            end
        end
        check("standalone quit action present once", quitCount == 1)
        check("About Wallpaper Veil is the final item", items[#items].title == "About Wallpaper Veil")
        check("standalone menu has no engine icon toggle", noEngineToggle)
        sync.setEnabled(false, true)
        for _, screen in ipairs(hs.screen.allScreens()) do
            if screen:getUUID() == sync.sourceUUID then source = screen end
            if screen:getUUID() == sync.followerUUID then follower = screen end
        end
        assert(source and follower and source ~= follower, "No distinct selected brightness pair")
        sourceBrightness = assert(read(source), "Source brightness unavailable")
        followerBrightness = assert(read(follower), "Follower brightness unavailable")
        assert(math.abs(sourceBrightness - followerBrightness) <= config.tolerance,
            "Align the selected pair before the bounded hardware test; no large follower adjustment was attempted")
        local low = math.max(0, sourceBrightness - config.delta, followerBrightness - config.delta)
        local high = math.min(1, sourceBrightness + config.delta, followerBrightness + config.delta)
        local target = high - sourceBrightness >= sourceBrightness - low and high or low
        assert(math.abs(target - sourceBrightness) > config.tolerance
            and math.abs(target - followerBrightness) > config.tolerance,
            "No sufficiently distinct bounded hardware target is available")
        hardwareTouched = true
        writeAndConfirm("source", source, target, function(passed, detail)
            report.brightness.source = detail
            check("source hardware brightness accepts changed target", passed, detail)
            if passed then
                follow(detail.observed)
            else
                check("hardware follower tracks changed source", false,
                    {skipped = true, cause = "source-write-unconfirmed"})
                finish("Source request was not confirmed; follower behavior was not tested")
            end
        end, sourceBrightness)
    end, debug.traceback)
    if not ok then finish(err) end
    if phase == "testing" then
        later(config.testTimeout, function() finish("Acceptance timed out; restoration requested") end)
    end
    return report
end

return M
