#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "lua.h"
#include "lauxlib.h"

// App-owned UI only. Never alter NSWindowController or another application's UI.
static NSString * const WVName = @"Wallpaper Veil";
static NSString * const WVRepository = @"https://github.com/Ry00ki/wallpaper-veil";
static BOOL WVConfigured = NO;
static BOOL WVPreferencesSuppressed = NO;
static BOOL WVConsoleSuppressed = NO;

@interface WVUIController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *aboutWindow;
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
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 370)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = WVName;
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSView *content = window.contentView;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(202, 252, 96, 96)];
    icon.image = WVIcon();
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:icon];
    [content addSubview:WVLabel(WVName, NSMakeRect(30, 211, 440, 32), 25, NSFontWeightSemibold)];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0.1.0";
    NSTextField *versionLabel = WVLabel([@"Version " stringByAppendingString:version],
        NSMakeRect(30, 186, 440, 20), 13, NSFontWeightRegular);
    versionLabel.textColor = NSColor.secondaryLabelColor;
    [content addSubview:versionLabel];
    NSTextField *detail = WVLabel(@"Standalone preview\nMIT licence. Open-source credits and additional notices\nare included with the app.",
        NSMakeRect(30, 115, 440, 58), 12, NSFontWeightRegular);
    detail.maximumNumberOfLines = 3;
    detail.cell.usesSingleLineMode = NO;
    detail.cell.wraps = YES;
    detail.cell.scrollable = NO;
    detail.lineBreakMode = NSLineBreakByWordWrapping;
    detail.textColor = NSColor.secondaryLabelColor;
    [content addSubview:detail];
    NSButton *repository = [NSButton buttonWithTitle:@"Open GitHub Repository"
        target:self action:@selector(openRepository:)];
    repository.frame = NSMakeRect(130, 67, 240, 32);
    repository.bezelStyle = NSBezelStyleRounded;
    [content addSubview:repository];
    NSButton *notices = [NSButton buttonWithTitle:@"Third-Party Notices"
        target:self action:@selector(openNotices:)];
    notices.frame = NSMakeRect(145, 25, 210, 32);
    notices.bezelStyle = NSBezelStyleRounded;
    [content addSubview:notices];
    self.aboutWindow = window;
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
        BOOL repositoryWired = NO, noticesWired = NO, iconPresent = NO;
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
            @"aboutIconPresent": @(iconPresent)};
    });
    lua_newtable(L);
    for (NSString *key in @[@"configured", @"preferencesSuppressed", @"consoleSuppressed",
        @"engineWindowsVisible", @"nativeMainMenuReady", @"aboutWindowCreated", @"aboutVisible",
        @"repositoryActionWired", @"noticesActionWired", @"aboutIconPresent"])
        WVSetBoolean(L, key.UTF8String, [values[key] boolValue]);
    WVSetString(L, "aboutTitle", values[@"aboutTitle"]);
    WVSetString(L, "repositoryURL", values[@"repositoryURL"]);
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
        {"saveAboutPreview", WVSaveAboutPreview}, {NULL, NULL}
    };
    luaL_newlib(L, functions);
    return 1;
}
