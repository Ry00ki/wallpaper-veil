#ifndef WV_SETUP_WIZARD_H
#define WV_SETUP_WIZARD_H
#import <AppKit/AppKit.h>
#include <math.h>
#include "lua.h"
#include "lauxlib.h"

// Lua owns the original state, previews, commit and restoration. This controller
// holds a single temporary callback and never writes application preferences.
static NSDictionary *WVSetupModel(NSData *data) {
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![value isKindOfClass:NSDictionary.class] ||
        ![value[@"colors"] isKindOfClass:NSArray.class] || ![value[@"colors"] count] ||
        ![value[@"color"] isKindOfClass:NSString.class] ||
        ![value[@"strength"] isKindOfClass:NSNumber.class]) return nil;
    double strength = [value[@"strength"] doubleValue];
    if (!isfinite(strength) || strength < 10 || strength > 80 || floor(strength) != strength) return nil;
    NSMutableSet *identifiers = [NSMutableSet set];
    for (id colour in value[@"colors"]) {
        if (![colour isKindOfClass:NSDictionary.class] ||
            ![colour[@"value"] isKindOfClass:NSString.class] || ![colour[@"value"] length] ||
            ![colour[@"title"] isKindOfClass:NSString.class] ||
            [identifiers containsObject:colour[@"value"]]) return nil;
        [identifiers addObject:colour[@"value"]];
    }
    return [identifiers containsObject:value[@"color"]] ? value : nil;
}

@interface WVSetupWizardController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSArray<NSView *> *pages;
@property(nonatomic, strong) NSArray<NSTextField *> *statusLabels;
@property(nonatomic, strong) NSArray<NSButton *> *primaryButtons;
@property(nonatomic, strong) NSPopUpButton *colourPopup;
@property(nonatomic, strong) NSSlider *strengthSlider;
@property(nonatomic, strong) NSTextField *strengthLabel;
@property(nonatomic, strong) NSButton *applyButton;
@property(nonatomic, assign) lua_State *luaState;
@property(nonatomic) int callbackReference;
@property(nonatomic) NSInteger stage;
@property(nonatomic) BOOL applied;
@property(nonatomic) BOOL previewActive;
@property(nonatomic) BOOL previewValid;
@property(nonatomic) BOOL performing;
@property(nonatomic) BOOL terminalPerformed;
@property(nonatomic, copy) NSString *colour;
@property(nonatomic) NSInteger strength;
@property(nonatomic, copy) NSString *lastError;
- (BOOL)requestClose;
- (void)forceShutdownClose;
@end
static WVSetupWizardController *WVSetupWizard;

@implementation WVSetupWizardController
- (instancetype)init {
    self = [super init];
    if (self) _callbackReference = LUA_NOREF;
    return self;
}
- (void)setError:(NSString *)error {
    self.lastError = error.length ? error : nil;
    for (NSTextField *label in self.statusLabels) label.stringValue = self.lastError ?: @"";
}
- (BOOL)perform:(NSString *)action {
    if (self.performing || !self.luaState || self.callbackReference == LUA_NOREF) return NO;
    self.performing = YES;
    lua_State *state = self.luaState; int top = lua_gettop(state);
    lua_rawgeti(state, LUA_REGISTRYINDEX, self.callbackReference);
    lua_pushstring(state, action.UTF8String);
    lua_pushstring(state, self.colour.UTF8String);
    lua_pushinteger(state, self.strength);
    NSString *failure = nil;
    if (lua_pcall(state, 3, 1, 0) != LUA_OK) {
        const char *message = lua_tostring(state, -1);
        failure = message ? [NSString stringWithUTF8String:message] : @"The wallpaper tint could not be changed. Try again.";
    } else if (lua_type(state, -1) == LUA_TSTRING) {
        failure = [NSString stringWithUTF8String:lua_tostring(state, -1)];
    }
    lua_settop(state, top); self.performing = NO;
    [self setError:failure];
    return !failure.length;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.frame = frame; label.font = [NSFont systemFontOfSize:size weight:weight];
    label.maximumNumberOfLines = 0; label.selectable = YES;
    return label;
}
- (NSButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action page:(NSView *)page {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame; button.bezelStyle = NSBezelStyleRounded;
    [page addSubview:button]; return button;
}
- (void)makeWindow:(NSDictionary *)model {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 350)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Wallpaper Veil Quick Setup"; window.releasedWhenClosed = NO;
    window.delegate = self; window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSMutableArray *pages = [NSMutableArray array], *statuses = [NSMutableArray array], *primary = [NSMutableArray array];
    for (NSInteger index = 1; index <= 3; index++) {
        NSView *page = [[NSView alloc] initWithFrame:window.contentView.bounds];
        [window.contentView addSubview:page]; [pages addObject:page];
        NSTextField *step = [self label:[NSString stringWithFormat:@"%ld of 3", (long)index]
            frame:NSMakeRect(34, 308, 450, 18) size:11 weight:NSFontWeightRegular];
        step.textColor = NSColor.secondaryLabelColor; [page addSubview:step];
        NSTextField *status = [self label:@"" frame:NSMakeRect(34, 59, 450, 48) size:12 weight:NSFontWeightRegular];
        status.textColor = NSColor.systemRedColor; [page addSubview:status]; [statuses addObject:status];
    }
    NSView *intro = pages[0];
    [intro addSubview:[self label:@"Welcome to Wallpaper Veil" frame:NSMakeRect(34, 253, 450, 38) size:23 weight:NSFontWeightSemibold]];
    NSTextField *introText = [self label:@"Add a tint behind your desktop icons. Try a colour and strength, then keep what you like."
        frame:NSMakeRect(34, 173, 450, 64) size:14 weight:NSFontWeightRegular];
    [intro addSubview:introText];
    NSButton *next = [self button:@"Next" frame:NSMakeRect(376, 20, 110, 32) action:@selector(next:) page:intro];
    [primary addObject:next];
    NSButton *introCancel = [self button:@"Cancel" frame:NSMakeRect(34, 20, 100, 32) action:@selector(cancel:) page:intro];
    introCancel.keyEquivalent = @"\033";

    NSView *preview = pages[1];
    [preview addSubview:[self label:@"Choose your wallpaper tint" frame:NSMakeRect(34, 253, 450, 38) size:23 weight:NSFontWeightSemibold]];
    NSTextField *previewText = [self label:@"Changes are previewed until you Apply."
        frame:NSMakeRect(34, 220, 450, 22) size:13 weight:NSFontWeightRegular];
    previewText.textColor = NSColor.secondaryLabelColor; [preview addSubview:previewText];
    [preview addSubview:[self label:@"Colour" frame:NSMakeRect(34, 180, 130, 24) size:13 weight:NSFontWeightMedium]];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(175, 173, 310, 32) pullsDown:NO];
    popup.identifier = @"setupColour"; popup.accessibilityLabel = @"Wallpaper tint colour"; popup.target = self; popup.action = @selector(previewChanged:);
    NSUInteger colourIndex = 0;
    for (NSDictionary *colour in model[@"colors"]) {
        [popup addItemWithTitle:[NSString stringWithFormat:@"__wv_setup_%lu", (unsigned long)colourIndex++]];
        NSMenuItem *item = popup.lastItem; item.title = colour[@"title"]; item.representedObject = colour[@"value"];
        if ([colour[@"value"] isEqual:self.colour]) [popup selectItem:item];
    }
    [preview addSubview:popup]; self.colourPopup = popup;
    [preview addSubview:[self label:@"Strength" frame:NSMakeRect(34, 134, 130, 24) size:13 weight:NSFontWeightMedium]];
    NSSlider *slider = [NSSlider sliderWithValue:self.strength minValue:10 maxValue:80 target:self action:@selector(previewChanged:)];
    slider.frame = NSMakeRect(175, 132, 245, 28); slider.continuous = YES; slider.identifier = @"setupStrength";
    slider.accessibilityLabel = @"Wallpaper tint strength";
    [preview addSubview:slider]; self.strengthSlider = slider;
    self.strengthLabel = [self label:[NSString stringWithFormat:@"%ld%%", (long)self.strength]
        frame:NSMakeRect(430, 135, 58, 22) size:13 weight:NSFontWeightRegular];
    [preview addSubview:self.strengthLabel];
    self.applyButton = [self button:@"Apply" frame:NSMakeRect(376, 20, 110, 32) action:@selector(apply:) page:preview];
    [primary addObject:self.applyButton];
    NSButton *previewCancel = [self button:@"Cancel" frame:NSMakeRect(34, 20, 100, 32) action:@selector(cancel:) page:preview];
    previewCancel.keyEquivalent = @"\033";

    NSView *complete = pages[2];
    [complete addSubview:[self label:@"You're all set" frame:NSMakeRect(34, 253, 450, 38) size:23 weight:NSFontWeightSemibold]];
    [complete addSubview:[self label:@"Your wallpaper tint has been saved." frame:NSMakeRect(34, 210, 450, 28) size:14 weight:NSFontWeightRegular]];
    NSTextField *thanks = [self label:@"Found something to improve? Open an issue on GitHub. You can also star the project to support it."
        frame:NSMakeRect(34, 150, 450, 50) size:13 weight:NSFontWeightRegular];
    thanks.textColor = NSColor.secondaryLabelColor; [complete addSubview:thanks];
    [self button:@"Open GitHub Repository" frame:NSMakeRect(115, 106, 290, 32) action:@selector(openRepository:) page:complete];
    NSButton *done = [self button:@"Done" frame:NSMakeRect(376, 20, 110, 32) action:@selector(done:) page:complete];
    [primary addObject:done];
    self.window = window; self.pages = pages; self.statusLabels = statuses; self.primaryButtons = primary;
    [self showStage:1];
}
- (void)showStage:(NSInteger)stage {
    self.stage = stage;
    for (NSUInteger index = 0; index < self.pages.count; index++) self.pages[index].hidden = index + 1 != stage;
    self.window.defaultButtonCell = self.primaryButtons[stage - 1].cell;
}
- (void)next:(id)sender {
    (void)sender;
    if (self.stage != 1 || self.performing) return;
    [self showStage:2]; self.previewActive = YES;
    self.previewValid = [self perform:@"preview"]; self.applyButton.enabled = self.previewValid;
}
- (void)previewChanged:(id)sender {
    (void)sender;
    if (self.stage != 2 || self.performing) return;
    self.colour = self.colourPopup.selectedItem.representedObject;
    self.strength = MAX(10, MIN(80, (NSInteger)lround(self.strengthSlider.doubleValue)));
    self.strengthLabel.stringValue = [NSString stringWithFormat:@"%ld%%", (long)self.strength];
    self.previewActive = YES; self.previewValid = [self perform:@"preview"];
    self.applyButton.enabled = self.previewValid;
}
- (void)apply:(id)sender {
    (void)sender;
    if (self.stage != 2 || self.performing || !self.previewValid) return;
    if (![self perform:@"apply"]) return;
    self.applied = YES; self.previewActive = NO; [self showStage:3];
}
- (BOOL)finish {
    if (self.terminalPerformed) return YES;
    if (![self perform:self.applied ? @"done" : @"cancel"]) return NO;
    self.terminalPerformed = YES; self.previewActive = NO; return YES;
}
- (BOOL)requestClose {
    if (!self.window) return YES;
    if (![self finish]) return NO;
    [self.window close]; return YES;
}
- (void)forceShutdownClose {
    // Shutdown has already attempted cancellation. Even if restoration failed,
    // the app is stopping its canvases and Lua must not outlive this callback.
    self.terminalPerformed = YES;
    if (self.luaState) luaL_unref(self.luaState, LUA_REGISTRYINDEX, self.callbackReference);
    self.callbackReference = LUA_NOREF; self.luaState = NULL;
    [self.window close];
}
- (void)cancel:(id)sender { (void)sender; [self requestClose]; }
- (void)done:(id)sender { (void)sender; [self requestClose]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; return [self finish]; }
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != self.window) return;
    // Also cover a programmatic NSWindow close, which bypasses shouldClose.
    if (!self.terminalPerformed) [self finish];
    if (self.luaState) luaL_unref(self.luaState, LUA_REGISTRYINDEX, self.callbackReference);
    self.callbackReference = LUA_NOREF; self.luaState = NULL; self.window = nil;
    self.pages = nil; self.statusLabels = nil; self.primaryButtons = nil;
    self.colourPopup = nil; self.strengthSlider = nil; self.applyButton = nil;
}
- (void)openRepository:(id)sender {
    (void)sender;
    if (![NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/Ry00ki/wallpaper-veil"]])
        [self setError:@"The repository could not be opened in your default browser."];
}
@end

static int WVShowSetupWizard(lua_State *state) {
    luaL_checktype(state, 1, LUA_TSTRING); luaL_checktype(state, 2, LUA_TFUNCTION);
    if (!NSThread.isMainThread) return luaL_error(state, "Quick Setup must be opened on the application thread");
    if (WVSetupWizard.window) {
        [WVSetupWizard.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        lua_pushboolean(state, YES); return 1;
    }
    size_t length = 0; const char *json = lua_tolstring(state, 1, &length);
    NSDictionary *model = WVSetupModel([NSData dataWithBytes:json length:length]);
    if (!model) {
        lua_pushboolean(state, NO); lua_pushstring(state, "The setup choices could not be read. Close Quick Setup and try again."); return 2;
    }
    WVSetupWizard = [[WVSetupWizardController alloc] init];
    WVSetupWizard.luaState = state; lua_pushvalue(state, 2);
    WVSetupWizard.callbackReference = luaL_ref(state, LUA_REGISTRYINDEX);
    WVSetupWizard.colour = model[@"color"]; WVSetupWizard.strength = [model[@"strength"] integerValue];
    [WVSetupWizard makeWindow:model]; [WVSetupWizard.window center];
    [WVSetupWizard.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    lua_pushboolean(state, YES); return 1;
}
static int WVCloseSetupWizard(lua_State *state) {
    if (!NSThread.isMainThread) return luaL_error(state, "Quick Setup must be closed on the application thread");
    BOOL force = NO;
    if (lua_gettop(state) > 0) { luaL_checktype(state, 1, LUA_TBOOLEAN); force = lua_toboolean(state, 1); }
    BOOL restored = !WVSetupWizard || [WVSetupWizard requestClose];
    NSString *failure = !restored ? (WVSetupWizard.lastError ?: @"The preview could not be restored. Try Cancel again.") : nil;
    if (force) [WVSetupWizard forceShutdownClose];
    // Preserve the cancellation result even when shutdown forces the UI closed.
    lua_pushboolean(state, restored);
    if (failure) lua_pushstring(state, failure.UTF8String);
    else lua_pushnil(state);
    return 2;
}
static int WVSetupWizardDiagnostics(lua_State *state) {
    lua_newtable(state);
    lua_pushboolean(state, WVSetupWizard.window.visible); lua_setfield(state, -2, "visible");
    NSInteger stage = WVSetupWizard.window ? WVSetupWizard.stage : 0;
    lua_pushinteger(state, stage); lua_setfield(state, -2, "stage");
    NSString *stageName = stage == 1 ? @"intro" : stage == 2 ? @"preview" : stage == 3 ? @"complete" : @"closed";
    lua_pushstring(state, stageName.UTF8String); lua_setfield(state, -2, "stageName");
    lua_pushboolean(state, WVSetupWizard.applied); lua_setfield(state, -2, "applied");
    lua_pushboolean(state, WVSetupWizard.previewActive); lua_setfield(state, -2, "previewActive");
    lua_pushboolean(state, WVSetupWizard.luaState != NULL); lua_setfield(state, -2, "callbackActive");
    lua_pushinteger(state, WVSetupWizard.strength); lua_setfield(state, -2, "strength");
    lua_pushstring(state, (WVSetupWizard.lastError ?: @"").UTF8String); lua_setfield(state, -2, "error");
    return 1;
}
#endif
