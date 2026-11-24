#ifndef WV_STRENGTH_SLIDER_H
#define WV_STRENGTH_SLIDER_H
#import <AppKit/AppKit.h>
#include <math.h>

static const CGFloat WVStrengthScaleHeight = 54;
static const NSInteger WVStrengthStops[] = {0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 97, 99, 100};
static const NSUInteger WVStrengthStopCount = sizeof(WVStrengthStops) / sizeof(WVStrengthStops[0]);

static NSInteger WVNearestStrengthStop(double value) {
    NSInteger nearest = WVStrengthStops[0];
    for (NSUInteger index = 1; index < WVStrengthStopCount; index++) {
        NSInteger stop = WVStrengthStops[index];
        if (fabs(stop - value) < fabs(nearest - value)) nearest = stop;
    }
    return nearest;
}

@interface WVStrengthSlider : NSSlider
@property(nonatomic, copy) void (^trackingChanged)(BOOL tracking);
@property(nonatomic) BOOL trackingPointer;
- (NSInteger)selectedPercent;
- (BOOL)selectPercent:(NSInteger)percent;
@end

@implementation WVStrengthSlider
- (NSInteger)selectedPercent {
    double value = self.doubleValue;
    if (self.trackingPointer && !(NSEvent.modifierFlags & NSEventModifierFlagOption)) {
        NSInteger stop = WVNearestStrengthStop(value);
        if (fabs(stop - value) <= 1.0) return stop;
    }
    return MAX(0, MIN(100, (NSInteger)lround(value)));
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    self.trackingPointer = YES;
    if (self.trackingChanged) self.trackingChanged(YES);
    @try { [super mouseDown:event]; }
    @finally {
        self.trackingPointer = NO;
        if (self.trackingChanged) self.trackingChanged(NO);
    }
}
- (BOOL)selectPercent:(NSInteger)percent {
    if (!self.enabled) return NO;
    self.integerValue = MAX(0, MIN(100, percent));
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    return [self sendAction:self.action to:self.target];
}
- (void)keyDown:(NSEvent *)event {
    NSString *keys = event.charactersIgnoringModifiers;
    NSEventModifierFlags standardModifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    if (keys.length == 1 && !(event.modifierFlags & standardModifiers)) {
        switch ([keys characterAtIndex:0]) {
            case NSLeftArrowFunctionKey: case NSDownArrowFunctionKey:
                [self selectPercent:self.integerValue - 1]; return;
            case NSRightArrowFunctionKey: case NSUpArrowFunctionKey:
                [self selectPercent:self.integerValue + 1]; return;
            case NSHomeFunctionKey: [self selectPercent:0]; return;
            case NSEndFunctionKey: [self selectPercent:100]; return;
        }
    }
    [super keyDown:event];
}
- (NSString *)accessibilityValueDescription {
    return [NSString stringWithFormat:@"%ld percent", (long)self.integerValue];
}
- (BOOL)accessibilityPerformIncrement { return [self selectPercent:self.integerValue + 1]; }
- (BOOL)accessibilityPerformDecrement { return [self selectPercent:self.integerValue - 1]; }
@end

@interface WVStrengthScale : NSView <NSViewToolTipOwner>
@property(nonatomic, strong, readonly) WVStrengthSlider *slider;
- (CGFloat)xForPercent:(NSInteger)percent;
- (NSInteger)stopNearX:(CGFloat)x;
@end

@implementation WVStrengthScale
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _slider = [[WVStrengthSlider alloc] initWithFrame:NSZeroRect];
        _slider.minValue = 0; _slider.maxValue = 100;
        _slider.accessibilityHelp = @"Arrow keys change the strength by one percent.";
        _slider.toolTip = @"Drag to adjust. Hold Option to drag without snapping.";
        [self addSubview:_slider];
        [self setNeedsLayout:YES];
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, WVStrengthScaleHeight); }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (void)layout {
    [super layout];
    self.slider.frame = NSMakeRect(14, 27, MAX(0, NSWidth(self.bounds) - 28), 27);
    [self removeAllToolTips];
    for (NSUInteger index = 0; index < WVStrengthStopCount; index++) {
        NSInteger stop = WVStrengthStops[index];
        CGFloat x = [self xForPercent:stop];
        CGFloat left = index == 0 ? x - 9 : MAX(x - 9, (x + [self xForPercent:WVStrengthStops[index - 1]]) / 2);
        CGFloat right = index + 1 == WVStrengthStopCount ? x + 9 :
            MIN(x + 9, (x + [self xForPercent:WVStrengthStops[index + 1]]) / 2);
        [self addToolTipRect:NSMakeRect(left, 0, right - left, 27) owner:self userData:(void *)(intptr_t)stop];
    }
}
- (CGFloat)xForPercent:(NSInteger)percent {
    NSSliderCell *cell = (NSSliderCell *)self.slider.cell;
    // Align labels with the thumb's center at either end of the native track.
    CGFloat knobWidth = cell.knobThickness;
    if (knobWidth <= 0) knobWidth = NSWidth([cell knobRectFlipped:self.slider.isFlipped]);
    CGFloat travel = MAX(0, NSWidth(self.slider.frame) - knobWidth);
    return NSMinX(self.slider.frame) + knobWidth / 2 + travel * percent / 100.0;
}
- (NSInteger)stopNearX:(CGFloat)x {
    CGFloat first = [self xForPercent:0], last = [self xForPercent:100];
    if (last <= first) return -1;
    NSInteger nearest = WVNearestStrengthStop(100 * (x - first) / (last - first));
    return fabs(x - [self xForPercent:nearest]) <= 9 ? nearest : -1;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    for (NSUInteger index = 0; index < WVStrengthStopCount; index++) {
        NSInteger stop = WVStrengthStops[index];
        BOOL major = stop != 10 && stop != 30 && stop % 10 == 0;
        CGFloat x = [self xForPercent:stop];
        [(major ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor) setFill];
        CGFloat width = major ? 2 : 1;
        NSRectFill(NSMakeRect(x - width / 2, major ? 18 : 21, width, major ? 8 : 5));
        // 95% sits below the main labels; the closest marks use tooltips.
        if (stop % 10 == 0 || stop == 95) {
            NSString *label = [NSString stringWithFormat:@"%ld%%", (long)stop];
            NSDictionary *attributes = @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:major ? 10 : 9
                    weight:major ? NSFontWeightMedium : NSFontWeightRegular],
                NSForegroundColorAttributeName: self.slider.enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor,
            };
            CGFloat labelWidth = [label sizeWithAttributes:attributes].width;
            [label drawAtPoint:NSMakePoint(x - labelWidth / 2, stop == 95 ? 0 : 8) withAttributes:attributes];
        }
    }
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger stop = [self stopNearX:point.x];
    if (point.y < 10 && fabs(point.x - [self xForPercent:95]) <= 10) {
        stop = 95;
    } else if (point.y >= 8 && point.y < 18 && (stop == 95 || stop == 97 || stop == 99)) {
        stop = fabs(point.x - [self xForPercent:100]) <= 11 ? 100 : -1;
    }
    if (self.slider.enabled && point.y < NSMinY(self.slider.frame) && stop >= 0) {
        [self.window makeFirstResponder:self.slider];
        [self.slider selectPercent:stop];
    } else {
        [super mouseDown:event];
    }
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)stop {
    (void)view; (void)tag; (void)point;
    return [NSString stringWithFormat:@"Set strength to %ld%%", (long)(intptr_t)stop];
}
@end
#endif
