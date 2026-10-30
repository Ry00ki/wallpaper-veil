-- Deterministic native-write/scheduler fixture; no host APIs or physical writes.
local function environment(options)
    options = options or {}
    local env = {time = 0, timers = {}, alerts = {}, settings = {}, sourceCalls = {}, syncCalls = {}}
    function env.schedule(delay, callback, interval, native)
        local timer = {at = env.time + delay, callback = callback, interval = interval,
            active = true, native = native == true}
        function timer:stop() self.active = false end
        function timer:running() return self.active end
        env.timers[#env.timers + 1] = timer
        return timer
    end
    function env.advance(untilTime, predicate)
        for _ = 1, 10000 do
            if predicate and predicate() then return end
            local nextTimer
            for _, timer in ipairs(env.timers) do
                if timer.active and timer.at <= untilTime and
                    (not nextTimer or timer.at < nextTimer.at) then nextTimer = timer end
            end
            if not nextTimer then env.time = untilTime; return end
            env.time = nextTimer.at
            if nextTimer.interval then nextTimer.at = env.time + nextTimer.interval
            else nextTimer.active = false end
            nextTimer.callback()
        end
        error("Fixture event loop exceeded its bound")
    end
    local function screen(uuid, value, behavior)
        behavior = behavior or {}
        local object = {uuid = uuid, value = value, writes = {}, behavior = behavior}
        function object:getUUID() return self.uuid end
        function object:name() return "Studio Display" end
        function object:getBrightness()
            if self.unreadable then return nil end
            return self.value
        end
        function object:setBrightness(target)
            self.writes[#self.writes + 1] = {value = target, time = env.time}
            local count = #self.writes
            if behavior.throw and behavior.throw(target, count) then error("Injected native request exception") end
            if behavior.ignore and behavior.ignore(target, count) then return self end
            local result = target
            if behavior.quantum then result = math.floor(target / behavior.quantum + 0.5) * behavior.quantum end
            if behavior.delay and behavior.delay > 0 then
                env.schedule(behavior.delay, function() self.value = result end, nil, true)
            else self.value = result end
            return self -- Real hs.screen returns itself even for a silent no-op.
        end
        return object
    end
    env.source = screen("source", options.sourceValue or 0.5, options.source)
    env.follower = screen("follower", options.followerValue or 0.5, options.follower)
    env.screens = {env.source, env.follower}
    env.settings["wallpaperVeil.brightnessSync.sourceUUID"] = "source"
    env.settings["wallpaperVeil.brightnessSync.followerUUID"] = "follower"
    hs = {
        timer = {
            secondsSinceEpoch = function() return env.time end,
            doAfter = function(delay, callback) return env.schedule(delay, callback) end,
            doEvery = function(delay, callback) return env.schedule(delay, callback, delay) end,
        },
        settings = {
            get = function(key) return env.settings[key] end,
            set = function(key, value) env.settings[key] = value end,
            clear = function(key) env.settings[key] = nil end,
        },
        screen = {allScreens = function() return env.screens end,
            primaryScreen = function() return env.source end},
        alert = {show = function(text) env.alerts[#env.alerts + 1] = text end},
        accessibilityState = function() return false end,
    }
    local veil = {enabled = true, opacity = 0.6, color = {red = 0, green = 0, blue = 0, alpha = 1},
        menu = {}, canvases = {}, widgets = {status = function() return {tracking = false} end}}
    function veil.menu:setMenu(callback) self.callback = callback end
    function veil.setEnabled(value)
        veil.enabled = value
        veil.canvases = {}
        if value then
            for _ in ipairs(env.screens) do
                veil.canvases[#veil.canvases + 1] = {alpha = function() return veil.opacity end}
            end
        end
    end
    function veil.setOpacity(value) veil.opacity = value end
    function veil.setColor(value)
        if type(value) == "string" then
            local hex = value:gsub("#", "")
            value = {red = tonumber(hex:sub(1, 2), 16) / 255,
                green = tonumber(hex:sub(3, 4), 16) / 255,
                blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = 1}
        end
        veil.color = value
    end
    function veil.colorHex(value)
        return string.format("#%02X%02X%02X", math.floor(value.red * 255 + 0.5),
            math.floor(value.green * 255 + 0.5), math.floor(value.blue * 255 + 0.5))
    end
    function veil.menuItems()
        return {{title = "Wallpaper tint enabled"}, {title = "Quit Wallpaper Veil"},
            {title = "About Wallpaper Veil"}}
    end
    veil.setEnabled(true)
    env.veil = veil
    function env.load(app)
        env.sync = assert(loadfile(app .. "/display_brightness_sync.lua"))().start(veil)
        local original = env.sync.setEnabled
        env.sync.setEnabled = function(value, quiet)
            env.syncCalls[#env.syncCalls + 1] = {enabled = value, time = env.time}
            return original(value, quiet)
        end
        if options.syncEnabled then env.sync.setEnabled(true, true) end
        wallpaperVeil, displayBrightnessSync = veil, env.sync
        env.acceptance = assert(loadfile(app .. "/acceptance.lua"))()
        return env
    end
    function env.check(report, name)
        for _, entry in ipairs(report.checks) do if entry.name == name then return entry end end
        error("Missing result: " .. name)
    end
    function env.activeAcceptanceTimers()
        local count = 0
        for _, timer in ipairs(env.timers) do
            if timer.active and not timer.interval and not timer.native then count = count + 1 end
        end
        return count
    end
    return env
end
return environment
