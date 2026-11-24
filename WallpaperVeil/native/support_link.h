#ifndef WV_SUPPORT_LINK_H
#define WV_SUPPORT_LINK_H
#import <AppKit/AppKit.h>

static NSButton *WVSupportLinkButton(NSRect frame, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:@"Buy me a coffee" target:target action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleInline;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    button.toolTip = @"Open Vincent × ry00ki’s Ko-fi page in your browser.";
    return button;
}

static BOOL WVOpenSupportPage(void) {
    return [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://ko-fi.com/ry00ki"]];
}
#endif
