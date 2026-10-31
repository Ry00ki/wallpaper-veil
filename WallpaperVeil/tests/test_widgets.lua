-- Run from the repository root: lua5.4 WallpaperVeil/tests/test_widgets.lua
-- These tests use in-memory hs stubs. They do not inspect UI or change preferences.
local source=arg[1] or 'WallpaperVeil/core/desktop_widgets.lua'
local count=0
local function equal(actual,expected,message)
    count=count+1
    assert(actual==expected,message..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function fixture(options)
    options=options or {}
    local w={time=0,ax=options.ax~=false,open=false,timers={},tasks={},taps={},
        prefs={['wallpaperVeil.widgets.showOnOpen']=options.showOnOpen==true,
            ['wallpaperVeil.widgets.hideOnClose']=false,
            ['wallpaperVeil.widgets.showOnClockClick']=false,
            unrelated='keep'},tapFailure=options.tapFailure}
    local panel={snapshot=function()
        if w.snapshotFailure then return nil,'Window list unavailable' end
        return {open=w.open,frame={x=0,y=0,w=1000,h=800}}
    end,reopen=function()w.reopens=(w.reopens or 0)+1;return true end}
    local clock={start=function()w.clockRunning=true;return package.loaded.desktop_widget_clock end,
        stop=function()w.clockRunning=false end,status=function()return {waitingForPermission=not w.ax}end,
        requestPermission=function()return w.ax end}
    package.loaded.desktop_widget_panel=panel
    package.loaded.desktop_widget_clock=clock
    hs={timer={absoluteTime=function()return w.time*1e9 end,
        doEvery=function(_,callback)
            local timer={callback=callback,running=true}
            function timer:stop()self.running=false;return self end
            w.timers[#w.timers+1]=timer;return timer
        end,
        doAfter=function(_,callback)
            local timer={callback=callback,running=true}
            function timer:stop()self.running=false;return self end
            w.timers[#w.timers+1]=timer;return timer
        end},
        settings={get=function(key)return w.prefs[key]end,
            set=function(key,value)w.prefs[key]=value end},
        accessibilityState=function()return w.ax end,
        task={new=function(path,callback,args)
            local task={path=path,callback=callback,args=args}
            function task:start()return true end
            function task:terminate()self.terminated=true end
            function task:finish(code,out)self.callback(code or 0,out or '', '')end
            w.tasks[#w.tasks+1]=task;return task
        end},
        eventtap={event={types={leftMouseDown=1,rightMouseDown=2,keyDown=3}},
            new=function(_,callback)
                if w.tapFailure=='new_nil' then return nil end
                if w.tapFailure=='new_throw' then error('Tap creation failed') end
                local tap={callback=callback,enabled=false}
                function tap:start()
                    if w.tapFailure=='start_throw' then error('Tap start failed') end
                    if w.tapFailure=='start_nil' then return nil end
                    self.enabled=w.tapFailure~='disabled';return self
                end
                function tap:isEnabled()
                    if w.tapFailure=='inspect_throw' then error('Tap inspection failed') end
                    return self.enabled
                end
                function tap:stop()self.enabled=false;self.stopped=true end
                w.taps[#w.taps+1]=tap;return tap
            end}}
    local module=assert(loadfile(source))()
    module.start()
    local function automaticReveal()
        w.open=true
        w.timers[1].callback()
        equal(#w.tasks,1,'automatic reveal first reads the visibility key')
        w.tasks[1]:finish(0,'1\n')
    end
    return w,module,automaticReveal
end
do
    local w,m=fixture({ax=false})
    equal(#w.timers,0,'all automation off starts no pollers')
    m.showNow();w.tasks[1]:finish(0,'1\n');w.tasks[2]:finish(0)
    local args=w.tasks[2].args
    equal(w.tasks[2].path,'/usr/bin/defaults','manual reveal uses the defaults tool')
    equal(table.concat(args,'|'),'write|com.apple.WindowManager|StandardHideWidgets|-int|0','manual reveal writes only the widget visibility key')
    equal(w.prefs.unrelated,'keep','unrelated preferences are untouched')
    equal(m.status().lastAppliedVisible,true,'manual reveal works without Accessibility')
    equal(#w.taps,0,'manual reveal creates no event tap')
    m.stop()
end
do
    local w,m,reveal=fixture({ax=false,showOnOpen=true})
    reveal()
    equal(#w.tasks,1,'denied preservation sends no preference write')
    equal(#w.taps,0,'denied preservation creates no event tap')
    equal(m.status().preservingPanel,false,'denied preservation leaves no repair')
    equal(m.status().showOnOpen,true,'denied permission does not change the option')
    equal(m.status().error,'Accessibility is needed to keep Notification Center open','denial explains the required permission')
    m.stop()
end
for _,failure in ipairs({'new_nil','new_throw','start_nil','start_throw','disabled','inspect_throw'}) do
    local w,m,reveal=fixture({showOnOpen=true,tapFailure=failure})
    local ok,why=pcall(reveal)
    equal(ok,true,'tap failure is handled without throwing: '..failure..' '..tostring(why))
    equal(#w.tasks,1,'tap failure aborts before preference write: '..failure)
    equal(m.status().preservingPanel,false,'tap failure leaves no repair: '..failure)
    equal(m.status().showOnOpen,true,'tap failure preserves configured automation: '..failure)
    equal(w.open,true,'tap failure leaves Notification Center open: '..failure)
    equal(m.status().error,'Could not monitor Notification Center dismissal','tap failure has a useful error: '..failure)
    if w.taps[1] then equal(w.taps[1].stopped,true,'failed tap was stopped: '..failure) end
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true})
    reveal();w.tasks[2]:finish(0)
    equal(m.status().preservingPanel,true,'successful write begins bounded preservation')
    equal(w.taps[1].enabled,true,'preservation monitors user dismissal')
    w.snapshotFailure=true;w.time=1
    w.timers[1].callback()
    equal(m.status().preservingPanel,true,'transient detection failure before deadline retains bounded repair')
    w.time=1.5;w.timers[1].callback()
    equal(m.status().preservingPanel,false,'repair expires at its deadline despite snapshot failure')
    equal(w.taps[1].enabled,false,'expired repair stops its cancellation tap')
    equal(m.status().error,'Could not keep Notification Center open','expired repair reports the preservation failure')
    w.snapshotFailure=false;w.open=false
    equal(m.retry(),true,'retry accepts a fresh healthy snapshot')
    w.tasks[3]:finish(0,'1\n');w.tasks[4]:finish(0)
    equal(m.status().error,nil,'successful retry clears the error')
    equal(m.status().lastAppliedVisible,true,'successful retry applies the requested visibility')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true})
    reveal() -- The write callback has not completed yet.
    w.snapshotFailure=true;w.time=2;w.timers[1].callback()
    equal(m.status().preservingPanel,false,'in-flight write does not extend the repair deadline')
    w.tasks[2]:finish(0)
    equal(m.status().preservingPanel,false,'late write callback does not resurrect expired repair')
    equal(m.status().error,'Could not keep Notification Center open','late write callback preserves the timeout error')
    equal(w.taps[1].enabled,false,'late callback leaves the expired tap stopped')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true})
    reveal();w.tasks[2]:finish(0)
    local tap=w.taps[1]
    local function event(kind,key)return {getType=function()return kind end,getKeyCode=function()return key end}end
    equal(tap.callback(event(hs.eventtap.event.types.keyDown,0)),false,'ordinary key event passes through')
    equal(m.status().preservingPanel,true,'ordinary key does not cancel panel preservation')
    equal(tap.callback(event(hs.eventtap.event.types.keyDown,53)),false,'Escape passes through')
    equal(m.status().preservingPanel,false,'Escape cancels panel preservation')
    equal(tap.enabled,false,'Escape stops cancellation monitoring')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true})
    reveal();w.tasks[2]:finish(0)
    m.setShowOnOpen(false)
    equal(w.timers[1].running,false,'disabling all automation stops the poller')
    equal(w.taps[1].enabled,false,'disabling automation stops preservation monitoring')
    equal(m.status().preservingPanel,false,'disabling automation clears repair state')
    m.stop()
end
do
    local w,m=fixture()
    m.showNow();m.stop();w.tasks[1]:finish(0,'1\n')
    equal(w.tasks[1].terminated,true,'stop terminates an in-flight task')
    equal(#w.tasks,1,'stopped callback cannot enqueue a preference write')
    equal(m.status().running,false,'stop reports the module inactive')
end
print('Widget failure, denial, retry and cancellation checks passed: '..count)
