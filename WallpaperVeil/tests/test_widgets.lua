-- In-memory widget mode, failure and stale-callback checks. No system preferences.
local source=arg[1] or 'WallpaperVeil/core/desktop_widgets.lua'
local count=0
local prefix='wallpaperVeil.widgets.'
local function equal(actual,expected,message)
    count=count+1
    assert(actual==expected,message..': expected '..tostring(expected)..', got '..tostring(actual))
end
local function clone(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=clone(item) end;return result
end
local function event(kind,key)return {getType=function()return kind end,getKeyCode=function()return key end}end
local function fixture(options)
    options=options or {}
    local w={time=0,ax=options.ax~=false,open=options.open==true,timers={},taps={},
        prefs=clone(options.prefs or {unrelated='keep'}),tapFailure=options.tapFailure,
        hidden=options.hidden,reads=0,writes=0,resets=0,snapshots=0,clockStarts=0,clockStops=0}
    if options.showOnOpen~=nil then w.prefs[prefix..'showOnOpen']=options.showOnOpen end
    local panel={snapshot=function()
        w.snapshots=w.snapshots+1
        if w.snapshotFailure then return nil,'Window list unavailable' end
        return {open=w.open,frame={x=0,y=0,w=1000,h=800}}
    end,reopen=function()w.reopens=(w.reopens or 0)+1;return not w.reopenFailure end,
        clearCache=function()w.cacheCleared=(w.cacheCleared or 0)+1 end}
    local clock={start=function(callback)
        w.clockCallback=callback;w.clockRunning=true;w.clockStarts=w.clockStarts+1
        return package.loaded.desktop_widget_clock
    end,stop=function()w.clockRunning=false;w.clockStops=w.clockStops+1 end,
        status=function()return {running=w.clockRunning,waitingForPermission=not w.ax}end,
        requestPermission=function()return w.ax end}
    package.loaded.desktop_widget_panel=panel;package.loaded.desktop_widget_clock=clock
    local function timer(kind,callback)
        local value={kind=kind,callback=callback,running=true}
        function value:stop()self.running=false;return self end
        w.timers[#w.timers+1]=value;return value
    end
    hs={timer={absoluteTime=function()return w.time*1e9 end,
        doEvery=function(_,callback)return timer('poll',callback)end,
        doAfter=function(_,callback)return timer('delay',callback)end},
        settings={get=function(key)return clone(w.prefs[key])end,
            set=function(key,value)
                if w.failSave or key==prefix..tostring(w.failSaveKey) then error('Settings are read-only') end
                if key==prefix..tostring(w.falseSaveKey) then return false end
                if key~=prefix..tostring(w.ignoreSaveKey) then w.prefs[key]=clone(value) end
            end,clear=function(key)
                if w.failSave or w.failClear then return false end
                if not w.ignoreClear then w.prefs[key]=nil end
                return true
            end},accessibilityState=function()return w.ax end,
        task={new=function()error('Desktop widgets must not spawn subprocesses')end},
        eventtap={event={types={leftMouseDown=1,rightMouseDown=2,keyDown=3}},new=function(_,callback)
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
    local adapter={read=function()
        w.reads=w.reads+1
        if w.readFailure then return {ok=false,error='Native read unavailable'} end
        return {ok=true,present=w.hidden~=nil,value=w.hidden}
    end,write=function(value)
        w.writes=w.writes+1
        if w.writeFailure then return {ok=false,error='Native write was not verified'} end
        w.hidden=value
        return {ok=true,present=true,value=w.hidden}
    end,reset=function()
        w.resets=w.resets+1
        if w.onReset then w.onReset() end
        if w.resetThrow then error('Native reset failed') end
        if w.resetFailure then return {ok=false,error='Native reset was not verified'} end
        if w.resetUnverified then return {ok=true,present=true,value=1} end
        w.hidden=nil
        return {ok=true,present=false,resetVerified=true}
    end}
    local module=assert(loadfile(source))();module.start(adapter)
    local function reveal()
        w.open=true
        for _,value in ipairs(w.timers) do if value.kind=='poll' and value.running then value.callback();return end end
        error('No active poller')
    end
    return w,module,reveal
end
local function allStopped(w,message)
    for _,timer in ipairs(w.timers) do equal(timer.running,false,message..' timer stopped') end
    for _,tap in ipairs(w.taps) do equal(tap.enabled,false,message..' tap stopped') end
    equal(w.clockRunning==true,false,message..' clock observer stopped')
end
local function automationOff(m,message)
    local s=m.status()
    for _,key in ipairs({'showOnOpen','hideOnClose','showOnClockClick','tracking','changingVisibility','preservingPanel'}) do
        equal(s[key],false,message..' '..key..' off')
    end
end
do
    local w,m=fixture({hidden=1,ax=false})
    equal(m.status().mode,'macOS','new users start with native macOS behaviour')
    equal(m.status().macOSDefaults,true,'new user defaults mode is checked')
    equal(m.status().resetVerified,false,'startup does not claim it reset a preference')
    equal(w.reads+w.writes+w.resets,0,'startup leaves existing OS preference untouched')
    equal(w.hidden,1,'fresh startup retains a personal OS setting')
    equal(w.snapshots,0,'default mode never inspects Notification Center')
    equal(#w.timers,0,'default mode starts no timer')
    automationOff(m,'fresh defaults')
    local menu=m.menuItems()
    equal(menu[1].title,'Use macOS defaults','defaults action is first')
    equal(menu[1].checked,true,'defaults action is checked')
    for index=4,6 do equal(menu[index].checked,false,'custom choice is unchecked');equal(menu[index].disabled==true,false,'custom choice stays clickable') end
    equal(m.useMacOSDefaults(),true,'explicit reset succeeds')
    equal(w.hidden,nil,'explicit reset removes the override')
    equal(m.status().resetVerified,true,'explicit reset reports verified absence')
    equal(w.prefs.unrelated,'keep','unrelated preferences survive')
    equal(m.useMacOSDefaults(),true,'explicit reset is repeatable')
    equal(w.resets,2,'each explicit action re-verifies defaults')
    m.stop();equal(w.resets,2,'stopping never resets system preferences')
end
do
    local w,m=fixture({hidden=1,ax=false})
    equal(m.showNow(),true,'manual reveal works without Accessibility')
    equal(w.hidden,0,'manual reveal synchronously writes the fixed native key')
    equal(m.status().mode,'managed','manual reveal explicitly opts into app control')
    equal(m.status().macOSDefaults,false,'manual reveal unchecks defaults')
    equal(#w.taps,0,'manual reveal creates no event tap')
    equal(m.hideNow(),true,'manual hide works')
    equal(w.hidden,1,'manual hide is verified')
    m.stop()
end
do
    local w,m=fixture({showOnOpen=true,hidden=0})
    equal(m.status().showOnOpen,true,'legacy explicit reveal is retained')
    equal(m.status().mode,'managed','legacy custom intent remains managed')
    m.stop()
    local legacy={[prefix..'hideOnClose']=true}
    w,m=fixture({prefs=legacy})
    equal(m.status().showOnOpen,true,'legacy implicit show default retained when another explicit choice exists')
    equal(m.status().hideOnClose,true,'legacy hide setting retained')
    m.stop()
    w,m=fixture({prefs={[prefix..'showOnOpen']=false,[prefix..'hideOnClose']=false,[prefix..'showOnClockClick']=false}})
    equal(m.status().mode,'macOS','legacy explicitly all-off choice stays off')
    equal(w.resets,0,'legacy all-off migration does not reset OS settings')
    m.stop()
end
do
    local w,m=fixture()
    local menu=m.menuItems();menu[4].fn()
    equal(m.status().showOnClockClick,true,'clicking a custom choice opts into managed mode')
    equal(m.status().macOSDefaults,false,'custom choice unchecks defaults')
    equal(w.clockRunning,true,'custom clock option starts observer')
    m.setShowOnOpen(true);m.setHideOnClose(true)
    for _,key in ipairs({'showOnOpen','hideOnClose','showOnClockClick'}) do equal(m.status()[key],true,'custom combinations retain '..key) end
    m.useMacOSDefaults()
    automationOff(m,'defaults after custom combination');allStopped(w,'defaults after custom combination')
    for _,key in ipairs({'showOnOpen','hideOnClose','showOnClockClick'}) do equal(w.prefs[prefix..key],false,'defaults clears stored '..key) end
    equal(w.prefs[prefix..'controlState'].mode,'macOS','canonical record gates old flags')
    -- A stale true legacy key must never override the canonical mode.
    w.prefs[prefix..'showOnOpen']=true
    m.stop();m.start()
    automationOff(m,'canonical default reload')
    equal(w.resets,1,'reload does not reset preferences again')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true,hidden=1,ax=false})
    reveal()
    equal(w.writes,0,'permission denial aborts before writing')
    equal(#w.taps,0,'permission denial creates no tap')
    equal(m.status().error,'Accessibility is needed to keep Notification Center open','denial explains permission')
    equal(m.status().showOnOpen,true,'denial retains configured custom choice')
    m.stop()
end
for _,failure in ipairs({'new_nil','new_throw','start_nil','start_throw','disabled','inspect_throw'}) do
    local w,m,reveal=fixture({showOnOpen=true,hidden=1,tapFailure=failure})
    local ok,why=pcall(reveal)
    equal(ok,true,'tap failure handled: '..failure..' '..tostring(why))
    equal(w.writes,0,'tap failure prevents preference write: '..failure)
    equal(m.status().preservingPanel,false,'tap failure leaves no repair: '..failure)
    equal(m.status().showOnOpen,true,'tap failure retains choice: '..failure)
    equal(w.open,true,'tap failure leaves Notification Center open: '..failure)
    equal(m.status().error,'Could not monitor Notification Center dismissal','tap error is useful: '..failure)
    if w.taps[1] then equal(w.taps[1].stopped,true,'failed tap stopped: '..failure) end
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true,hidden=1})
    reveal()
    equal(m.status().preservingPanel,true,'verified write begins bounded repair')
    w.snapshotFailure=true;w.time=1;w.timers[1].callback()
    equal(m.status().preservingPanel,true,'temporary snapshot failure retains bounded repair')
    w.time=1.5;w.timers[1].callback()
    equal(m.status().preservingPanel,false,'repair expires even when snapshots fail')
    equal(w.taps[1].enabled,false,'expired repair stops dismissal monitoring')
    equal(m.status().error,'Could not keep Notification Center open','timeout is explained')
    w.snapshotFailure=false;w.open=false;w.hidden=1
    equal(m.retry(),true,'retry accepts a healthy snapshot')
    equal(m.status().lastAppliedVisible,true,'retry applies requested visibility')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true,hidden=1})
    reveal()
    local tap=w.taps[1]
    equal(tap.callback(event(3,0)),false,'ordinary key passes through')
    equal(m.status().preservingPanel,true,'ordinary key leaves preservation active')
    equal(tap.callback(event(3,53)),false,'Escape passes through')
    equal(m.status().preservingPanel,false,'Escape cancels repair')
    equal(tap.enabled,false,'Escape stops the cancellation tap')
    m.stop()
end
do
    local w,m,reveal=fixture({showOnOpen=true,hidden=1})
    m.setShowOnClockClick(true);reveal();w.clockCallback()
    local oldPoll,oldTap,oldClock=w.timers[1],w.taps[1],w.timers[#w.timers]
    w.onReset=function()
        equal(w.prefs[prefix..'resetPending'],true,'stop intent is verified before native reset')
        allStopped(w,'before native reset')
        automationOff(m,'before native reset')
    end
    equal(m.useMacOSDefaults(),true,'defaults succeeds from active repair and delayed clock action')
    local reads,writes,snapshots=w.reads,w.writes,w.snapshots
    oldPoll.callback();oldClock.callback();oldTap.callback(event(1,0))
    equal(w.reads,reads,'queued callbacks cannot read preferences after reset')
    equal(w.writes,writes,'queued callbacks cannot rewrite preferences after reset')
    equal(w.snapshots,snapshots,'queued callbacks cannot inspect Notification Center after reset')
    equal(w.reopens,nil,'queued callbacks cannot reopen Notification Center')
    -- After opt-in, prior-generation callbacks cannot act on new work either.
    w.onReset=nil;w.hidden=1;w.open=false;m.setShowOnOpen(true);m.setShowOnClockClick(true)
    reveal();w.clockCallback()
    local newClock=w.timers[#w.timers]
    oldClock.callback();oldTap.callback(event(3,53));oldPoll.callback()
    equal(m.status().preservingPanel,true,'old tap cannot cancel a new generation repair')
    equal(newClock.running,true,'old delayed callback cannot clear a new timer')
    equal(m.useMacOSDefaults(),true,'second reset still cancels the new timer')
    equal(newClock.running,false,'new timer retained ownership until reset')
    m.stop()
end
for _,failure in ipairs({'resetFailure','resetUnverified','resetThrow'}) do
    local w,m=fixture({showOnOpen=true,hidden=1})
    w[failure]=true
    equal(m.useMacOSDefaults(),false,'reset failure returns false: '..failure)
    equal(m.status().macOSDefaults,false,'failed reset never checks defaults: '..failure)
    equal(m.status().resetVerified,false,'failed reset never claims verification: '..failure)
    equal(m.status().mode,'resetFailed','failed reset mode is honest: '..failure)
    automationOff(m,'failed reset');allStopped(w,'failed reset')
    equal(type(m.status().error),'string','failed reset gives a useful error')
    local saved=clone(w.prefs);m.stop();local w2,m2=fixture({prefs=saved,hidden=1})
    automationOff(m2,'failed reset restart')
    equal(w2.resets+w2.writes+w2.reads,0,'failed reset is never retried automatically on restart')
    equal(m2.status().macOSDefaults,false,'failed reset remains unchecked after restart')
    m2.stop();w[failure]=false
    equal(m.retry(),true,'same action can retry a failed reset while stopped')
    equal(m.status().macOSDefaults,true,'successful retry checks defaults')
end
do
    local w,m=fixture({showOnOpen=true,hidden=1});w.failSave=true
    equal(m.useMacOSDefaults(),false,'settings failure is reported')
    equal(w.resets,0,'failed disabled-state persistence prevents native reset')
    automationOff(m,'settings failure');allStopped(w,'settings failure')
    equal(m.status().macOSDefaults,false,'settings failure does not claim defaults success')
    m.stop()
end
do
    local w,m=fixture({hidden=1});w.readFailure=true
    equal(m.showNow(),false,'native read failure is handled')
    equal(w.writes,0,'read failure never attempts a write')
    equal(m.status().error,'Native read unavailable','native read error is useful')
    w.readFailure=false;w.writeFailure=true
    equal(m.showNow(),false,'native write failure is handled')
    equal(m.status().lastAppliedVisible,nil,'unverified write never reports applied visibility')
    equal(m.status().error,'Native write was not verified','native write error is useful')
    m.stop()
end
do
    local w,m=fixture({showOnOpen=true,hidden=1})
    local old=w.timers[1];m.stop();m.start();local before=w.snapshots
    old.callback();equal(w.snapshots,before,'old poll cannot act after stop/start')
    m.stop();m.setShowOnOpen(true);m.setHideOnClose(true);m.setShowOnClockClick(true)
    allStopped(w,'setting stopped choices')
    equal(m.useMacOSDefaults(),true,'explicit defaults reset also works for stopped acceptance transaction')
    equal(m.status().running,false,'stopped reset does not start automation')
    automationOff(m,'stopped reset')
end
-- Persistence regression: use a genuinely new module, not just stop/start.
for _,failure in ipairs({'failSaveKey','falseSaveKey','ignoreSaveKey'}) do
    local w,m=fixture();m.setShowOnOpen(true)
    equal(w.prefs[prefix..'controlState'].mode,'managed','seed a previously saved managed record')
    w[failure]='controlState'
    equal(m.useMacOSDefaults(),false,'canonical persistence failure aborts defaults: '..failure)
    equal(w.resets,0,'canonical save failure never calls native reset: '..failure)
    equal(w.prefs[prefix..'controlState'].mode,'managed','repro retains stale canonical record: '..failure)
    equal(w.prefs[prefix..'resetPending'],true,'separate stop intent survives canonical failure: '..failure)
    for _,key in ipairs({'showOnOpen','hideOnClose','showOnClockClick'}) do equal(w.prefs[prefix..key],false,'all legacy clears attempted despite canonical failure') end
    m.stop()
    local fresh,freshModule=fixture({prefs=w.prefs,hidden=1})
    automationOff(freshModule,'fresh module honors stop intent')
    equal(freshModule.status().mode,'resetFailed','fresh module does not resume stale managed state')
    equal(freshModule.status().macOSDefaults,false,'fresh module never claims incomplete reset succeeded')
    equal(fresh.reads+fresh.writes+fresh.resets,0,'fresh guarded start does no native operations')
    equal(fresh.snapshots,0,'fresh guarded start does not inspect Notification Center')
    equal(freshModule.useMacOSDefaults(),true,'explicit retry can finish partial persistence failure')
    equal(fresh.prefs[prefix..'resetPending'],nil,'verified successful retry clears stop guard')
    freshModule.stop()
end
for _,guard in ipairs({false,'malformed',{unexpected=true}}) do
    local prefs={[prefix..'controlState']={schema=1,mode='managed',showOnOpen=true,hideOnClose=true,showOnClockClick=true},
        [prefix..'resetPending']=guard}
    local w,m=fixture({prefs=prefs})
    automationOff(m,'present or malformed guard is fail closed')
    equal(m.status().mode,'resetFailed','malformed guard blocks a stale managed record')
    equal(w.reads+w.writes+w.resets+w.snapshots,0,'guarded startup does no native or NC operations')
    m.stop()
end
do
    local w,m=fixture();m.setShowOnOpen(true);w.failSaveKey='resetPending'
    equal(m.useMacOSDefaults(),false,'unverified guard prevents native reset')
    equal(w.resets,0,'missing stop guard never reaches native reset')
    equal(w.prefs[prefix..'controlState'].mode,'resetFailed','canonical failure mode is an independent safe record')
    m.stop();local fresh,nextModule=fixture({prefs=w.prefs})
    automationOff(nextModule,'saved canonical failure remains stopped')
    equal(fresh.snapshots,0,'canonical failed-mode reload starts no observers');nextModule.stop()
end
for _,failure in ipairs({'failClear','ignoreClear'}) do
    local w,m=fixture();w[failure]=true
    equal(m.useMacOSDefaults(),false,'guard clearing must be verified: '..failure)
    equal(w.prefs[prefix..'resetPending'],true,'failed clear retains stop intent: '..failure)
    equal(m.status().macOSDefaults,false,'uncleared guard does not claim completed defaults: '..failure)
    local writes=w.writes
    equal(m.showNow(),false,'manual opt-in cannot bypass uncleared guard: '..failure)
    equal(w.writes,writes,'uncleared guard prevents manual native write: '..failure)
    equal(m.setShowOnClockClick(true),false,'custom opt-in cannot bypass uncleared guard: '..failure)
    automationOff(m,'uncleared opt-in guard');allStopped(w,'uncleared opt-in guard')
    w[failure]=false
    equal(m.setShowOnClockClick(true),true,'explicit opt-in succeeds after guard can be cleared')
    equal(w.prefs[prefix..'resetPending'],nil,'custom opt-in clears guard')
    equal(w.clockRunning,true,'verified custom opt-in restarts clock observer')
    m.stop()
end
do
    local w,m=fixture();m.setShowOnOpen(true);w.failSave=true
    equal(m.useMacOSDefaults(),false,'fully unwritable store fails without reset')
    equal(w.resets,0,'fully unwritable store aborts native reset')
    equal(w.prefs[prefix..'resetPending'],nil,'no guard is falsely claimed to be stored')
    equal(m.status().stopIntentRemembered,false,'complete storage failure is reported honestly')
    equal(m.status().error:find('this session only',1,true)~=nil,true,'failure warns that off state cannot be remembered')
    m.stop();local snapshots=w.snapshots;m.start()
    automationOff(m,'volatile stop intent survives same-process restart')
    equal(w.snapshots,snapshots,'same-process stop/start cannot resume failed reset automation')
    m.stop()
    -- A new process cannot infer an unrecorded choice on an unwritable store.
    -- The explicit warning above is required; no second storage system exists.
end
print('Widget modes, reset, denial and stale-callback checks passed: '..count)
