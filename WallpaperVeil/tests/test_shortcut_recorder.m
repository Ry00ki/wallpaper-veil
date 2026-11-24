// Pure event encoding policy; no application, window, event monitor, hotkey,
// preferences, permission requests or input injection is used.
#import <AppKit/AppKit.h>
#import "shortcut_recorder.h"
static NSUInteger assertions;
static void check(BOOL value, NSString *message) {
    assertions++; if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static NSEvent *event(NSEventType type, NSUInteger flags, unsigned short code, BOOL repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:0 context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:repeat keyCode:code];
}
static NSString *chord(NSUInteger flags, unsigned short code, NSString **label, NSString **error, BOOL *cancel) {
    return WVShortcutRecordedChord(event(NSEventTypeKeyDown,flags,code,NO),label,error,cancel);
}
int main(void) { @autoreleasepool {
    NSString *label=nil,*error=nil;BOOL cancel=NO;
    NSEventModifierFlags extras=NSEventModifierFlagFunction|NSEventModifierFlagCapsLock|NSEventModifierFlagNumericPad;
    check([chord(NSEventModifierFlagControl|NSEventModifierFlagOption,116,&label,&error,&cancel) isEqual:@"3:116"],@"Control Option PageUp physical encoding");
    check([label isEqual:@"Control–Option–Page Up"]&&!error&&!cancel,@"PageUp readable label");
    check([chord(NSEventModifierFlagControl|NSEventModifierFlagOption|extras,121,&label,&error,&cancel) isEqual:@"3:121"],@"Fn Caps and keypad metadata ignored");
    check([label isEqual:@"Control–Option–Page Down"],@"PageDown readable label");
    for(NSUInteger mask=0;mask<16;mask++){
        NSUInteger flags=((mask&1)?NSEventModifierFlagControl:0)|((mask&2)?NSEventModifierFlagOption:0)|
            ((mask&4)?NSEventModifierFlagShift:0)|((mask&8)?NSEventModifierFlagCommand:0);
        check(WVShortcutModifierMask(flags|extras)==mask,@"All four modifier bits round trip ignoring unrelated flags");
        for(unsigned short code=0;code<128;code++){
            NSString *value=chord(flags,code,&label,&error,&cancel);
            BOOL modifier=code>=54&&code<=63;
            BOOL escape=code==53&&mask==0;
            BOOL valid=(mask&11)&&!modifier;
            check((value!=nil)==valid,@"Requires primary modifier and a nonmodifier physical key");
            check(cancel==escape,@"Only unmodified Escape cancels");
            if(valid)check([value isEqual:[NSString stringWithFormat:@"%lu:%u",(unsigned long)mask,code]],@"Physical keycode not translated to characters");
            else if(!modifier&&!escape)check(error.length>0,@"Invalid chord reports a useful inline error");
        }
    }
    check(!chord(extras,53,&label,&error,&cancel)&&cancel,@"Escape with ignored-only flags still cancels");
    check([chord(NSEventModifierFlagCommand,53,&label,&error,&cancel) isEqual:@"8:53"]&&!cancel,@"Modified Escape can be a shortcut");
    check(!chord(NSEventModifierFlagControl,128,&label,&error,&cancel)&&error.length>0,@"Invalid physical keycode rejected");
    check(!WVShortcutRecordedChord(event(NSEventTypeKeyDown,NSEventModifierFlagControl,0,YES),&label,&error,&cancel)&&!error&&!cancel,@"Repeats ignored without changing preview");
    check(!WVShortcutRecordedChord(event(NSEventTypeKeyUp,NSEventModifierFlagControl,0,NO),&label,&error,&cancel)&&!error&&!cancel,@"Only keyDown records");
    printf("PASS %lu shortcut recorder policy assertions\n",(unsigned long)assertions);
}return 0;}
