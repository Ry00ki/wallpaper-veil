#ifndef WV_SETTINGS_WINDOW_H
#define WV_SETTINGS_WINDOW_H
#import <AppKit/AppKit.h>
#include "lua.h"
#include "lauxlib.h"
#import "shortcut_recorder.h"

// The window renders app-owned Lua snapshots. Only explicit control actions
// call perform; opening, focusing and diagnostics never perform an action.
static BOOL WVSettingsRowEnabled(NSDictionary *row) {
    id value = row[@"enabled"];
    return value == nil || ([value isKindOfClass:NSNumber.class] && [value boolValue]);
}

static NSArray<NSDictionary *> *WVSettingsSections(NSData *data, NSString **failure) {
    NSError *error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"sections"] isKindOfClass:NSArray.class]) {
        if (failure) *failure = @"Settings could not be read. Close this window and try again.";
        return nil;
    }
    NSMutableSet *sectionIDs = [NSMutableSet set], *actionIDs = [NSMutableSet set];
    NSMutableArray *sections = [NSMutableArray array];
    for (id section in value[@"sections"]) {
        if (![section isKindOfClass:NSDictionary.class] ||
            ![@[@"general", @"wallpaper", @"brightness", @"misc"] containsObject:section[@"id"]] ||
            [sectionIDs containsObject:section[@"id"]] ||
            ![section[@"title"] isKindOfClass:NSString.class] ||
            ![section[@"rows"] isKindOfClass:NSArray.class]) {
            if (failure) *failure = @"A settings section could not be read. Close this window and try again.";
            return nil;
        }
        [sectionIDs addObject:section[@"id"]];
        for (id row in section[@"rows"]) {
            if (![row isKindOfClass:NSDictionary.class] ||
                ![@[@"toggle", @"choice", @"button", @"note", @"shortcut"] containsObject:row[@"type"]]) {
                if (failure) *failure = @"A settings control could not be read. Close this window and try again.";
                return nil;
            }
            if ([row[@"type"] isEqual:@"note"]) {
                if (![row[@"text"] isKindOfClass:NSString.class]) {
                    if (failure) *failure = @"A settings explanation could not be read.";
                    return nil;
                }
                continue;
            }
            NSString *identifier = row[@"id"];
            if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
                [actionIDs containsObject:identifier] || ![row[@"title"] isKindOfClass:NSString.class]) {
                if (failure) *failure = @"A settings action could not be read. Close this window and try again.";
                return nil;
            }
            [actionIDs addObject:identifier];
            if ([row[@"type"] isEqual:@"toggle"] && ![row[@"value"] isKindOfClass:NSNumber.class]) {
                if (failure) *failure = @"A settings value could not be read.";
                return nil;
            }
            if ([row[@"type"] isEqual:@"shortcut"] && ![row[@"value"] isKindOfClass:NSString.class]) {
                if (failure) *failure = @"A shortcut could not be read.";
                return nil;
            }
            if ([row[@"type"] isEqual:@"choice"]) {
                if (![row[@"options"] isKindOfClass:NSArray.class]) {
                    if (failure) *failure = @"The available choices could not be read.";
                    return nil;
                }
                NSMutableSet *values = [NSMutableSet set];
                for (id option in row[@"options"]) {
                    if (![option isKindOfClass:NSDictionary.class] ||
                        ![option[@"value"] isKindOfClass:NSString.class] ||
                        ![option[@"title"] isKindOfClass:NSString.class] ||
                        [values containsObject:option[@"value"]]) {
                        if (failure) *failure = @"An available choice could not be read.";
                        return nil;
                    }
                    [values addObject:option[@"value"]];
                }
            }
        }
        [sections addObject:section];
    }
    return sections;
}

@interface WVSettingsFlippedView : NSView
@end
@implementation WVSettingsFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface WVSettingsController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WVShortcutRecorder *shortcutRecorder;
@property(nonatomic, strong) NSTabView *tabs;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, assign) lua_State *luaState;
@property(nonatomic) int snapshotReference;
@property(nonatomic) int actionReference;
@property(nonatomic) NSUInteger bindingGeneration;
@property(nonatomic) BOOL refreshQueued;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) BOOL performing;
@property(nonatomic) BOOL snapshotValid;
@property(nonatomic) NSUInteger refreshGeneration;
@property(nonatomic, copy) NSString *selectedSection;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, strong) NSArray<NSDictionary *> *sections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSControl *> *controls;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *rows;
- (void)refresh;
- (void)queueRefresh;
- (void)closeAndRelease;
- (NSString *)performAction:(NSString *)identifier value:(id)value;
@end
static WVSettingsController *WVSettings;

@implementation WVSettingsController
- (instancetype)init {
    self = [super init];
    if (self) { _snapshotReference = LUA_NOREF; _actionReference = LUA_NOREF; _sections = @[]; }
    return self;
}
- (void)releaseCallbacks {
    // End recording while the original action closure is still valid.
    [self.shortcutRecorder cancel:nil]; self.shortcutRecorder = nil;
    self.bindingGeneration++;
    if (self.luaState) {
        luaL_unref(self.luaState, LUA_REGISTRYINDEX, self.snapshotReference);
        luaL_unref(self.luaState, LUA_REGISTRYINDEX, self.actionReference);
    }
    self.snapshotReference = LUA_NOREF; self.actionReference = LUA_NOREF; self.luaState = NULL;
}
- (void)bind:(lua_State *)state snapshot:(int)snapshot action:(int)action {
    [self releaseCallbacks];
    self.luaState = state; self.snapshotReference = snapshot; self.actionReference = action;
}
- (NSString *)luaError:(lua_State *)state fallback:(NSString *)fallback {
    const char *message = lua_tostring(state, -1);
    NSString *text = message ? [NSString stringWithUTF8String:message] : nil;
    return text.length ? text : fallback;
}
- (NSArray<NSDictionary *> *)readSections:(NSString **)failure {
    if (!self.luaState || self.snapshotReference == LUA_NOREF) {
        if (failure) *failure = @"Settings are no longer available. Close this window and open Settings again.";
        return nil;
    }
    lua_State *state = self.luaState; int top = lua_gettop(state);
    lua_rawgeti(state, LUA_REGISTRYINDEX, self.snapshotReference);
    if (lua_pcall(state, 0, 1, 0) != LUA_OK) {
        if (failure) *failure = [self luaError:state fallback:@"Settings could not be read. Try again."];
        lua_settop(state, top); return nil;
    }
    size_t length = 0;
    const char *json = lua_type(state, -1) == LUA_TSTRING ? lua_tolstring(state, -1, &length) : NULL;
    NSData *data = json ? [NSData dataWithBytes:json length:length] : nil;
    lua_settop(state, top);
    if (!data) { if (failure) *failure = @"Settings could not be read. Try again."; return nil; }
    return WVSettingsSections(data, failure);
}
- (void)makeWindow {
    if (self.window) return;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 740, 550)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Wallpaper Veil Settings"; window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(620, 430); window.delegate = self;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(16, 58, 708, 476)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window.contentView addSubview:tabs];
    NSTextField *status = [NSTextField wrappingLabelWithString:@""];
    status.frame = NSMakeRect(22, 14, 696, 34); status.font = [NSFont systemFontOfSize:12];
    status.textColor = NSColor.secondaryLabelColor; status.autoresizingMask = NSViewWidthSizable;
    status.maximumNumberOfLines = 2; [window.contentView addSubview:status];
    self.window = window; self.tabs = tabs; self.statusLabel = status; self.selectedSection = @"wallpaper";
}
- (NSTextField *)detail:(NSString *)text {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:12]; field.textColor = NSColor.secondaryLabelColor;
    field.selectable = YES; field.maximumNumberOfLines = 0;
    return field;
}
- (NSView *)viewForRow:(NSDictionary *)row {
    NSStackView *column = [[NSStackView alloc] init];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading; column.spacing = 5;
    NSString *type = row[@"type"], *identifier = row[@"id"];
    if ([type isEqual:@"note"]) {
        NSTextField *note = [self detail:row[@"text"]];
        [column addArrangedSubview:note];
        [note.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
        return column;
    }
    NSControl *control;
    if ([type isEqual:@"toggle"]) {
        NSButton *button = [NSButton checkboxWithTitle:row[@"title"] target:self action:@selector(performControl:)];
        button.state = [row[@"value"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [column addArrangedSubview:button]; control = button;
    } else if ([type isEqual:@"choice"]) {
        NSStackView *line = [[NSStackView alloc] init];
        line.orientation = NSUserInterfaceLayoutOrientationHorizontal; line.alignment = NSLayoutAttributeCenterY; line.spacing = 16;
        NSTextField *label = [NSTextField labelWithString:row[@"title"]];
        label.font = [NSFont systemFontOfSize:13];
        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        popup.target = self; popup.action = @selector(performControl:); popup.menu.autoenablesItems = NO;
        BOOL found = NO; NSUInteger enabledOptions = 0, optionIndex = 0;
        for (NSDictionary *option in row[@"options"]) {
            // Let NSPopUpButton install the menu tracking target/action. Unique
            // seed titles also allow two real displays with identical names.
            [popup addItemWithTitle:[NSString stringWithFormat:@"__wv_choice_%lu", (unsigned long)optionIndex++]];
            NSMenuItem *item = popup.lastItem; item.title = option[@"title"];
            item.representedObject = option[@"value"]; item.enabled = WVSettingsRowEnabled(option);
            if (item.enabled) enabledOptions++;
            if ([option[@"value"] isEqual:row[@"value"]]) { [popup selectItem:item]; found = YES; }
        }
        if (!found) {
            [popup insertItemWithTitle:@"__wv_choice_placeholder" atIndex:0];
            NSMenuItem *placeholder = [popup itemAtIndex:0]; placeholder.title = @"Choose…";
            placeholder.enabled = NO; [popup selectItem:placeholder];
        }
        popup.enabled = WVSettingsRowEnabled(row) && enabledOptions > 0;
        [line addArrangedSubview:label]; [line addArrangedSubview:popup];
        [popup.widthAnchor constraintGreaterThanOrEqualToConstant:230].active = YES;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [column addArrangedSubview:line]; [line.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
        control = popup;
    } else if ([type isEqual:@"shortcut"]) {
        NSTextField *title = [NSTextField labelWithString:row[@"title"]];
        title.font = [NSFont systemFontOfSize:13]; [column addArrangedSubview:title];
        NSStackView *line = [[NSStackView alloc] init];
        line.orientation = NSUserInterfaceLayoutOrientationHorizontal; line.alignment = NSLayoutAttributeCenterY; line.spacing = 16;
        NSTextField *label = [NSTextField wrappingLabelWithString:[row[@"value"] length] ? row[@"value"] : @"Not set"];
        label.font = [NSFont systemFontOfSize:13];
        [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *button = [NSButton buttonWithTitle:@"Set Shortcut…" target:self action:@selector(recordShortcut:)];
        button.bezelStyle = NSBezelStyleRounded;
        [line addArrangedSubview:label]; [line addArrangedSubview:button];
        [column addArrangedSubview:line]; [line.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
        control = button;
    } else {
        NSButton *button = [NSButton buttonWithTitle:row[@"title"] target:self action:@selector(performControl:)];
        button.bezelStyle = NSBezelStyleRounded; [column addArrangedSubview:button]; control = button;
    }
    control.identifier = identifier;
    if (![type isEqual:@"choice"]) control.enabled = WVSettingsRowEnabled(row);
    self.controls[identifier] = control; self.rows[identifier] = row;
    if ([row[@"detail"] isKindOfClass:NSString.class] && [row[@"detail"] length]) {
        NSTextField *detail = [self detail:row[@"detail"]];
        [column addArrangedSubview:detail]; [detail.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
    }
    return column;
}
- (NSView *)viewForSection:(NSDictionary *)section {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES; scroll.hasHorizontalScroller = NO; scroll.drawsBackground = NO;
    WVSettingsFlippedView *document = [[WVSettingsFlippedView alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO; scroll.documentView = document;
    NSStackView *stack = [[NSStackView alloc] init]; stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading; stack.spacing = 20; [document addSubview:stack];
    for (NSDictionary *row in section[@"rows"]) {
        NSView *view = [self viewForRow:row]; [stack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [document.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentView.heightAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:document.bottomAnchor constant:-20]
    ]];
    return scroll;
}
- (void)refresh {
    if (self.refreshing || self.performing || !self.luaState || !self.window) return;
    self.refreshing = YES; self.refreshGeneration++;
    NSString *failure = nil; NSArray *sections = [self readSections:&failure];
    if (sections) {
        if (!self.snapshotValid || ![sections isEqual:self.sections]) {
            NSString *selected = self.tabs.selectedTabViewItem.identifier ?: self.selectedSection;
            self.controls = [NSMutableDictionary dictionary]; self.rows = [NSMutableDictionary dictionary];
            for (NSTabViewItem *item in [self.tabs.tabViewItems copy]) [self.tabs removeTabViewItem:item];
            self.sections = sections;
            for (NSDictionary *section in sections) {
                NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:section[@"id"]];
                item.label = section[@"title"]; item.view = [self viewForSection:section]; [self.tabs addTabViewItem:item];
            }
            for (NSTabViewItem *item in self.tabs.tabViewItems)
                if ([item.identifier isEqual:selected]) { [self.tabs selectTabViewItem:item]; break; }
        }
        self.snapshotValid = YES;
        self.statusLabel.stringValue = self.lastError ?: @"";
        self.statusLabel.textColor = self.lastError.length ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    } else {
        self.snapshotValid = NO;
        self.statusLabel.stringValue = failure ?: @"Settings could not be read. Try again.";
        self.statusLabel.textColor = NSColor.systemRedColor;
        for (NSControl *control in self.controls.allValues) control.enabled = NO;
    }
    self.refreshing = NO;
}
- (void)queueRefresh {
    if (self.refreshQueued || !self.window.visible || !self.luaState) return;
    self.refreshQueued = YES; NSUInteger generation = self.bindingGeneration;
    NSUInteger refreshGeneration = self.refreshGeneration;
    __weak WVSettingsController *owner = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WVSettingsController *current = owner; current.refreshQueued = NO;
        if (current.bindingGeneration == generation && current.refreshGeneration == refreshGeneration &&
            current.window.visible && current.luaState) [current refresh];
    });
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object == self.window) [self queueRefresh];
}
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != self.window) return;
    self.selectedSection = nil;
    [self releaseCallbacks]; self.window = nil; self.tabs = nil; self.statusLabel = nil;
    self.sections = @[]; self.controls = nil; self.rows = nil; self.lastError = nil; self.snapshotValid = NO;
}
- (void)closeAndRelease {
    if (self.window) [self.window close]; else [self releaseCallbacks];
}
- (NSString *)performAction:(NSString *)identifier value:(id)value {
    if (self.performing || !self.luaState || self.actionReference == LUA_NOREF)
        return @"Settings are no longer available. Close this window and try again.";
    self.performing = YES; lua_State *state = self.luaState; int top = lua_gettop(state);
    lua_rawgeti(state, LUA_REGISTRYINDEX, self.actionReference);
    lua_pushstring(state, identifier.UTF8String);
    if ([value isKindOfClass:NSNumber.class]) lua_pushboolean(state, [value boolValue]);
    else if ([value isKindOfClass:NSString.class]) lua_pushstring(state, [value UTF8String]);
    else lua_pushnil(state);
    NSString *failure = nil;
    if (lua_pcall(state, 2, 1, 0) != LUA_OK) failure = [self luaError:state fallback:@"The setting could not be changed. Try again."];
    else if (lua_type(state, -1) == LUA_TSTRING) failure = [NSString stringWithUTF8String:lua_tostring(state, -1)];
    lua_settop(state, top); self.performing = NO;
    return failure.length ? failure : nil;
}
- (void)recordShortcut:(NSControl *)control {
    NSDictionary *row = self.rows[control.identifier];
    if (self.performing || !self.luaState || !control.enabled || ![row[@"type"] isEqual:@"shortcut"]) return;
    if (self.shortcutRecorder) { [self.shortcutRecorder.window makeKeyAndOrderFront:nil]; return; }
    NSString *identifier = [control.identifier copy];
    NSString *failure = [self performAction:[identifier stringByAppendingString:@".begin"] value:nil];
    if (failure) {
        NSString *restore = [self performAction:[identifier stringByAppendingString:@".end"] value:nil];
        self.lastError = restore ?: failure; [self refresh]; return;
    }
    NSUInteger generation = self.bindingGeneration;
    __weak WVSettingsController *owner = self;
    WVShortcutRecorder *recorder = [[WVShortcutRecorder alloc] init]; self.shortcutRecorder = recorder;
    [recorder presentForWindow:self.window title:row[@"title"] currentLabel:row[@"value"]
        save:^NSString *(NSString *chord) {
            WVSettingsController *current = owner;
            if (!current.luaState || current.bindingGeneration != generation) return @"Shortcut settings are no longer available.";
            return [current performAction:identifier value:chord];
        } finish:^{
            WVSettingsController *current = owner; current.shortcutRecorder = nil;
            if (current.luaState && current.bindingGeneration == generation) {
                current.lastError = [current performAction:[identifier stringByAppendingString:@".end"] value:nil];
                [current refresh];
            }
        }];
}
- (void)performControl:(NSControl *)control {
    NSDictionary *row = self.rows[control.identifier];
    if (self.performing || !self.luaState || !row || !control.enabled || self.actionReference == LUA_NOREF) return;
    if (self.shortcutRecorder) { [self.shortcutRecorder.window makeKeyAndOrderFront:nil]; return; }
    if ([row[@"type"] isEqual:@"shortcut"]) { [self recordShortcut:control]; return; }
    id value = nil;
    if ([row[@"type"] isEqual:@"toggle"]) value = @(((NSButton *)control).state == NSControlStateValueOn);
    else if ([row[@"type"] isEqual:@"choice"]) {
        NSMenuItem *item = ((NSPopUpButton *)control).selectedItem;
        if (!item.enabled || ![item.representedObject isKindOfClass:NSString.class]) return;
        value = item.representedObject;
    }
    self.lastError = [self performAction:control.identifier value:value];
    [self refresh];
}
@end

static int WVShowSettings(lua_State *state) {
    luaL_checktype(state, 1, LUA_TFUNCTION); luaL_checktype(state, 2, LUA_TFUNCTION);
    if (!NSThread.isMainThread) return luaL_error(state, "Settings must be opened on the application thread");
    lua_pushvalue(state, 1); int snapshot = luaL_ref(state, LUA_REGISTRYINDEX);
    lua_pushvalue(state, 2); int action = luaL_ref(state, LUA_REGISTRYINDEX);
    if (!WVSettings) WVSettings = [[WVSettingsController alloc] init];
    [WVSettings bind:state snapshot:snapshot action:action]; [WVSettings makeWindow];
    if (!WVSettings.window.visible) [WVSettings.window center];
    [WVSettings.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    // The explicit refresh supersedes any focus refresh queued by opening.
    [WVSettings refresh];
    lua_pushboolean(state, YES); return 1;
}
static int WVCloseSettings(lua_State *state) {
    if (!NSThread.isMainThread) return luaL_error(state, "Settings must be closed on the application thread");
    [WVSettings closeAndRelease]; lua_pushboolean(state, YES); return 1;
}
static int WVSettingsDiagnostics(lua_State *state) {
    lua_newtable(state);
    lua_pushboolean(state, WVSettings.window.visible); lua_setfield(state, -2, "visible");
    lua_pushboolean(state, WVSettings.luaState != NULL); lua_setfield(state, -2, "bindingActive");
    lua_pushboolean(state, WVSettings.shortcutRecorder.window != nil); lua_setfield(state, -2, "recordingShortcut");
    lua_pushstring(state, (WVSettings.statusLabel.stringValue ?: @"").UTF8String); lua_setfield(state, -2, "error");
    NSString *selected = WVSettings.tabs.selectedTabViewItem.identifier ?: @"";
    lua_pushstring(state, selected.UTF8String); lua_setfield(state, -2, "selectedSection");
    lua_newtable(state);
    NSInteger sectionIndex = 1;
    for (NSDictionary *section in WVSettings.sections) {
        lua_pushstring(state, [section[@"id"] UTF8String]); lua_rawseti(state, -2, sectionIndex++);
    }
    lua_setfield(state, -2, "sections");
    lua_newtable(state);
    for (NSDictionary *section in WVSettings.sections) {
        lua_newtable(state); NSInteger rowIndex = 1;
        for (NSDictionary *row in section[@"rows"]) {
            if ([row[@"type"] isEqual:@"note"]) continue;
            NSControl *control = WVSettings.controls[row[@"id"]]; lua_newtable(state);
            for (NSString *key in @[@"id", @"type", @"title"]) {
                lua_pushstring(state, [row[key] UTF8String]); lua_setfield(state, -2, key.UTF8String);
            }
            lua_pushboolean(state, control.enabled); lua_setfield(state, -2, "enabled");
            if ([row[@"type"] isEqual:@"toggle"]) {
                lua_pushboolean(state, ((NSButton *)control).state == NSControlStateValueOn); lua_setfield(state, -2, "value");
            } else if ([row[@"type"] isEqual:@"choice"]) {
                lua_pushinteger(state, ((NSPopUpButton *)control).numberOfItems); lua_setfield(state, -2, "optionCount");
            }
            lua_rawseti(state, -2, rowIndex++);
        }
        lua_setfield(state, -2, [section[@"id"] UTF8String]);
    }
    lua_setfield(state, -2, "controls");
    return 1;
}
#endif
