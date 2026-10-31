-- State/action regressions. No native app, macOS preferences or permission changes.
local root = arg[1] or "WallpaperVeil/core"
local settings = assert(loadfile(root .. "/app_settings.lua"))()
local assertions = 0
local function check(value, message)
    assertions=assertions+1
    assert(value, message)
end
local function fixture()
    local w={granted=false, prompts=0, reads=0, loginReads=0, loginOpens=0, accessOpens=0, writes={},
        login={ok=true,enabled=false,registered=false,requiresApproval=false},pane="Device Control and Data Access"}
    hs={accessibilityState=function(prompt)
        if prompt then w.prompts=w.prompts+1 else w.reads=w.reads+1 end
        return w.granted
    end}
    w.native={loginStatus=function() w.loginReads=w.loginReads+1;return w.login end,
        setLaunchAtLogin=function(value) w.writes[#w.writes+1]=value;return true end,
        openLoginSettings=function() w.loginOpens=w.loginOpens+1;return true end,
        openAccessibilitySettings=function() w.accessOpens=w.accessOpens+1;return true end,
        accessibilitySettingsInfo=function() return {paneName=w.pane} end}
    function w.menu() return settings.menuItems(w.native) end
    return w
end
local function find(items,title)
    for _,item in ipairs(items) do if item.title==title then return item end end
    error("Missing menu item: " .. title)
end

do
    local w=fixture();local items=w.menu()
    check(items[1].title=="Startup" and items[1].disabled,"Startup has an explicit group")
    local startup=find(items,"Start Wallpaper Veil when I sign in")
    check(startup.checked==false and not startup.disabled,"Disabled startup is unchecked and actionable")
    check(find(items,"Desktop widget controls").disabled,"Desktop controls have their own group")
    check(find(items,"Desktop control access not enabled").checked==false,"Untrusted process is not ticked")
    check(find(items,"Privacy & Security → Device Control and Data Access").disabled,"Current OS permission pane is named")
    check(w.prompts==0 and #w.writes==0,"Opening the menu never prompts or changes startup")
    startup.fn();check(w.writes[1]==true,"Unchecked startup requests enable")
    find(items,"Open System Settings → General → Login Items…").fn()
    check(w.loginOpens==1 and w.accessOpens==0,"Login link opens only Login Items")
end
do
    local w=fixture();w.granted=true;w.login.enabled=true;w.login.registered=true
    local items=w.menu()
    check(find(items,"Start Wallpaper Veil when I sign in").checked==true,"Enabled OS startup is ticked")
    check(find(items,"Desktop control access enabled").checked==true,"Current process trust is ticked")
    find(items,"Manage Desktop Control Access…").fn()
    check(w.accessOpens==1 and w.prompts==0,"Manage always opens the pane without another permission prompt")
    check(#w.writes==0 and w.loginOpens==0,"Managing desktop access cannot change startup")
    find(items,"Start Wallpaper Veil when I sign in").fn()
    check(w.writes[1]==false,"Enabled startup requests disable")
end
do
    local w=fixture();w.login.registered=true;w.login.requiresApproval=true
    local items=w.menu()
    check(find(items,"Start Wallpaper Veil when I sign in").checked==false,"Pending registration is not presented as active startup")
    check(find(items,"Waiting for macOS approval; startup is not active").disabled,"Pending approval is explicit")
    find(items,"Start Wallpaper Veil when I sign in").fn()
    check(w.loginOpens==1 and #w.writes==0,"Pending approval opens settings instead of registering again")
end
do
    local w=fixture();w.login={ok=false}
    local items=w.menu()
    check(find(items,"Start Wallpaper Veil when I sign in").disabled,"Unavailable startup cannot be toggled")
    check(find(items,"Startup setting is unavailable").disabled,"Unavailable state is explained")
    find(items,"Start Wallpaper Veil when I sign in").fn()
    check(#w.writes==0,"A stale action cannot mutate an unavailable startup setting")
end
do
    local w=fixture();local items=w.menu()
    local enable=find(items,"Enable Desktop Control Access…")
    enable.fn()
    check(w.prompts==1 and w.accessOpens==1,"Enable requests current-process permission and opens its settings pane")
    check(find(w.menu(),"Desktop control access not enabled").checked==false,"A request alone never implies a permission grant")
    w.granted=true;w.login.enabled=true
    local refreshed=w.menu()
    check(find(refreshed,"Desktop control access enabled").checked==true,"Reopening reads a new permission grant")
    check(find(refreshed,"Start Wallpaper Veil when I sign in").checked==true,"Reopening reads a changed startup setting")
    enable.fn()
    check(w.prompts==1 and w.accessOpens==2,"A stale Enable action rechecks trust and still opens settings")
    w.granted=false
    find(refreshed,"Manage Desktop Control Access…").fn()
    check(w.prompts==2 and w.accessOpens==3,"A stale Manage action rechecks revoked trust")
end
do
    local w=fixture();local startup=find(w.menu(),"Start Wallpaper Veil when I sign in")
    w.login.enabled=true;startup.fn()
    check(w.writes[1]==false,"Startup action rechecks changes made after menu opening")
    w.pane="Accessibility"
    check(find(w.menu(),"Privacy & Security → Accessibility").disabled,"Earlier macOS pane name remains clear")
end
do
    local w=fixture()
    w.native.loginStatus=function() error("unavailable native status") end
    hs.accessibilityState=function() error("permission query failed") end
    local items=w.menu()
    check(find(items,"Start Wallpaper Veil when I sign in").disabled,"Status query failures are unavailable, never enabled")
    check(find(items,"Desktop control access not enabled").checked==false,"Permission query errors never imply trust")
    find(items,"Enable Desktop Control Access…").fn()
    check(w.accessOpens==1,"A failed prompt cannot prevent opening the settings pane")
end
print("PASS " .. assertions .. " app-settings state/action assertions")
