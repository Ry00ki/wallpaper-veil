#import "update_download.h"
#import "update_check.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface WVUpdateDownloader () {
    int _descriptorFD;
    CC_SHA256_CTX _hash;
}
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSTimer *deadline;
@property(nonatomic, strong) NSURL *directoryURL;
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic, copy) NSDictionary *descriptor;
@property(nonatomic, copy) NSDictionary *asset;
@property(nonatomic, copy) void (^progressBlock)(int64_t, int64_t);
@property(nonatomic, copy) void (^completionBlock)(NSDictionary *);
@property(nonatomic) int64_t received;
@property(nonatomic) NSUInteger redirects;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL receiptPhase;
@end

@implementation WVUpdateDownloader
- (instancetype)init {
    if ((self = [super init])) _descriptorFD = -1;
    return self;
}
- (void)finish:(NSString *)state error:(NSString *)message {
    if (!self.running) return;
    self.running = NO;
    self.generation++;
    [self.deadline invalidate]; self.deadline = nil;
    [self.task cancel]; self.task = nil;
    [self.session invalidateAndCancel]; self.session = nil;
    if (_descriptorFD >= 0) { close(_descriptorFD); _descriptorFD = -1; }
    BOOL success = [state isEqualToString:@"downloaded"];
    NSMutableDictionary *result = [@{@"ok": @(success), @"state": state,
        @"descriptor": self.descriptor ?: @{}} mutableCopy];
    if (success) {
        result[@"fileURL"] = self.fileURL;
        result[@"directoryURL"] = self.directoryURL;
    } else {
        if (self.directoryURL) [NSFileManager.defaultManager removeItemAtURL:self.directoryURL error:NULL];
        result[@"error"] = message ?: @"The download failed.";
    }
    void (^completion)(NSDictionary *) = self.completionBlock;
    self.progressBlock = nil; self.completionBlock = nil;
    self.asset = nil; self.fileURL = nil; self.directoryURL = nil;
    if (completion) completion(result);
}
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Download API must run on the main thread");
    [self finish:@"cancelled" error:@"Download cancelled. Your installed app has not changed."];
}
- (BOOL)openAsset:(NSDictionary *)asset receipt:(BOOL)receipt {
    self.asset = asset; self.receiptPhase = receipt;
    self.received = 0; self.redirects = 0;
    self.fileURL = [self.directoryURL URLByAppendingPathComponent:receipt ? @"build-receipt.json" : @"WallpaperVeil.zip"];
    _descriptorFD = open(self.fileURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (_descriptorFD < 0 || fstat(_descriptorFD, &info) || !S_ISREG(info.st_mode) || info.st_uid != geteuid() || fchmod(_descriptorFD, 0600)) {
        [self finish:@"error" error:@"Could not create the private download file."];
        return NO;
    }
    CC_SHA256_Init(&_hash);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:asset[@"url"]]];
    [request setValue:@"Wallpaper-Veil-Native-Updater" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
    return YES;
}
- (NSURLSessionConfiguration *)sessionConfiguration { return NSURLSessionConfiguration.ephemeralSessionConfiguration; }
- (NSTimeInterval)deadlineInterval { return 120; }
- (BOOL)startDescriptor:(NSDictionary *)descriptor
              progress:(void (^)(int64_t, int64_t))progress
            completion:(void (^)(NSDictionary *))completion {
    NSAssert(NSThread.isMainThread, @"Download API must run on the main thread");
    if (self.running || !WVValidateDownloadDescriptor(descriptor) || ![NSJSONSerialization isValidJSONObject:descriptor]) {
        if (completion) completion(@{@"ok": @NO, @"state": @"error", @"error": self.running ? @"A download is already running." : @"The selected release download metadata is invalid."});
        return NO;
    }
    NSData *raw = [NSJSONSerialization dataWithJSONObject:descriptor options:0 error:NULL];
    self.descriptor = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    self.progressBlock = progress; self.completionBlock = completion;
    self.running = YES; self.generation++;
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wallpaper-veil-download-XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    char *directory = buffer ? mkdtemp(buffer) : NULL;
    if (directory) self.directoryURL = [NSURL fileURLWithFileSystemRepresentation:directory isDirectory:YES relativeToURL:nil];
    free(buffer);
    struct stat info;
    if (!self.directoryURL || lstat(self.directoryURL.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)
        || info.st_uid != geteuid() || chmod(self.directoryURL.fileSystemRepresentation, 0700)) {
        [self finish:@"error" error:@"Could not create a private update download directory."];
        return NO;
    }
    NSURLSessionConfiguration *configuration = [self sessionConfiguration];
    configuration.URLCache = nil; configuration.HTTPCookieStorage = nil; configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil; configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 120;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSUInteger generation = self.generation;
    __weak WVUpdateDownloader *weakSelf = self;
    self.deadline = [NSTimer timerWithTimeInterval:[self deadlineInterval] repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        WVUpdateDownloader *strongSelf = weakSelf;
        if (strongSelf.running && strongSelf.generation == generation)
            [strongSelf finish:@"error" error:@"The download timed out. Your installed app has not changed."];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.deadline forMode:NSRunLoopCommonModes];
    return [self openAsset:self.descriptor[@"receiptAsset"] receipt:YES];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session;
    if (!self.running || task != self.task) { completion(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    BOOL valid = http.statusCode == 200 && WVUpdateDownloadURLAllowed(http.URL, self.asset, YES)
        && (response.expectedContentLength < 0 || response.expectedContentLength == [self.asset[@"size"] longLongValue]);
    completion(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    if (!valid) [self finish:@"error" error:@"The release download returned an unexpected response or size. Check for updates again."];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (!self.running || task != self.task) return;
    int64_t expected = [self.asset[@"size"] longLongValue];
    if (data.length > (NSUInteger)(expected - self.received)) {
        [self finish:@"error" error:@"The download exceeded its declared size. Your installed app has not changed."];
        return;
    }
    const uint8_t *bytes = data.bytes; NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t written = write(_descriptorFD, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { [self finish:@"error" error:@"Could not write the download. Check free disk space and retry."]; return; }
        bytes += written; remaining -= (NSUInteger)written;
    }
    CC_SHA256_Update(&_hash, data.bytes, (CC_LONG)data.length);
    self.received += data.length;
    if (!self.receiptPhase && self.progressBlock) self.progressBlock(self.received, expected);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    (void)session; (void)response;
    if (!self.running || task != self.task) { completion(nil); return; }
    if (++self.redirects > 5 || !WVUpdateDownloadURLAllowed(request.URL, self.asset, YES)) {
        completion(nil); [self finish:@"error" error:@"The asset download redirected outside the permitted GitHub hosts."]; return;
    }
    NSMutableURLRequest *safe = [request mutableCopy];
    [safe setValue:nil forHTTPHeaderField:@"Authorization"]; [safe setValue:nil forHTTPHeaderField:@"Cookie"];
    completion(safe);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    if (!self.running || task != self.task) return;
    if (error || self.received != [self.asset[@"size"] longLongValue]) {
        [self finish:@"error" error:@"The release download did not finish. Check your connection and retry."]; return;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &_hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    if (![hex isEqualToString:self.asset[@"sha256"]] || fsync(_descriptorFD)) {
        [self finish:@"error" error:@"The download could not be verified against GitHub's SHA-256 digest."]; return;
    }
    if (close(_descriptorFD)) { _descriptorFD = -1; [self finish:@"error" error:@"Could not save the verified download."]; return; }
    _descriptorFD = -1;
    if (self.receiptPhase) {
        NSData *raw = [NSData dataWithContentsOfURL:self.fileURL options:NSDataReadingMappedIfSafe error:NULL];
        NSDictionary *receipt = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
        if (![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"version"] isEqual:self.descriptor[@"version"]]
            || ![receipt[@"release_tag"] isEqual:self.descriptor[@"tag"]] || ![receipt[@"release_channel"] isEqual:self.descriptor[@"channel"]]
            || ![receipt[@"build"] isKindOfClass:NSString.class] || ![receipt[@"build"] length]
            || [receipt[@"build"] hasPrefix:@"0"] || [receipt[@"build"] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) {
            [self finish:@"error" error:@"The verified build receipt does not describe the selected release."]; return;
        }
        NSMutableDictionary *bound = [self.descriptor mutableCopy]; bound[@"buildReceipt"] = receipt;
        self.descriptor = [bound copy];
        [NSFileManager.defaultManager removeItemAtURL:self.fileURL error:NULL];
        [self openAsset:self.descriptor receipt:NO];
        return;
    }
    [self finish:@"downloaded" error:nil];
}
@end
