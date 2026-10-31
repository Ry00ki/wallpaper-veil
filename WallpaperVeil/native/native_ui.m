#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <ServiceManagement/ServiceManagement.h>
#include "lua.h"
#include "lauxlib.h"
#import "update_check.h"
#import "widget_preferences.h"
#import "update_download.h"
#import "update_package.h"

// App-owned UI only. Never alter NSWindowController or another application's UI.
static NSString * const WVName = @"Wallpaper Veil";
static NSString * const WVRepository = @"https://github.com/Ry00ki/wallpaper-veil";
static BOOL WVConfigured = NO;
static BOOL WVPreferencesSuppressed = NO;
static BOOL WVConsoleSuppressed = NO;
static NSString *WVUpdateAcknowledgedNonce;

@interface WVUIController : NSObject <NSWindowDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSWindow *aboutWindow;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSButton *releaseButton;
@property(nonatomic, strong) NSTextField *updateLabel;
@property(nonatomic, strong) NSProgressIndicator *updateProgress;
@property(nonatomic, strong) NSURLSession *updateSession;
@property(nonatomic, strong) NSURLSessionDataTask *updateTask;
@property(nonatomic, strong) NSTimer *updateDeadline;
@property(nonatomic, strong) NSMutableArray *releasePages;
@property(nonatomic, copy) NSDictionary *updateResult;
@property(nonatomic) NSUInteger updateGeneration;
@property(nonatomic, strong) NSDictionary *catalog;
@property(nonatomic, strong) NSButton *stableButton;
@property(nonatomic, strong) NSButton *previewButton;
@property(nonatomic, strong) NSTextField *stableLabel;
@property(nonatomic, strong) NSTextField *previewLabel;
@property(nonatomic, strong) WVUpdateDownloader *downloader;
@property(nonatomic, copy) NSString *installPhase;
@property(nonatomic) BOOL testingAutoCheck;
@property(nonatomic) NSUInteger installGeneration;
@property(nonatomic, strong) NSTask *installer;
@property(nonatomic, strong) NSTimer *installerPoll;
@property(nonatomic, strong) NSDictionary *installRequest;
- (void)renderCatalog;
- (void)installRelease:(id)sender;
- (void)cancelInstall;
- (void)finishInstallError:(NSString *)message;
- (void)startInstaller:(NSDictionary *)request;

- (void)checkForUpdates:(id)sender;
- (void)cancelUpdateCheck;
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
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,665)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=WVName; window.releasedWhenClosed=NO; window.delegate=self;
    window.tabbingMode=NSWindowTabbingModeDisallowed;
    NSView *content=window.contentView;
    NSImageView *icon=[[NSImageView alloc] initWithFrame:NSMakeRect(232,548,96,96)];
    icon.image=WVIcon();icon.imageScaling=NSImageScaleProportionallyUpOrDown;[content addSubview:icon];
    [content addSubview:WVLabel(WVName,NSMakeRect(20,506,520,34),25,NSFontWeightSemibold)];
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    NSTextField *version=WVLabel([NSString stringWithFormat:@"Version %@ (build %@)",info[@"CFBundleShortVersionString"]?:@"Unknown",info[@"CFBundleVersion"]?:@"Unknown"],NSMakeRect(20,480,520,20),13,NSFontWeightRegular);
    version.textColor=NSColor.secondaryLabelColor;[content addSubview:version];
    NSTextField *channel=WVLabel([NSString stringWithFormat:@"%@ · %@",[info[@"WVReleaseChannel"] capitalizedString]?:@"Unknown",info[@"WVReleaseTag"]?:@""],NSMakeRect(20,456,520,20),12,NSFontWeightRegular);
    channel.textColor=NSColor.secondaryLabelColor;[content addSubview:channel];
    NSTextField *detail=WVLabel(@"Standalone macOS app · MIT licence\nOpen-source credits and additional notices are included.",NSMakeRect(20,408,520,40),12,NSFontWeightRegular);
    detail.maximumNumberOfLines=2;detail.textColor=NSColor.secondaryLabelColor;[content addSubview:detail];
    self.updateButton=[NSButton buttonWithTitle:@"Check Again" target:self action:@selector(checkForUpdates:)];
    self.updateButton.frame=NSMakeRect(195,367,170,30);self.updateButton.bezelStyle=NSBezelStyleRounded;[content addSubview:self.updateButton];
    self.updateProgress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(375,374,16,16)];
    self.updateProgress.style=NSProgressIndicatorStyleSpinning;self.updateProgress.displayedWhenStopped=NO;[content addSubview:self.updateProgress];
    self.updateLabel=WVLabel(@"Checking GitHub releases…",NSMakeRect(20,322,520,38),12,NSFontWeightRegular);
    self.updateLabel.maximumNumberOfLines=2;self.updateLabel.cell.wraps=YES;self.updateLabel.cell.scrollable=NO;self.updateLabel.textColor=NSColor.secondaryLabelColor;[content addSubview:self.updateLabel];
    self.stableLabel=WVLabel(@"Stable release · Recommended",NSMakeRect(20,271,520,42),12,NSFontWeightMedium);self.stableLabel.maximumNumberOfLines=2;[content addSubview:self.stableLabel];
    self.stableButton=[NSButton buttonWithTitle:@"Checking stable release…" target:self action:@selector(installRelease:)];
    self.stableButton.tag=0;self.stableButton.frame=NSMakeRect(115,235,330,30);self.stableButton.bezelStyle=NSBezelStyleRounded;self.stableButton.enabled=NO;[content addSubview:self.stableButton];
    self.previewLabel=WVLabel(@"Preview · Early access builds",NSMakeRect(20,180,520,42),12,NSFontWeightRegular);self.previewLabel.maximumNumberOfLines=2;self.previewLabel.textColor=NSColor.secondaryLabelColor;[content addSubview:self.previewLabel];
    self.previewButton=[NSButton buttonWithTitle:@"Checking preview…" target:self action:@selector(installRelease:)];
    self.previewButton.tag=1;self.previewButton.frame=NSMakeRect(115,145,330,30);self.previewButton.bezelStyle=NSBezelStyleRounded;self.previewButton.enabled=NO;[content addSubview:self.previewButton];
    self.releaseButton=[NSButton buttonWithTitle:@"View Release on GitHub" target:self action:@selector(openRelease:)];
    self.releaseButton.frame=NSMakeRect(35,92,230,30);self.releaseButton.bezelStyle=NSBezelStyleRounded;self.releaseButton.hidden=YES;[content addSubview:self.releaseButton];
    NSButton *repository=[NSButton buttonWithTitle:@"Open GitHub Repository" target:self action:@selector(openRepository:)];
    repository.frame=NSMakeRect(275,92,250,30);repository.bezelStyle=NSBezelStyleRounded;[content addSubview:repository];
    NSButton *notices=[NSButton buttonWithTitle:@"Third-Party Notices" target:self action:@selector(openNotices:)];notices.frame=NSMakeRect(170,48,220,30);notices.bezelStyle=NSBezelStyleRounded;[content addSubview:notices];
    NSTextField *footer=WVLabel(@"Checks on opening. Download & Install restarts the app and keeps your settings.",NSMakeRect(15,14,530,20),10.5,NSFontWeightRegular);footer.textColor=NSColor.secondaryLabelColor;[content addSubview:footer];
    self.updateResult=@{@"state":@"idle"};self.aboutWindow=window;
}
- (void)renderCatalog {
    BOOL busy=self.installPhase.length>0 || self.updateTask!=nil;
    for(NSString *key in @[@"stable",@"preview"]){
        NSDictionary *row=self.catalog[key];BOOL stable=[key isEqual:@"stable"];
        NSButton *button=stable?self.stableButton:self.previewButton;
        NSTextField *label=stable?self.stableLabel:self.previewLabel;
        NSString *title=stable?@"Stable release · Recommended":@"Preview · Early access";
        label.stringValue=[NSString stringWithFormat:@"%@\n%@",title,row[@"message"]?:@"Checking…"];
        NSString *tag=row[@"latestTag"];
        button.title=[row[@"canInstall"] boolValue]?[NSString stringWithFormat:@"Download & Install %@",tag]:
            ([row[@"state"] isEqual:@"current"]?@"Installed":([row[@"state"] isEqual:@"ahead"]?@"Installed version is newer":(tag.length?@"Download unavailable":@"Not published yet")));
        button.enabled=!busy&&[row[@"canInstall"] boolValue];
    }
}
- (void)finishInstallError:(NSString *)message {
    self.installPhase=nil;self.installer=nil;[self.installerPoll invalidate];self.installerPoll=nil;
    self.updateLabel.stringValue=message?:@"The update could not be installed. Your current app has been kept.";
    self.updateButton.title=@"Check Again";self.updateButton.enabled=YES;[self.updateProgress stopAnimation:nil];[self renderCatalog];
}
- (void)cancelInstall {
    if(!self.installPhase.length || [self.installPhase isEqual:@"handoff"])return;
    self.installGeneration++;[self.downloader cancel];self.downloader=nil;
    [self finishInstallError:@"Update cancelled. Your installed app is unchanged."];
}
- (void)installRelease:(id)sender {
    if(self.installPhase.length||self.updateTask)return;
    NSString *key=[sender tag]==1?@"preview":@"stable";NSDictionary *row=self.catalog[key];
    if(![row[@"canInstall"] boolValue])return;
    self.installPhase=@"downloading";NSUInteger generation=++self.installGeneration;
    self.updateButton.title=@"Cancel Download";self.updateButton.enabled=YES;[self.updateProgress startAnimation:nil];[self renderCatalog];
    self.downloader=[WVUpdateDownloader new];
    __weak WVUIController *weakSelf=self;
    [self.downloader startDescriptor:row[@"descriptor"] progress:^(int64_t received,int64_t expected){
        WVUIController *owner=weakSelf;if(!owner||owner.installGeneration!=generation)return;
        owner.updateLabel.stringValue=[NSString stringWithFormat:@"Downloading update… %.0f%%",expected>0?100.0*received/expected:0];
    } completion:^(NSDictionary *result){
        WVUIController *owner=weakSelf;if(!owner)return;
        NSURL *directory=result[@"directoryURL"];
        if(owner.installGeneration!=generation){if(directory)[NSFileManager.defaultManager removeItemAtURL:directory error:NULL];return;}
        owner.downloader=nil;
        if(![result[@"ok"] boolValue]){[owner finishInstallError:result[@"error"]?:@"The download could not be verified. Try again."];return;}
        owner.installPhase=@"verifying";owner.updateLabel.stringValue=@"Verifying the downloaded app…";
        NSURL *zip=result[@"fileURL"];
        NSURL *outer=[NSBundle.mainBundle.bundleURL URLByDeletingLastPathComponent];outer=[outer URLByDeletingLastPathComponent];outer=[outer URLByDeletingLastPathComponent];
        NSURL *jobs=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Wallpaper Veil/Updates"] isDirectory:YES];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSError *error=nil;NSDictionary *request=WVPrepareUpdate(zip,result[@"descriptor"],outer,jobs,getpid(),&error);
            if(directory)[NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{
                WVUIController *current=weakSelf;
                if(!current||current.installGeneration!=generation){if(request)WVDiscardPreparedUpdate(request,NULL);return;}
                if(!request){[current finishInstallError:error.localizedDescription?:@"The downloaded app could not be prepared. Your current app is unchanged."];return;}
                [current startInstaller:request];
            });
        });
    }];
}
- (void)startInstaller:(NSDictionary *)request {
    self.installPhase=@"handoff";self.installRequest=request;self.updateButton.enabled=NO;
    self.updateLabel.stringValue=@"Preparing to restart Wallpaper Veil…";[self renderCatalog];
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:request[@"helperPath"]];task.arguments=@[@"--install",request[@"jobDir"]];
    NSError *error=nil;if(![task launchAndReturnError:&error]){WVDiscardPreparedUpdate(request,NULL);[self finishInstallError:error.localizedDescription];return;}
    self.installer=task;NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    __weak WVUIController *weakSelf=self;
    self.installerPoll=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){
        WVUIController *owner=weakSelf;if(!owner){[timer invalidate];return;}
        NSDictionary *ready=WVReadPrivateUpdateJSON([NSURL fileURLWithPath:[request[@"jobDir"] stringByAppendingPathComponent:@"ready.json"]],NULL);
        if([ready[@"nonce"] isEqual:request[@"nonce"]]&&[ready[@"helperPID"] intValue]==task.processIdentifier&&task.running){
            [timer invalidate];owner.installerPoll=nil;owner.updateLabel.stringValue=@"Installing and restarting…";[NSApp terminate:nil];return;
        }
        if(!task.running||deadline.timeIntervalSinceNow<=0){
            [timer invalidate];owner.installerPoll=nil;
            // The helper never replaces a live original runtime. Retain its
            // journal for recovery; do not delete files it may still own.
            if(task.running)[task terminate];
            [owner finishInstallError:@"The installer could not start. Your current app is still running. Close About and try again."];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.installerPoll forMode:NSRunLoopCommonModes];
}
- (void)windowWillClose:(NSNotification *)notification {
    if(notification.object==self.aboutWindow){[self cancelUpdateCheck];[self cancelInstall];}
}
- (void)finishUpdate:(NSDictionary *)result {
    // Every terminal path invalidates queued callbacks and the whole-check clock.
    self.updateGeneration++;
    [self.updateDeadline invalidate];
    self.updateDeadline = nil;
    [self.updateTask cancel];
    [self.updateSession invalidateAndCancel];
    self.updateResult = result;
    if([result[@"state"] isEqual:@"error"]){NSDictionary *row=@{@"state":@"error",@"message":@"Unable to check right now",@"canInstall":@NO};self.catalog=@{@"stable":row,@"preview":row};}
    self.updateLabel.stringValue = result[@"message"] ?: @"";
    self.updateButton.enabled = YES;
    self.updateButton.title = @"Check Again";
    [self.updateProgress stopAnimation:nil];
    self.releaseButton.hidden = ![result[@"latestURL"] length];
    self.updateSession = nil;
    self.updateTask = nil;
    self.releasePages = nil;
    [self renderCatalog];
}
- (void)cancelUpdateCheck {
    if (!self.updateTask && !self.updateDeadline) return;
    [self finishUpdate:@{@"state": @"cancelled",
        @"message": @"Update check canceled. Click Check Again to retry."}];
}
- (void)checkForUpdates:(id)sender {
    (void)sender;
    [self makeAbout];
    if(self.installPhase.length){[self cancelInstall];return;}
    if (self.updateTask) return;
    self.updateGeneration++;
    self.releasePages = [NSMutableArray array];
    self.updateResult = @{@"state": @"checking"};
    self.updateLabel.stringValue = @"Checking published GitHub releases…";
    self.stableButton.enabled=NO;self.previewButton.enabled=NO;
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
    NSUInteger generation = self.updateGeneration;
    self.updateDeadline = [NSTimer timerWithTimeInterval:45 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        if (generation != self.updateGeneration) return;
        [self finishUpdate:WVUpdateError(@"The update check timed out after 45 seconds. Check your connection and try again.")];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.updateDeadline forMode:NSRunLoopCommonModes];
    [self fetchReleasePage:1 generation:generation];
}
- (void)fetchReleasePage:(NSUInteger)page generation:(NSUInteger)generation {
    // Never follow a server-supplied pagination URL or an asset download URL.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/Ry00ki/wallpaper-veil/releases?per_page=100&page=%lu", (unsigned long)page]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2026-03-10" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"Wallpaper-Veil-Update-Check" forHTTPHeaderField:@"User-Agent"];
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
            self.catalog=WVUpdateCatalog(self.releasePages,info[@"WVReleaseTag"]);
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
    BOOL opening=!self.aboutWindow.visible;
    if (opening) [self.aboutWindow center];
    [self.aboutWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if(opening && (strcmp(getenv("WV_UI_TEST")?:"","1")!=0 || self.testingAutoCheck) && !self.installPhase.length)[self checkForUpdates:nil];
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

static NSString * const WVAccessibilitySettingsURL = @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility";
static NSString * const WVLegacyAccessibilitySettingsURL = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

static NSString *WVAccessibilityPaneName(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ?
        @"Device Control and Data Access" : @"Accessibility";
}

static int WVAccessibilitySettingsInfo(lua_State *L) {
    lua_newtable(L);
    WVSetString(L, "paneName", WVAccessibilityPaneName());
    WVSetString(L, "url", WVAccessibilitySettingsURL);
    WVSetString(L, "subjectBundleID", NSBundle.mainBundle.bundleIdentifier);
    return 1;
}

static int WVOpenAccessibilitySettings(lua_State *L) {
    __block BOOL opened = NO;
    WVOnMain(^{
        // System Settings owns this route; opening it never grants permission.
        // Unlike AX's prompt option this works even when already trusted.
        opened = [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:WVAccessibilitySettingsURL]];
        if (!opened) opened = [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:WVLegacyAccessibilitySettingsURL]];
        if (!opened) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Open Desktop Control Settings";
            alert.informativeText = [NSString stringWithFormat:
                @"Open System Settings → Privacy & Security → %@ to manage Wallpaper Veil's desktop control access.", WVAccessibilityPaneName()];
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        }
    });
    lua_pushboolean(L, opened);
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
            @"releaseActionWired": @(releaseWired),
            @"stableInstallAvailable": @([WVController.catalog[@"stable"][@"canInstall"] boolValue]),
            @"previewInstallAvailable": @([WVController.catalog[@"preview"][@"canInstall"] boolValue]),
            @"stableTag": WVController.catalog[@"stable"][@"latestTag"]?:@"",
            @"previewTag": WVController.catalog[@"preview"][@"latestTag"]?:@"",
            @"stableState": WVController.catalog[@"stable"][@"state"]?:@"idle",
            @"previewState": WVController.catalog[@"preview"][@"state"]?:@"idle",
            @"installPhase": WVController.installPhase?:@"idle",
            @"automaticCheckOnOpen":@YES, @"updateInProgress": @(WVController.updateTask != nil),
            @"updateDeadlineActive": @(WVController.updateDeadline.isValid),
            @"desktopControlSettingsPane": WVAccessibilityPaneName(),
            @"desktopControlSettingsURL": WVAccessibilitySettingsURL,
            @"desktopControlSubjectBundleID": NSBundle.mainBundle.bundleIdentifier ?: @"",
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
        @"updateActionWired", @"releaseActionWired", @"updateInProgress", @"updateDeadlineActive", @"stableInstallAvailable", @"previewInstallAvailable", @"automaticCheckOnOpen"])
        WVSetBoolean(L, key.UTF8String, [values[key] boolValue]);
    WVSetString(L, "aboutTitle", values[@"aboutTitle"]);
    WVSetString(L, "repositoryURL", values[@"repositoryURL"]);
    for (NSString *key in @[@"desktopControlSettingsPane", @"desktopControlSettingsURL", @"desktopControlSubjectBundleID", @"currentReleaseTag", @"releaseChannel", @"currentVersion", @"currentBuild",
        @"updateState", @"updateMessage", @"latestTag", @"latestURL", @"stableTag", @"previewTag", @"stableState", @"previewState", @"installPhase"])
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
static int WVCancelUpdateCheck(lua_State *L) {
    WVOnMain(^{ [WVController cancelUpdateCheck]; });
    return WVDiagnostics(L);
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
        if (result[@"releases"]) result = WVEvaluateReleases(result[@"releases"], NSBundle.mainBundle.infoDictionary[@"WVReleaseTag"], NSBundle.mainBundle.infoDictionary[@"WVReleaseChannel"]);
        [WVController finishUpdate:result];
    });
    return WVDiagnostics(L);
}
static int WVTestInstallUpdate(lua_State *L) {
    if(strcmp(getenv("WV_UI_TEST")?:"","1")!=0)return luaL_error(L,"Update installation qualification requires WV_UI_TEST=1");
    const char *value=luaL_checkstring(L,1);NSString *channel=[NSString stringWithUTF8String:value];
    if(![@[@"stable",@"preview"] containsObject:channel])return luaL_error(L,"Unknown update channel");
    __block BOOL started=NO;
    WVOnMain(^{NSDictionary *row=WVController.catalog[channel];if([row[@"canInstall"] boolValue]){
        [WVController installRelease:[channel isEqual:@"stable"]?WVController.stableButton:WVController.previewButton];started=WVController.installPhase.length>0;}});
    lua_pushboolean(L,started);return 1;
}
static int WVTestAutomaticAboutCheck(lua_State *L) {
    if(strcmp(getenv("WV_UI_TEST")?:"","1")!=0)return luaL_error(L,"About fixtures require WV_UI_TEST=1");
    __block BOOL started=NO;
    WVOnMain(^{[WVController.aboutWindow close];WVController.testingAutoCheck=YES;[WVController showAbout:nil];
        started=WVController.aboutWindow.visible&&WVController.updateTask!=nil;
        WVController.testingAutoCheck=NO;[WVController cancelUpdateCheck];});
    lua_pushboolean(L,started);return 1;
}
static int WVAcknowledgeUpdate(lua_State *L) {
    NSString *job=NSProcessInfo.processInfo.environment[@"WV_UPDATE_TRANSACTION"];
    NSString *nonce=NSProcessInfo.processInfo.environment[@"WV_UPDATE_NONCE"];
    if(!job.length&&!nonce.length){lua_pushboolean(L,YES);return 1;}
    if(nonce.length&&[nonce isEqual:WVUpdateAcknowledgedNonce]){lua_pushboolean(L,YES);return 1;}
    NSError *error=nil;NSURL *jobURL=[NSURL fileURLWithPath:job?:@""];
    NSDictionary *request=WVUpdateRequestForJob(jobURL,&error);
    NSURL *outer=[[[NSBundle.mainBundle.bundleURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSDictionary *build=nil;
    NSData *data=[NSData dataWithContentsOfURL:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"wallpaper-veil-build.json"]];
    id raw=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
    if([raw isKindOfClass:NSDictionary.class])build=raw;
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    BOOL valid=request&&[nonce isEqual:request[@"nonce"]]&&WVAuthorizeUpdateLaunch(jobURL,nonce,outer,&error)&&
        [info[@"WVReleaseTag"] isEqual:request[@"tag"]]&&[info[@"CFBundleVersion"] isEqual:request[@"build"]]&&
        [build[@"source"][@"local_head"] isEqual:request[@"sourceCommit"]];
    if(valid){NSDictionary *health=@{@"ok":@YES,@"nonce":nonce,@"tag":info[@"WVReleaseTag"],@"build":info[@"CFBundleVersion"],
        @"sourceCommit":build[@"source"][@"local_head"],@"pid":@(getpid()),@"executablePath":NSBundle.mainBundle.executablePath,
        @"installedAppPath":outer.path};valid=WVWritePrivateUpdateJSON(health,[jobURL URLByAppendingPathComponent:@"health.json"],&error);}
    if(valid)WVUpdateAcknowledgedNonce=[nonce copy];
    lua_pushboolean(L,valid);if(!valid){lua_pushstring(L,(error.localizedDescription?:@"The update health identity did not match").UTF8String);return 2;}return 1;
}
static int WVCloseAbout(lua_State *L) {
    WVOnMain(^{ [WVController.aboutWindow close]; });
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
static int WVPushWidgetPreference(lua_State *L, NSDictionary *result) {
    lua_newtable(L);
    WVSetBoolean(L, "ok", [result[@"ok"] boolValue]);
    if (result[@"present"]) WVSetBoolean(L, "present", [result[@"present"] boolValue]);
    if (result[@"resetVerified"]) WVSetBoolean(L, "resetVerified", [result[@"resetVerified"] boolValue]);
    if (result[@"value"]) { lua_pushinteger(L, [result[@"value"] integerValue]); lua_setfield(L, -2, "value"); }
    WVSetString(L, "error", result[@"error"]);
    WVSetString(L, "type", result[@"type"]);
    WVSetString(L, "domain", WVWidgetPreferenceDomain);
    WVSetString(L, "key", WVWidgetPreferenceKey);
    return 1;
}

static int WVReadWidgetPreference(lua_State *L) {
    luaL_argcheck(L, lua_gettop(L) == 0, 1, "no domain/key arguments are accepted");
    return WVPushWidgetPreference(L, WVReadWidgetPreferenceInDomain(WVWidgetPreferenceDomain, &WVSystemWidgetPreferences));
}

static int WVWriteWidgetPreference(lua_State *L) {
    luaL_argcheck(L, lua_gettop(L) == 1, 1, "one visibility value is required");
    lua_Integer hidden = luaL_checkinteger(L, 1);
    luaL_argcheck(L, hidden == 0 || hidden == 1, 1, "visibility must be 0 or 1");
    return WVPushWidgetPreference(L, WVWriteWidgetPreferenceInDomain(WVWidgetPreferenceDomain,
        (NSInteger)hidden, &WVSystemWidgetPreferences));
}

static int WVResetWidgetDefaults(lua_State *L) {
    luaL_argcheck(L, lua_gettop(L) == 0, 1, "no domain/key arguments are accepted");
    return WVPushWidgetPreference(L, WVResetWidgetPreferenceInDomain(WVWidgetPreferenceDomain, &WVSystemWidgetPreferences));
}

static int WVRestoreWidgetPreferenceForTest(lua_State *L) {
    if (![[NSProcessInfo processInfo].environment[@"WV_SELF_TEST"] isEqual:@"1"])
        return WVPushWidgetPreference(L, WVWidgetPreferenceFailure(@"Widget recovery is available only in --self-test"));
    luaL_argcheck(L, lua_gettop(L) == 1 && lua_istable(L, 1), 1, "one captured widget test state is required");
    lua_getfield(L, 1, "present");
    luaL_argcheck(L, lua_isboolean(L, -1), 1, "present must be a boolean");
    BOOL present = lua_toboolean(L, -1); lua_pop(L, 1);
    NSMutableDictionary *state = [@{@"present": @(present)} mutableCopy];
    if (present) {
        lua_getfield(L, 1, "value");
        lua_Integer value = luaL_checkinteger(L, -1);
        luaL_argcheck(L, value == 0 || value == 1, 1, "value must be 0 or 1");
        state[@"value"] = @((NSInteger)value); lua_pop(L, 1);
        lua_getfield(L, 1, "type");
        state[@"type"] = [NSString stringWithUTF8String:luaL_checkstring(L, -1)]; lua_pop(L, 1);
    }
    return WVPushWidgetPreference(L, WVRestoreWidgetPreferenceForTestInDomain(WVWidgetPreferenceDomain,
        state, &WVSystemWidgetPreferences));
}

__attribute__((visibility("default"))) int luaopen_wallpaperveil_ui(lua_State *L) {
    static const luaL_Reg functions[] = {
        {"configure", WVConfigure}, {"showAbout", WVShowAbout},
        {"diagnostics", WVDiagnostics}, {"closeAbout", WVCloseAbout},
        {"checkForUpdates", WVCheckForUpdates}, {"cancelUpdateCheck", WVCancelUpdateCheck},
        {"testUpdateResponse", WVTestUpdateResponse},
        {"testAutomaticAboutCheck", WVTestAutomaticAboutCheck}, {"testInstallUpdate", WVTestInstallUpdate}, {"acknowledgeUpdate", WVAcknowledgeUpdate},
        {"saveAboutPreview", WVSaveAboutPreview},
        {"loginStatus", WVLoginStatus}, {"setLaunchAtLogin", WVSetLaunchAtLogin},
        {"openLoginSettings", WVOpenLoginSettings},
        {"openAccessibilitySettings", WVOpenAccessibilitySettings},
        {"accessibilitySettingsInfo", WVAccessibilitySettingsInfo},
        {"widgetPreferenceRead", WVReadWidgetPreference}, {"widgetPreferenceWrite", WVWriteWidgetPreference},
        {"resetWidgetDefaults", WVResetWidgetDefaults},
        {"widgetPreferenceRestoreForTest", WVRestoreWidgetPreferenceForTest}, {NULL, NULL}
    };
    luaL_newlib(L, functions);
    return 1;
}
