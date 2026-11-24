local here = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local create = dofile(here .. "brightness_mock.lua")
local app = os.getenv("WV_TEST_APP_DIR") or "WallpaperVeil/core"
local cases = 0
local function test(name, callback)
    callback(); cases = cases + 1; print("PASS brightness: " .. name)
end

test("silent first follower request is retried and confirmed by read-back", function()
    local e = create{followerValue = 0.25, follower = {ignore = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true)
    assert(e.sync.pending and not e.sync.lastWrite.confirmed)
    e.advance(1.1)
    assert(e.sync.enabled and not e.sync.pending)
    assert(e.follower.value == 0.5 and e.sync.lastWrite.attempts == 2 and e.sync.lastWrite.confirmed)
end)

test("permanent no-op fails after bounded requests without widening tolerance", function()
    local e = create{followerValue = 0.25, follower = {ignore = function() return true end}}.load(app)
    e.sync.setEnabled(true, true); e.advance(3)
    assert(not e.sync.enabled and #e.follower.writes == 3)
    assert(e.sync.lastFailure.cause == "follower-write-unconfirmed")
    assert(e.sync.tolerance == 0.02 and #e.alerts == 1)
end)

test("new source value supersedes an obsolete pending target", function()
    local e = create{followerValue = 0.25, follower = {ignore = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true)
    e.source.value = 0.75; e.advance(1.1)
    assert(e.sync.enabled and e.follower.value == 0.75 and not e.sync.pending)
    assert(e.follower.writes[2].value == 0.75 and e.sync.lastWrite.confirmed)
end)

test("source reverting to the follower clears an obsolete pending request", function()
    local e = create{followerValue = 0.25, follower = {ignore = function() return true end}}.load(app)
    e.sync.setEnabled(true, true)
    e.source.value = 0.25; e.advance(3)
    assert(e.sync.enabled and not e.sync.pending and #e.follower.writes == 1 and #e.alerts == 0)
end)

test("transient native exception retries without treating the screen return as success", function()
    local e = create{followerValue = 0.25, follower = {throw = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true); e.advance(1.1)
    assert(e.sync.enabled and e.sync.lastWrite.confirmed and #e.follower.writes == 2)
end)

test("display disconnect pauses and reconnect resumes without a stale request", function()
    local e = create{followerValue = 0.25, follower = {ignore = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true)
    e.screens = {e.source}; e.advance(0.6)
    assert(e.sync.enabled and not e.sync.pending and #e.alerts == 0)
    e.screens = {e.source, e.follower}; e.advance(1.6)
    assert(e.sync.enabled and e.follower.value == 0.5 and not e.sync.pending)
end)

test("sleep discards an old pending deadline and wake confirms a fresh write", function()
    local e = create{followerValue = 0.25, follower = {ignore = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true)
    local oldTimer = e.sync.timer
    assert(e.sync.pending and e.sync.pending.deadline == 2)
    e.sync.suspend("system")
    assert(e.sync.enabled and e.sync.suspended and not e.sync.pending and not e.sync.timer)
    assert(not oldTimer.active and e.settings["wallpaperVeil.brightnessSync.enabled"] == true)
    e.time = 30 -- Real suspension elapses without dispatching the app's timers.
    oldTimer.callback()
    assert(#e.follower.writes == 1 and not e.sync.pending)
    e.sync.resume("system")
    assert(e.sync.enabled and not e.sync.suspended and e.sync.pending.deadline == 32)
    assert(#e.follower.writes == 2 and not e.sync.lastWrite.confirmed)
    e.advance(30.6)
    assert(e.sync.enabled and not e.sync.pending and e.sync.lastWrite.confirmed)
    assert(e.follower.value == 0.5 and not e.sync.lastFailure and #e.alerts == 0)
end)

test("resumed hardware failure still exhausts the original bounded retry policy", function()
    local e = create{followerValue = 0.25, follower = {ignore = function() return true end}}.load(app)
    e.sync.setEnabled(true, true)
    e.sync.suspend(); e.time = 30; e.sync.resume()
    assert(e.sync.enabled and e.sync.pending.deadline == 32 and #e.alerts == 0)
    e.advance(32.1)
    assert(not e.sync.enabled and #e.follower.writes == 4)
    assert(e.sync.lastFailure.cause == "follower-write-unconfirmed")
    assert(e.sync.lastFailure.write.attempts == 3 and e.sync.tolerance == 0.02)
    assert(e.settings["wallpaperVeil.brightnessSync.enabled"] == false and #e.alerts == 1)
end)

test("overlapping sleep reasons resume once and disabling while asleep stays disabled", function()
    local e = create{}.load(app)
    e.sync.setEnabled(true, true)
    e.sync.suspend("system"); e.sync.suspend("display"); e.sync.suspend("display")
    e.sync.resume("system")
    assert(e.sync.suspended and not e.sync.timer)
    e.sync.resume("display"); local resumedTimer = e.sync.timer
    e.sync.resume("display")
    local active = 0
    for _, timer in ipairs(e.timers) do if timer.active and timer.interval then active = active + 1 end end
    assert(not e.sync.suspended and e.sync.timer == resumedTimer and active == 1)
    e.sync.suspend("display"); e.sync.setEnabled(false, true); e.sync.resume("display")
    assert(not e.sync.enabled and not e.sync.timer and not e.sync.suspended)
    assert(e.settings["wallpaperVeil.brightnessSync.enabled"] == false)
    e.sync.suspend("system"); e.sync.stop(); e.sync.resume("system")
    assert(not e.sync.enabled and not e.sync.timer)
end)

test("wake with a disconnected display retains intent and reconnects without stale work", function()
    local e = create{followerValue = 0.25, follower = {ignore = function(_, n) return n == 1 end}}.load(app)
    e.sync.setEnabled(true, true)
    e.sync.suspend("system"); e.time = 30; e.screens = {e.source}; e.sync.resume("system")
    assert(e.sync.enabled and not e.sync.pending and #e.follower.writes == 1)
    assert(e.sync.message == "Paused: waiting for the selected displays")
    e.screens = {e.source, e.follower}; e.advance(31.1)
    assert(e.sync.enabled and not e.sync.pending and e.sync.lastWrite.confirmed)
    assert(e.follower.value == 0.5 and #e.alerts == 0)
end)

test("outer app menu remains usable through sync stop and restart", function()
    local e = create{}.load(app)
    local captured = e.veil.menuItems
    e.veil.menuItems = function() local items = captured(); items[#items + 1] = {title = "App item"}; return items end
    e.sync.stop()
    local function count()
        local found = 0
        for _, item in ipairs(e.veil.menuItems()) do
            if item.title == "Display brightness" then
                found = found + 1
                assert(item.menu[1].title == "Synchronise display brightness")
            end
        end
        return found
    end
    assert(count() == 0)
    e.sync.start(e.veil); assert(count() == 1)
    e.sync.stop(); assert(count() == 0)
end)

test("brightness controls share one submenu after the wallpaper controls", function()
    local e = create{}.load(app)
    local items = e.veil.menuItems()
    assert(items[1].title == "Wallpaper tint" and items[2].title == "Colour: Black")
    assert(items[3].title == "Strength: 60%" and items[4].title == "-")
    assert(items[5].title == "Display brightness" and items[6].title == "Desktop widgets")
    for _, item in ipairs(items) do
        assert(item.title ~= "Synchronise display brightness" and item.title ~= "Brightness sync settings")
    end
    local toggle = items[5].menu[1]
    assert(not toggle.checked and #e.follower.writes == 0)
    toggle.fn()
    local controls = e.veil.menuItems()[5].menu
    assert(e.sync.enabled and controls[1].checked and controls[2].disabled)
    assert(controls[4].title == "Source display (controls both)" and #controls[4].menu == 2)
    assert(controls[5].title == "Follower display" and #controls[5].menu == 2)
    controls[1].fn()
    assert(not e.sync.enabled)
end)

test("reading unavailable display choices neither selects a pair nor touches preferences", function()
    local e = create{}.load(app)
    e.sync.sourceUUID, e.sync.followerUUID = nil, nil
    e.settings["wallpaperVeil.brightnessSync.sourceUUID"] = nil
    e.settings["wallpaperVeil.brightnessSync.followerUUID"] = nil
    e.follower.unreadable = true
    e.veil.menuItems()
    local choices = e.sync.settingsChoices()
    assert(#choices == 2 and not choices[1].enabled and choices[2].enabled)
    assert(e.sync.sourceUUID == nil and e.sync.followerUUID == nil)
    assert(next(e.settings) == nil and #e.follower.writes == 0)
end)

test("brightness shortcuts adjust the sync source or the active supported display", function()
    local e = create{}.load(app)
    hs.screen.mainScreen = function() return e.follower end
    assert(e.sync.adjustBrightness(1) and e.follower.value == 0.5 + 1 / 16)
    e.sync.setEnabled(true, true)
    assert(e.sync.adjustBrightness(-1) and e.source.value == 0.5 - 1 / 16)
    e.advance(1)
    assert(e.follower.value == e.source.value)
    e.source.value = 1
    assert(e.sync.adjustBrightness(1) and #e.source.writes == 1)
    e.sync.suspend("display")
    assert(not e.sync.adjustBrightness(-1))
    assert(e.source.value == 1)
end)

test("a brightness shortcut checks for a silent hardware write failure", function()
    local e = create{follower={ignore=function()return true end}}.load(app)
    hs.screen.mainScreen = function() return e.follower end
    assert(e.sync.adjustBrightness(1) and #e.alerts == 0)
    e.advance(0.5)
    assert(#e.alerts == 1 and e.alerts[1]:find("confirm", 1, true))
    assert(e.sync.adjustBrightness(1))
    e.sync.suspend("display")
    e.advance(1)
    assert(#e.alerts == 1)
end)

print(string.format("Brightness sync: %d focused cases passed", cases))
