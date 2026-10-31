-- Exercise deferred UI qualification cleanup with a virtual timer queue.
-- No app, network, preference or display access.
local path = arg[1] or 'WallpaperVeil/core/init.lua'
local file = assert(io.open(path)); local source=file:read('a'); file:close()
local first=assert(source:find('    if os.getenv("WV_UI_TEST") == "1" then',1,true))
local last=assert(source:find('    if os.getenv("WV_SELF_TEST") == "1" then',first,true))
local block=source:sub(first,last-1)
local count=0
local function scenario(mode)
  local now, sequence, closed, cancelled, captures, writeAttempts = 0,0,0,0,0,0
  local queue, reports, live = {}, {}, false
  local function after(delay, fn)
    sequence=sequence+1; queue[#queue+1]={at=now+delay,fn=fn,seq=sequence}
  end
  local function diagnostic()
    if live and mode=='diagnostics' then error('diagnostic fixture failure') end
    return {configured=true,nativeMainMenuReady=true,aboutVisible=closed==0,aboutTitle='Wallpaper Veil',
      engineWindowsVisible=false,repositoryActionWired=true,noticesActionWired=true,aboutIconPresent=true,
      updateActionWired=true,releaseActionWired=true,currentVersion='0.1.4',currentBuild='5',
      currentReleaseTag='v0.1.4-preview.1',releaseChannel='preview',
      updateState=live and ((mode=='deadline' and cancelled==0) and 'checking' or (cancelled>0 and 'cancelled' or 'ahead')) or 'idle',
      updateInProgress=live and mode=='deadline' and cancelled==0}
  end
  local autoChecks, installs=0,0
  local native={testStartupCheckOnce=function()return true end,testInstallUpdate=function(channel)assert(channel=="stable");installs=installs+1;return true end,testAutomaticAboutCheck=function()autoChecks=autoChecks+1;return true end,openAccessibilitySettings=function() return true end,showAbout=function() end,closeAbout=function() closed=closed+1 end,
    diagnostics=diagnostic,cancelUpdateCheck=function() cancelled=cancelled+1 end,
    checkForUpdates=function() live=true end,
    saveAboutPreview=function()
      captures=captures+1
      if live and mode=='capture' then return false,'capture fixture failure' end
      return true
    end,
    testUpdateResponse=function(input,status)
      if status==403 then return {updateState='error',updateMessage='rate limit'} end
      if input=='{' then return {updateState='error'} end
      if input=='[]' then return {updateState='no-release'} end
      local tag=input[1].tag_name
      return {updateState=tag=='v0.1.4-preview.1' and 'current' or 'available',latestTag=tag,
        latestURL='https://github.com/Ry00ki/wallpaper-veil/releases/tag/'..tag}
    end}
  local env=setmetatable({appSettings={menuItems=function() return {} end},nativeUI=native,support='/mock',after=after,
    os={getenv=function(key)if key=='WV_UPDATE_TEST_CHANNEL' then return mode=='install' and 'stable' or '' end;return '1' end,date=os.date},
    hs={timer={secondsSinceEpoch=function() return now end},json={encode=function(x) return x end},printf=function() end},
    writeReport=function(value,target)
      if target=='/mock/update-check.json' then
        writeAttempts=writeAttempts+1
        if mode=='write' and writeAttempts==1 then error('report fixture failure') end
      end
      reports[target]=value
    end},{__index=_G})
  assert(load(block,'@ui-test-poll','t',env))()
  local steps=0
  while #queue>0 do
    table.sort(queue,function(a,b) return a.at==b.at and a.seq<b.seq or a.at<b.at end)
    local next=table.remove(queue,1); now=next.at; next.fn(); steps=steps+1
    assert(steps<1000,'unbounded deferred callbacks')
  end
  assert(reports['/mock/ui-check.json'].ok,'fixture qualification failed in '..mode)
  local result=assert(reports['/mock/update-check.json'],'missing terminal receipt in '..mode)
  if mode=='install' then assert(closed==0 and installs==1 and result.updateInstallationRequested,'Active update was cancelled by qualification cleanup')
  else assert(closed>0,'About left open in '..mode)end
  if mode=='success' or mode=='install' then
    assert(result.ok and cancelled==0,'success was canceled or failed')
    assert(result.desktopControlSettingsDispatched==false,'Unchanged permission route was unexpectedly opened')
    assert(autoChecks==1,'Automatic About check was not qualified once')
  else
    assert(not result.ok and cancelled>0,'error not canceled/failed in '..mode)
    assert(result.error and #result.error>0,'terminal cause absent in '..mode)
  end
  if mode=='deadline' then assert(result.qualificationTimedOut and not result.updateInProgress) end
  count=count+1; print('PASS UI poll '..mode)
end
for _,mode in ipairs({'success','diagnostics','capture','write','deadline','install'}) do scenario(mode) end
print('PASS '..count..' deferred UI cleanup scenarios')
