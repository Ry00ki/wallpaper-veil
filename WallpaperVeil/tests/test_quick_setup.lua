local root = arg[1] or "WallpaperVeil/core"
local setup = assert(loadfile(root .. "/quick_setup.lua"))()
local veil = assert(loadfile(root .. "/wallpaper_veil.lua"))()
local prefs, writes, reject = {}, 0, nil
local screen = {fullFrame = function() return {x=0, y=0, w=600, h=400} end}
hs = {
    settings = {
        get = function(key) return prefs[key] end,
        getKeys = function() local keys = {}; for key in pairs(prefs) do keys[#keys+1] = key end; return keys end,
        set = function(key, value)
            writes = writes + 1
            if key == reject then reject = nil; return false end
            prefs[key] = value
        end,
        clear = function(key) prefs[key] = nil end,
    },
    screen = {allScreens = function() return {screen} end},
    canvas = {new = function()
        local canvas = {}
        for _, name in ipairs({"behavior", "sendToBack", "mouseCallback", "clickActivating", "show", "delete"}) do
            canvas[name] = function(self) return self end
        end
        function canvas:elementAttribute(index, field, value) self[index][field] = value end
        function canvas:alpha(value) self.strength = value; return self end
        return canvas
    end},
    json = {encode = function(model)
        assert(model.color == "#000000" and model.strength == 40 and #model.colors >= 3)
        return "fixture"
    end},
}
assert(setup.shouldOffer(hs.settings, false))
assert(not setup.shouldOffer(hs.settings, true))
prefs["wallpaperVeil.opacity"] = 0.4
assert(not setup.shouldOffer(hs.settings, false))
prefs = {}
assert(not setup.shouldOffer({getKeys=function() error("unavailable") end}, false))

veil.running, veil.enabled, veil.opacity, veil.savedColors = true, false, 0.4, {}
veil.color = assert(veil.parseColor("#000000"))
local perform, closes = nil, 0
local native = {showSetupWizard = function(model, callback)
    assert(model == "fixture")
    perform = callback
    return true
end}
assert(setup.open(native, veil, function() closes = closes + 1 end) == nil)
assert(writes == 1 and prefs["wallpaperVeil.quickSetupSeen"] == true)
assert(not setup.shouldOffer(hs.settings, false) and #veil.canvases == 0)
assert(perform("preview", "#FFFFFF", 60) == nil)
assert(#veil.canvases == 1 and veil.canvases[1].strength == 0.6)
local canvas = veil.canvases[1]
assert(veil.colorHex(canvas[1].fillColor) == "#FFFFFF" and not veil.enabled and writes == 1)
assert(perform("preview", "#000000", 25) == nil)
assert(veil.canvases[1] == canvas and canvas.strength == 0.25)
assert(type(perform("preview", "#FEFEFE", 15)) == "string")
assert(perform("preview", "#FFFFFF", 0) == nil and canvas.strength == 0)
assert(perform("preview", "#FFFFFF", 100) == nil and canvas.strength == 1)
assert(type(perform("preview", "#FFFFFF", -1)) == "string")
assert(type(perform("preview", "#FFFFFF", 101)) == "string")
assert(perform("cancel") == nil and closes == 1 and #veil.canvases == 0 and writes == 1)
assert(not veil.enabled and veil.opacity == 0.4 and veil.colorHex(veil.color) == "#000000")

assert(setup.open(native, veil, function() closes = closes + 1 end) == nil)
assert(perform("preview", "#FFFFFF", 55) == nil)
reject = "wallpaperVeil.opacity"
assert(type(perform("apply", "#FFFFFF", 55)) == "string")
assert(prefs["wallpaperVeil.color"] == nil and prefs["wallpaperVeil.opacity"] == nil and not veil.enabled)
assert(perform("apply", "#FFFFFF", 100) == nil)
assert(veil.enabled and veil.opacity == 1 and not veil.setupPreview and #veil.canvases == 1)
assert(veil.colorHex(prefs["wallpaperVeil.color"]) == "#FFFFFF")
assert(prefs["wallpaperVeil.enabled"] == true and prefs["wallpaperVeil.opacity"] == 1)
assert(perform("done") == nil and closes == 2 and #veil.canvases == 1)
assert(veil.previewSetup("#000000", 20))
assert(veil.cancelSetup())
assert(#veil.canvases == 1 and veil.canvases[1].strength == 1)
assert(veil.colorHex(veil.canvases[1][1].fillColor) == "#FFFFFF")
print("Quick Setup preview, cancel, first-run guard and save recovery passed")
