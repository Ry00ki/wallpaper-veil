#ifndef WV_SYSTEM_BRIGHTNESS_INDICATOR_H
#define WV_SYSTEM_BRIGHTNESS_INDICATOR_H
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdint.h>

// The private service displays Apple's classic brightness indicator. It
// accepts a display ID and a level, and does not acknowledge rendering.
@protocol WVAppleOSDProtocol
- (void)showImage:(long long)image onDisplayID:(uint32_t)displayID priority:(uint32_t)priority
    msecUntilFade:(uint32_t)milliseconds filledChiclets:(uint32_t)filled
    totalChiclets:(uint32_t)total locked:(BOOL)locked;
@end

@protocol WVSystemBrightnessRendering <NSObject>
// NO means dispatch failed immediately. If dispatch starts, reported
// transport failures call the handler asynchronously on the main thread.
- (BOOL)showLevel:(double)level onDisplay:(uint32_t)displayID onFailure:(dispatch_block_t)failure;
- (void)close;
@end

static const uint32_t WVBrightnessCueDurationMS = 1000;

@interface WVSystemBrightnessIndicator : NSObject <WVSystemBrightnessRendering>
@property(nonatomic, strong) NSXPCConnection *connection;
@property(nonatomic, copy) dispatch_block_t pendingFailure;
@property(nonatomic) NSTimeInterval failureDeadline;
@property(nonatomic) NSUInteger requestGeneration;
@end

@implementation WVSystemBrightnessIndicator
- (void)close {
    NSXPCConnection *connection = self.connection;
    self.connection = nil;
    self.pendingFailure = nil;
    self.requestGeneration++;
    connection.interruptionHandler = nil;
    connection.invalidationHandler = nil;
    [connection invalidate];
}
- (void)transportFailed:(NSXPCConnection *)connection {
    if (!connection || self.connection != connection) return;
    // A later service exit should not bring back an old indicator.
    dispatch_block_t failure = NSProcessInfo.processInfo.systemUptime <= self.failureDeadline ? self.pendingFailure : nil;
    [self close];
    if (failure) failure();
}
- (NSXPCConnection *)openConnection {
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:@"com.apple.OSDUIHelper" options:0];
    if (!connection) return nil;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WVAppleOSDProtocol)];
    __weak WVSystemBrightnessIndicator *owner = self;
    __weak NSXPCConnection *observed = connection;
    dispatch_block_t failed = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner transportFailed:observed];
        });
    };
    connection.interruptionHandler = failed;
    connection.invalidationHandler = failed;
    self.connection = connection;
    [connection resume];
    return connection;
}
- (BOOL)showLevel:(double)level onDisplay:(uint32_t)displayID onFailure:(dispatch_block_t)failure {
    if (!displayID) return NO;
    @try {
        NSXPCConnection *connection = self.connection ?: [self openConnection];
        if (!connection) return NO;
        NSUInteger generation = ++self.requestGeneration;
        self.pendingFailure = failure;
        self.failureDeadline = NSProcessInfo.processInfo.systemUptime + WVBrightnessCueDurationMS / 1000.0;
        __weak WVSystemBrightnessIndicator *owner = self;
        __weak NSXPCConnection *observed = connection;
        id<WVAppleOSDProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(__unused NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WVSystemBrightnessIndicator *current = owner;
                if (current.requestGeneration == generation) [current transportFailed:observed];
            });
        }];
        if (proxy) {
            [proxy showImage:1 onDisplayID:displayID priority:500 msecUntilFade:WVBrightnessCueDurationMS
                filledChiclets:(uint32_t)lround(level * 100) totalChiclets:100 locked:NO];
            return YES;
        }
    } @catch (__unused NSException *error) {
        // A future system can reject this private selector or interface.
    }
    [self close];
    return NO;
}
@end
#endif
