-- App-owned widget controls. macOS-managed mode never observes the clock or
-- Notification Center. The explicit defaults action deletes one native override.
local M = {}
local panel = require('desktop_widget_panel')
local prefix = 'wallpaperVeil.widgets.'
local running, generation = false, 0
local showOnOpen, hideOnClose, showOnClockClick = false, false, false
local mode, resetVerified, preferences = 'macOS', false, nil
local sessionStopIntent, sessionError, stopIntentRemembered = false, nil, true
local pollTimer, clockTimer, clock, repair, cancelTap
local lastOpen, lastCloseAt, lastApplied, lastRequested, errorMessage
local poll
local function now() return hs.timer.absoluteTime()/1e9 end
local function clearRepair()
    repair = nil
    if cancelTap then pcall(function() cancelTap:stop() end); cancelTap=nil end
end
local function fail(message)
    errorMessage=message
    clearRepair()
    return false
end
local function preferenceCall(name, ...)
    if not preferences or type(preferences[name])~='function' then
        return nil,'The native desktop widget controls are unavailable'
    end
    local ok,result=pcall(preferences[name],...)
    if not ok or type(result)~='table' or result.ok~=true then
        return nil,type(result)=='table' and result.error or 'The native desktop widget request failed'
    end
    return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function saveSetting(name,value)
    local ok,result=pcall(hs.settings.set,prefix..name,value)
    if not ok or result==false then return false end
    local read,saved=pcall(hs.settings.get,prefix..name)
    return read and same(saved,value)
end
local function clearResetGuard()
    local read,value=pcall(hs.settings.get,prefix..'resetPending')
    if not read then return false end
    if value==nil then return true end
    if type(hs.settings.clear)~='function' then return false end
    local ok,result=pcall(hs.settings.clear,prefix..'resetPending')
    local verified,remaining=pcall(hs.settings.get,prefix..'resetPending')
    return ok and result~=false and verified and remaining==nil
end
local function saveState()
    -- App-owned mode and stop intent contain no OS setting or restoration
    -- snapshot. Try every flag even when a particular setting cannot be saved.
    local values={controlState={schema=1,mode=mode,showOnOpen=showOnOpen,
        hideOnClose=hideOnClose,showOnClockClick=showOnClockClick,
        resetVerified=resetVerified,error=errorMessage},
        showOnOpen=showOnOpen,hideOnClose=hideOnClose,showOnClockClick=showOnClockClick}
    local saved=true
    for _,name in ipairs({'controlState','showOnOpen','hideOnClose','showOnClockClick'}) do
        if not saveSetting(name,values[name]) then saved=false end
    end
    return saved
end
local function beginRepair(snapshot)
    clearRepair()
    local token=generation
    local r={frame=snapshot.frame,deadline=now()+1.5,attempted=false}
    -- Never alter visibility unless user-dismissal monitoring is active.
    local created,tap=pcall(hs.eventtap.new,{hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,hs.eventtap.event.types.keyDown},function(event)
        if running and mode=='managed' and token==generation and repair==r and
            (event:getType()~=hs.eventtap.event.types.keyDown or event:getKeyCode()==53) then
            clearRepair()
        end
        return false
    end)
    if not created or not tap then return nil,'Could not monitor Notification Center dismissal' end
    local started,result=pcall(function() return tap:start() end)
    local inspected,enabled=pcall(function() return tap:isEnabled() end)
    if not started or not result or not inspected or enabled~=true then
        pcall(function() tap:stop() end)
        return nil,'Could not monitor Notification Center dismissal'
    end
    repair,cancelTap=r,tap
    return r
end
local function request(visible,preserve)
    if not running or mode~='managed' then return false end
    lastRequested=visible
    if not visible then clearRepair() end
    errorMessage=nil
    local value,why=preferenceCall('read')
    if not value then return fail(why) end
    if value.present~=false and (value.present~=true or (value.value~=0 and value.value~=1)) then
        return fail('Could not read desktop widget visibility')
    end
    if value.present and (value.value==0)==visible then
        lastApplied=visible
        return true
    end
    local transaction
    if visible and preserve then
        local snapshot=panel.snapshot()
        if not snapshot then return fail('Could not verify Notification Center before showing widgets') end
        if snapshot.open then
            if not hs.accessibilityState(false) then
                return fail('Accessibility is needed to keep Notification Center open')
            end
            transaction,why=beginRepair(snapshot)
            if not transaction then return fail(why) end
        end
    end
    -- This bridge synchronizes and verifies before returning. There is no
    -- subprocess or late write callback that can outlive a defaults reset.
    local result,problem=preferenceCall('write',visible and 0 or 1)
    if not result or result.present~=true or result.value~=(visible and 0 or 1) then
        return fail(problem or 'Could not verify desktop widget visibility')
    end
    lastApplied=visible
    if transaction and repair==transaction then transaction.readyAt=now()+0.12 end
    return true
end
poll=function()
    if not running or mode~='managed' then return end
    if repair and now()>=repair.deadline then
        fail('Could not keep Notification Center open');return
    end
    local snapshot,problem=panel.snapshot()
    if not snapshot then errorMessage=problem or 'Could not inspect Notification Center';return end
    local isOpen=snapshot.open
    if repair then
        local r=repair
        if isOpen then
            if r.attempted or now()>(r.readyAt or math.huge)+0.45 then clearRepair() end
            lastOpen=true
            return
        elseif now()>=(r.readyAt or math.huge) and not r.attempted then
            local ok,why=panel.reopen(r)
            r.attempted=true
            if not ok then fail(why or 'Could not reopen Notification Center') end
            return
        else return end
    end
    local previous=lastOpen
    lastOpen=isOpen
    if isOpen and previous~=true and showOnOpen then
        request(true,true)
    elseif not isOpen and previous==true then
        lastCloseAt=now()
        if hideOnClose then request(false,false) end
    end
end
local function onClockClick()
    if not running or mode~='managed' or not showOnClockClick then return end
    local wasOpen=lastOpen
    if clockTimer then clockTimer:stop() end
    local token=generation
    local timer
    timer=hs.timer.doAfter(0.15,function()
        if clockTimer~=timer then return end
        clockTimer=nil
        if not running or mode~='managed' or token~=generation or not showOnClockClick then return end
        local state=panel.snapshot()
        if not state then return end
        if not state.open and hideOnClose and (wasOpen==true or (lastCloseAt and now()-lastCloseAt<0.6)) then
            request(false,false)
        else request(true,state.open) end
    end)
    clockTimer=timer
end
local function updateTracking()
    if not running or mode~='managed' then return end
    if showOnOpen or hideOnClose or showOnClockClick then
        if not pollTimer then
            lastOpen=nil
            local token=generation
            pollTimer=hs.timer.doEvery(0.15,function()
                if running and token==generation then poll() end
            end)
            poll()
        end
    else
        if pollTimer then pollTimer:stop();pollTimer=nil;generation=generation+1 end
        lastOpen=nil
        clearRepair()
    end
    if showOnClockClick then clock=require('desktop_widget_clock').start(onClockClick)
    else
        if clockTimer then clockTimer:stop();clockTimer=nil end
        if clock then clock.stop();clock=nil end
    end
end
function M.stop()
    running=false;generation=generation+1
    if pollTimer then pollTimer:stop();pollTimer=nil end
    if clockTimer then clockTimer:stop();clockTimer=nil end
    if clock then clock.stop();clock=nil end
    clearRepair();repair=nil
    lastOpen,lastCloseAt=nil,nil
    if panel.clearCache then panel.clearCache() end
    return M
end
local function quiesce()
    local wasRunning=running
    M.stop()
    running=wasRunning
end
local function offWithError(message)
    quiesce()
    showOnOpen,hideOnClose,showOnClockClick=false,false,false
    mode,resetVerified,errorMessage='resetFailed',false,message
    sessionStopIntent=true
    local guarded=saveSetting('resetPending',true)
    local saved=saveState()
    stopIntentRemembered=guarded or saved
    if not stopIntentRemembered then
        errorMessage=message..'; disabled for this session only because the choice could not be remembered'
    end
    sessionError=errorMessage
    return false
end
function M.useMacOSDefaults()
    -- The independent guard overrides a stale managed record after a failed
    -- controlState write. No native reset runs without a verified stop intent.
    quiesce()
    showOnOpen,hideOnClose,showOnClockClick=false,false,false
    lastApplied,lastRequested=nil,nil
    mode,resetVerified,errorMessage='resetting',false,nil
    sessionStopIntent=true
    local guarded=saveSetting('resetPending',true)
    local saved=saveState()
    if not guarded or not saved then return offWithError('Could not save disabled widget controls; retry macOS defaults') end
    stopIntentRemembered=true
    local result,problem=preferenceCall('reset')
    if not result or result.present~=false or result.resetVerified~=true then
        return offWithError(problem or 'Could not verify macOS desktop widget defaults; retry')
    end
    mode,resetVerified='macOS',true
    if not saveState() or not clearResetGuard() then
        return offWithError('Could not save macOS widget mode; retry macOS defaults')
    end
    sessionStopIntent,sessionError=false,nil
    return true
end
local function enterManaged()
    if not saveState() or not clearResetGuard() then
        return offWithError('Could not save custom widget controls')
    end
    sessionStopIntent,sessionError,stopIntentRemembered=false,nil,true
    return true
end
local function option(name,value)
    if type(value)~='boolean' then return false end
    local revealNow=name=='showOnOpen' and value and not showOnOpen and pollTimer~=nil
    mode,resetVerified,errorMessage='managed',false,nil
    if name=='showOnOpen' then showOnOpen=value
    elseif name=='hideOnClose' then hideOnClose=value
    else showOnClockClick=value end
    if not enterManaged() then return false end
    updateTracking()
    if revealNow then local state=panel.snapshot();if state and state.open then request(true,true) end end
    return true
end
function M.setShowOnOpen(value) return option('showOnOpen',value) end
function M.setHideOnClose(value) return option('hideOnClose',value) end
function M.setShowOnClockClick(value) return option('showOnClockClick',value) end
function M.allowClockClicks()
    if not showOnClockClick and not M.setShowOnClockClick(true) then return false end
    return clock and clock.requestPermission() or false
end
local function manual(visible)
    if not running then return false end
    mode,resetVerified,errorMessage='managed',false,nil
    if not enterManaged() then return false end
    return request(visible,false)
end
function M.showNow() return manual(true) end
function M.hideNow() return manual(false) end
function M.retry()
    if mode=='resetFailed' or mode=='resetting' then return M.useMacOSDefaults() end
    if not running or mode~='managed' then return false end
    errorMessage=nil
    local state,why=panel.snapshot()
    if not state then errorMessage=why or 'Could not inspect Notification Center';return false end
    if lastRequested~=nil and not request(lastRequested,state.open) then return false end
    poll();return errorMessage==nil
end
function M.status()
    return {running=running,mode=mode,macOSDefaults=mode=='macOS',resetVerified=resetVerified,
        stopIntentRemembered=stopIntentRemembered,
        showOnOpen=mode=='managed' and showOnOpen,hideOnClose=mode=='managed' and hideOnClose,
        showOnClockClick=mode=='managed' and showOnClockClick,tracking=pollTimer~=nil,
        notificationCenterOpen=lastOpen,changingVisibility=false,
        preservingPanel=repair~=nil,lastAppliedVisible=lastApplied,
        lastRequestedVisible=lastRequested,error=errorMessage,
        detector='Notification Center window',clock=clock and clock.status() or nil}
end
function M.menuItems()
    local managed=mode=='managed'
    local items={
        {title='Use macOS defaults',checked=mode=='macOS',fn=M.useMacOSDefaults},
        {title='-'},
        {title='Custom behaviour',disabled=true},
        {title='Show when the clock is clicked',checked=managed and showOnClockClick,fn=function()
            M.setShowOnClockClick(not (mode=='managed' and showOnClockClick))
            if showOnClockClick and clock and clock.status().waitingForPermission then M.allowClockClicks() end
        end},
        {title='Show when Notification Center opens',checked=managed and showOnOpen,
            fn=function()M.setShowOnOpen(not (mode=='managed' and showOnOpen))end},
        {title='Hide when Notification Center closes',checked=managed and hideOnClose,
            fn=function()M.setHideOnClose(not (mode=='managed' and hideOnClose))end},
        {title='-'},{title='Show now',fn=M.showNow},{title='Hide now',fn=M.hideNow},
    }
    if managed and (showOnClockClick or showOnOpen) and not hs.accessibilityState(false) then
        items[#items+1]={title='-'}
        items[#items+1]={title='Automatic reveal needs Accessibility permission',disabled=true}
        items[#items+1]={title='Allow Accessibility…',fn=function()hs.accessibilityState(true)end}
    elseif clock and showOnClockClick and clock.status().error then
        items[#items+1]={title=clock.status().error,disabled=true}
    end
    if errorMessage then
        items[#items+1]={title='-'}
        items[#items+1]={title=errorMessage,disabled=true}
        items[#items+1]={title=(mode=='resetFailed' or mode=='resetting') and 'Retry macOS defaults' or 'Retry widget controls',fn=M.retry}
    end
    return items
end
function M.start(adapter)
    if running then return M end
    if adapter then preferences=adapter end
    local saved=hs.settings.get(prefix..'controlState')
    local pending=hs.settings.get(prefix..'resetPending')
    showOnOpen,hideOnClose,showOnClockClick=false,false,false
    mode,resetVerified,errorMessage='macOS',false,nil
    if sessionStopIntent or pending~=nil then
        mode='resetFailed'
        errorMessage=sessionError or 'The widget defaults reset did not finish; retry macOS defaults or select a custom option'
        stopIntentRemembered=pending~=nil or (type(saved)=='table' and saved.schema==1 and
            (saved.mode=='resetFailed' or saved.mode=='resetting' or saved.mode=='macOS'))
    elseif saved~=nil then
        if type(saved)=='table' and saved.schema==1 and
            (saved.mode=='macOS' or saved.mode=='managed' or saved.mode=='resetting' or saved.mode=='resetFailed') then
            mode=saved.mode
            if mode=='managed' then
                showOnOpen,hideOnClose,showOnClockClick=saved.showOnOpen==true,saved.hideOnClose==true,saved.showOnClockClick==true
            elseif mode=='macOS' then resetVerified=saved.resetVerified==true
            else
                mode='resetFailed'
                errorMessage=saved.error or 'The widget defaults reset did not finish; retry macOS defaults'
            end
        else mode,errorMessage='resetFailed','Saved widget controls are invalid; choose macOS defaults or a custom option' end
    else
        local show,hide,click=hs.settings.get(prefix..'showOnOpen'),hs.settings.get(prefix..'hideOnClose'),hs.settings.get(prefix..'showOnClockClick')
        -- Preserve explicitly configured legacy intent. A genuinely new user
        -- (no stored flags) starts with all automation off and no OS writes.
        if show~=nil or hide~=nil or click~=nil then
            showOnOpen,hideOnClose,showOnClockClick=show~=false,hide==true,click==true
            if showOnOpen or hideOnClose or showOnClockClick then mode='managed' end
        end
    end
    running=true;generation=generation+1;lastOpen,lastCloseAt=nil,nil
    updateTracking()
    return M
end
return M
