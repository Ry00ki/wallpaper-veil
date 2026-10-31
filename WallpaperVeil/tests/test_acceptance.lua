local here = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local create = dofile(here .. "brightness_mock.lua")
local app = os.getenv("WV_TEST_APP_DIR") or "WallpaperVeil/core"
local cases = 0
local function test(name, callback)
    callback(); cases = cases + 1; print("PASS acceptance: " .. name)
end
local function run(options)
    local e = create(options).load(app)
    local result
    e.acceptance.run(function(value) result = value end)
    e.advance(24, function() return result ~= nil end)
    assert(result, "Acceptance failed to produce a bounded report")
    assert(e.activeAcceptanceTimers() == 0, "Acceptance timer leaked")
    return e, result
end

test("source retry must confirm a real change before enabling follower sync", function()
    local e, report = run{source = {ignore = function(_, n) return n == 1 end}}
    assert(report.ok)
    assert(#report.brightness.source.attempts == 2 and report.brightness.source.confirmed)
    local firstEnable
    for _, call in ipairs(e.syncCalls) do if call.enabled then firstEnable = call.time; break end end
    assert(firstEnable and firstEnable >= 0.5)
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("unchanged source is explicitly not a successful follower test", function()
    local e, report = run{source = {ignore = function() return true end}}
    assert(not report.ok and #report.brightness.source.attempts == 3)
    assert(not e.check(report, "source hardware brightness accepts changed target").passed)
    local follower = e.check(report, "hardware follower tracks changed source")
    assert(not follower.passed and follower.detail.skipped and follower.detail.cause == "source-write-unconfirmed")
    for _, call in ipairs(e.syncCalls) do assert(not call.enabled, "Sync enabled before a confirmed source change") end
    assert(e.check(report, "source brightness restored").passed)
end)

test("source success and follower no-op have distinct failure evidence", function()
    local e, report = run{follower = {ignore = function() return true end}}
    assert(not report.ok and e.check(report, "source hardware brightness accepts changed target").passed)
    local follower = e.check(report, "hardware follower tracks changed source")
    assert(not follower.passed and follower.detail.cause == "follower-write-unconfirmed")
    assert(e.check(report, "sync off permits independent brightness").passed)
    assert(e.check(report, "source brightness restored").passed and e.check(report, "follower brightness restored").passed)
end)

test("delayed native writes restore both values before resuming original sync", function()
    local e, report = run{syncEnabled = true, source = {delay = 0.35}, follower = {delay = 0.35, quantum = 1 / 64}}
    assert(report.ok and e.sync.enabled)
    assert(report.brightness.restoreSource.confirmed and report.brightness.restoreFollower.confirmed)
    local resumed = e.syncCalls[#e.syncCalls]
    assert(resumed.enabled and resumed.time >= report.brightness.restoreSource.confirmedAt
        and resumed.time >= report.brightness.restoreFollower.confirmedAt)
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("shutdown cancellation overrides in-flight test requests and reports its limit", function()
    local e = create{source = {delay = 0.5}, follower = {delay = 0.5}}.load(app)
    local report, calls
    calls = 0
    e.acceptance.run(function(value) report = value; calls = calls + 1 end)
    e.advance(0.2); assert(e.acceptance.cancel); e.acceptance.cancel()
    assert(report and not report.ok and report.recoveryRequired)
    assert(e.activeAcceptanceTimers() == 0 and not e.sync.enabled)
    e.advance(10)
    assert(calls == 1 and e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("restoration failure still attempts the other display and leaves sync disabled", function()
    local e, report = run{syncEnabled = true, source = {ignore = function(value, n) return value == 0.5 and n > 1 end}}
    assert(not report.ok and report.recoveryRequired and not e.sync.enabled)
    assert(not e.check(report, "source brightness restored").passed)
    assert(e.check(report, "follower brightness restored").passed)
    assert(not e.check(report, "sync setting restored").passed)
end)

test("cancelling during restoration cannot leave stale callbacks or duplicate results", function()
    local e = create{source = {delay = 0.35}, follower = {delay = 0.35}}.load(app)
    local report, calls = nil, 0
    e.acceptance.run(function(value) report = value; calls = calls + 1 end)
    e.advance(10, function()
        for _, write in ipairs(e.source.writes) do if write.value == 0.5 then return true end end
    end)
    assert(e.acceptance.active and e.acceptance.cancel)
    e.acceptance.cancel()
    assert(report and not report.ok and e.activeAcceptanceTimers() == 0)
    local names = {}
    for _, entry in ipairs(report.checks) do assert(not names[entry.name]); names[entry.name] = true end
    e.advance(20)
    assert(calls == 1 and e.source.value == 0.5 and e.follower.value == 0.5)
end)

test("source drift during follower restoration fails the final pair gate", function()
    local e
    e = create{syncEnabled = true, follower = {ignore = function(value, count)
        if value == 0.5 and count == 3 then
            -- Source restoration has already confirmed. Drift before the next
            -- follower read would be missed by earlier per-display booleans.
            e.schedule(0.05, function() e.source.value = 0.625 end)
        end
        return false
    end}}.load(app)
    local report
    e.acceptance.run(function(value) report = value end)
    e.advance(24, function() return report ~= nil end)
    assert(report and not report.ok and report.recoveryRequired)
    assert(not e.sync.enabled, "Sync resumed despite a stale source restoration result")
    local sourceResult = e.check(report, "source brightness restored")
    assert(not sourceResult.passed and sourceResult.detail.finalObserved == 0.625)
    assert(sourceResult.detail.confirmed and not sourceResult.detail.finalConfirmed)
    assert(e.check(report, "follower brightness restored").passed)
    assert(not e.check(report, "sync setting restored").passed)
    assert(e.activeAcceptanceTimers() == 0)
end)

test("unaligned initial pair is rejected before a large hardware adjustment", function()
    local e, report = run{sourceValue = 0.8, followerValue = 0.2}
    assert(not report.ok and #e.source.writes == 0 and #e.follower.writes == 0)
end)

test("invalid requested delta is rejected before changing settings or hardware", function()
    local e = create{}.load(app)
    local ok = pcall(e.acceptance.run, function() end, {delta = 0.25})
    assert(not ok and #e.source.writes == 0 and #e.follower.writes == 0)
    assert(e.veil.enabled and e.veil.opacity == 0.6)
end)

test("report callback exceptions cannot bypass cleanup or leak timers", function()
    local e = create{}.load(app)
    local calls = 0
    e.acceptance.run(function() calls = calls + 1; error("Injected report failure") end)
    e.advance(24)
    assert(calls == 1 and not e.acceptance.active and e.activeAcceptanceTimers() == 0)
    assert(e.acceptance.lastReport.callbackError:find("Injected report failure", 1, true))
    assert(e.source.value == 0.5 and e.follower.value == 0.5)
end)

print(string.format("Acceptance: %d focused cases passed", cases))
