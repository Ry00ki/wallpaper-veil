-- Real observer module with synthetic input and in-memory AX/timers only.
local source=arg[1] or 'WallpaperVeil/app/desktop_widget_clock.lua'
local checks=0
local function equal(actual,expected,message)
    checks=checks+1
    assert(actual==expected,message..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function fixture(granted)
    local w={granted=granted~=false,timers={},taps={},clicks=0,inspections=0,permissions=0}
    local function timer(kind,callback)
        local t={kind=kind,callback=callback,running=true}
        function t:stop()self.running=false;return self end
        w.timers[#w.timers+1]=t;return t
    end
    local element={pid=function()return 99 end,setTimeout=function()return true end,
        attributeValue=function(_,name)
            if name=='AXIdentifier' then return 'com.apple.menuextra.clock' end
            if name=='AXRole' then return 'AXMenuBarItem' end
        end}
    hs={timer={doAfter=function(_,callback)return timer('after',callback)end,
        doEvery=function(_,callback)return timer('permission',callback)end},
        accessibilityState=function()w.permissions=w.permissions+1;return w.granted end,
        screen={allScreens=function()return {{fullFrame=function()return {x=0,y=0,w=1000,h=800}end}}end},
        axuielement={systemElementAtPosition=function()w.inspections=w.inspections+1;return element end},
        application={applicationForPID=function()return {bundleID=function()return 'com.apple.controlcenter' end}end},
        eventtap={event={types={leftMouseDown=1,leftMouseUp=2}},new=function(_,callback)
            local tap={callback=callback,enabled=false}
            function tap:start()self.enabled=true;return self end
            function tap:stop()self.enabled=false;return self end
            function tap:isEnabled()return self.enabled end
            w.taps[#w.taps+1]=tap;return tap
        end}}
    local m=assert(loadfile(source))()
    local function click()w.clicks=w.clicks+1 end
    m.start(click)
    local function event(kind)
        return {getType=function()return kind end,location=function()return {x=980,y=12}end,
            timestamp=function()return kind==1 and 1000000000 or 1100000000 end}
    end
    return w,m,event,click
end
do
    local w,m,event=fixture()
    equal(#w.taps,1,'clock starts one input observer')
    equal(m.status().watching,true,'granted clock observer is active')
    equal(w.taps[1].callback(event(1)),false,'clock mouse down is never consumed')
    equal(w.taps[1].callback(event(2)),false,'clock mouse up is never consumed')
    local inspection=w.timers[#w.timers]
    inspection.callback()
    equal(w.inspections,1,'clock AX inspection is deferred outside event tap')
    local action=w.timers[#w.timers]
    equal(w.clicks,0,'clock callback is separately deferred')
    action.callback()
    equal(w.clicks,1,'validated clock click invokes action')
    m.stop()
    equal(m.status().watching,false,'stop disables observer')
    equal(w.taps[1].enabled,false,'stop disables input tap')
    for _,t in ipairs(w.timers) do if t.kind=='permission' then equal(t.running,false,'stop cancels permission retry') end end
end
do
    local w,m,event=fixture()
    w.taps[1].callback(event(1));local inspect=w.timers[#w.timers]
    m.stop();inspect.callback()
    equal(w.inspections,0,'queued inspection after stop cannot inspect AX')
    equal(w.clicks,0,'queued inspection after stop cannot trigger action')
end
do
    local w,m,event=fixture()
    w.taps[1].callback(event(1));w.taps[1].callback(event(2));w.timers[#w.timers].callback()
    local action=w.timers[#w.timers]
    m.stop();equal(action.running,false,'stop cancels queued clock action');action.callback()
    equal(w.clicks,0,'queued action after stop cannot trigger feature')
end
do
    local w,m,event,click=fixture()
    local oldTap,oldPermission=w.taps[1],w.timers[1]
    oldTap.callback(event(1));local oldInspect=w.timers[#w.timers]
    m.stop();m.start(click)
    local taps,timers,permissions=#w.taps,#w.timers,w.permissions
    oldPermission.callback();oldTap.callback(event(1));oldInspect.callback()
    equal(#w.taps,taps,'old permission callback cannot replace a current observer')
    equal(#w.timers,timers,'old event callback cannot schedule work after restart')
    equal(w.permissions,permissions,'old permission callback cannot query permission after restart')
    equal(w.inspections,0,'old AX callback cannot inspect after restart')
    local newTap=w.taps[#w.taps]
    newTap.callback(event(1));newTap.callback(event(2));w.timers[#w.timers].callback()
    w.timers[#w.timers].callback()
    equal(w.clicks,1,'current generation remains functional after stale callbacks')
    m.stop()
end
do
    local w,m=fixture(false)
    equal(#w.taps,0,'denied permission creates no input tap')
    equal(m.status().waitingForPermission,true,'denied permission is visible')
    local permission=w.timers[1];m.stop();w.granted=true;permission.callback()
    equal(#w.taps,0,'stopped permission retry cannot create an observer')
    equal(permission.running,false,'permission retry stops with module')
end
print('Clock observer cancellation checks passed: '..checks)
