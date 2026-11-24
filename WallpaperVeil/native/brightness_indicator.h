#ifndef WV_BRIGHTNESS_INDICATOR_H
#define WV_BRIGHTNESS_INDICATOR_H
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdint.h>
#include "lua.h"
#include "lauxlib.h"
#import "system_brightness_indicator.h"

// Visual feedback shares the already confirmed hardware value. The Apple
// service is tried first, and Wallpaper Veil draws a panel on failure.
@interface WVBrightnessPanel : NSPanel
@end
@implementation WVBrightnessPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface WVBrightnessIndicatorController : NSObject
@property(nonatomic, strong) WVBrightnessPanel *panel;
@property(nonatomic, strong) NSTextField *percentage;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSTimer *dismissTimer;
@property(nonatomic, strong) id<WVSystemBrightnessRendering> systemIndicator;
@property(nonatomic) NSUInteger requestGeneration;
- (instancetype)initWithSystemIndicator:(id<WVSystemBrightnessRendering>)indicator;
- (void)showLevel:(double)level onScreen:(NSScreen *)screen;
- (void)close;
@end
static WVBrightnessIndicatorController *WVBrightnessIndicator;

static NSScreen *WVBrightnessScreenForDisplay(uint32_t displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return screen;
    }
    return nil;
}

@implementation WVBrightnessIndicatorController
- (instancetype)init {
    return [self initWithSystemIndicator:[[WVSystemBrightnessIndicator alloc] init]];
}
- (instancetype)initWithSystemIndicator:(id<WVSystemBrightnessRendering>)indicator {
    self = [super init];
    if (self) _systemIndicator = indicator;
    return self;
}
- (void)makePanel {
    if (self.panel) return;
    NSRect bounds = NSMakeRect(0, 0, 244, 62);
    WVBrightnessPanel *panel = [[WVBrightnessPanel alloc] initWithContentRect:bounds
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Wallpaper Veil Brightness";
    panel.releasedWhenClosed = NO; panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor; panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO; panel.ignoresMouseEvents = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    NSVisualEffectView *surface = [[NSVisualEffectView alloc] initWithFrame:bounds];
    surface.material = NSVisualEffectMaterialHUDWindow;
    surface.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    surface.state = NSVisualEffectStateActive; surface.wantsLayer = YES;
    surface.layer.cornerRadius = 25; surface.layer.masksToBounds = YES;
    surface.layer.borderWidth = 0.5;
    surface.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.35].CGColor;
    panel.contentView = surface;

    NSImageView *sun = [[NSImageView alloc] initWithFrame:NSMakeRect(18, 21, 24, 24)];
    sun.image = [NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:@"Brightness"];
    sun.contentTintColor = NSColor.labelColor; [surface addSubview:sun];
    NSTextField *title = [NSTextField labelWithString:@"Brightness"];
    title.frame = NSMakeRect(54, 32, 120, 18);
    title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    title.textColor = NSColor.labelColor; [surface addSubview:title];
    NSTextField *percentage = [NSTextField labelWithString:@"0%"];
    percentage.frame = NSMakeRect(177, 31, 48, 20);
    percentage.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    percentage.textColor = NSColor.labelColor; percentage.alignment = NSTextAlignmentRight;
    [surface addSubview:percentage]; self.percentage = percentage;
    NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(54, 17, 171, 6)];
    progress.style = NSProgressIndicatorStyleBar; progress.indeterminate = NO;
    progress.controlSize = NSControlSizeSmall; progress.minValue = 0; progress.maxValue = 1;
    progress.accessibilityLabel = @"Wallpaper Veil display brightness";
    [surface addSubview:progress]; self.progress = progress;
    self.panel = panel;
}
- (void)showFallbackLevel:(double)level onScreen:(NSScreen *)screen {
    [self makePanel];
    [self.dismissTimer invalidate]; self.dismissTimer = nil;
    self.percentage.stringValue = [NSString stringWithFormat:@"%ld%%", (long)lround(level * 100)];
    self.progress.doubleValue = level;
    NSRect available = screen.visibleFrame, frame = self.panel.frame;
    frame.origin.x = floor(NSMidX(available) - NSWidth(frame) / 2);
    frame.origin.y = floor(NSMaxY(available) - NSHeight(frame) - 24);
    [self.panel setFrame:frame display:NO];
    // Neither makeKeyAndOrderFront nor application activation belongs here.
    [self.panel orderFrontRegardless];
    __weak WVBrightnessIndicatorController *owner = self;
    self.dismissTimer = [NSTimer timerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *timer) {
        WVBrightnessIndicatorController *current = owner;
        if (!current || current.dismissTimer != timer) return;
        current.dismissTimer = nil; [current.panel orderOut:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.dismissTimer forMode:NSRunLoopCommonModes];
}
- (void)hideFallback {
    [self.dismissTimer invalidate]; self.dismissTimer = nil;
    [self.panel orderOut:nil];
}
- (void)showLevel:(double)level onScreen:(NSScreen *)screen {
    uint32_t displayID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    NSUInteger request = ++self.requestGeneration;
    __weak WVBrightnessIndicatorController *owner = self;
    BOOL sent = [self.systemIndicator showLevel:level onDisplay:displayID onFailure:^{
        WVBrightnessIndicatorController *current = owner;
        if (current.requestGeneration != request) return;
        current.requestGeneration++;
        // A display may disappear while the async request is in flight.
        NSScreen *target = WVBrightnessScreenForDisplay(displayID);
        if (target) [current showFallbackLevel:level onScreen:target];
    }];
    if (sent) [self hideFallback];
    else [self showFallbackLevel:level onScreen:screen];
}
- (void)close {
    self.requestGeneration++;
    [self.systemIndicator close];
    [self hideFallback]; [self.panel close];
    self.panel = nil; self.percentage = nil; self.progress = nil;
}
@end

static int WVShowBrightnessIndicator(lua_State *state) {
    luaL_argcheck(state, lua_gettop(state) >= 1 && lua_gettop(state) <= 2, 1,
        "a confirmed brightness and an optional display ID are required");
    luaL_checktype(state, 1, LUA_TNUMBER);
    double level = lua_tonumber(state, 1);
    luaL_argcheck(state, isfinite(level) && level >= 0 && level <= 1, 1,
        "confirmed brightness must be between 0 and 1");
    BOOL selectedDisplay = !lua_isnoneornil(state, 2);
    lua_Integer displayID = selectedDisplay ? luaL_checkinteger(state, 2) : 0;
    luaL_argcheck(state, !selectedDisplay || (displayID > 0 && (unsigned long long)displayID <= UINT32_MAX),
        2, "display ID must be a positive 32-bit display identifier");
    if (!NSThread.isMainThread) return luaL_error(state, "Brightness feedback must run on the application thread");
    NSScreen *screen = selectedDisplay ? WVBrightnessScreenForDisplay((uint32_t)displayID)
        : (NSScreen.mainScreen ?: NSScreen.screens.firstObject);
    if (!screen) {
        lua_pushboolean(state, NO); lua_pushstring(state, "The display for brightness feedback is unavailable."); return 2;
    }
    if (!WVBrightnessIndicator) WVBrightnessIndicator = [[WVBrightnessIndicatorController alloc] init];
    [WVBrightnessIndicator showLevel:level onScreen:screen];
    lua_pushboolean(state, YES); return 1;
}
static int WVCloseBrightnessIndicator(lua_State *state) {
    luaL_argcheck(state, lua_gettop(state) == 0, 1, "no arguments are accepted");
    if (!NSThread.isMainThread) return luaL_error(state, "Brightness feedback must close on the application thread");
    [WVBrightnessIndicator close]; WVBrightnessIndicator = nil;
    lua_pushboolean(state, YES); return 1;
}
#endif
