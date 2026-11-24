#ifndef WV_SHORTCUT_RECORDER_H
#define WV_SHORTCUT_RECORDER_H
#import <AppKit/AppKit.h>

// Physical key codes and four persisted modifier bits only. Fn, Caps Lock and
// numeric-pad metadata deliberately do not affect a binding.
static NSUInteger WVShortcutModifierMask(NSEventModifierFlags flags) {
    return ((flags & NSEventModifierFlagControl) ? 1 : 0) |
        ((flags & NSEventModifierFlagOption) ? 2 : 0) |
        ((flags & NSEventModifierFlagShift) ? 4 : 0) |
        ((flags & NSEventModifierFlagCommand) ? 8 : 0);
}
static BOOL WVShortcutIsModifier(unsigned short code) {
    return code >= 54 && code <= 63;
}
static NSString *WVShortcutKeyLabel(unsigned short code, NSString *characters) {
    NSDictionary *names = @{@36:@"Return", @48:@"Tab", @49:@"Space", @51:@"Delete", @53:@"Escape",
        @76:@"Enter", @115:@"Home", @116:@"Page Up", @117:@"Forward Delete", @119:@"End", @121:@"Page Down",
        @123:@"Left Arrow", @124:@"Right Arrow", @125:@"Down Arrow", @126:@"Up Arrow",
        @122:@"F1", @120:@"F2", @99:@"F3", @118:@"F4", @96:@"F5", @97:@"F6", @98:@"F7",
        @100:@"F8", @101:@"F9", @109:@"F10", @103:@"F11", @111:@"F12", @105:@"F13", @107:@"F14",
        @113:@"F15", @106:@"F16", @64:@"F17", @79:@"F18", @80:@"F19", @90:@"F20"};
    NSString *name = names[@(code)];
    if (name) return name;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithRange:NSMakeRange(0xF700, 0x100)];
    if (characters.length && characters.length <= 8 &&
        [characters rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
        [characters rangeOfCharacterFromSet:invalid].location == NSNotFound) return characters.uppercaseString;
    return [NSString stringWithFormat:@"Key %u", code];
}
static NSString *WVShortcutChordLabel(NSUInteger mask, unsigned short code, NSString *characters) {
    NSMutableArray *parts = [NSMutableArray array];
    if (mask & 1) [parts addObject:@"Control"];
    if (mask & 2) [parts addObject:@"Option"];
    if (mask & 4) [parts addObject:@"Shift"];
    if (mask & 8) [parts addObject:@"Command"];
    [parts addObject:WVShortcutKeyLabel(code, characters)];
    return [parts componentsJoinedByString:@"–"];
}


static NSString *WVShortcutRecordedChord(NSEvent *event, NSString **label, NSString **failure, BOOL *cancel) {
    if (label) *label = nil;
    if (failure) *failure = nil;
    if (cancel) *cancel = NO;
    if (event.type != NSEventTypeKeyDown || event.isARepeat) return nil;
    NSUInteger mask = WVShortcutModifierMask(event.modifierFlags); unsigned short code = event.keyCode;
    if (code == 53 && mask == 0) { if (cancel) *cancel = YES; return nil; }
    if (WVShortcutIsModifier(code)) return nil;
    if (code > 127 || !(mask & 11)) {
        if (failure) *failure = @"Include Control, Option or Command with a key.";
        return nil;
    }
    if (label) *label = WVShortcutChordLabel(mask, code, event.charactersIgnoringModifiers ?: @"");
    return [NSString stringWithFormat:@"%lu:%u", (unsigned long)mask, code];
}

@class WVShortcutRecorder;
@interface WVShortcutKeyView : NSView
@property(nonatomic, weak) WVShortcutRecorder *recorder;
@end
@interface WVShortcutWindow : NSPanel
@property(nonatomic, weak) WVShortcutRecorder *recorder;
@end
@interface WVShortcutRecorder : NSObject <NSWindowDelegate>
@property(nonatomic, strong) WVShortcutWindow *window;
@property(nonatomic, strong) WVShortcutKeyView *keyView;
@property(nonatomic, strong) NSTextField *previewLabel;
@property(nonatomic, strong) NSTextField *errorLabel;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, copy) NSString *encodedChord;
@property(nonatomic, copy) NSString *(^saveBinding)(NSString *chord);
@property(nonatomic, copy) void (^didFinish)(void);
@property(nonatomic) BOOL finished;
- (void)presentForWindow:(NSWindow *)parent title:(NSString *)title currentLabel:(NSString *)label
    save:(NSString *(^)(NSString *chord))save finish:(void (^)(void))finish;
- (void)receiveKeyDown:(NSEvent *)event;
- (void)cancel:(id)sender;
- (void)save:(id)sender;
@end

@implementation WVShortcutKeyView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (void)keyDown:(NSEvent *)event {
    // Unmodified Tab remains ordinary keyboard navigation to Save/Cancel.
    if (event.keyCode == 48 && !(WVShortcutModifierMask(event.modifierFlags) & 11)) {
        if (event.modifierFlags & NSEventModifierFlagShift) [self.window selectPreviousKeyView:nil];
        else [self.window selectNextKeyView:nil];
        return;
    }
    [self.recorder receiveKeyDown:event];
}
- (void)mouseDown:(NSEvent *)event { (void)event; [self.window makeFirstResponder:self]; }
@end
@implementation WVShortcutWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Intercept a command chord only in this sheet's focused recording view,
    // before menu key equivalents; never monitor the application or desktop.
    if (self.isKeyWindow && self.firstResponder == self.recorder.keyView && event.type == NSEventTypeKeyDown) {
        [self.recorder.keyView keyDown:event]; return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@implementation WVShortcutRecorder
- (void)presentForWindow:(NSWindow *)parent title:(NSString *)title currentLabel:(NSString *)label
    save:(NSString *(^)(NSString *chord))save finish:(void (^)(void))finish {
    self.saveBinding = save; self.didFinish = finish; self.finished = NO;
    WVShortcutWindow *window = [[WVShortcutWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 236)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Set Shortcut"; window.releasedWhenClosed = NO; window.delegate = self; window.recorder = self;
    window.tabbingMode = NSWindowTabbingModeDisallowed; self.window = window;
    WVShortcutKeyView *keyView = [[WVShortcutKeyView alloc] initWithFrame:window.contentView.bounds];
    keyView.recorder = self; window.contentView = keyView; self.keyView = keyView;
    NSTextField *heading = [NSTextField labelWithString:title ?: @"Brightness shortcut"];
    heading.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]; heading.frame = NSMakeRect(20, 194, 400, 22);
    [keyView addSubview:heading];
    NSTextField *help = [NSTextField wrappingLabelWithString:@"Press Control, Option or Command with a key. Escape cancels."];
    help.font = [NSFont systemFontOfSize:12]; help.textColor = NSColor.secondaryLabelColor;
    help.frame = NSMakeRect(20, 154, 400, 34); [keyView addSubview:help];
    NSTextField *preview = [NSTextField labelWithString:label.length ? label : @"Press a shortcut…"];
    preview.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium]; preview.alignment = NSTextAlignmentCenter;
    preview.frame = NSMakeRect(20, 108, 400, 32); [keyView addSubview:preview]; self.previewLabel = preview;
    NSTextField *error = [NSTextField wrappingLabelWithString:@""];
    error.font = [NSFont systemFontOfSize:12]; error.textColor = NSColor.systemRedColor;
    error.frame = NSMakeRect(20, 54, 400, 44); error.maximumNumberOfLines = 3; [keyView addSubview:error]; self.errorLabel = error;
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e"; cancel.keyEquivalentModifierMask = 0;
    cancel.bezelStyle = NSBezelStyleRounded; cancel.frame = NSMakeRect(246, 16, 82, 30); [keyView addSubview:cancel];
    NSButton *button = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    button.keyEquivalent = @"\r"; button.keyEquivalentModifierMask = 0;
    button.bezelStyle = NSBezelStyleRounded; button.frame = NSMakeRect(336, 16, 82, 30); button.enabled = NO;
    [keyView addSubview:button]; self.saveButton = button;
    keyView.nextKeyView = button; button.nextKeyView = cancel; cancel.nextKeyView = keyView;
    [parent beginSheet:window completionHandler:nil]; [window makeFirstResponder:keyView];
}
- (void)receiveKeyDown:(NSEvent *)event {
    if (self.finished) return;
    NSString *label = nil, *failure = nil; BOOL cancel = NO;
    NSString *chord = WVShortcutRecordedChord(event, &label, &failure, &cancel);
    if (cancel) { [self cancel:nil]; return; }
    if (!chord && !failure) return; // Modifier-only, non-key and repeat events.
    self.encodedChord = chord; self.saveButton.enabled = chord != nil;
    self.errorLabel.stringValue = failure ?: @"";
    if (label) self.previewLabel.stringValue = label;
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES;
    NSWindow *window = self.window;
    if (window.sheetParent) [window.sheetParent endSheet:window returnCode:NSModalResponseCancel];
    [window orderOut:nil]; window.delegate = nil;
    void (^finished)(void) = self.didFinish;
    self.didFinish = nil; self.saveBinding = nil; self.window = nil; self.keyView = nil;
    if (finished) finished();
}
- (void)cancel:(id)sender { (void)sender; [self finish]; }
- (void)save:(id)sender {
    (void)sender;
    if (self.finished || !self.encodedChord.length || !self.saveButton.enabled) return;
    NSString *failure = self.saveBinding ? self.saveBinding(self.encodedChord) : @"Shortcut settings are no longer available.";
    if (failure.length) { self.errorLabel.stringValue = failure; return; }
    [self finish];
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self cancel:nil]; return NO; }
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.window) [self finish];
}
@end
#endif
