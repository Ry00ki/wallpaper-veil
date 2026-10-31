#ifndef WV_UPDATE_DOWNLOAD_H
#define WV_UPDATE_DOWNLOAD_H
#import <Foundation/Foundation.h>

// Main-thread API/callbacks. No application launch, install, settings or TCC calls.
// Successful completion transfers ownership of its private staging directory to
// the caller; failed/cancelled attempts remove all owned temporary files.
@interface WVUpdateDownloader : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, readonly, getter=isRunning) BOOL running;
- (BOOL)startDescriptor:(NSDictionary *)descriptor
              progress:(void (^)(int64_t received, int64_t expected))progress
            completion:(void (^)(NSDictionary *result))completion;
- (void)cancel;
@end
#endif
