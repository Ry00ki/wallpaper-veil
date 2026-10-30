local here = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local create = dofile(here .. "brightness_mock.lua")
local app = os.getenv("WV_TEST_APP_DIR") or "WallpaperVeil/app"
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

test("outer app menu remains usable through sync stop and restart", function()
    local e = create{}.load(app)
    local captured = e.veil.menuItems
    e.veil.menuItems = function() local items = captured(); items[#items + 1] = {title = "App item"}; return items end
    e.sync.stop()
    local function count()
        local found = 0
        for _, item in ipairs(e.veil.menuItems()) do
            if item.title == "Synchronise display brightness" then found = found + 1 end
        end
        return found
    end
    assert(count() == 0)
    e.sync.start(e.veil); assert(count() == 1)
    e.sync.stop(); assert(count() == 0)
end)

print(string.format("Brightness sync: %d focused cases passed", cases))
