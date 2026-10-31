#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "../native/update_download.h"
#import "../native/update_check.h"
#include <sys/stat.h>

@interface WVUpdateDownloader (FixtureHooks)
- (NSURLSessionConfiguration *)sessionConfiguration;
- (NSTimeInterval)deadlineInterval;
@end
static NSData *receiptBody, *zipBody;
static NSString *fault;
static NSUInteger requests;
static NSMutableArray<NSString *> *requestURLs;

@interface WVFixtureProtocol : NSURLProtocol
@property BOOL stopped;
@end
@implementation WVFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"github.com"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    requests++;
    [requestURLs addObject:self.request.URL.absoluteString];
    if ([fault isEqual:@"stall"]) return;
    BOOL receipt = [self.request.URL.path hasSuffix:@"wallpaper-veil-build.json"];
    NSData *body = receipt ? receiptBody : zipBody;
    NSUInteger declared = body.length;
    if ((!receipt && [fault isEqual:@"hash"]) || (receipt && [fault isEqual:@"receipt-hash"])) {
        NSMutableData *changed = [body mutableCopy]; ((uint8_t *)changed.mutableBytes)[0] ^= 1; body = changed;
    }
    if (!receipt && [fault isEqual:@"truncated"]) body = [body subdataWithRange:NSMakeRange(0, body.length - 1)];
    if (!receipt && [fault isEqual:@"overflow"]) { NSMutableData *more = [body mutableCopy]; [more appendBytes:"!" length:1]; body = more; }
    if (!receipt && [fault isEqual:@"length"]) declared++;
    NSInteger status = !receipt && [fault isEqual:@"http"] ? 404 : 200;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status
        HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length": [@(declared) stringValue]}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSUInteger half = body.length / 2;
    [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(0, half)]];
    [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(half, body.length - half)]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { self.stopped = YES; }
@end
@interface WVFixtureDownloader : WVUpdateDownloader
@end
@implementation WVFixtureDownloader
- (NSURLSessionConfiguration *)sessionConfiguration {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[WVFixtureProtocol.class];
    return configuration;
}
- (NSTimeInterval)deadlineInterval { return [fault isEqual:@"stall"] ? 0.025 : 3; }
@end

static NSUInteger assertions;
static void check(BOOL condition, NSString *message) {
    assertions++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSString *sha(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *value = [NSMutableString string];
    for (NSUInteger i=0;i<sizeof(bytes);i++) [value appendFormat:@"%02x", bytes[i]];
    return value;
}
static NSMutableDictionary *descriptor(void) {
    zipBody = [@"A streamed, inert ZIP fixture; never extracted or launched." dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *receipt = @{@"version": @"1.0.0", @"build": @"20", @"release_tag": @"v1.0.0", @"release_channel": @"stable"};
    if ([fault isEqual:@"receipt-version"]) receipt = @{@"version": @"9.0.0", @"build": @"20", @"release_tag": @"v1.0.0", @"release_channel": @"stable"};
    receiptBody = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:NULL];
    requests = 0; requestURLs = [NSMutableArray array];
    NSDictionary *receiptAsset = @{@"assetID": @12, @"name": @"wallpaper-veil-build.json", @"size": @(receiptBody.length),
        @"sha256": sha(receiptBody), @"url": WVUpdateAssetURL(@"v1.0.0", @"wallpaper-veil-build.json")};
    return [@{@"tag": @"v1.0.0", @"version": @"1.0.0", @"channel": @"stable", @"releaseID": @10,
        @"assetID": @11, @"name": @"wallpaper-veil.zip", @"size": @(zipBody.length), @"sha256": sha(zipBody),
        @"url": WVUpdateAssetURL(@"v1.0.0", @"wallpaper-veil.zip"), @"receiptAsset": receiptAsset} mutableCopy];
}
static void waitFor(BOOL (^finished)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!finished() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    check(finished(), @"bounded fixture completion");
}
static NSDictionary *run(NSString *mode, BOOL cancelOnProgress) {
    fault = mode;
    WVFixtureDownloader *downloader = [WVFixtureDownloader new];
    NSDictionary *selection = descriptor();
    __block NSDictionary *result;
    __block NSUInteger callbacks = 0, progress = 0;
    [downloader startDescriptor:selection progress:^(int64_t received,int64_t expected) {
        check(NSThread.isMainThread && received > 0 && received <= expected, @"main-thread bounded progress");
        progress++;
        if (cancelOnProgress) [downloader cancel];
    } completion:^(NSDictionary *value) {
        check(NSThread.isMainThread, @"main-thread completion"); result=value; callbacks++;
    }];
    NSURL *directory = [downloader valueForKey:@"directoryURL"];
    waitFor(^BOOL { return result != nil; });
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    check(callbacks == 1 && !downloader.running, @"one terminal completion and inactive download");
    if ([result[@"ok"] boolValue]) {
        check([result[@"descriptor"][@"buildReceipt"][@"build"] isEqual:@"20"], @"verified build receipt accompanies ZIP");
        check([[NSData dataWithContentsOfURL:result[@"fileURL"]] isEqual:zipBody], @"streamed ZIP bytes preserved");
        check(requests == 2 && [requestURLs[0] hasSuffix:@"wallpaper-veil-build.json"], @"receipt bound before ZIP");
        struct stat info;
        check(lstat([result[@"directoryURL"] fileSystemRepresentation], &info) == 0 && (info.st_mode & 0777) == 0700, @"private directory mode");
        check(lstat([result[@"fileURL"] fileSystemRepresentation], &info) == 0 && (info.st_mode & 0777) == 0600, @"private file mode");
        check(progress > 0, @"ZIP progress delivered");
        [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    } else {
        check(![NSFileManager.defaultManager fileExistsAtPath:directory.path], @"failure/cancellation removes all staging");
        check(!result[@"fileURL"], @"unverified file is never returned");
    }
    return result;
}
int main(void) {
    @autoreleasepool {
        check([run(@"good", NO)[@"ok"] boolValue], @"successful streaming transfer");
        for (NSString *mode in @[@"hash", @"receipt-hash", @"receipt-version", @"truncated", @"overflow", @"length", @"http", @"stall"])
            check(![run(mode, NO)[@"ok"] boolValue], [@"reject " stringByAppendingString:mode]);
        check([run(@"good", YES)[@"state"] isEqual:@"cancelled"], @"cancel during data callback");
        fault = @"stall";
        WVFixtureDownloader *retry = [WVFixtureDownloader new];
        __block NSUInteger first=0, second=0;
        [retry startDescriptor:descriptor() progress:nil completion:^(NSDictionary *r) { first++; check([r[@"state"] isEqual:@"cancelled"], @"first attempt cancellation"); }];
        NSURL *cancelledDirectory = [retry valueForKey:@"directoryURL"];
        [retry cancel];
        check(![NSFileManager.defaultManager fileExistsAtPath:cancelledDirectory.path], @"immediate cancel cleans staging");
        fault = @"good";
        [retry startDescriptor:descriptor() progress:nil completion:^(NSDictionary *r) {
            second++; check([r[@"ok"] boolValue], @"retry succeeds independently");
            [NSFileManager.defaultManager removeItemAtURL:r[@"directoryURL"] error:NULL];
        }];
        waitFor(^BOOL { return second == 1; });
        check(first == 1 && second == 1 && !retry.running, @"late first attempt cannot duplicate retry callback");
        fault = @"stall";
        WVFixtureDownloader *busy = [WVFixtureDownloader new];
        __block NSUInteger activeCalls=0, deniedCalls=0;
        [busy startDescriptor:descriptor() progress:nil completion:^(NSDictionary *r) { (void)r; activeCalls++; }];
        check(![busy startDescriptor:descriptor() progress:nil completion:^(NSDictionary *r) {
            deniedCalls++; check(![r[@"ok"] boolValue], @"second start rejected");
        }], @"concurrent start cannot replace active selection");
        check(busy.running && deniedCalls == 1 && activeCalls == 0, @"original transfer remains active");
        [busy cancel];
        check(activeCalls == 1, @"original transfer cancels once");
        fault = @"stall";
        WVFixtureDownloader *redirect = [WVFixtureDownloader new];
        __block NSDictionary *redirectResult;
        [redirect startDescriptor:descriptor() progress:nil completion:^(NSDictionary *r) { redirectResult = r; }];
        NSURL *redirectDirectory = [redirect valueForKey:@"directoryURL"];
        NSURLSessionTask *redirectTask = [redirect valueForKey:@"task"];
        NSMutableURLRequest *cdn = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://release-assets.githubusercontent.com/asset?sig=fixture"]];
        [cdn setValue:@"secret" forHTTPHeaderField:@"Authorization"];
        [cdn setValue:@"secret" forHTTPHeaderField:@"Cookie"];
        __block NSURLRequest *accepted;
        [redirect URLSession:nil task:redirectTask willPerformHTTPRedirection:nil newRequest:cdn completionHandler:^(NSURLRequest *request) { accepted=request; }];
        check(accepted && ![accepted valueForHTTPHeaderField:@"Authorization"] && ![accepted valueForHTTPHeaderField:@"Cookie"], @"native redirect strips credential headers");
        NSURLRequest *evil = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://evil.invalid/asset"]];
        [redirect URLSession:nil task:redirectTask willPerformHTTPRedirection:nil newRequest:evil completionHandler:^(NSURLRequest *request) { check(!request, @"native delegate rejects untrusted redirect"); }];
        check(redirectResult && ![redirectResult[@"ok"] boolValue] && !redirect.running
            && ![NSFileManager.defaultManager fileExistsAtPath:redirectDirectory.path], @"redirect failure cleans staging without transfer");
        fault = @"good";
        WVFixtureDownloader *immutable = [WVFixtureDownloader new];
        NSMutableDictionary *mutableSelection = descriptor();
        __block NSDictionary *immutableResult;
        [immutable startDescriptor:mutableSelection progress:nil completion:^(NSDictionary *r) { immutableResult=r; }];
        mutableSelection[@"sha256"] = [@"" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
        waitFor(^BOOL { return immutableResult != nil; });
        check([immutableResult[@"ok"] boolValue] && ![immutableResult[@"descriptor"][@"sha256"] isEqual:mutableSelection[@"sha256"]], @"transfer uses immutable descriptor snapshot");
        [NSFileManager.defaultManager removeItemAtURL:immutableResult[@"directoryURL"] error:NULL];
        printf("PASS: %lu native download assertions\n", (unsigned long)assertions);
    }
    return 0;
}
