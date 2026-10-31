-- A configurable translucent colour layer between wallpaper and desktop items.
-- Photos rotation continues underneath; this configuration never reads Photos.
local M = {canvases = {}, running = false, generation = 0}
local prefix = "wallpaperVeil."
local presets = {
    {name = "Black", color = {red = 0, green = 0, blue = 0, alpha = 1}},
    {name = "White", color = {red = 1, green = 1, blue = 1, alpha = 1}},
    {name = "Charcoal", color = {red = 0.10, green = 0.11, blue = 0.13, alpha = 1}},
}

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function normalizeColor(color)
    if type(color) ~= "table" then return nil end
    local result = {alpha = 1}
    for _, channel in ipairs({"red", "green", "blue"}) do
        local value = color[channel]
        if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then return nil end
        result[channel] = value
    end
    return result
end

function M.colorHex(color)
    return string.format("#%02X%02X%02X", math.floor(color.red * 255 + 0.5),
        math.floor(color.green * 255 + 0.5), math.floor(color.blue * 255 + 0.5))
end

function M.colorRGB(color)
    return string.format("%d, %d, %d", math.floor(color.red * 255 + 0.5),
        math.floor(color.green * 255 + 0.5), math.floor(color.blue * 255 + 0.5))
end

function M.parseColor(text)
    text = trim(text)
    local hex = text:match("^#?(%x%x%x%x%x%x)$")
    local short = text:match("^#(%x%x%x)$")
    if short then
        hex = short:gsub("%x", function(digit) return digit .. digit end)
    end
    if hex then
        return {red = tonumber(hex:sub(1, 2), 16) / 255,
            green = tonumber(hex:sub(3, 4), 16) / 255,
            blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = 1}
    end
    local rgb = trim(text:lower():match("^rgb%s*%((.-)%)$") or text)
    local red, green, blue = rgb:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
    if not red then red, green, blue = rgb:match("^(%d+)%s+(%d+)%s+(%d+)$") end
    red, green, blue = tonumber(red), tonumber(green), tonumber(blue)
    if red and red <= 255 and green <= 255 and blue <= 255 then
        return {red = red / 255, green = green / 255, blue = blue / 255, alpha = 1}
    end
    return nil, "Use #RRGGBB (for example #FFFFFF) or three RGB integers from 0 to 255 (for example 255, 255, 255)."
end

local function sameColor(left, right)
    return M.colorHex(left) == M.colorHex(right)
end

function M.colorName()
    for _, entry in ipairs(presets) do
        if sameColor(M.color, entry.color) then return entry.name end
    end
    for _, entry in ipairs(M.savedColors) do
        if sameColor(M.color, entry.color) then return entry.name end
    end
    return "Custom " .. M.colorHex(M.color)
end

local function clearCanvases()
    for _, canvas in ipairs(M.canvases) do canvas:delete() end
    M.canvases = {}
end

local function updateMenu()
    if M.menu then
        M.menu:setTitle(M.enabled and "◐ Veil" or "○ Veil")
        M.menu:setTooltip(M.enabled
            and string.format("Wallpaper veil: %s at %d%%", M.colorName(), math.floor(M.opacity * 100 + 0.5))
            or "Wallpaper veil: off")
    end
end

function M.rebuild()
    if not M.running then return end
    clearCanvases()
    if M.enabled then
        for _, screen in ipairs(hs.screen.allScreens()) do
            local canvas = assert(hs.canvas.new(screen:fullFrame()), "Cannot create wallpaper veil")
            canvas[1] = {
                type = "rectangle", action = "fill", fillColor = M.previewColor or M.color,
                frame = {x = 0, y = 0, w = "100%", h = "100%"},
            }
            -- sendToBack uses desktopIcon - 1, above wallpaper and below icons.
            -- No mouse callbacks means the window ignores mouse events.
            canvas:behavior({"canJoinAllSpaces", "stationary", "ignoresCycle"})
            canvas:sendToBack():mouseCallback(nil):clickActivating(false)
                :alpha(M.opacity):show()
            table.insert(M.canvases, canvas)
        end
    end
    updateMenu()
end

function M.setEnabled(enabled)
    M.enabled = not not enabled
    hs.settings.set(prefix .. "enabled", M.enabled)
    M.rebuild()
end

function M.setOpacity(opacity)
    assert(type(opacity) == "number" and opacity >= 0.10 and opacity <= 0.80,
        "Wallpaper veil strength must be between 10% and 80%")
    M.opacity = opacity
    hs.settings.set(prefix .. "opacity", M.opacity)
    for _, canvas in ipairs(M.canvases) do canvas:alpha(M.opacity) end
    updateMenu()
end

function M.setColor(color)
    if M.picker and not M.picker.closing then M.finishPicker(false) end
    if type(color) == "string" then color = M.parseColor(color) end
    M.color = assert(normalizeColor(color), "Invalid RGB colour")
    hs.settings.set(prefix .. "color", M.color)
    for _, canvas in ipairs(M.canvases) do canvas:elementAttribute(1, "fillColor", M.color) end
    updateMenu()
end

local function validName(name)
    local length = utf8.len(name)
    return name ~= "" and length and length <= 80 and not name:find("%c")
end

local function readPalette(value)
    local result = {}
    if type(value) == "table" then
        for _, entry in ipairs(value) do
            if type(entry) == "table" and type(entry.name) == "string"
                and validName(trim(entry.name)) and normalizeColor(entry.color) then
                table.insert(result, {name = entry.name, color = normalizeColor(entry.color)})
            end
        end
    end
    return result
end

function M.saveColor(name)
    name = trim(name)
    if not validName(name) then
        return false, "Choose a name between 1 and 80 characters, without line breaks."
    end
    for _, entry in ipairs(M.savedColors) do
        if entry.name:lower() == name:lower() then
            entry.name, entry.color = name, normalizeColor(M.color)
            hs.settings.set(prefix .. "savedColors", M.savedColors)
            updateMenu()
            return true
        end
    end
    table.insert(M.savedColors, {name = name, color = normalizeColor(M.color)})
    hs.settings.set(prefix .. "savedColors", M.savedColors)
    updateMenu()
    return true
end

function M.removeSavedColor(name)
    if M.picker and M.picker.editName == name and not M.picker.closing then M.finishPicker(false) end
    for index, entry in ipairs(M.savedColors) do
        if entry.name == name then
            table.remove(M.savedColors, index)
            hs.settings.set(prefix .. "savedColors", M.savedColors)
            updateMenu()
            return true
        end
    end
    return false
end

function M.deleteAllColors()
    if #M.savedColors == 0 then return end
    if M.picker and not M.picker.closing then M.finishPicker(false) end
    M.deletedColors = readPalette(M.savedColors)
    hs.settings.set(prefix .. "deletedColors", M.deletedColors)
    M.savedColors = {}
    hs.settings.set(prefix .. "savedColors", M.savedColors)
    updateMenu()
end

function M.undoDeleteAllColors()
    for _, entry in ipairs(M.deletedColors) do
        local exists = false
        for _, current in ipairs(M.savedColors) do
            if current.name:lower() == entry.name:lower() then exists = true; break end
        end
        if not exists then table.insert(M.savedColors, {name = entry.name, color = normalizeColor(entry.color)}) end
    end
    M.deletedColors = {}
    hs.settings.set(prefix .. "savedColors", M.savedColors)
    hs.settings.clear(prefix .. "deletedColors")
    updateMenu()
end

function M.renameSavedColor(oldName, newName)
    newName = trim(newName)
    if not validName(newName) then return false, "Choose a name between 1 and 80 characters, without line breaks." end
    local target
    for _, entry in ipairs(M.savedColors) do
        if entry.name == oldName then target = entry
        elseif entry.name:lower() == newName:lower() then return false, "That name is already used. Choose another name." end
    end
    if not target then return false, "That custom colour no longer exists." end
    if M.picker and M.picker.editName == oldName and not M.picker.closing then M.finishPicker(false) end
    target.name = newName
    hs.settings.set(prefix .. "savedColors", M.savedColors)
    updateMenu()
    return true
end

function M.promptRenameColor(name)
    local value, message = name, "Choose a new name for this custom colour."
    while true do
        local button
        button, value = hs.dialog.textPrompt("Rename custom colour", message, value, "Rename", "Cancel")
        if button ~= "Rename" then return end
        local ok, failure = M.renameSavedColor(name, value)
        if ok then return end
        message = failure
    end
end

local function renderColor(color)
    for _, canvas in ipairs(M.canvases) do canvas:elementAttribute(1, "fillColor", color) end
end

local function swatch(color)
    M.swatches = M.swatches or {}
    local hex = M.colorHex(color)
    if not M.swatches[hex] then
        local canvas = hs.canvas.new({x = 0, y = 0, w = 16, h = 16})
        canvas[1] = {type = "rectangle", action = "strokeAndFill", fillColor = color,
            strokeColor = {white = 0.5, alpha = 0.7}, strokeWidth = 1,
            frame = {x = 1, y = 1, w = 14, h = 14}, roundedRectRadii = {xRadius = 3, yRadius = 3}}
        M.swatches[hex] = canvas:imageFromCanvas()
        canvas:delete()
    end
    return M.swatches[hex]
end

function M.refreshPickerReadout()
    local session = M.picker
    if not session or not session.readout then return end
    local color = session.color
    session.readout:elementAttribute(3, "fillColor", color)
    session.readout:elementAttribute(4, "text", "HEX   " .. M.colorHex(color))
    session.readout:elementAttribute(5, "text", "RGB   " .. M.colorRGB(color))
end

function M.finishPicker(apply, saveName)
    local session = M.picker
    if not session or session.closing then return end
    if apply then
        local latest = normalizeColor(hs.drawing.color.asRGB(hs.dialog.color.color()))
        if latest then session.color = latest end
    end
    session.closing = true
    M.previewColor = nil
    if apply then
        M.setColor(session.color)
        if saveName then assert(M.saveColor(saveName)) end
    else
        renderColor(M.color)
    end
    if session.readout then session.readout:delete(); session.readout = nil end
    -- Restore the shared panel's callback only when its queued close arrives.
    hs.dialog.color.hide()
end

function M.savePickerColor()
    local session = M.picker
    if not session or session.closing then return end
    local latest = normalizeColor(hs.drawing.color.asRGB(hs.dialog.color.color()))
    if latest then session.color = latest; M.refreshPickerReadout() end
    local number, occupied = 1, {}
    for _, entry in ipairs(M.savedColors) do occupied[entry.name:lower()] = true end
    while occupied[("Custom colour " .. number):lower()] do number = number + 1 end
    local value = "Custom colour " .. number
    local message = "Give this custom colour a name. Reusing a saved name updates it.\nHEX " .. M.colorHex(session.color)
        .. "    RGB " .. M.colorRGB(session.color)
    while true do
        local button
        button, value = hs.dialog.textPrompt("Save custom colour", message, value, "Save", "Cancel")
        if button ~= "Save" then return end
        value = trim(value)
        if validName(value) then M.finishPicker(true, value); return end
        message = "Choose a name between 1 and 80 characters, without line breaks."
    end
end

function M.openPicker(editName)
    if M.picker then
        M.picker.afterClose = function() M.openPicker(editName) end
        M.finishPicker(false)
        return
    end
    local color = M.color
    if editName then
        color = nil
        for _, entry in ipairs(M.savedColors) do if entry.name == editName then color = entry.color; break end end
        if not color then return end
    end
    local panel = hs.dialog.color
    local session = {color = normalizeColor(color), editName = editName,
        previousCallback = panel.callback(), previousMode = panel.mode(),
        previousContinuous = panel.continuous(), previousShowsAlpha = panel.showsAlpha(),
        previousApp = hs.application.frontmostApplication()}
    M.picker = session
    M.previewColor = session.color
    renderColor(session.color)
    local frame = hs.screen.mainScreen():frame()
    local readout = assert(hs.canvas.new({x = frame.x + (frame.w - 440) / 2,
        y = frame.y + frame.h - 218, w = 440, h = 196}), "Cannot create colour controls")
    session.readout = readout
    local white, muted = {white = 1}, {white = 0.72}
    local function text(value, x, y, w, h, size, colorValue)
        return {type = "text", text = value, textColor = colorValue or white,
            textSize = size or 14, frame = {x = x, y = y, w = w, h = h}}
    end
    readout:appendElements(
        {type = "rectangle", action = "strokeAndFill", fillColor = {white = 0.11, alpha = 0.98},
            strokeColor = {white = 0.4}, strokeWidth = 1,
            frame = {x = 0.5, y = 0.5, w = 439, h = 195}, roundedRectRadii = {xRadius = 12, yRadius = 12}},
        text(editName and "Edit custom colour" or "New custom colour", 20, 12, 400, 25, 17),
        {type = "rectangle", action = "strokeAndFill", fillColor = session.color,
            strokeColor = {white = 0.6}, strokeWidth = 1, frame = {x = 20, y = 48, w = 62, h = 62},
            roundedRectRadii = {xRadius = 7, yRadius = 7}},
        text("", 100, 51, 320, 25, 17), text("", 100, 81, 320, 25, 16),
        text(editName and "Pick a colour. Save changes to keep, or Cancel to revert."
            or "Pick a colour. Save it, or Apply only for now.", 20, 119, 405, 20, 12, muted)
    )
    for _, button in ipairs({
        {id = editName and "apply" or "save", title = editName and "Save changes" or "Save colour…", x = 20, w = 140, blue = true},
        {id = editName and "save" or "apply", title = editName and "Save as new…" or "Apply only", x = 174, w = 116},
        {id = "cancel", title = "Cancel", x = 304, w = 116},
    }) do
        readout:appendElements(
            {id = button.id, type = "rectangle", action = "fill", trackMouseUp = true,
                fillColor = button.blue and {red = 0.04, green = 0.4, blue = 0.9} or {white = 0.25},
                frame = {x = button.x, y = 150, w = button.w, h = 30}, roundedRectRadii = {xRadius = 6, yRadius = 6}},
            {id = button.id, type = "text", text = button.title, textColor = white, textSize = 14,
                textAlignment = "center", trackMouseUp = true, frame = {x = button.x, y = 155, w = button.w, h = 22}}
        )
    end
    readout:level(hs.canvas.windowLevels.floating):behavior({"canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle"})
        :clickActivating(true):mouseCallback(function(_, event, id)
            if event ~= "mouseUp" then return end
            if id == "apply" then M.finishPicker(true, session.editName)
            elseif id == "save" then M.savePickerColor()
            elseif id == "cancel" then M.finishPicker(false) end
        end):show()
    session.callback = function(value, closed)
        if M.picker ~= session then return end
        if closed then
            if not session.closing then
                M.previewColor = nil
                renderColor(M.color)
                if session.readout then session.readout:delete(); session.readout = nil end
            end
            if panel.callback() == session.callback then
                panel.callback(session.previousCallback)
                panel.mode(session.previousMode)
                panel.continuous(session.previousContinuous)
                panel.showsAlpha(session.previousShowsAlpha)
            end
            M.picker = nil
            if session.afterClose then session.afterClose()
            elseif session.previousApp then
                local front = hs.application.frontmostApplication()
                if front and front:bundleID() == hs.processInfo.bundleID then session.previousApp:activate() end
            end
            return
        end
        if session.closing then return end
        local rgb = hs.drawing.color.asRGB(value)
        rgb = normalizeColor(rgb)
        if rgb then
            session.color, M.previewColor = rgb, rgb
            renderColor(rgb)
            M.refreshPickerReadout()
        end
    end
    panel.callback(session.callback)
    panel.continuous(true)
    panel.showsAlpha(false)
    panel.color(session.color)
    panel.alpha(1)
    panel.mode("wheel")
    M.refreshPickerReadout()
    panel.show()
    hs.focus()
end

function M.promptColor()
    local value = M.colorHex(M.color)
    local message = "Enter #RRGGBB or RGB values from 0 to 255, for example 255, 255, 255. Strength stays separate."
    while true do
        local button
        button, value = hs.dialog.textPrompt("Wallpaper veil colour", message, value, "Apply", "Cancel")
        if button ~= "Apply" then return end
        local color, failure = M.parseColor(value)
        if color then M.setColor(color); return end
        message = failure
    end
end

function M.menuItems()
    local colors = {{title = "New custom colour…", fn = function() M.openPicker() end}}
    local edit, rename, remove = {}, {}, {}
    for _, entry in ipairs(presets) do
        local preset = entry
        table.insert(colors, {title = preset.name, image = swatch(preset.color),
            checked = sameColor(M.color, preset.color), fn = function() M.setColor(preset.color) end})
    end
    local favorites = {}
    if #M.savedColors > 0 then
        for index, entry in ipairs(M.savedColors) do
            local saved = entry
            local label = tostring(index) .. ". " .. saved.name
            table.insert(favorites, {title = label, image = swatch(saved.color),
                checked = sameColor(M.color, saved.color), fn = function() M.setColor(saved.color) end})
            table.insert(edit, {title = label, image = swatch(saved.color), fn = function() M.openPicker(saved.name) end})
            table.insert(rename, {title = label, fn = function() M.promptRenameColor(saved.name) end})
            table.insert(remove, {title = label,
                fn = function() M.removeSavedColor(saved.name) end})
        end
    end
    if #M.savedColors > 0 then
        -- Management is near the top, so bulk actions never require scrolling through favourites.
        table.insert(colors, 2, {title = "Edit custom colour…", menu = edit})
        table.insert(colors, 3, {title = "Rename custom colour…", menu = rename})
        table.insert(colors, 4, {title = "Delete custom colour", menu = remove})
    end
    local managementEnd = #M.savedColors > 0 and 5 or 2
    table.insert(colors, managementEnd, {title = "Delete all custom colours", disabled = #M.savedColors == 0, fn = M.deleteAllColors})
    if #M.deletedColors > 0 then
        table.insert(colors, managementEnd + 1, {title = "Undo delete all custom colours", fn = M.undoDeleteAllColors})
        managementEnd = managementEnd + 1
    end
    table.insert(colors, managementEnd + 1, {title = "-"})
    table.insert(colors, managementEnd + 2, {title = "Standard colours", disabled = true})
    table.insert(colors, {title = "-"})
    table.insert(colors, {title = "Custom colours (" .. #M.savedColors .. ")", disabled = true})
    for _, favorite in ipairs(favorites) do table.insert(colors, favorite) end
    if #favorites == 0 then table.insert(colors, {title = "Choose New custom colour to add one", disabled = true}) end
    table.insert(colors, {title = "-"})
    local visibleColor = M.previewColor or M.color
    table.insert(colors, {title = "HEX  " .. M.colorHex(visibleColor), disabled = true})
    table.insert(colors, {title = "RGB  " .. M.colorRGB(visibleColor), disabled = true})
    table.insert(colors, {title = "Advanced", menu = {{title = "Enter RGB or Hex…", fn = M.promptColor}}})
    local strengths = {}
    for _, percent in ipairs({10, 20, 30, 40, 50, 60, 70, 80}) do
        local opacity = percent / 100
        table.insert(strengths, {title = string.format("%d%%%s", percent, percent == 40 and " (default)" or ""),
            checked = math.abs(M.opacity - opacity) < 0.001, fn = function() M.setOpacity(opacity) end})
    end
    return {
        {title = "Wallpaper Veil", disabled = true},
        {title = "Wallpaper tint enabled", checked = M.enabled, fn = function() M.setEnabled(not M.enabled) end},
        {title = "Colour: " .. M.colorName(), menu = colors},
        {title = "Strength", menu = strengths},
        {title = "-"},
        {title = "Desktop widgets", menu = M.widgets.menuItems()},
        {title = "-"},
        {title = "Refresh displays", fn = M.rebuild},
        {title = "-"},
    }
end

function M.status()
    local status = {
        enabled = M.enabled, running = M.running, opacity = M.opacity,
        launchAtLogin = M.loginItemStatus and M.loginItemStatus().enabled or false,
        hammerspoonIconVisible = hs.menuIcon(),
        color = normalizeColor(M.color), colorHex = M.colorHex(M.color), colorName = M.colorName(),
        savedColorCount = #M.savedColors, undoColorCount = #M.deletedColors,
        colorRGB = M.colorRGB(M.color), pickerOpen = M.picker ~= nil,
        displayCount = #hs.screen.allScreens(), canvases = {},
        widgets = M.widgets and M.widgets.status() or nil,
    }
    for _, canvas in ipairs(M.canvases) do
        local frame = canvas:frame()
        table.insert(status.canvases, {
            showing = canvas:isShowing(), alpha = canvas:alpha(), level = canvas:level(),
            expectedLevel = hs.canvas.windowLevels.desktopIcon - 1,
            clickActivating = canvas:clickActivating(),
            color = normalizeColor(canvas:elementAttribute(1, "fillColor")),
            behaviors = canvas:behaviorAsLabels(),
            frame = {x = frame.x, y = frame.y, w = frame.w, h = frame.h},
        })
    end
    return status
end

function M.stop()
    M.running = false
    M.generation = M.generation + 1
    if M.widgets then M.widgets.stop() end
    if M.picker then
        -- Shutdown must finish synchronously and must not reopen a queued editor.
        local session, panel = M.picker, hs.dialog.color
        session.afterClose = nil
        M.picker, M.previewColor = nil, nil
        if session.readout then session.readout:delete(); session.readout = nil end
        if panel.callback() == session.callback then
            panel.callback(nil)
            panel.hide()
            panel.mode(session.previousMode)
            panel.continuous(session.previousContinuous)
            panel.showsAlpha(session.previousShowsAlpha)
        end
    end
    if M.screenWatcher then M.screenWatcher:stop(); M.screenWatcher = nil end
    if M.wakeWatcher then M.wakeWatcher:stop(); M.wakeWatcher = nil end
    if M.refreshTimer then M.refreshTimer:stop(); M.refreshTimer = nil end
    clearCanvases()
    if M.menu then M.menu:delete(); M.menu = nil end
end

function M.start(widgetPreferences)
    if M.running then return M end
    M.running = true
    M.generation = M.generation + 1
    local token = M.generation
    local ok, failure = xpcall(function()
        M.widgets = require("desktop_widgets")
        M.widgets.start(widgetPreferences)
        M.enabled = hs.settings.get(prefix .. "enabled") ~= false
        local savedOpacity = hs.settings.get(prefix .. "opacity")
        M.opacity = type(savedOpacity) == "number" and savedOpacity >= 0.10
            and savedOpacity <= 0.80 and savedOpacity or 0.40
        M.color = normalizeColor(hs.settings.get(prefix .. "color")) or normalizeColor(presets[3].color)
        M.savedColors = readPalette(hs.settings.get(prefix .. "savedColors"))
        M.deletedColors = readPalette(hs.settings.get(prefix .. "deletedColors"))
        M.menu = assert(hs.menubar.new(true, "WallpaperVeilStandalone"), "Cannot create wallpaper veil menu")
        M.menu:setMenu(M.menuItems)
        M.refreshTimer = hs.timer.delayed.new(0.5, function()
            if M.running and M.generation == token then M.rebuild() end
        end)
        M.screenWatcher = hs.screen.watcher.new(function()
            if M.running and M.generation == token and M.refreshTimer then M.refreshTimer:start() end
        end):start()
        M.wakeWatcher = hs.caffeinate.watcher.new(function(event)
            if not M.running or M.generation ~= token then return end
            if event == hs.caffeinate.watcher.systemDidWake
                or event == hs.caffeinate.watcher.screensDidWake then
                M.refreshTimer:start()
            end
        end):start()
        M.rebuild()

    end, debug.traceback)
    if not ok then
        M.stop()
        error(failure, 0)
    end
    return M
end

return M
