-- Wallpaper Veil runtime inspection. Load only after the app-owned init completes.
-- No settings, menu callbacks, hardware changes, login changes or app reloads.
-- Login inspection may run the bundled read-only status command.
-- Usage: local p = dofile('/private/tmp/wallpaper-veil-runtime-probe.lua')
-- local report = p.collect({expectedBundleID='...', expectedModuleRoot='...'})
-- The caller may serialize report with hs.json.encode(report, true).
local Probe = {}

local function clean(value, seen, depth)
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' or kind == 'string' then return value end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
        return value
    end
    if kind ~= 'table' then return '<' .. kind .. '>' end
    seen, depth = seen or {}, depth or 0
    if seen[value] then return '<cycle>' end
    if depth > 12 then return '<depth limit>' end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        if type(key) == 'number' or type(key) == 'string' then
            result[key] = clean(item, seen, depth + 1)
        end
    end
    seen[value] = nil
    return result
end

local function attempt(fn)
    local ok, result = pcall(fn)
    if ok then return {ok = true, value = clean(result)} end
    return {ok = false, error = tostring(result)}
end

local function method(object, name)
    return attempt(function()
        if not object then error('object absent') end
        local fn = object[name]
        if type(fn) ~= 'function' then error('method unavailable: ' .. name) end
        return fn(object)
    end)
end

local function functionInfo(fn)
    if type(fn) ~= 'function' then return nil end
    local info = debug.getinfo(fn, 'S')
    return {source = info.source, firstLine = info.linedefined,
        lastLine = info.lastlinedefined, kind = info.what}
end

local function status(module)
    if type(module) ~= 'table' or type(module.status) ~= 'function' then
        return {ok = false, error = 'loaded status() unavailable'}
    end
    return attempt(module.status)
end

local function scopedSettings()
    local result = {}
    for _, key in ipairs(hs.settings.getKeys()) do
        if key:sub(1, #'wallpaperVeil.') == 'wallpaperVeil.' then
            result[key] = clean(hs.settings.get(key))
        end
    end
    return result
end

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    for key, item in pairs(left) do if not same(item, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function objectState(object)
    if object == nil then return {present = false} end
    return {present = true, running = method(object, 'running'),
        enabled = method(object, 'isEnabled')}
end

local function namedUpvalues(fn, names)
    local result = {}
    if type(fn) ~= 'function' then return result end
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if names[name] then result[name] = value end
    end
    return result
end

local function menuTree(items)
    local result = {}
    for _, item in ipairs(items) do
        local node = {title = item.title, checked = item.checked,
            disabled = item.disabled, hasAction = type(item.fn) == 'function'}
        if type(item.menu) == 'table' then node.children = menuTree(item.menu)
        elseif item.menu ~= nil then node.submenuType = type(item.menu) end
        result[#result + 1] = node
    end
    return result
end

function Probe.collect(options)
    options = options or {}
    local expectedRoot = options.expectedModuleRoot and options.expectedModuleRoot:gsub('/+$', '')
    local report = {schema = 1, mode = 'read-only runtime inspection',
        observedAtUTC = os.date('!%Y-%m-%dT%H:%M:%SZ'), checks = {}}
    local before = scopedSettings()
    local process = hs.processInfo or {}
    report.identity = {}
    for _, key in ipairs({'processID', 'processName', 'bundleID', 'bundlePath',
        'resourcePath', 'executablePath', 'version', 'buildVersion'}) do
        report.identity[key] = clean(process[key])
    end
    report.identity.settingsBundleID = hs.settings.bundleID
    report.paths = {configdir = hs.configdir, packagePath = package.path,
        packageCPath = package.cpath, cwd = attempt(hs.fs.currentDir)}
    report.application = {accessibilityGranted = attempt(function() return hs.accessibilityState(false) end),
        launchAtLogin = attempt(function()
            local veil = rawget(_G, "wallpaperVeil")
            return veil and veil.loginItemStatus and veil.loginItemStatus().enabled or false
        end),
        dockIconVisible = attempt(function() return hs.dockIcon() end),
        engineMenuIconVisible = attempt(function() return hs.menuIcon() end),
        crashUploads = attempt(function() return hs.uploadCrashData() end)}

    local veil = rawget(_G, 'wallpaperVeil') or package.loaded.wallpaper_veil
    local sync = rawget(_G, 'displayBrightnessSync') or package.loaded.display_brightness_sync
    local widgets = package.loaded.desktop_widgets
    local clock = package.loaded.desktop_widget_clock
    report.modules = {}
    local moduleNames = {'wallpaper_veil', 'display_brightness_sync', 'desktop_widgets',
        'desktop_widget_clock', 'desktop_widget_panel'}
    local sourcesUnderRoot = true
    for _, name in ipairs(moduleNames) do
        local module = package.loaded[name]
        local entry = {loaded = type(module) == 'table', functions = {}}
        if type(module) == 'table' then
            for _, key in ipairs({'start', 'stop', 'status', 'menuItems', 'tick', 'snapshot'}) do
                entry.functions[key] = functionInfo(module[key])
            end
            if expectedRoot then
                local hasLuaSource = false
                for _, info in pairs(entry.functions) do
                    local source = info.source or ''
                    if source:sub(1, 1) == '@' then
                        hasLuaSource = true
                        source = source:sub(2)
                        if source:sub(1, #expectedRoot + 1) ~= expectedRoot .. '/' then
                            sourcesUnderRoot = false
                        end
                    end
                end
                if not hasLuaSource then sourcesUnderRoot = false end
            end
        elseif expectedRoot then sourcesUnderRoot = false end
        entry.searchPathCandidate = attempt(function() return package.searchpath(name, package.path) end)
        report.modules[name] = entry
    end
    report.states = {veil = status(veil), sync = status(sync), widgets = status(widgets), clock = status(clock)}
    report.persistedSettings = before
    report.userValues = veil and clean({enabled = veil.enabled, opacity = veil.opacity,
        color = veil.color, savedColors = veil.savedColors, deletedColors = veil.deletedColors,
        previewActive = veil.previewColor ~= nil, pickerOpen = veil.picker ~= nil}) or nil
    report.timers = {brightnessSync = objectState(sync and sync.timer),
        deferredDisplayRefresh = objectState(veil and veil.refreshTimer),
        screenWatcherPresent = veil and veil.screenWatcher ~= nil or false,
        wakeWatcherPresent = veil and veil.wakeWatcher ~= nil or false}
    local widgetUpvalues = namedUpvalues(widgets and widgets.stop,
        {pollTimer = true, clockTimer = true, task = true, repair = true})
    report.timers.widgetPoll = objectState(widgetUpvalues.pollTimer)
    report.timers.widgetClock = objectState(widgetUpvalues.clockTimer)
    report.timers.widgetTaskPresent = widgetUpvalues.task ~= nil
    report.timers.widgetRepairPresent = widgetUpvalues.repair ~= nil
    local clockUpvalues = namedUpvalues(clock and clock.stop,
        {permissionTimer = true, pendingTimers = true, tap = true})
    report.timers.clockPermissionPoll = objectState(clockUpvalues.permissionTimer)
    -- tap lives in stopTap's closure, while pendingTimers lives in cancelPending.
    local clockChildren = namedUpvalues(clock and clock.stop, {stopTap = true, cancelPending = true})
    local tapUpvalues = namedUpvalues(clockChildren.stopTap, {tap = true})
    local pendingUpvalues = namedUpvalues(clockChildren.cancelPending, {pendingTimers = true})
    report.timers.clockEventTap = objectState(tapUpvalues.tap)
    local pendingCount = 0
    for _ in pairs(pendingUpvalues.pendingTimers or {}) do pendingCount = pendingCount + 1 end
    report.timers.clockPendingActions = pendingCount

    report.screens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local entry = {uuid = method(screen, 'getUUID'), name = method(screen, 'name'),
            id = method(screen, 'id'), frame = attempt(function()
                local frame = screen:fullFrame()
                return {x = frame.x, y = frame.y, w = frame.w, h = frame.h}
            end),
            brightness = method(screen, 'getBrightness')}
        local uuid = entry.uuid.value
        entry.selectedSource = sync and uuid == sync.sourceUUID or false
        entry.selectedFollower = sync and uuid == sync.followerUUID or false
        report.screens[#report.screens + 1] = entry
    end
    report.canvasCount = veil and #(veil.canvases or {}) or 0
    report.checks.allApplicationModulesLoaded = true
    for _, name in ipairs(moduleNames) do
        if not report.modules[name].loaded then report.checks.allApplicationModulesLoaded = false end
    end
    report.checks.canvasCountMatchesEnabledState = veil ~= nil
        and report.canvasCount == (veil.enabled and #report.screens or 0)
    report.checks.canvasPropertiesMatch = true
    if report.states.veil.ok then
        for _, canvas in ipairs(report.states.veil.value.canvases or {}) do
            if not canvas.showing or canvas.level ~= canvas.expectedLevel
                or canvas.clickActivating or math.abs(canvas.alpha - veil.opacity) > 0.0001 then
                report.checks.canvasPropertiesMatch = false
            end
        end
    else report.checks.canvasPropertiesMatch = false end
    if options.expectedBundleID then
        report.checks.expectedBundleID = process.bundleID == options.expectedBundleID
        report.checks.isolatedSettingsDomain = hs.settings.bundleID == options.expectedBundleID
    end
    if expectedRoot then report.checks.loadedSourcesUnderExpectedRoot = sourcesUnderRoot end
    report.checks.brightnessTimerMatchesEnabledState = sync ~= nil and
        ((sync.enabled == true and sync.suspended ~= true and
            (report.timers.brightnessSync.running or {}).value == true) or
         ((sync.enabled ~= true or sync.suspended == true) and
            report.timers.brightnessSync.present == false))
    report.checks.suspendedBrightnessHasNoPendingWrite = sync ~= nil and
        (sync.suspended ~= true or sync.pending == nil)
    report.checks.canvasFramesMatchScreens = report.states.veil.ok and true or false
    local unmatched = {}
    for index, screen in ipairs(report.screens) do unmatched[index] = screen.frame.value end
    if report.states.veil.ok then
        for _, canvas in ipairs(report.states.veil.value.canvases or {}) do
            local matched
            for index, frame in pairs(unmatched) do
                local equal = true
                for _, key in ipairs({'x', 'y', 'w', 'h'}) do
                    if not frame or math.abs((canvas.frame[key] or math.huge) - (frame[key] or 0)) > 0.01 then
                        equal = false
                    end
                end
                if equal then matched = index; break end
            end
            if matched then unmatched[matched] = nil
            else report.checks.canvasFramesMatchScreens = false end
        end
        if veil.enabled and next(unmatched) then report.checks.canvasFramesMatchScreens = false end
    end

    -- settingsMenu() can auto-select and persist a pair if both UUIDs are nil.
    -- Refuse that path. Do not invoke any fn callbacks. Menu rendering may warm
    -- an in-memory image cache but does not change settings in the checked path.
    if veil and type(veil.menuItems) == 'function' and (not sync or sync.sourceUUID or sync.followerUUID) then
        report.menu = attempt(function() return menuTree(veil.menuItems()) end)
    else
        report.menu = {ok = false, skipped = true,
            reason = 'Menu unavailable or unselected pair could cause an automatic preference write'}
    end
    if report.menu.ok then
        report.menuRequiredItemCounts = {}
        for _, title in ipairs({'Wallpaper tint enabled', 'Synchronise display brightness',
            'Brightness sync settings', 'Strength', 'Desktop widgets', 'Refresh displays'}) do
            local count = 0
            for _, item in ipairs(report.menu.value) do if item.title == title then count = count + 1 end end
            report.menuRequiredItemCounts[title] = count
        end
        report.checks.requiredMenuItemsPresentOnce = true
        for _, count in pairs(report.menuRequiredItemCounts) do
            if count ~= 1 then report.checks.requiredMenuItemsPresentOnce = false end
        end
    end
    report.checks.scopedSettingsUnchangedDuringProbe = same(before, scopedSettings())
    report.limitations = {
        'No menu action, display brightness change, sleep/wake, Spaces transition or widget visibility change was exercised.',
        'Equal reported brightness values do not prove follower response to a changed source.',
        'Watcher presence is observable; it is not proof its callbacks executed.',
        'Canvas geometry/layer checks do not establish pixel-perfect visual appearance.',
        'Loaded function source proves its Lua origin; searchPathCandidate only describes current resolution.',
        'Current values and display identifiers are private diagnostics; sanitize before publication.'}
    return report
end

return Probe
