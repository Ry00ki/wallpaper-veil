#import <Foundation/Foundation.h>
#import "../native/update_check.h"

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
        NSString *sha = [@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
        NSMutableDictionary *(^installable)(NSString *, BOOL) = ^(NSString *tag, BOOL preview) {
            NSMutableDictionary *r = [release(tag, NO, preview) mutableCopy];
            r[@"id"] = @10;
            NSString *zipName = preview ? @"wallpaper-veil-preview.zip" : @"wallpaper-veil.zip";
            r[@"assets"] = @[
                @{@"id": @11, @"name": zipName, @"state": @"uploaded", @"size": @100,
                  @"digest": [@"sha256:" stringByAppendingString:sha], @"browser_download_url": WVUpdateAssetURL(tag, zipName)},
                @{@"id": @12, @"name": @"wallpaper-veil-build.json", @"state": @"uploaded", @"size": @200,
                  @"digest": [@"sha256:" stringByAppendingString:sha], @"browser_download_url": WVUpdateAssetURL(tag, @"wallpaper-veil-build.json")}];
            return r;
        };
        NSDictionary *stable = installable(@"v1.0.0", NO), *preview = installable(@"v1.1.0-preview.2", YES);
        NSDictionary *catalog = WVUpdateCatalog(@[preview, stable], @"v1.0.0-preview.1");
        check([catalog[@"stable"][@"latestTag"] isEqual:@"v1.0.0"] && [catalog[@"stable"][@"canInstall"] boolValue], @"preview can promote to stable");
        check([catalog[@"preview"][@"latestTag"] isEqual:@"v1.1.0-preview.2"], @"separate preview catalog");
        state(WVUpdateCatalog(@[stable], @"v0.9.0")[@"preview"], @"no-release", @"preview never falls back to stable");
        state(WVUpdateCatalog(@[preview], @"v0.9.0")[@"stable"], @"no-release", @"stable never takes preview");
        catalog = WVUpdateCatalog(@[stable], @"v2.0.0-preview.1");
        check(![catalog[@"stable"][@"canInstall"] boolValue] && [catalog[@"stable"][@"state"] isEqual:@"ahead"], @"channel switch cannot downgrade");
        check(![WVUpdateCatalog(@[stable], @"v1.0.0")[@"stable"][@"canInstall"] boolValue], @"current is not reinstallable");
        NSDictionary *descriptor = WVUpdateCatalog(@[stable], @"v0.9.0")[@"stable"][@"descriptor"];
        check(WVValidateDownloadDescriptor(descriptor), @"bound install descriptor");
        for (id value in @[@0, @YES, @1.5, @(-1), NSNull.null]) {
            NSMutableDictionary *bad = [descriptor mutableCopy]; bad[@"size"] = value;
            check(!WVValidateDownloadDescriptor(bad), @"invalid download size rejected");
        }
        for (NSString *key in @[@"name", @"channel", @"version", @"receiptAsset", @"sha256"]) {
            NSMutableDictionary *bad = [descriptor mutableCopy]; bad[key] = NSNull.null;
            check(!WVValidateDownloadDescriptor(bad), @"malformed descriptor type rejected");
        }
        NSMutableDictionary *wrongName = [descriptor mutableCopy];
        wrongName[@"name"] = @"wallpaper-veil-preview.zip";
        wrongName[@"url"] = WVUpdateAssetURL(@"v1.0.0", @"wallpaper-veil-preview.zip");
        check(!WVValidateDownloadDescriptor(wrongName), @"stable cannot consume preview-named ZIP");
        NSMutableDictionary *missing = installable(@"v1.2.0", NO);
        missing[@"assets"] = @[];
        state(WVUpdateCatalog(@[stable, missing], @"v0.9.0")[@"stable"], @"error", @"latest incomplete release does not fall back");
        NSMutableDictionary *duplicate = installable(@"v1.0.0", NO);
        duplicate[@"assets"] = [duplicate[@"assets"] arrayByAddingObject:duplicate[@"assets"][0]];
        state(WVUpdateCatalog(@[duplicate], @"v0.9.0")[@"stable"], @"error", @"duplicate ZIP rejected");
        NSMutableDictionary *oldA = installable(@"v0.8.0", NO), *oldB = installable(@"v0.8.0", NO);
        oldB[@"id"] = @22;
        check([WVUpdateCatalog(@[oldA, oldB, stable], @"v0.9.0")[@"stable"] isEqual:WVUpdateCatalog(@[stable, oldB, oldA], @"v0.9.0")[@"stable"]], @"older ambiguity cannot make catalog feed-order dependent");
        NSMutableDictionary *wrongFlag = installable(@"v1.0.0-preview.1", NO);
        state(WVUpdateCatalog(@[wrongFlag], @"v0.9.0")[@"preview"], @"no-release", @"preview requires matching prerelease flag");
        NSMutableDictionary *mutableRelease = installable(@"v1.0.0", NO);
        NSMutableString *mutableURL = [WVUpdateAssetURL(@"v1.0.0", @"wallpaper-veil.zip") mutableCopy];
        NSMutableDictionary *mutableAsset = [mutableRelease[@"assets"][0] mutableCopy]; mutableAsset[@"browser_download_url"] = mutableURL;
        mutableRelease[@"assets"] = @[mutableAsset, mutableRelease[@"assets"][1]];
        NSDictionary *frozen = WVUpdateCatalog(@[mutableRelease], @"v0.9.0")[@"stable"][@"descriptor"];
        [mutableURL appendString:@"?changed=1"];
        check(WVValidateDownloadDescriptor(frozen), @"selected descriptor cannot mutate with API objects");
        check(WVUpdateDownloadURLAllowed([NSURL URLWithString:descriptor[@"url"]], descriptor, NO), @"canonical initial URL");
        check(WVUpdateDownloadURLAllowed([NSURL URLWithString:@"https://release-assets.githubusercontent.com/signed/asset?token=abc"], descriptor, YES), @"permitted GitHub CDN redirect");
        for (NSString *url in @[@"http://github.com/Ry00ki/wallpaper-veil/releases/download/v1.0.0/wallpaper-veil.zip",
            @"https://github.com/other/repo/releases/download/v1.0.0/wallpaper-veil.zip", @"https://release-assets.githubusercontent.com.evil.invalid/asset",
            @"https://user@release-assets.githubusercontent.com/asset", @"https://release-assets.githubusercontent.com:444/asset",
            @"https://evil.invalid/asset", @"https://github.com/Ry00ki/wallpaper-veil/releases/download/v1.0.0/wallpaper-veil.zip?x=1"]) {
            check(!WVUpdateDownloadURLAllowed([NSURL URLWithString:url], descriptor, YES), @"untrusted asset redirect rejected");
        }
        printf("PASS: %lu native update-check assertions\n", (unsigned long)assertions);
    }
    return 0;
}
