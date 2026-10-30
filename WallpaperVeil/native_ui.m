#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <ServiceManagement/ServiceManagement.h>
#include "lua.h"
#include "lauxlib.h"
#import "update_check.h"

// App-owned UI only. Never alter NSWindowController or another application's UI.
static NSString * const WVName = @"Wallpaper Veil";
static NSString * const WVRepository = @"https://github.com/Ry00ki/wallpaper-veil";
static BOOL WVConfigured = NO;
static BOOL WVPreferencesSuppressed = NO;
static BOOL WVConsoleSuppressed = NO;

@interface WVUIController : NSObject <NSWindowDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSWindow *aboutWindow;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSButton *releaseButton;
@property(nonatomic, strong) NSTextField *updateLabel;
@property(nonatomic, strong) NSProgressIndicator *updateProgress;
@property(nonatomic, strong) NSURLSession *updateSession;
@property(nonatomic, strong) NSURLSessionDataTask *updateTask;
@property(nonatomic, strong) NSMutableArray *releasePages;
@property(nonatomic, copy) NSDictionary *updateResult;
@property(nonatomic) NSUInteger updateGeneration;
- (void)checkForUpdates:(id)sender;
- (void)openRelease:(id)sender;
- (void)finishUpdate:(NSDictionary *)result;
- (void)fetchReleasePage:(NSUInteger)page generation:(NSUInteger)generation;
- (void)showAbout:(id)sender;
- (void)openRepository:(id)sender;
- (void)openNotices:(id)sender;
- (void)quit:(id)sender;
@end
static WVUIController *WVController;

static NSImage *WVIcon(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *configured = bundle.infoDictionary[@"CFBundleIconFile"];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObjects:@"WallpaperVeil.icns", nil];
    if (configured.length) [names addObject:configured.pathExtension.length ? configured : [configured stringByAppendingPathExtension:@"icns"]];
    [names addObject:@"AppIcon.icns"];
    for (NSString *name in names) {
        NSString *path = [bundle.resourcePath stringByAppendingPathComponent:name];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) return image;
    }
    return nil;
}

static NSTextField *WVLabel(NSString *text, NSRect frame, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.alignment = NSTextAlignmentCenter;
    label.selectable = YES;
    return label;
}

@implementation WVUIController
- (void)makeAbout {
    if (self.aboutWindow) return;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 550)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = WVName;
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSView *content = window.contentView;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(212, 430, 96, 96)];
    icon.image = WVIcon();
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:icon];
    [content addSubview:WVLabel(WVName, NSMakeRect(30, 390, 460, 32), 25, NSFontWeightSemibold)];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"Unknown";
    NSString *build = info[@"CFBundleVersion"] ?: @"Unknown";
    NSTextField *versionLabel = WVLabel([NSString stringWithFormat:@"Version %@ (build %@)", version, build],
        NSMakeRect(30, 365, 460, 20), 13, NSFontWeightRegular);
    versionLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:versionLabel];
    NSString *channel = info[@"WVReleaseChannel"] ?: @"Unknown";
    NSString *tag = info[@"WVReleaseTag"] ?: @"Unversioned build";
    NSTextField *releaseLabel = WVLabel([NSString stringWithFormat:@"%@ · %@", channel.capitalizedString, tag],
        NSMakeRect(30, 341, 460, 20), 12, NSFontWeightRegular);
    releaseLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:releaseLabel];
    NSTextField *detail = WVLabel(@"Standalone macOS app\nMIT licence. Open-source credits and additional notices\nare included with the app.",
        NSMakeRect(30, 276, 460, 58), 12, NSFontWeightRegular);
    detail.maximumNumberOfLines = 3;
    detail.cell.usesSingleLineMode = NO;
    detail.cell.wraps = YES;
    detail.cell.scrollable = NO;
    detail.lineBreakMode = NSLineBreakByWordWrapping;
    detail.textColor = NSColor.secondaryLabelColor;
    [content addSubview:detail];
    self.updateButton = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkForUpdates:)];
    self.updateButton.frame = NSMakeRect(160, 236, 200, 32);
    self.updateButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.updateButton];
    self.updateProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(373, 245, 16, 16)];
    self.updateProgress.style = NSProgressIndicatorStyleSpinning;
    self.updateProgress.displayedWhenStopped = NO;
    [content addSubview:self.updateProgress];
    self.updateLabel = WVLabel(@"Check GitHub for a newer release.\nNo automatic downloads or installation.",
        NSMakeRect(30, 170, 460, 58), 12, NSFontWeightRegular);
    self.updateLabel.maximumNumberOfLines = 3;
    self.updateLabel.cell.usesSingleLineMode = NO;
    self.updateLabel.cell.wraps = YES;
    self.updateLabel.cell.scrollable = NO;
    self.updateLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.updateLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.updateLabel];
    self.releaseButton = [NSButton buttonWithTitle:@"View Release on GitHub" target:self action:@selector(openRelease:)];
    self.releaseButton.frame = NSMakeRect(140, 132, 240, 32);
    self.releaseButton.bezelStyle = NSBezelStyleRounded;
    self.releaseButton.hidden = YES;
    [content addSubview:self.releaseButton];
    NSButton *repository = [NSButton buttonWithTitle:@"Open GitHub Repository"
        target:self action:@selector(openRepository:)];
    repository.frame = NSMakeRect(140, 87, 240, 32);
    repository.bezelStyle = NSBezelStyleRounded;
    [content addSubview:repository];
    NSButton *notices = [NSButton buttonWithTitle:@"Third-Party Notices"
        target:self action:@selector(openNotices:)];
    notices.frame = NSMakeRect(155, 45, 210, 32);
    notices.bezelStyle = NSBezelStyleRounded;
    [content addSubview:notices];
    NSTextField *manual = WVLabel(@"Updates are checked only when you click. Installation stays manual.",
        NSMakeRect(20, 14, 480, 18), 10.5, NSFontWeightRegular);
    manual.textColor = NSColor.secondaryLabelColor;
    [content addSubview:manual];
    self.updateResult = @{@"state": @"idle"};
    self.aboutWindow = window;
}
- (void)finishUpdate:(NSDictionary *)result {
    self.updateResult = result;
    self.updateLabel.stringValue = result[@"message"] ?: @"";
    self.updateButton.enabled = YES;
    self.updateButton.title = @"Check Again";
    [self.updateProgress stopAnimation:nil];
    self.releaseButton.hidden = ![result[@"latestURL"] length];
    [self.updateSession finishTasksAndInvalidate];
    self.updateSession = nil;
    self.updateTask = nil;
    self.releasePages = nil;
}
- (void)checkForUpdates:(id)sender {
    (void)sender;
    [self makeAbout];
    if (self.updateTask) return;
    self.updateGeneration++;
    self.releasePages = [NSMutableArray array];
    self.updateResult = @{@"state": @"checking"};
    self.updateLabel.stringValue = @"Checking published GitHub releases…";
    self.releaseButton.hidden = YES;
    self.updateButton.enabled = NO;
    [self.updateProgress startAnimation:nil];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 15;
    configuration.timeoutIntervalForResource = 45;
    self.updateSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [self fetchReleasePage:1 generation:self.updateGeneration];
}
- (void)fetchReleasePage:(NSUInteger)page generation:(NSUInteger)generation {
    // Never follow a server-supplied pagination URL or an asset download URL.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/Ry00ki/wallpaper-veil/releases?per_page=100&page=%lu", (unsigned long)page]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2026-03-10" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"Wallpaper-Veil-Manual-Update-Check" forHTTPHeaderField:@"User-Agent"];
    self.updateTask = [self.updateSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.updateGeneration) return;
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            NSDictionary *result = WVReleaseResponse(data, http.statusCode, http.allHeaderFields, error);
            if (result[@"state"]) { [self finishUpdate:result]; return; }
            NSArray *releases = result[@"releases"];
            [self.releasePages addObjectsFromArray:releases];
            if (WVReleasePageHasNext(http.allHeaderFields, releases.count)) {
                if (page >= 10) {
                    [self finishUpdate:WVUpdateError(@"There are more releases than this check can examine. Visit the repository's Releases page; no up-to-date result can be confirmed.")];
                    return;
                }
                self.updateLabel.stringValue = @"Checking more published GitHub releases…";
                [self fetchReleasePage:page + 1 generation:generation];
                return;
            }
            NSDictionary *info = NSBundle.mainBundle.infoDictionary;
            [self finishUpdate:WVEvaluateReleases(self.releasePages, info[@"WVReleaseTag"], info[@"WVReleaseChannel"])];
        });
    }];
    [self.updateTask resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    // A repository relocation or redirect needs a reviewed source change.
    completionHandler(nil);
}
- (void)openRelease:(id)sender {
    (void)sender;
    NSString *tag = self.updateResult[@"latestTag"];
    NSString *url = WVTrustedReleaseURL(tag);
    if (!url || ![url isEqualToString:self.updateResult[@"latestURL"]]) return;
    if (![NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]]) {
        self.updateLabel.stringValue = @"The release page could not be opened in your default browser. Try again or open the repository's Releases page.";
    }
}
- (void)showAbout:(id)sender {
    (void)sender;
    [self makeAbout];
    if (!self.aboutWindow.visible) [self.aboutWindow center];
    [self.aboutWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)openRepository:(id)sender {
    (void)sender;
    BOOL opened = [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:WVRepository]];
    if (!opened) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = WVName;
        alert.informativeText = @"The repository could not be opened in your default browser.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}
- (void)openNotices:(id)sender {
    (void)sender;
    NSString *directory = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Acknowledgements"];
    NSString *readme = [directory stringByAppendingPathComponent:@"THIRD_PARTY_NOTICES.md"];
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:readme];
    NSString *target = exists ? readme : directory;
    BOOL opened = [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:target]];
    if (!opened) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = WVName;
        alert.informativeText = @"The bundled Third-Party Notices could not be opened.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}
- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}
@end

static void WVSuppressEngineWindow(id self, SEL command, id sender) {
    (void)command; (void)sender;
    // Limit suppression to these engine controller classes. Do not instantiate
    // their windows merely to suppress a show request.
    if ([self isKindOfClass:NSWindowController.class]) {
        NSWindowController *controller = self;
        if (controller.isWindowLoaded) [controller.window orderOut:nil];
    }
}

static BOOL WVInstallScopedSuppression(NSString *name) {
    Class target = NSClassFromString(name);
    if (!target || target == NSWindowController.class) return NO;
    SEL selector = @selector(showWindow:);
    Method inheritedOrOwn = class_getInstanceMethod(target, selector);
    if (!inheritedOrOwn) return NO;
    const char *encoding = method_getTypeEncoding(inheritedOrOwn);
    if (class_getMethodImplementation(target, selector) == (IMP)WVSuppressEngineWindow) return YES;
    // Console inherits showWindow:. Preferences has its own implementation.
    // Add on the concrete class first; replace only that class if needed.
    if (!class_addMethod(target, selector, (IMP)WVSuppressEngineWindow, encoding)) {
        class_replaceMethod(target, selector, (IMP)WVSuppressEngineWindow, encoding);
    }
    return class_getMethodImplementation(target, selector) == (IMP)WVSuppressEngineWindow;
}

static void WVBuildMainMenu(void) {
    NSMenu *main = [[NSMenu alloc] initWithTitle:WVName];
    NSMenuItem *application = [[NSMenuItem alloc] initWithTitle:WVName action:NULL keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:WVName];
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About Wallpaper Veil"
        action:@selector(showAbout:) keyEquivalent:@""];
    about.target = WVController;
    [menu addItem:about];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Wallpaper Veil"
        action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = WVController;
    quit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:quit];
    application.submenu = menu;
    [main addItem:application];
    NSApp.mainMenu = main;
}

static void WVConfigureOnMain(void) {
    if (!WVController) WVController = [[WVUIController alloc] init];
    WVPreferencesSuppressed = WVInstallScopedSuppression(@"MJPreferencesWindowController");
    WVConsoleSuppressed = WVInstallScopedSuppression(@"MJConsoleWindowController");
    for (NSWindow *window in NSApp.windows) {
        NSWindowController *controller = window.windowController;
        Class preferences = NSClassFromString(@"MJPreferencesWindowController");
        Class console = NSClassFromString(@"MJConsoleWindowController");
        if ((preferences && [controller isKindOfClass:preferences]) ||
            (console && [controller isKindOfClass:console])) [window orderOut:nil];
    }
    WVBuildMainMenu();
    WVConfigured = WVPreferencesSuppressed && WVConsoleSuppressed;
}

static void WVOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}
static void WVSetBoolean(lua_State *L, const char *key, BOOL value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, key);
}
static void WVSetString(lua_State *L, const char *key, NSString *value) {
    lua_pushstring(L, (value ?: @"").UTF8String); lua_setfield(L, -2, key);
}
static NSDictionary *WVLoginCommand(NSString *command) {
    NSURL *outer = NSBundle.mainBundle.bundleURL;
    for (NSUInteger index = 0; index < 3; index++) outer = outer.URLByDeletingLastPathComponent;
    NSBundle *launcher = [NSBundle bundleWithURL:outer];
    if (![launcher.bundleIdentifier isEqualToString:@"com.ry00ki.wallpaperveil.launcher"] ||
        ![launcher.executableURL.lastPathComponent isEqualToString:@"WallpaperVeil"]) {
        return @{@"ok": @NO, @"statusString": @"unavailable",
                 @"error": @{@"description": @"The installed Wallpaper Veil launcher could not be found."}};
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = launcher.executableURL;
    task.arguments = @[command];
    NSPipe *output = NSPipe.pipe;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return @{@"ok": @NO, @"statusString": @"unavailable",
                 @"error": @{@"description": error.localizedDescription ?: @"The login setting is unavailable."}};
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.01];
    if (task.running) {
        [task terminate];
        return @{@"ok": @NO, @"statusString": @"unavailable",
                 @"error": @{@"description": @"The login setting did not respond. Check Login Items in System Settings."}};
    }
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![result isKindOfClass:NSDictionary.class]) {
        return @{@"ok": @NO, @"statusString": @"unavailable",
                 @"error": @{@"description": @"The login setting could not be read. Check Login Items in System Settings."}};
    }
    return result;
}

static int WVPushLoginStatus(lua_State *L, NSDictionary *status) {
    lua_newtable(L);
    for (NSString *key in @[@"ok", @"supported", @"registered", @"enabled", @"requiresApproval", @"changed"])
        WVSetBoolean(L, key.UTF8String, [status[key] boolValue]);
    for (NSString *key in @[@"statusString", @"targetBundleID", @"registration"])
        WVSetString(L, key.UTF8String, status[key]);
    WVSetString(L, "error", [status[@"error"] isKindOfClass:NSDictionary.class] ? status[@"error"][@"description"] : nil);
    return 1;
}

static int WVLoginStatus(lua_State *L) {
    return WVPushLoginStatus(L, WVLoginCommand(@"--login-status"));
}

static int WVSetLaunchAtLogin(lua_State *L) {
    BOOL enabled = lua_toboolean(L, 1);
    NSDictionary *result = WVLoginCommand(enabled ? @"--enable-login" : @"--disable-login");
    if (![result[@"ok"] boolValue]) {
        WVOnMain(^{
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Wallpaper Veil";
            alert.informativeText = @"The login setting could not be changed. Check Login Items in System Settings and try again.";
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        });
    }
    return WVPushLoginStatus(L, result);
}

static int WVOpenLoginSettings(lua_State *L) {
    WVOnMain(^{ [SMAppService openSystemSettingsLoginItems]; });
    lua_pushboolean(L, YES);
    return 1;
}

static int WVDiagnostics(lua_State *L) {
    __block NSDictionary *values;
    WVOnMain(^{
        BOOL engineVisible = NO;
        for (NSWindow *window in NSApp.windows) {
            NSWindowController *controller = window.windowController;
            Class preferences = NSClassFromString(@"MJPreferencesWindowController");
            Class console = NSClassFromString(@"MJConsoleWindowController");
            if (window.visible && ((preferences && [controller isKindOfClass:preferences]) ||
                (console && [controller isKindOfClass:console]))) engineVisible = YES;
        }
        NSMutableArray<NSString *> *menuItems = [NSMutableArray array];
        for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
            if (![top.title isEqualToString:WVName]) continue;
            for (NSMenuItem *item in top.submenu.itemArray) {
                if ([item.title isEqualToString:@"About Wallpaper Veil"] ||
                    [item.title isEqualToString:@"Quit Wallpaper Veil"]) [menuItems addObject:item.title];
            }
        }
        NSMutableArray<NSString *> *aboutText = [NSMutableArray array];
        NSMutableArray<NSString *> *aboutButtons = [NSMutableArray array];
        BOOL repositoryWired = NO, noticesWired = NO, updateWired = NO, releaseWired = NO, iconPresent = NO;
        for (NSView *view in WVController.aboutWindow.contentView.subviews) {
            if ([view isKindOfClass:NSTextField.class]) {
                [aboutText addObject:((NSTextField *)view).stringValue ?: @""];
            } else if ([view isKindOfClass:NSButton.class]) {
                NSButton *button = (NSButton *)view;
                [aboutButtons addObject:button.title ?: @""];
                if ([button.title isEqualToString:@"Open GitHub Repository"])
                    repositoryWired = button.target == WVController && button.action == @selector(openRepository:);
                if ([button.title isEqualToString:@"Third-Party Notices"])
                    noticesWired = button.target == WVController && button.action == @selector(openNotices:);
                if (button == WVController.updateButton)
                    updateWired = button.target == WVController && button.action == @selector(checkForUpdates:);
                if (button == WVController.releaseButton)
                    releaseWired = button.target == WVController && button.action == @selector(openRelease:);
            } else if ([view isKindOfClass:NSImageView.class]) {
                iconPresent = ((NSImageView *)view).image != nil;
            }
        }
        values = @{@"configured": @(WVConfigured), @"preferencesSuppressed": @(WVPreferencesSuppressed),
            @"consoleSuppressed": @(WVConsoleSuppressed), @"engineWindowsVisible": @(engineVisible),
            @"nativeMainMenuReady": @([NSApp.mainMenu.title isEqualToString:WVName]),
            @"aboutWindowCreated": @(WVController.aboutWindow != nil),
            @"aboutVisible": @(WVController.aboutWindow.visible),
            @"aboutTitle": WVController.aboutWindow.title ?: @"", @"menuItems": menuItems,
            @"aboutText": aboutText, @"aboutButtons": aboutButtons, @"repositoryURL": WVRepository,
            @"repositoryActionWired": @(repositoryWired), @"noticesActionWired": @(noticesWired),
            @"aboutIconPresent": @(iconPresent), @"updateActionWired": @(updateWired),
            @"releaseActionWired": @(releaseWired), @"updateInProgress": @(WVController.updateTask != nil),
            @"currentReleaseTag": NSBundle.mainBundle.infoDictionary[@"WVReleaseTag"] ?: @"",
            @"releaseChannel": NSBundle.mainBundle.infoDictionary[@"WVReleaseChannel"] ?: @"",
            @"currentVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
            @"currentBuild": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"",
            @"updateState": WVController.updateResult[@"state"] ?: @"idle",
            @"updateMessage": WVController.updateLabel.stringValue ?: @"",
            @"latestTag": WVController.updateResult[@"latestTag"] ?: @"",
            @"latestURL": WVController.updateResult[@"latestURL"] ?: @""};
    });
    lua_newtable(L);
    for (NSString *key in @[@"configured", @"preferencesSuppressed", @"consoleSuppressed",
        @"engineWindowsVisible", @"nativeMainMenuReady", @"aboutWindowCreated", @"aboutVisible",
        @"repositoryActionWired", @"noticesActionWired", @"aboutIconPresent",
        @"updateActionWired", @"releaseActionWired", @"updateInProgress"])
        WVSetBoolean(L, key.UTF8String, [values[key] boolValue]);
    WVSetString(L, "aboutTitle", values[@"aboutTitle"]);
    WVSetString(L, "repositoryURL", values[@"repositoryURL"]);
    for (NSString *key in @[@"currentReleaseTag", @"releaseChannel", @"currentVersion", @"currentBuild",
        @"updateState", @"updateMessage", @"latestTag", @"latestURL"])
        WVSetString(L, key.UTF8String, values[key]);
    for (NSString *key in @[@"menuItems", @"aboutText", @"aboutButtons"]) {
        lua_newtable(L);
        NSInteger index = 1;
        for (NSString *title in values[key]) {
            lua_pushstring(L, title.UTF8String); lua_rawseti(L, -2, index++);
        }
        lua_setfield(L, -2, key.UTF8String);
    }
    return 1;
}
static int WVConfigure(lua_State *L) {
    WVOnMain(^{ WVConfigureOnMain(); });
    return WVDiagnostics(L);
}
static int WVShowAbout(lua_State *L) {
    WVOnMain(^{
        if (!WVController) WVConfigureOnMain();
        [WVController showAbout:nil];
    });
    lua_pushboolean(L, YES); return 1;
}
static int WVCheckForUpdates(lua_State *L) {
    WVOnMain(^{
        if (!WVController) WVConfigureOnMain();
        [WVController showAbout:nil];
        [WVController checkForUpdates:nil];
    });
    lua_pushboolean(L, YES); return 1;
}
// Test mode can render deterministic results without any network or browser action.
static int WVTestUpdateResponse(lua_State *L) {
    if (strcmp(getenv("WV_UI_TEST") ?: "", "1") != 0) return luaL_error(L, "Update fixtures require WV_UI_TEST=1");
    size_t length;
    const char *json = luaL_checklstring(L, 1, &length);
    NSData *data = [NSData dataWithBytes:json length:length];
    NSInteger status = luaL_optinteger(L, 2, 200);
    __block NSDictionary *result = WVReleaseResponse(data, status, status == 403 ? @{@"X-RateLimit-Remaining": @"0"} : @{}, nil);
    WVOnMain(^{
        if (!WVController) WVConfigureOnMain();
        [WVController makeAbout];
        WVController.updateGeneration++;
        [WVController.updateTask cancel];
        if (result[@"releases"]) result = WVEvaluateReleases(result[@"releases"], NSBundle.mainBundle.infoDictionary[@"WVReleaseTag"], NSBundle.mainBundle.infoDictionary[@"WVReleaseChannel"]);
        [WVController finishUpdate:result];
    });
    return WVDiagnostics(L);
}
static int WVCloseAbout(lua_State *L) {
    WVOnMain(^{ [WVController.aboutWindow orderOut:nil]; });
    lua_pushboolean(L, YES); return 1;
}
static int WVSaveAboutPreview(lua_State *L) {
    NSString *path = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    __block BOOL saved = NO;
    __block NSString *errorText = nil;
    WVOnMain(^{
        NSView *view = WVController.aboutWindow.contentView;
        if (!view) { errorText = @"Show the app-owned About window before capturing its view"; return; }
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        if (!bitmap) { errorText = @"The About view could not create an image buffer"; return; }
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        saved = [png writeToFile:path options:NSDataWritingAtomic error:&error];
        if (!saved) errorText = error.localizedDescription ?: @"The About view image could not be saved";
    });
    lua_pushboolean(L, saved);
    if (!saved) { lua_pushstring(L, (errorText ?: @"Unknown capture error").UTF8String); return 2; }
    return 1;
}
__attribute__((visibility("default"))) int luaopen_wallpaperveil_ui(lua_State *L) {
    static const luaL_Reg functions[] = {
        {"configure", WVConfigure}, {"showAbout", WVShowAbout},
        {"diagnostics", WVDiagnostics}, {"closeAbout", WVCloseAbout},
        {"checkForUpdates", WVCheckForUpdates}, {"testUpdateResponse", WVTestUpdateResponse},
        {"saveAboutPreview", WVSaveAboutPreview},
        {"loginStatus", WVLoginStatus}, {"setLaunchAtLogin", WVSetLaunchAtLogin},
        {"openLoginSettings", WVOpenLoginSettings}, {NULL, NULL}
    };
    luaL_newlib(L, functions);
    return 1;
}
