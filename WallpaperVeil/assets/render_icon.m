#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>

// Code-native vector icon renderer. Logical coordinates match WallpaperVeil.svg.
static void rgb(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    CGContextSetRGBFillColor(c, r / 255.0, g / 255.0, b / 255.0, a);
}
static void gradient(CGContextRef c, CGRect rect, CGFloat r1, CGFloat g1, CGFloat b1,
                     CGFloat r2, CGFloat g2, CGFloat b2) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[] = {r1/255, g1/255, b1/255, 1, r2/255, g2/255, b2/255, 1};
    CGGradientRef value = CGGradientCreateWithColorComponents(space, components, NULL, 2);
    CGContextDrawLinearGradient(c, value, CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
        CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)), 0);
    CGGradientRelease(value); CGColorSpaceRelease(space);
}
static CGPathRef rounded(CGRect rect, CGFloat radius) {
    return CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
}
static void roundStroke(CGContextRef c, CGRect rect, CGFloat radius, CGFloat alpha) {
    CGPathRef path = rounded(rect, radius);
    CGContextAddPath(c, path);
    CGContextSetRGBStrokeColor(c, 216/255.0, 229/255.0, 234/255.0, alpha);
    CGContextSetLineWidth(c, 3);
    CGContextStrokePath(c); CGPathRelease(path);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "Usage: render_icon output.png pixel-size\n"); return 64; }
        NSInteger size = atoi(argv[2]);
        if (size < 16 || size > 1024) { fprintf(stderr, "Size must be 16..1024\n"); return 64; }
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        if (!bitmap) return 70;
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = context;
        CGContextRef c = context.CGContext;
        CGContextClearRect(c, CGRectMake(0, 0, size, size));
        CGContextSetShouldAntialias(c, true);
        CGContextTranslateCTM(c, 0, size);
        CGFloat scale = size / 1024.0;
        CGContextScaleCTM(c, scale, -scale);
        CGRect outer = CGRectMake(64, 64, 896, 896);
        CGPathRef outerPath = rounded(outer, 196);
        CGContextAddPath(c, outerPath); CGContextClip(c); CGPathRelease(outerPath);
        gradient(c, outer, 40, 60, 81, 16, 29, 44);
        CGContextSaveGState(c);
        CGRect photo = CGRectMake(164, 212, 696, 600);
        CGPathRef photoPath = rounded(photo, 60);
        CGContextAddPath(c, photoPath); CGContextClip(c); CGPathRelease(photoPath);
        gradient(c, photo, 86, 126, 149, 42, 80, 102);
        rgb(c, 213, 225, 220, .88);
        CGContextFillEllipseInRect(c, CGRectMake(616, 300, 120, 120));
        rgb(c, 131, 163, 173, 1);
        CGContextBeginPath(c);
        CGContextMoveToPoint(c,164,662); CGContextAddLineToPoint(c,350,410);
        CGContextAddLineToPoint(c,524,614); CGContextAddLineToPoint(c,658,490);
        CGContextAddLineToPoint(c,860,706); CGContextAddLineToPoint(c,860,812);
        CGContextAddLineToPoint(c,164,812); CGContextClosePath(c); CGContextFillPath(c);
        rgb(c, 54, 95, 115, 1);
        CGContextBeginPath(c);
        CGContextMoveToPoint(c,164,734); CGContextAddLineToPoint(c,326,566);
        CGContextAddLineToPoint(c,476,716); CGContextAddLineToPoint(c,650,548);
        CGContextAddLineToPoint(c,860,738); CGContextAddLineToPoint(c,860,812);
        CGContextAddLineToPoint(c,164,812); CGContextClosePath(c); CGContextFillPath(c);
        rgb(c, 29, 62, 82, 1);
        CGContextBeginPath(c); CGContextMoveToPoint(c,164,756);
        CGContextAddCurveToPoint(c,304,702,422,760,540,728);
        CGContextAddCurveToPoint(c,650,698,748,710,860,766);
        CGContextAddLineToPoint(c,860,812); CGContextAddLineToPoint(c,164,812);
        CGContextClosePath(c); CGContextFillPath(c);
        rgb(c, 7, 21, 34, .31);
        CGContextBeginPath(c); CGContextMoveToPoint(c,580,212);
        CGContextAddCurveToPoint(c,502,416,590,618,498,812);
        CGContextAddLineToPoint(c,860,812); CGContextAddLineToPoint(c,860,212);
        CGContextClosePath(c); CGContextFillPath(c);
        CGContextBeginPath(c); CGContextMoveToPoint(c,580,212);
        CGContextAddCurveToPoint(c,502,416,590,618,498,812);
        CGContextSetRGBStrokeColor(c,216/255.0,229/255.0,234/255.0,.18);
        CGContextSetLineWidth(c,3); CGContextStrokePath(c);
        CGContextRestoreGState(c);
        roundStroke(c, photo, 60, .20);
        roundStroke(c, CGRectMake(66,66,892,892),194,.12);
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        if (![png writeToFile:[NSString stringWithUTF8String:argv[1]] options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 74;
        }
        return 0;
    }
}
