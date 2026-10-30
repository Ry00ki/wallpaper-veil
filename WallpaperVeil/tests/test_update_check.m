#import <Foundation/Foundation.h>
#import "../update_check.h"

static NSUInteger assertions = 0;
static void check(BOOL condition, NSString *label) {
    assertions++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); }
}
static NSDictionary *release(NSString *tag, BOOL draft, BOOL prerelease) {
    return @{@"tag_name": tag, @"draft": @(draft), @"prerelease": @(prerelease),
        @"html_url": [@"https://github.com/Ry00ki/wallpaper-veil/releases/tag/" stringByAppendingString:tag]};
}
static NSDictionary *evaluate(NSArray *releases, NSString *current, NSString *channel) {
    return WVEvaluateReleases(releases, current, channel);
}
static void state(NSDictionary *result, NSString *expected, NSString *label) {
    check([result[@"state"] isEqual:expected], label);
}
int main(void) {
    @autoreleasepool {
        check(WVParseReleaseTag(@"v0.1.4") != nil, @"stable tag");
        check(WVParseReleaseTag(@"v0.1.4-preview.1") != nil, @"preview tag");
        for (id tag in @[@"0.1.4", @"v01.2.3", @"v1.2", @"v1.2.3-beta.1", @"v1.2.3+dev", @"v1.2.3\n", @"xv1.2.3", @"v1.2.3-preview.01", @"v1.2.3-preview.0", @"v1.2.3/../../x", @23])
            check(WVParseReleaseTag(tag) == nil, [@"reject malformed tag " stringByAppendingFormat:@"%@", tag]);
        check(WVCompareReleaseVersions(WVParseReleaseTag(@"v0.1.10"), WVParseReleaseTag(@"v0.1.9")) == NSOrderedDescending, @"numeric minor patch");
        check(WVCompareReleaseVersions(WVParseReleaseTag(@"v2.0.0"), WVParseReleaseTag(@"v1.999.999")) == NSOrderedDescending, @"major dominates");
        check(WVCompareReleaseVersions(WVParseReleaseTag(@"v0.1.4-preview.10"), WVParseReleaseTag(@"v0.1.4-preview.9")) == NSOrderedDescending, @"numeric preview");
        check(WVCompareReleaseVersions(WVParseReleaseTag(@"v0.1.4"), WVParseReleaseTag(@"v0.1.4-preview.99")) == NSOrderedDescending, @"stable follows previews");
        check(WVCompareReleaseVersions(WVParseReleaseTag(@"v9999999999999999999999.0.0"), WVParseReleaseTag(@"v9999999999999999999998.0.0")) == NSOrderedDescending, @"no integer overflow");
        NSArray *feed = @[release(@"v0.1.4-preview.1", NO, YES), release(@"v9.0.0", YES, NO),
            release(@"v0.1.3", NO, NO), release(@"v0.1.4-preview.10", NO, YES),
            release(@"v5.0.0-beta.1", NO, YES), release(@"v0.1.4-preview.2", NO, YES)];
        NSDictionary *selected = evaluate(feed, @"v0.1.4-preview.1", @"preview");
        state(selected, @"available", @"preview sees newer preview");
        check([selected[@"latestTag"] isEqual:@"v0.1.4-preview.10"], @"feed order and drafts ignored");
        NSDictionary *reversed = evaluate(feed.reverseObjectEnumerator.allObjects, @"v0.1.4-preview.1", @"preview");
        check([selected isEqual:reversed], @"selection independent of ordering");
        selected = evaluate(feed, @"v0.1.3", @"stable");
        state(selected, @"current", @"stable ignores previews");
        check([selected[@"latestTag"] isEqual:@"v0.1.3"], @"stable picks published stable only");
        state(evaluate(@[release(@"v0.1.4", NO, NO)], @"v0.1.4-preview.99", @"preview"), @"available", @"preview accepts newer stable");
        state(evaluate(@[release(@"v0.1.4-preview.1", NO, YES)], @"v0.1.4-preview.1", @"preview"), @"current", @"same preview current");
        state(evaluate(@[release(@"v0.1.3", NO, NO)], @"v0.1.4-preview.1", @"preview"), @"ahead", @"local candidate ahead of GitHub");
        state(evaluate(@[], @"v0.1.4", @"stable"), @"no-release", @"empty is not up-to-date");
        state(evaluate(@[release(@"v0.1.4-preview.1", NO, YES)], @"v0.1.3", @"stable"), @"no-release", @"no eligible channel release");
        state(evaluate(feed, @"unversioned", @"preview"), @"error", @"invalid installed version");
        state(evaluate(feed, @"v0.1.4", @"nightly"), @"error", @"unsupported channel");
        NSMutableDictionary *untrusted = [release(@"v10.0.0", NO, NO) mutableCopy];
        for (NSString *url in @[@"https://evil.invalid/Ry00ki/wallpaper-veil/releases/tag/v10.0.0",
            @"https://github.com/another/repo/releases/tag/v10.0.0", @"https://github.com/Ry00ki/wallpaper-veil/releases/tag/v10.0.0?redirect=1",
            @"https://github.com@evil.invalid/Ry00ki/wallpaper-veil/releases/tag/v10.0.0"]) {
            untrusted[@"html_url"] = url;
            state(evaluate(@[untrusted], @"v0.1.4", @"preview"), @"no-release", @"untrusted release URL rejected");
        }
        check(WVTrustedReleaseURL(@"../../download") == nil, @"URL creation requires safe semantic tag");
        state(evaluate(@[@"unexpected", @{}, @{@"tag_name": @"v3.0.0", @"html_url": WVTrustedReleaseURL(@"v3.0.0")}], @"v0.1.4", @"preview"), @"no-release", @"malformed entries ignored");
        NSData *valid = [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
        check([WVReleaseResponse(valid, 200, @{}, nil)[@"releases"] isKindOfClass:NSArray.class], @"valid HTTP response");
        state(WVReleaseResponse([@"{" dataUsingEncoding:NSUTF8StringEncoding], 200, @{}, nil), @"error", @"invalid JSON");
        state(WVReleaseResponse([@"{}" dataUsingEncoding:NSUTF8StringEncoding], 200, @{}, nil), @"error", @"wrong JSON shape");
        NSDictionary *rate = WVReleaseResponse(valid, 403, @{@"x-ratelimit-remaining": @"0"}, nil);
        check([rate[@"message"] containsString:@"rate limit"], @"rate limit 403");
        check([WVReleaseResponse(valid, 403, @{@"Retry-After": @"60"}, nil)[@"message"] containsString:@"rate limit"], @"secondary limit 403");
        check([WVReleaseResponse(valid, 429, @{}, nil)[@"message"] containsString:@"rate limit"], @"rate limit 429");
        check([WVReleaseResponse(valid, 403, @{}, nil)[@"message"] containsString:@"refused"], @"ordinary forbidden distinct");
        check([WVReleaseResponse(valid, 404, @{}, nil)[@"message"] containsString:@"unavailable"], @"unavailable feed distinct");
        check([WVReleaseResponse(valid, 503, @{}, nil)[@"message"] containsString:@"503"], @"server error status shown");
        check([WVReleaseResponse(nil, 0, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil])[@"message"] containsString:@"in time"], @"timeout retry message");
        check([WVReleaseResponse(nil, 0, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil])[@"message"] containsString:@"connection"], @"offline retry message");
        check(WVReleasePageHasNext(@{@"Link": @"<https://api.github.com/ignored>; rel=\"next\", <https://api.github.com/ignored>; rel=\"last\""}, 1), @"next link followed");
        check(!WVReleasePageHasNext(@{@"Link": @"<https://api.github.com/ignored>; rel=\"last\""}, 1), @"last only completes");
        check(WVReleasePageHasNext(@{}, 100), @"full page cannot falsely report latest");
        check(!WVReleasePageHasNext(@{}, 99), @"short final page completes");
        printf("PASS: %lu native update-check assertions\n", (unsigned long)assertions);
    }
    return 0;
}
