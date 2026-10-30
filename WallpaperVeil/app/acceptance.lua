-- Bounded local acceptance. Hardware changes are small and always restored.
local M = {}
function M.run(done)
    M.timers = {}
    local function later(seconds, callback)
        local timer = hs.timer.doAfter(seconds, callback)
        M.timers[#M.timers+1] = timer
        return timer
    end
    local report = {schema=1, observedAtUTC=os.date("!%Y-%m-%dT%H:%M:%SZ"),
        checks={}, limitations={"Sleep/wake and visual feel require normal user testing."}}
    local veil, sync = assert(wallpaperVeil), assert(displayBrightnessSync)
    local old = {enabled=veil.enabled, opacity=veil.opacity, color=veil.color,
        syncEnabled=sync.enabled}
    local source, follower, sourceBrightness, followerBrightness
    local finished = false
    local function check(name, result, detail)
        report.checks[#report.checks+1]={name=name,passed=result==true,detail=detail}
    end
    local function cancelTimers()
        for _,timer in ipairs(M.timers) do timer:stop() end
        M.timers={}
    end
    local function restore()
        local errors={}
        local function attempt(name,fn)
            local ok,err=pcall(fn)
            if not ok then errors[#errors+1]=name..": "..tostring(err) end
        end
        attempt("disable sync",function() sync.setEnabled(false,true) end)
        if source and sourceBrightness then attempt("source brightness",function() source:setBrightness(sourceBrightness) end) end
        if follower and followerBrightness then attempt("follower brightness",function() follower:setBrightness(followerBrightness) end) end
        attempt("tint settings",function() veil.setColor(old.color);veil.setOpacity(old.opacity);veil.setEnabled(old.enabled) end)
        attempt("sync setting",function() sync.setEnabled(old.syncEnabled,true) end)
        return errors
    end
    M.cancel=function()
        if finished then return end
        finished=true;cancelTimers();restore()
        M.cancel=nil
    end
    local function finish(err)
        if finished then return end
        finished=true;cancelTimers()
        local errors=restore()
        if err then check("test execution",false,tostring(err)) end
        later(0.4,function()
            M.cancel=nil
            check("restoration calls completed",#errors==0,errors)
            check("tint settings restored",veil.enabled==old.enabled
                and math.abs(veil.opacity-old.opacity)<0.0001
                and veil.colorHex(veil.color)==veil.colorHex(old.color))
            check("sync setting restored",sync.enabled==old.syncEnabled)
            if source and sourceBrightness then
                local value=source:getBrightness()
                check("source brightness restored",type(value)=="number" and math.abs(value-sourceBrightness)<=0.02)
            end
            if follower and followerBrightness then
                local value=follower:getBrightness()
                check("follower brightness restored",type(value)=="number" and math.abs(value-followerBrightness)<=0.02)
            end
            report.accessibilityGranted=hs.accessibilityState(false)
            report.widgets=veil.widgets and veil.widgets.status() or nil
            report.ok=true
            for _,entry in ipairs(report.checks) do if not entry.passed then report.ok=false end end
            done(report)
        end)
    end
    local ok, err = xpcall(function()
        veil.setEnabled(false)
        check("tint disabled removes canvases",#veil.canvases==0)
        veil.setEnabled(true)
        check("tint enabled covers displays",#veil.canvases==#hs.screen.allScreens())
        local opacity=old.opacity>=0.75 and old.opacity-0.05 or old.opacity+0.05
        veil.setOpacity(opacity)
        local opacityMatches=true
        for _, canvas in ipairs(veil.canvases) do
            if math.abs(canvas:alpha()-opacity)>0.0001 then opacityMatches=false end
        end
        check("opacity updates all canvases",opacityMatches)
        veil.setColor("#101820")
        check("colour setter",veil.colorHex(veil.color)=="#101820")
        veil.setColor(old.color);veil.setOpacity(old.opacity);veil.setEnabled(old.enabled)
        local quitCount=0
        for _, item in ipairs(veil.menuItems()) do
            if item.title=="Quit Wallpaper Veil" then quitCount=quitCount+1 end
        end
        check("standalone quit action present once",quitCount==1)
        local items=veil.menuItems()
        check("About Wallpaper Veil is the final item",items[#items].title=="About Wallpaper Veil")
        local noEngineToggle=true
        for _,item in ipairs(items) do
            if item.title:find("Hammerspoon",1,true) or item.title=="Show troubleshooting menu" then noEngineToggle=false end
        end
        check("standalone menu has no engine icon toggle",noEngineToggle)
        for _, screen in ipairs(hs.screen.allScreens()) do
            if screen:getUUID()==sync.sourceUUID then source=screen end
            if screen:getUUID()==sync.followerUUID then follower=screen end
        end
        assert(source and follower,"No selected brightness pair")
        sourceBrightness=source:getBrightness();followerBrightness=follower:getBrightness()
        assert(type(sourceBrightness)=="number" and type(followerBrightness)=="number",
            "Selected hardware brightness unavailable")
        sync.setEnabled(false,true)
        local target=sourceBrightness>0.8 and sourceBrightness-0.0625 or sourceBrightness+0.0625
        source:setBrightness(target)
        assert(sync.setEnabled(true,true),"Cannot enable brightness sync")
        later(2.5,function()
            if finished then return end
            local success,errorText=xpcall(function()
                local actualSource,actualFollower=source:getBrightness(),follower:getBrightness()
                check("hardware follower tracks changed source",
                    type(actualSource)=="number" and type(actualFollower)=="number"
                    and math.abs(actualSource-target)<=0.02 and math.abs(actualFollower-actualSource)<=0.02,
                    {requested=target,source=actualSource,follower=actualFollower})
                sync.setEnabled(false,true)
                local separate=actualSource>0.1 and actualSource-0.0625 or actualSource+0.0625
                follower:setBrightness(separate)
                later(1,function()
                    if finished then return end
                    local passed,failure=xpcall(function()
                        local a,b=source:getBrightness(),follower:getBrightness()
                        check("sync off permits independent brightness",
                            type(a)=="number" and type(b)=="number"
                            and math.abs(a-actualSource)<=0.02 and math.abs(b-separate)<=0.02,
                            {source=a,follower=b})
                    end,debug.traceback)
                    finish(not passed and failure or nil)
                end)
            end,debug.traceback)
            if not success then finish(errorText) end
        end)
    end,debug.traceback)
    if not ok then finish(err) end
    later(8,function() if not finished then finish("Acceptance timed out; restoration requested") end end)
end
return M
