local root = arg[1] or "WallpaperVeil/core"
local hotkeys = assert(loadfile(root .. "/brightness_hotkeys.lua"))()
local prefs, bound, unavailable, writes = nil, {}, {}, 0
local now, events = 0, {}
hs = {
    settings = {get = function() return prefs end, set = function(_, value) prefs = value; writes = writes + 1 end},
    keycodes = {map = {[0]="a", [1]="s"}},
    timer = {secondsSinceEpoch = function() return now end},
    alert = {show = function() error("unexpected alert") end},
    hotkey = {new = function(mods, code, pressed, _, repeated)
        local id = table.concat(mods, "+") .. ":" .. code
        local key = {pressed=pressed, repeated=repeated}
        function key:enable()
            if unavailable[id] or bound[id] then return nil end
            bound[id] = self
            return self
        end
        function key:delete() if bound[id] == self then bound[id] = nil end end
        return key
    end},
}

hotkeys.start(function(direction) events[#events+1] = direction; return true end)
assert(not hotkeys.status().enabled and hotkeys.status().upLabel == "Control–Option–Page Up")
assert(hotkeys.status().downLabel == "Control–Option–Page Down" and writes == 0 and next(bound) == nil)
assert(hotkeys.setEnabled(true))
local pressed = assert(bound["ctrl+alt:116"]).pressed
pressed()
bound["ctrl+alt:116"].repeated()
assert(#events == 1 and events[1] == 1)
now = 0.2; bound["ctrl+alt:116"].repeated()
bound["ctrl+alt:121"].pressed()
assert(#events == 3 and events[2] == 1 and events[3] == -1)

assert(hotkeys.pauseRecording(true) and next(bound) == nil)
pressed()
assert(#events == 3)
assert(not hotkeys.setBinding("up", "3:121"))
assert(not hotkeys.setBinding("up", "4:0"))
assert(not hotkeys.setBinding("up", "3:58"))
unavailable["ctrl:0"] = true
assert(not hotkeys.setBinding("up", "1:0"))
assert(prefs.up == "3:116")
assert(hotkeys.setBinding("up", "1:1") and next(bound) == nil)
assert(hotkeys.pauseRecording(false) and bound["ctrl:1"] and bound["ctrl+alt:121"])
assert(not bound["ctrl+alt:116"] and hotkeys.status().upLabel == "Control–S")
assert(hotkeys.setBinding("down", nil) and not bound["ctrl+alt:121"])
assert(hotkeys.setEnabled(false) and next(bound) == nil)
assert(hotkeys.setBinding("up", nil) and not hotkeys.setEnabled(true))
hotkeys.stop()
assert(next(bound) == nil and not hotkeys.status().enabled)
hotkeys.start(function() error("cleared binding must stay disabled") end)
assert(hotkeys.status().upLabel == "" and hotkeys.status().downLabel == "")
print("Brightness hotkey defaults, enable/disable, repeat, capture, conflict and clear passed")
