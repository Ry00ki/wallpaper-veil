-- Notification Center geometry detector and bounded, verified clock reopening.
-- No input synthesis, focus changes, timers, or preference writes.
local M = {}
local NC_BUNDLE = "com.apple.notificationcenterui"
local OWNER_BUNDLES = {"com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"}
local OWNERS = {}
for _, name in ipairs(OWNER_BUNDLES) do OWNERS[name] = true end
local CLOCK_IDS = { ["clock"]=true, ["com.apple.menuextra.clock"]=true,
    ["com.apple.controlcenter.clock"]=true }
local cache = {}

local function sameFrame(a,b)
    return a and b and math.abs(a.x-b.x)<=2 and math.abs(a.y-b.y)<=2
        and math.abs(a.w-b.w)<=2 and math.abs(a.h-b.h)<=2
end

local function screenFrames()
    local result = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local f=screen:fullFrame()
        result[#result+1]={x=f.x,y=f.y,w=f.w,h=f.h}
    end
    return result
end

local function detect()
    local frames=screenFrames()
    if #frames==0 then return nil,"No display frame is available" end
    local pids={}
    for _, app in ipairs(hs.application.applicationsForBundleID(NC_BUNDLE)) do pids[app:pid()]=true end
    if next(pids)==nil then return {open=false} end
    local windows=hs.window.list(true)
    if type(windows)~="table" then return nil,"The window list is unavailable" end
    for _, window in ipairs(windows) do
        local bounds=window.kCGWindowBounds
        -- list(true) already enumerates only on-screen windows. IsOnscreen is
        -- optional in CoreGraphics dictionaries; an explicit false is rejected.
        if pids[window.kCGWindowOwnerPID] and window.kCGWindowLayer==21
            and window.kCGWindowIsOnscreen~=false and (window.kCGWindowAlpha or 0)>0.01
            and type(bounds)=="table" then
            local frame={x=bounds.X,y=bounds.Y,w=bounds.Width,h=bounds.Height}
            if type(frame.x)=="number" and type(frame.y)=="number"
                and type(frame.w)=="number" and type(frame.h)=="number" then
                for _, display in ipairs(frames) do
                    if sameFrame(frame,display) then
                        return {open=true,frame=display,windowID=window.kCGWindowNumber,
                            pid=window.kCGWindowOwnerPID}
                    end
                end
            end
        end
    end
    return {open=false}
end

function M.snapshot()
    local ok,state,message=pcall(detect)
    if not ok then return nil,"Notification Center visibility could not be read" end
    return state,message
end

local function frameKey(frame)
    return string.format("%g:%g:%g:%g",frame.x,frame.y,frame.w,frame.h)
end

local function validClock(element,frame)
    if not element or not element:setTimeout(0.02) or element:isValid()~=true then return nil end
    if element:attributeValue("AXRole")~="AXMenuBarItem" then return nil end
    if not CLOCK_IDS[element:attributeValue("AXIdentifier")] then return nil end
    local app=hs.application.applicationForPID(element:pid())
    if not app or not OWNERS[app:bundleID()] then return nil end
    local position=element:attributeValue("AXPosition")
    local size=element:attributeValue("AXSize")
    if not position or not size then return nil end
    local w,h=size.w or size.width,size.h or size.height
    if type(position.x)~="number" or type(position.y)~="number"
        or type(w)~="number" or type(h)~="number" or w<=0 or h<=0 then return nil end
    local cx,cy=position.x+w/2,position.y+h/2
    if cx<frame.x or cx>=frame.x+frame.w or cy<frame.y or cy>=frame.y+math.min(80,frame.h) then return nil end
    return element
end

local function clockAncestor(element,frame)
    for _=1,5 do
        if not element or not element:setTimeout(0.02) then break end
        local role=element:attributeValue("AXRole")
        if role=="AXMenuBarItem" then return validClock(element,frame) end
        if role=="AXApplication" or role=="AXMenuBar" then break end
        element=element:attributeValue("AXParent")
    end
end

local function searchMenuTrees(frame)
    local remaining=80
    for _, bundle in ipairs(OWNER_BUNDLES) do
        for _, app in ipairs(hs.application.applicationsForBundleID(bundle)) do
            local root=hs.axuielement.applicationElement(app)
            local queue={{element=root,depth=0}}
            local index=1
            while queue[index] and remaining>0 do
                local item=queue[index];index=index+1;remaining=remaining-1
                local element=item.element
                if element and element:setTimeout(0.02) then
                    local role=element:attributeValue("AXRole")
                    if role=="AXMenuBarItem" then
                        local found=validClock(element,frame)
                        if found then return found end
                    elseif item.depth<3 and (role=="AXApplication" or role=="AXMenuBar" or role=="AXGroup") then
                        for _,child in ipairs(element:attributeValue("AXChildren") or {}) do
                            if #queue>=80 then break end
                            queue[#queue+1]={element=child,depth=item.depth+1}
                        end
                    end
                end
            end
        end
    end
end

local function find(frame)
    if type(frame)~="table" or type(frame.x)~="number" or type(frame.y)~="number"
        or type(frame.w)~="number" or type(frame.h)~="number" then
        return nil,"The original display is unavailable"
    end
    local current=false
    for _, display in ipairs(screenFrames()) do if sameFrame(display,frame) then current=true;break end end
    if not current then return nil,"The original display has changed" end
    local key=frameKey(frame)
    if cache[key] then
        local ok,element=pcall(validClock,cache[key],frame)
        if ok and element then return element end
        cache[key]=nil
    end
    -- Locations are search hints only. Identity, owner, role and display are
    -- validated before AXPress; nothing at an unverified location is clicked.
    for offset=20,260,20 do
        if offset<frame.w then
            local ok,element=pcall(function()
                return clockAncestor(hs.axuielement.systemElementAtPosition({
                    x=frame.x+frame.w-offset,y=frame.y+15}),frame)
            end)
            if ok and element then cache[key]=element;return element end
        end
    end
    -- A hidden/obscured menu bar can block hit testing. Its verified AX menu
    -- item may still be available in Apple's menu-owner hierarchy.
    local element=searchMenuTrees(frame)
    if element then cache[key]=element;return element end
    return nil,"The clock on the original display could not be found"
end

function M.findClock(frame)
    if not hs.accessibilityState(false) then return nil,"Accessibility permission is required to reopen Notification Center" end
    local ok,element,message=pcall(find,frame)
    if not ok then return nil,"The clock could not be inspected" end
    return element,message
end

function M.reopen(previous)
    local current,message=M.snapshot()
    if not current then return false,message end
    if current.open then return true,"Notification Center is already open" end
    local element,reason=M.findClock(previous and previous.frame)
    if not element then return false,reason end
    -- The user may have opened it while clock discovery was running.
    current,message=M.snapshot()
    if not current then return false,message end
    if current.open then return true,"Notification Center is already open" end
    local ok,result=pcall(function() return element:performAction("AXPress") end)
    if not ok or not result then return false,"The clock did not accept the open request" end
    -- AX acceptance does not guarantee the resulting UI state. The caller
    -- must observe a later snapshot to confirm the panel actually reopened.
    return true,"Open request sent"
end

function M.clearCache() cache={} end

return M
