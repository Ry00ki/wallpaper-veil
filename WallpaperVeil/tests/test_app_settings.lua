-- Pure settings-window state/action regressions. No native app, OS preferences,
-- display writes or actual permission changes are used by these fixtures.
local root = arg[1] or "WallpaperVeil/core"
local settings = assert(loadfile(root .. "/app_settings.lua"))()
local assertions = 0
local function check(value, message)
    assertions=assertions+1
    assert(value, message)
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local result={};for key,item in pairs(value) do result[key]=clone(item) end;return result
end
local function fixture()
    local w={granted=false,prompts=0,permissionReads=0,calls={},snapshots=0,opens=0,setupCalls=0,
        login={ok=true,enabled=false,registered=false,requiresApproval=false},startup=true,
        pane="Device Control and Data Access",
        shortcutState={upLabel="Control–Option–Page Up",downLabel="Control–Option–Page Down",message=""}}
    local function record(name,...)
        w.calls[#w.calls+1]={name=name,args={...}}
        if w.throws == name then error("Fixture failure") end
        if w.fails == name then return false,"Could not complete "..name end
        if w.nilError == name then return nil,"Could not complete "..name end
        if w.void == name then return nil end
        return true
    end
    hs={accessibilityState=function(prompt)
            if prompt then w.prompts=w.prompts+1 else w.permissionReads=w.permissionReads+1 end
            if w.permissionFailure then error("Permission unavailable") end
            return w.granted
        end,json={encode=function(value)
            w.snapshot=clone(value);w.snapshots=w.snapshots+1;return '{"fixture":true}'
        end}}
    w.native={showSettings=function(snapshot,perform,section)
            w.openedSection=section
            w.current,w.perform=snapshot,perform;w.opens=w.opens+1
            check(type(snapshot())=="string","Native snapshot callback returns JSON text")
            return true
        end,loginStatus=function()
            if w.loginFailure then error("Login status unavailable") end
            return clone(w.login)
        end,setLaunchAtLogin=function(value)
            local ok,why=record("login",value);return {ok=ok,error=why}
        end,
        openLoginSettings=function()return record("loginSettings")end,
        startupChecksEnabled=function()if w.startupFailure then error("Preference unavailable") end;return w.startup end,
        setStartupChecksEnabled=function(value)return record("startupChecks",value)end,
        openAccessibilitySettings=function()return record("desktopAccess")end,
        accessibilitySettingsInfo=function()return {paneName=w.pane}end}
    w.veil={running=true,opacity=.4,
        setOpacity=function(value)return record("strength",value)end,
        rebuild=function()return record("refresh")end}
    w.hotkeys={status=function()return clone(w.shortcutState)end,
        setBinding=function(which,value)return record("shortcutBinding",which,value)end,
        pauseRecording=function(value)return record("shortcutPause",value)end}
    w.startSetup=function()w.setupCalls=w.setupCalls+1;return w.setupError end
    function w.open(section)return settings.open(w.native,w.veil,w.startSetup,w.hotkeys,section)end
    function w.refresh()w.current();return w.snapshot end
    function w.row(id)
        for _,section in ipairs(w.snapshot.sections) do
            for _,row in ipairs(section.rows) do if row.id==id then return row end end
        end
        error("Missing settings row "..id)
    end
    function w.last()return w.calls[#w.calls]end
    return w
end

-- The native callbacks are lazy and fresh, and opening is observational only.
do
    local w=fixture();check(w.open()==true,"Native settings window opens")
    check(w.opens==1 and w.snapshots==1,"Opening obtains one snapshot, with no extra polling")
    check(w.prompts==0 and #w.calls==0 and w.setupCalls==0,"Opening never starts setup, requests access, selects displays or writes any setting")
    local expected={"wallpaper","general","brightness","permissions"}
    for index,id in ipairs(expected) do check(w.snapshot.sections[index].id==id,"Wallpaper-first tab order: "..id)end
    local seen={}
    for _,section in ipairs(w.snapshot.sections) do for _,row in ipairs(section.rows) do
        check(not seen[row.id],"Action/note IDs are unique: "..row.id);seen[row.id]=true
        check(({toggle=true,range=true,button=true,note=true,shortcut=true})[row.type],"Renderer receives a supported row type")
    end end
    check(w.row("wallpaper.strength").type=="range" and w.row("wallpaper.strength").value==40,
        "Current strength is displayed on the slider")
    check(w.row("general.startupChecks").value==true,"Startup checks use the native preference reader")
    check(w.row("permissions.desktopAccess").detail:find(w.pane,1,true),"Permission action uses the current OS pane name")
    check(w.row("wallpaper.refresh").title=="Refresh wallpaper tint","Refresh is labelled for its wallpaper-only effect")
    for _,id in ipairs({"wallpaper.enabled","wallpaper.color","wallpaper.picker","brightness.enabled","brightness.source",
        "brightness.follower","brightness.status","brightness.shortcutsEnabled","misc.defaults","misc.showNow","misc.hideNow"}) do
        check(not seen[id] and type(w.perform(id,true))=="string","Menu-only control is absent from Settings: "..id)
    end
    w.veil.opacity=.73;w.startup=false;w.refresh()
    check(w.row("wallpaper.strength").value==73 and w.row("general.startupChecks").value==false,"Refresh reads new app/native state")
    w.open("brightness")
    check(w.openedSection=="brightness","Menu can request the shortcut tab directly")
    check(w.prompts==0 and #w.calls==0,"Repeated snapshots remain read-only")
end

-- Quick Setup is an injected explicit action, never a side effect of a snapshot.
do
    local w=fixture();w.open();w.refresh()
    check(w.snapshot.sections[2].rows[1].id=="general.quickSetup" and w.row("general.quickSetup").enabled,"Quick Setup is the first General action")
    check(w.setupCalls==0,"Opening and refreshing do not start Quick Setup")
    check(w.perform("general.quickSetup")==nil and w.setupCalls==1,"One explicit action opens Quick Setup exactly once")
    check(#w.calls==0 and w.prompts==0,"Opening Quick Setup does not itself change settings or request access")
    w.setupError="Quick Setup could not open"
    check(w.perform("general.quickSetup")==w.setupError and w.setupCalls==2,"Quick Setup errors return to the settings window")
    w=fixture();w.startSetup=nil;w.open()
    check(not w.row("general.quickSetup").enabled,"Missing Quick Setup callback is unavailable")
    check(type(w.perform("general.quickSetup"))=="string" and w.setupCalls==0,"A stale setup action cannot invoke a missing callback")
end

-- Login approval is distinct from enabled and is reread at action dispatch.
do
    local w=fixture();w.open()
    check(w.row("general.login").value==false and w.row("general.login").enabled,"Inactive sign-in is actionable")
    check(w.perform("general.login",true)==nil and w.last().name=="login" and w.last().args[1]==true,"Sign-in dispatches the requested state")
    w.login.enabled=true;w.refresh();check(w.row("general.login").value==true,"Enabled OS sign-in is checked")
    check(w.perform("general.login",false)==nil and w.last().args[1]==false,"Sign-in can be disabled")
    w.fails="login"
    check(w.perform("general.login",true)=="Could not complete login","Structured native login failures are surfaced")
    w.fails=nil
    w.login.requiresApproval=true;w.refresh()
    check(w.row("general.login").value==false,"Pending registration is never presented as active")
    check(w.row("general.login").detail:find("approval",1,true),"Pending approval is explained")
    local pendingCount=#w.calls
    check(not w.row("general.login").enabled and w.perform("general.login",true):find("App permissions",1,true)
        and #w.calls==pendingCount,"Pending login approval points to App permissions without triggering OS actions")
    w.login={ok=false};local count=#w.calls;w.refresh()
    check(not w.row("general.login").enabled,"Unavailable sign-in is disabled")
    check(type(w.perform("general.login",true))=="string" and #w.calls==count,"A stale sign-in action cannot mutate an unavailable setting")
    check(w.perform("permissions.loginSettings")==nil and w.last().name=="loginSettings","Login settings stay reachable independently")
    w.loginFailure=true;w.refresh();check(not w.row("general.login").enabled,"A query exception never implies active startup")
end

-- Native update preferences are reused, and false toggle results are handled.
do
    local w=fixture();w.open()
    check(w.perform("general.startupChecks",false)==nil,"Disabling startup checks succeeds")
    check(w.last().name=="startupChecks" and w.last().args[1]==false,"Disabling goes through the native preference setter")
    w.fails="startupChecks"
    check(w.perform("general.startupChecks",true)=="Could not complete startupChecks","Native persistence errors are returned to the window")
    w.startupFailure=true;w.refresh()
    check(not w.row("general.startupChecks").enabled and not w.row("general.startupChecks").value,"An unreadable preference is unavailable, not guessed enabled")
end

-- Permission belongs only to explicit access action; ordinary controls stay usable.
do
    local w=fixture();w.open()
    for _,id in ipairs({"wallpaper.strength","wallpaper.refresh","brightness.shortcutUp"})do
        check(w.row(id).enabled,"No blanket Accessibility gate on "..id)
    end
    check(w.row("permissions.overview").text:find("without Accessibility or Input Monitoring",1,true),
        "App permissions explains which features work without special access")
    local use=w.row("permissions.desktopUse").text
    check(use:find("clock clicks",1,true) and use:find("keeping Notification Center open",1,true),
        "App permissions names the two desktop widget features that use access")
    check(w.perform("permissions.desktopAccess")==nil and w.prompts==1 and w.last().name=="desktopAccess","Explicit Enable requests current-process access and opens its pane")
    w.refresh();check(w.row("permissions.desktopAccess").title=="Enable Desktop Control Access…","A request alone does not imply a grant")
    w.granted=true;w.refresh()
    check(w.row("permissions.desktopAccess").title=="Manage Desktop Control Access…","Fresh grant changes the action to Manage")
    check(w.perform("permissions.desktopAccess")==nil and w.prompts==1,"Manage opens Settings without another prompt")
    w.granted=false
    check(w.perform("permissions.desktopAccess")==nil and w.prompts==2,"A stale Manage action rereads a revoked grant")
    w.permissionFailure=true
    check(w.perform("permissions.desktopAccess")==nil and w.last().name=="desktopAccess","A failing access query/prompt still allows opening Settings")
end

-- Fine strength keeps the persisted 1% value and rejects invalid actions.
do
    local w=fixture();w.veil.opacity=.45;w.open()
    local row=w.row("wallpaper.strength")
    check(row.type=="range" and row.value==45,"A saved 45% strength is accurately represented")
    for _, percent in ipairs({0, 45, 90, 99, 100}) do
        check(w.perform("wallpaper.strength",percent)==nil and w.last().args[1]==percent/100,
            "Whole percentage " .. percent .. " survives the settings round-trip")
    end
    check(w.perform("wallpaper.refresh")==nil and w.last().name=="refresh","Refresh uses the existing rebuild")
    local count=#w.calls
    for _,case in ipairs({{"general.login","yes"},{"general.startupChecks",1},
        {"wallpaper.strength",-1},{"wallpaper.strength",101},{"wallpaper.strength",45.5},
        {"wallpaper.strength","NaN"},{"unknown"},{false}})do
        check(type(w.perform(case[1],case[2]))=="string","Malformed/unknown action fails cleanly")
    end
    check(#w.calls==count and w.prompts==0,"Invalid actions have zero dispatch/permission side effects")
    w.veil.running=false
    check(type(w.perform("wallpaper.strength",100))=="string" and #w.calls==count,"A stopped veil cannot be mutated by retained callback")
    w.veil.running=true;w.nilError="refresh"
    check(w.perform("wallpaper.refresh")=="Could not complete refresh","A nil,error failure is surfaced")
    w.nilError=nil;w.void="refresh"
    check(w.perform("wallpaper.refresh")==nil,"A void action with no second error return succeeds")
    w.void=nil;w.throws="refresh"
    check(type(w.perform("wallpaper.refresh"))=="string","An action exception stays inside the native callback boundary")
end

-- Shortcut snapshots only read status; recording and clearing are explicit
-- typed actions. End must restore registrations even during parent shutdown.
do
    local w=fixture();w.open();w.refresh()
    check(#w.calls==0,"Opening Settings does not register, pause or change any shortcut")
    check(w.row("brightness.shortcutUp").type=="shortcut" and w.row("brightness.shortcutUp").value=="Control–Option–Page Up","Increase recorder shows the current shortcut label")
    check(w.row("brightness.shortcutDown").value=="Control–Option–Page Down","Decrease recorder shows the current shortcut label")
    check(w.perform("brightness.shortcutUp.begin")==nil and w.last().name=="shortcutPause" and w.last().args[1]==true,"Opening the recorder suspends registered brightness hotkeys")
    check(w.perform("brightness.shortcutUp","3:116")==nil and w.last().name=="shortcutBinding" and w.last().args[1]=="up" and w.last().args[2]=="3:116","Increase saves the physical chord through the module API")
    w.fails="shortcutBinding"
    check(w.perform("brightness.shortcutDown","3:116")=="Could not complete shortcutBinding","A conflict remains a readable error for the recorder")
    w.fails=nil
    check(w.perform("brightness.shortcutDown","3:121")==nil and w.last().args[1]=="down","Decrease has its own binding action")
    check(w.perform("brightness.clearShortcutUp")==nil and w.last().args[1]=="up" and w.last().args[2]==nil,"Increase Clear passes an explicit nil binding")
    check(w.perform("brightness.clearShortcutDown")==nil and w.last().args[1]=="down" and w.last().args[2]==nil,"Decrease Clear is separate")
    check(w.perform("brightness.shortcutUp.end")==nil and w.last().name=="shortcutPause" and w.last().args[1]==false,"Recording end resumes registration")
    w.veil.running=false
    check(w.perform("brightness.shortcutDown.end")==nil and w.last().args[1]==false,"Parent shutdown can end recording after the tint stops")
    local count=#w.calls
    check(type(w.perform("brightness.shortcutUp.begin"))=="string" and #w.calls==count,"A stopped app cannot begin another recording")
    w.veil.running=true
    for _,case in ipairs({{"brightness.shortcutsEnabled",1},{"brightness.shortcutUp",false},{"brightness.shortcutDown",""}})do
        check(type(w.perform(case[1],case[2]))=="string","Malformed shortcut callback is rejected")
    end
    check(#w.calls==count and w.prompts==0,"Malformed shortcut actions never dispatch or request access")
    w.shortcutState.upLabel="";w.refresh()
    check(not w.row("brightness.clearShortcutUp").enabled and w.row("brightness.shortcutUp").value=="","Cleared shortcut remains unset and can be recorded again")
    w=fixture();w.hotkeys=nil;w.open()
    check(not w.row("brightness.shortcutUp").enabled,"Unavailable module disables shortcut recording")
    check(type(w.perform("brightness.shortcutUp.begin"))=="string","Stale recorder action fails safely if shortcuts are unavailable")
end

-- Exercise the widget menu and explicit permission action with the actual widget and clock modules using
-- an in-memory OS adapter. This protects the narrow permission boundary and
-- proves Default stops their real timers/taps, rather than just a mock method.
do
    local w=fixture()
    local prefs,timers,taps={}, {}, {}
    local reads,writes,resets,hidden=0,0,0,nil
    hs.settings={get=function(key)return clone(prefs[key])end,
        set=function(key,value)prefs[key]=clone(value)end,
        clear=function(key)prefs[key]=nil;return true end}
    hs.timer={absoluteTime=function()return 0 end,doEvery=function(delay,callback)
        local timer={delay=delay,callback=callback,running=true}
        function timer:stop()self.running=false end
        timers[#timers+1]=timer;return timer
    end}
    hs.eventtap={event={types={leftMouseDown=1,leftMouseUp=2,rightMouseDown=3,keyDown=4}},new=function()
        local tap={enabled=false}
        function tap:start()self.enabled=true;return self end
        function tap:stop()self.enabled=false end
        function tap:isEnabled()return self.enabled end
        taps[#taps+1]=tap;return tap
    end}
    local previousPanel,previousClock=package.loaded.desktop_widget_panel,package.loaded.desktop_widget_clock
    package.loaded.desktop_widget_panel={snapshot=function()return {open=false}end,clearCache=function()end}
    local clock=assert(loadfile(root.."/desktop_widget_clock.lua"))()
    package.loaded.desktop_widget_clock=clock
    local widgets=assert(loadfile(root.."/desktop_widgets.lua"))().start({
        read=function()reads=reads+1;return {ok=true,present=hidden~=nil,value=hidden}end,
        write=function(value)writes=writes+1;hidden=value;return {ok=true,present=true,value=value}end,
        reset=function()resets=resets+1;hidden=nil;return {ok=true,present=false,resetVerified=true}end})
    w.open();w.refresh()
    local function widgetMenuAction(title)
        for _, item in ipairs(widgets.menuItems()) do
            if item.title == title then item.fn(); return end
        end
        error("Missing widget menu action "..title)
    end
    check(reads+writes+resets==0 and #timers==0 and #taps==0,"Opening settings leaves real macOS-default widget module quiescent")
    widgetMenuAction("Show now");check(hidden==0,"Real manual Show succeeds while access is denied")
    widgetMenuAction("Hide now");check(hidden==1,"Real manual Hide succeeds while access is denied")
    widgetMenuAction("Hide when Notification Center closes");check(widgets.status().tracking,"Hide-on-close starts metadata tracking without an access prompt")
    widgetMenuAction("Show when the clock is clicked")
    check(clock.status().waitingForPermission and not clock.status().watching and #taps==0,"Denied real clock observer waits without creating an event tap")
    widgetMenuAction("Show when Notification Center opens");check(w.prompts==0,"Automatic reveal selection also makes zero implicit permission requests")
    check(w.perform("permissions.desktopAccess")==nil and w.prompts==1,"Only explicit Enable makes a permission request")
    check(not clock.status().watching,"A request does not promote the real observer to granted")
    w.granted=true
    for _,timer in ipairs(timers)do if timer.running and timer.delay==3 then timer.callback()end end
    check(clock.status().watching and #taps==1,"The real observer begins only after a fresh grant read")
    widgetMenuAction("Use macOS defaults");check(resets==1,"Default dispatches the real guarded reset")
    local current=widgets.status()
    check(current.mode=="macOS" and not current.tracking and not current.showOnOpen and not current.showOnClockClick and not current.hideOnClose,"Default clears all real automation choices")
    for _,timer in ipairs(timers)do check(not timer.running,"Default stops an actual widget/clock timer")end
    for _,tap in ipairs(taps)do check(not tap.enabled,"Default stops the actual clock event tap")end
    local before=reads+writes+resets;w.refresh()
    check(reads+writes+resets==before,"Refreshing settings after reset does not touch widget preferences")
    widgets.stop();package.loaded.desktop_widget_panel=previousPanel;package.loaded.desktop_widget_clock=previousClock
end

print("PASS "..assertions.." app-settings state/action assertions")
