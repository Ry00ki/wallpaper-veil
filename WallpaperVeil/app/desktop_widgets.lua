-- Desktop widget visibility with actual Notification Center window detection.
local M = {}
local panel = require('desktop_widget_panel')
local prefix = 'wallpaperVeil.widgets.'
local running, generation = false, 0
local showOnOpen, hideOnClose, showOnClockClick = true, false, false
local pollTimer, clockTimer, clock, task, repair, cancelTap
local lastOpen, lastCloseAt, lastApplied, lastRequested
local desired, desiredPreserve, errorMessage
local drain, poll
local function now() return hs.timer.absoluteTime()/1e9 end
local function clearRepair()
    repair = nil
    if cancelTap then cancelTap:stop(); cancelTap=nil end
end
local function stopTask()
    if task then pcall(function() task:terminate() end);task=nil end
end
local function fail(message)
    errorMessage=message
    clearRepair()
end
local function startTask(path,args,callback)
    local token=generation
    local created,t=pcall(hs.task.new,path,function(code,out,err)
        if running and token==generation then callback(code,out,err) end
    end,args)
    if not created or not t then return false end
    task=t
    local ok,started=pcall(function()return t:start()end)
    if not ok or not started then task=nil;return false end
    return true
end
local function request(visible,preserve)
    if not running then return false end
    desired,desiredPreserve,lastRequested=visible,preserve==true,visible
    if not visible then clearRepair() end
    errorMessage=nil
    drain()
    return true
end
local function beginRepair(snapshot)
    local r={frame=snapshot.frame,writing=true,deadline=now()+2,attempted=false}
    repair=r
    -- A user's dismissal cancels preservation; never fight a click-away or Escape.
    cancelTap=hs.eventtap.new({hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,hs.eventtap.event.types.keyDown},function(event)
        if event:getType()~=hs.eventtap.event.types.keyDown or event:getKeyCode()==53 then
            clearRepair()
        end
        return false
    end):start()
    return r
end

drain=function()
    if not running or task or desired==nil then return end
    local visible,preserve=desired,desiredPreserve
    desired,desiredPreserve=nil,nil
    local started=startTask('/usr/bin/defaults',{'read','com.apple.WindowManager','StandardHideWidgets'},function(code,out)
        task=nil
        local value=(out or ''):match('^%s*(.-)%s*$')
        if code~=0 or (value~='0' and value~='1') then
            fail('Could not read desktop widget visibility');drain();return
        end
        if (value=='0')==visible then
            lastApplied=visible;errorMessage=nil
            drain();return
        end
        local transaction
        local snapshot=panel.snapshot()
        if visible and preserve and not snapshot then
            fail('Could not verify Notification Center before showing widgets');drain();return
        end
        if visible and preserve and snapshot and snapshot.open then
            if not hs.accessibilityState(false) then
                fail('Accessibility is needed to keep Notification Center open');drain();return
            end
            transaction=beginRepair(snapshot)
        end
        local wrote=startTask('/usr/bin/defaults',{'write','com.apple.WindowManager','StandardHideWidgets','-int',visible and '0' or '1'},function(exit)
            task=nil
            if exit==0 then
                lastApplied=visible;errorMessage=nil
                if transaction and repair==transaction then
                    transaction.writing=false
                    transaction.readyAt=now()+0.12
                    transaction.deadline=now()+1.5
                end
            else fail('Could not change desktop widget visibility') end
            drain()
        end)
        if not wrote then fail('Could not start desktop widget visibility change');drain() end
    end)
    if not started then fail('Could not read desktop widget visibility') end
end

poll=function()
    if not running then return end
    local snapshot,problem=panel.snapshot()
    if not snapshot then errorMessage=problem or 'Could not inspect Notification Center';return end
    local isOpen=snapshot.open
    if repair then
        local r=repair
        if now()>r.deadline then
            fail('Could not keep Notification Center open')
        elseif r.writing then return
        elseif isOpen then
            if r.attempted or now()>r.readyAt+0.45 then clearRepair() end
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
    if not running or not showOnClockClick then return end
    local wasOpen=lastOpen
    if clockTimer then clockTimer:stop() end
    local token=generation
    clockTimer=hs.timer.doAfter(0.15,function()
        clockTimer=nil
        if not running or token~=generation or not showOnClockClick then return end
        local state=panel.snapshot()
        if not state then return end
        if not state.open and hideOnClose and (wasOpen==true or (lastCloseAt and now()-lastCloseAt<0.6)) then
            request(false,false)
        else
            request(true,state.open)
        end
    end)
end

local function updateTracking()
    if not running then return end
    if showOnOpen or hideOnClose or showOnClockClick then
        if not pollTimer then
            lastOpen=nil
            pollTimer=hs.timer.doEvery(0.15,poll)
            poll()
        end
    else
        if pollTimer then pollTimer:stop();pollTimer=nil end
        lastOpen=nil
        clearRepair()
    end
    if showOnClockClick then clock=require('desktop_widget_clock').start(onClockClick)
    elseif clock then clock.stop() end
end
local function option(name,value)
    if type(value)~='boolean' then return false end
    local revealNow=name=='showOnOpen' and value and not showOnOpen and pollTimer~=nil
    if name=='showOnOpen' then showOnOpen=value
    elseif name=='hideOnClose' then hideOnClose=value
    else showOnClockClick=value end
    hs.settings.set(prefix..name,value)
    updateTracking()
    if revealNow then local state=panel.snapshot();if state and state.open then request(true,true) end end
    return true
end
function M.setShowOnOpen(value) return option('showOnOpen',value) end
function M.setHideOnClose(value) return option('hideOnClose',value) end
function M.setShowOnClockClick(value) return option('showOnClockClick',value) end
function M.allowClockClicks()
    if not showOnClockClick then M.setShowOnClockClick(true) end
    return clock and clock.requestPermission() or false
end
function M.showNow() return request(true,false) end
function M.hideNow() return request(false,false) end
function M.retry()
    errorMessage=nil
    local state,why=panel.snapshot()
    if not state then errorMessage=why or 'Could not inspect Notification Center';return false end
    if lastRequested~=nil then request(lastRequested,state.open) end
    poll();return true
end
function M.status()
    return {running=running,showOnOpen=showOnOpen,hideOnClose=hideOnClose,
        showOnClockClick=showOnClockClick,tracking=pollTimer~=nil,
        notificationCenterOpen=lastOpen,changingVisibility=task~=nil,
        preservingPanel=repair~=nil,lastAppliedVisible=lastApplied,
        lastRequestedVisible=lastRequested,error=errorMessage,
        detector='Notification Center window',clock=clock and clock.status() or nil}
end
function M.menuItems()
    local items={
        {title='Show when the clock is clicked',checked=showOnClockClick,fn=function()
            M.setShowOnClockClick(not showOnClockClick)
            if showOnClockClick and clock.status().waitingForPermission then M.allowClockClicks() end
        end},
        {title='Show when Notification Center opens',checked=showOnOpen,fn=function()M.setShowOnOpen(not showOnOpen)end},
        {title='Hide when Notification Center closes',checked=hideOnClose,fn=function()M.setHideOnClose(not hideOnClose)end},
        {title='-'},{title='Show now',fn=M.showNow},{title='Hide now',fn=M.hideNow},
    }
    if (showOnClockClick or showOnOpen) and not hs.accessibilityState(false) then
        items[#items+1]={title='-'}
        items[#items+1]={title='Automatic reveal needs Accessibility permission',disabled=true}
        items[#items+1]={title='Allow Accessibility…',fn=function()hs.accessibilityState(true)end}
    elseif clock and showOnClockClick and clock.status().error then
        items[#items+1]={title=clock.status().error,disabled=true}
    end
    if errorMessage then
        items[#items+1]={title='-'}
        items[#items+1]={title=errorMessage,disabled=true}
        items[#items+1]={title='Retry widget controls',fn=M.retry}
    end
    return items
end
function M.start()
    if running then return M end
    showOnOpen=hs.settings.get(prefix..'showOnOpen')~=false
    hideOnClose=hs.settings.get(prefix..'hideOnClose')==true
    showOnClockClick=hs.settings.get(prefix..'showOnClockClick')==true
    running=true;generation=generation+1;errorMessage=nil;lastOpen=nil;lastCloseAt=nil
    updateTracking()
    return M
end
function M.stop()
    running=false;generation=generation+1
    if pollTimer then pollTimer:stop();pollTimer=nil end
    if clockTimer then clockTimer:stop();clockTimer=nil end
    if clock then clock.stop() end
    clearRepair();stopTask();desired=nil
    return M
end
return M
