-- Deterministic lifecycle regressions. No live app, settings, AX or hardware.
local root = arg[1] or 'WallpaperVeil/core'
package.path = root .. '/?.lua;' .. package.path
local report = {}
local function check(name, expected, actual, detail)
  report[#report+1] = {name=name,expected=expected,actual=actual,passed=expected==actual,detail=detail}
end
local function display(id,x,w)
  local screen={rect={x=x,y=0,w=w,h=800}}
  function screen:id()return id end
  function screen:fullFrame()return self.rect end
  return screen
end
local function fresh()
  for _,name in ipairs({'wallpaper_veil','desktop_widgets','desktop_widget_clock','desktop_widget_panel','display_brightness_sync','runtime_probe','acceptance'}) do package.loaded[name]=nil end
  _G.wallpaperVeil, _G.displayBrightnessSync = nil, nil
  local w={now=0,ax=false,timers={},tasks={},taps={},menus={},screenWatchers={},wakeWatchers={},canvases={},prefs={},promptCount=0}
  w.screens={display(101,0,1000)}
  w.canvasEvents={}
  local function timer(callback, running)
    local t={callback=callback,running=running}
    function t:stop() self.running=false;return self end
    function t:start() self.running=true;return self end
    w.timers[#w.timers+1]=t;return t
  end
  local function watcher(collection,callback)
    local t={callback=callback,running=false}
    function t:start()self.running=true;return self end
    function t:stop()self.running=false;return self end
    collection[#collection+1]=t;return t
  end
  hs={timer={absoluteTime=function()return w.now*1e9 end,
       doEvery=function(_,cb)return timer(cb,true)end,
       doAfter=function(_,cb)return timer(cb,true)end,
       delayed={new=function(_,cb)return timer(cb,false)end}},
    settings={get=function(k)return w.prefs[k]end,set=function(k,v)w.prefs[k]=v end,clear=function(k)w.prefs[k]=nil end,bundleID='com.ry00ki.wallpaperveil'},
    accessibilityState=function(prompt)if prompt then w.promptCount=w.promptCount+1 end;return w.ax end,
    eventtap={event={types={leftMouseDown=1,leftMouseUp=2,rightMouseDown=3,keyDown=4}},new=function(_,cb)
      if w.failTap then return nil end
      local t={callback=cb,enabled=false}
      function t:start()self.enabled=true;return self end
      function t:stop()self.enabled=false;return self end
      function t:isEnabled()return self.enabled end
      w.taps[#w.taps+1]=t;return t
    end},
    task={new=function(path,cb,args)
      local t={path=path,callback=cb,args=args}
      function t:start()self.started=true;return self end
      function t:terminate()self.terminated=true;return self end
      function t:finish(code,out,err)self.callback(code or 0,out or '',err or '')end
      w.tasks[#w.tasks+1]=t;return t
    end},
    screen={allScreens=function()return w.screens end,
      watcher={new=function(cb)return watcher(w.screenWatchers,cb)end}},
    caffeinate={watcher={systemDidWake=1,screensDidWake=2,systemWillSleep=3,screensDidSleep=4,
      new=function(cb)return watcher(w.wakeWatchers,cb)end}},
    canvas={windowLevels={desktopIcon=0},new=function(frame)
      if w.failCanvas then error('simulated canvas construction failure') end
      local c={rect=frame,visible=false,deleted=false,shows=0,frameChanges=0}
      for _,name in ipairs({'behavior','sendToBack','mouseCallback','clickActivating','alpha','elementAttribute','level'})do c[name]=function(self,...)return self end end
      function c:frame(next)
        if not next then return self.rect end
        self.rect=next
        self.frameChanges=self.frameChanges+1
        return self
      end
      function c:isShowing()return self.visible end
      function c:show()
        if w.failShowX==self.rect.x then error('simulated canvas show failure') end
        self.visible,self.shows=true,self.shows+1
        w.canvasEvents[#w.canvasEvents+1]={action='show',canvas=self}
        return self
      end
      function c:delete()
        self.deleted,self.visible=true,false
        w.canvasEvents[#w.canvasEvents+1]={action='delete',canvas=self}
      end
      w.canvases[#w.canvases+1]=c;return c
    end},
    menubar={new=function()
      local m={deleted=false}
      for _,name in ipairs({'setMenu','setTitle','setTooltip','removeFromMenuBar','returnToMenuBar','autosaveName'})do m[name]=function(self,...)return self end end
      function m:delete()self.deleted=true end
      w.menus[#w.menus+1]=m;return m
    end},
    autoLaunch=function()return false end,menuIcon=function()return false end,dockIcon=function()return false end,uploadCrashData=function()return false end,
    processInfo={bundleID='com.ry00ki.wallpaperveil',resourcePath='/mock/Resources',processID=1},
    json={encode=function(value)w.report=value;return '{}' end},alert={show=function(msg)w.alert=msg end},
    application={applicationForPID=function()return {kill=function()end}end},
  }
  return w
end
local function veil(w)
  package.loaded.desktop_widgets={start=function()return package.loaded.desktop_widgets end,stop=function()w.widgetStop=(w.widgetStop or 0)+1 end,menuItems=function()return {}end,status=function()return {}end}
  return assert(loadfile(root..'/wallpaper_veil.lua'))()
end
do
  local w=fresh();local m=veil(w);m.start();m.start()
  local active=0;for _,menu in ipairs(w.menus)do if not menu.deleted then active=active+1 end end
  check('Starting tint twice keeps one menu',1,active)
  active=0;for _,s in ipairs(w.screenWatchers)do if s.running then active=active+1 end end
  check('Starting tint twice keeps one screen watcher',1,active)
  m.stop()
end
do
  local w=fresh();local m=veil(w);m.start()
  local original=m.canvases[1]
  local refresh=w.timers[1]
  w.screenWatchers[1].callback()
  check('Screen notification still schedules veil reconciliation',true,refresh.running)
  refresh.callback()
  check('Unchanged screen topology retains the actual overlay',original,m.canvases[1])
  check('Unchanged screen topology never orders the veil off or redraws its frame',true,
    #w.canvases==1 and not original.deleted and original.visible and original.shows==1 and original.frameChanges==0)
  local detectedScreens=w.screens
  w.screens={}
  refresh.callback()
  w.screens=detectedScreens
  refresh.callback()
  check('An empty display snapshot during reconfiguration does not clear the veil',true,
    #w.canvases==1 and m.canvases[1]==original and original.visible and original.shows==1)
  original.visible=false
  refresh.callback()
  check('A hidden veil is shown again without allocating a second canvas',true,
    #w.canvases==1 and m.canvases[1]==original and original.visible and original.shows==2)
  m.stop()
end
do
  local w=fresh();local m=veil(w)
  w.screens={display(101,0,1000),display(102,1000,800)}
  m.start()
  local retained,removed=table.unpack(m.canvases)
  w.screens={display(103,1200,900),display(101,0,1200)}
  m.rebuild()
  check('Display removal and addition preserve the surviving window across screen-list reorder',true,
    #w.canvases==3 and #m.canvases==2 and m.canvases[2]==retained and m.canvases[1]==w.canvases[3])
  check('A surviving display resizes its veil in place',true,
    retained.visible and not retained.deleted and retained.frameChanges==1 and retained.rect.w==1200 and retained.shows==1)
  check('The new display is covered before the obsolete canvas is deleted',true,
    w.canvasEvents[3].action=='show' and w.canvasEvents[3].canvas==m.canvases[1]
      and w.canvasEvents[4].action=='delete' and w.canvasEvents[4].canvas==removed)
  m.setEnabled(false)
  check('Turning tint off removes all live windows',true,#m.canvases==0 and retained.deleted and w.canvases[3].deleted)
  m.stop()
end
do
  local w=fresh();local m=veil(w);m.start()
  local original=m.canvases[1]
  w.screens={w.screens[1],display(102,1000,800),display(103,1800,900)}
  w.failShowX=1800
  local ok=pcall(m.rebuild)
  check('A failed newly attached overlay is reported and leaves the existing tint in place',true,
    not ok and #m.canvases==1 and m.canvases[1]==original and original.visible and not original.deleted)
  check('Partially created display windows are cleaned up after the failure',true,
    #w.canvases==3 and w.canvases[2].deleted and w.canvases[3].deleted)
  w.failShowX=nil
  m.rebuild()
  check('Following refresh can add both displays and retain the original tint',true,
    #m.canvases==3 and m.canvases[1]==original and original.shows==1)
  m.stop()
end
do
  local w=fresh();local m=veil(w);m.start();local oldWatcher=w.screenWatchers[1];local refresh=w.timers[1];m.stop()
  oldWatcher.callback();check('Stale screen callback cannot restart refresh after stop',false,refresh.running)
  refresh.callback();local visible=0;for _,c in ipairs(w.canvases)do if c.visible then visible=visible+1 end end
  check('Stale refresh cannot recreate tint after stop',0,visible)
end
do
  local w=fresh();local m=veil(w);m.start()
  for _, value in ipairs({0, 0.99, 1}) do
    m.setOpacity(value);m.stop();m.start()
    check('Tint strength survives restart at ' .. tostring(value),value,m.opacity)
  end
  m.stop()
end
local function runInit(failBrightness)
  local w=fresh();local v=veil(w);package.loaded.wallpaper_veil=v
  package.loaded.display_brightness_sync={
    start=function()if failBrightness then error('mock brightness startup failure')end end,
    stop=function()w.syncStop=true end,
    suspend=function(reason)w.suspensions=(w.suspensions or 0)+1;w.lastSuspend=reason end,
    resume=function(reason)w.resumptions=(w.resumptions or 0)+1;w.lastResume=reason end,
  }
  local getenv,loadlib,open,rename=os.getenv,package.loadlib,io.open,os.rename
  io.open=function()return {write=function()end,close=function()end}end
  os.rename=function()return true end
  os.getenv=function(name)if name=='WV_APP_CODE'then return root elseif name=='WV_APPLICATION_SUPPORT'then return '/test/app-state' else return '0'end end
  package.loadlib=function()return function()return {configure=function()return {configured=true}end,diagnostics=function()return {}end}end end
  hs.shutdownCallback=nil
  assert(loadfile(root..'/init.lua'))()
  os.getenv,package.loadlib,io.open,os.rename=getenv,loadlib,open,rename
  if not failBrightness then assert(not w.report or not w.report.error,w.report and w.report.error) end
  return w
end
do
  local w=runInit(false);assert(hs.shutdownCallback,w.report and w.report.error);hs.shutdownCallback();local active=0
  for _,t in ipairs(w.timers)do if t.running==true then active=active+1 end end
  check('App shutdown stops retained app-owned delayed timers',0,active)
end
do
  local w=runInit(false)
  local lifecycle=w.wakeWatchers[#w.wakeWatchers]
  lifecycle.callback(hs.caffeinate.watcher.systemWillSleep)
  check('App lifecycle forwards actual system sleep notification', 'system',w.lastSuspend)
  lifecycle.callback(hs.caffeinate.watcher.screensDidSleep)
  check('App lifecycle forwards actual display sleep notification', 'display',w.lastSuspend)
  lifecycle.callback(hs.caffeinate.watcher.systemDidWake)
  check('App lifecycle forwards actual system wake notification', 'system',w.lastResume)
  lifecycle.callback(hs.caffeinate.watcher.screensDidWake)
  check('App lifecycle forwards actual display wake notification', 'display',w.lastResume)
  local before=w.resumptions
  hs.shutdownCallback()
  check('App cleanup stops the brightness lifecycle watcher',false,lifecycle.running)
  lifecycle.callback(hs.caffeinate.watcher.systemDidWake)
  check('Queued wake after app cleanup cannot resume brightness',before,w.resumptions)
end
do
  local w=runInit(true)
  check('Partial startup failure tears down started tint/widget resources',true,(w.widgetStop or 0)>0,w.report and w.report.error)
end
do
  local w=fresh();local m=veil(w);m.start()
  local oldScreen, oldWake = w.screenWatchers[1], w.wakeWatchers[1]
  m.stop();m.start();local refresh=w.timers[#w.timers]
  oldScreen.callback();oldWake.callback(hs.caffeinate.watcher.systemDidWake)
  check('Prior generation cannot schedule a fresh generation timer',false,refresh.running)
  m.stop()
end
do
  local w=fresh();local m=veil(w);w.failCanvas=true
  local ok=pcall(m.start)
  check('Failed canvas creation is reported',false,ok)
  check('Failed startup stops widgets',true,(w.widgetStop or 0)>0)
  check('Failed startup deletes its menu',true,w.menus[1].deleted)
  check('Failed startup stops screen watcher',false,w.screenWatchers[1].running)
  check('Failed startup stops wake watcher',false,w.wakeWatchers[1].running)
  w.failCanvas=false;m.start();check('Failed startup can be retried',true,m.running);m.stop()
end
local passed=0
for _,r in ipairs(report)do
  print((r.passed and 'PASS ' or 'FAIL ')..r.name..' expected='..tostring(r.expected)..' actual='..tostring(r.actual)..(r.detail and (' detail='..r.detail)or''))
  if r.passed then passed=passed+1 end
end
print(string.format('TOTAL %d/%d checks meet intended behavior',passed,#report))

assert(passed==#report, "Lifecycle regression failed")
