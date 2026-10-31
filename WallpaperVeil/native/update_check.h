#ifndef WV_UPDATE_CHECK_H
#define WV_UPDATE_CHECK_H
#import <Foundation/Foundation.h>

// Pure Foundation rules shared by the native UI and offline comparison tests.
// Only published releases with these exact semantic tags are product releases.
static NSArray<NSString *> *WVParseReleaseTag(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
            @"v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-preview\\.([1-9][0-9]*))?"
            options:0 error:NULL];
    });
    NSString *tag = value;
    NSTextCheckingResult *match = [pattern firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match || !NSEqualRanges(match.range, NSMakeRange(0, tag.length))) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 1; i <= 4; i++) {
        NSRange range = [match rangeAtIndex:i];
        [parts addObject:range.location == NSNotFound ? @"" : [tag substringWithRange:range]];
    }
    return parts;
}

static NSComparisonResult WVCompareNumericPart(NSString *a, NSString *b) {
    if (a.length != b.length) return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
    return [a compare:b options:NSLiteralSearch];
}

static NSComparisonResult WVCompareReleaseVersions(NSArray<NSString *> *a, NSArray<NSString *> *b) {
    for (NSUInteger i = 0; i < 3; i++) {
        NSComparisonResult order = WVCompareNumericPart(a[i], b[i]);
        if (order != NSOrderedSame) return order;
    }
    if (!a[3].length || !b[3].length) {
        if (a[3].length == b[3].length) return NSOrderedSame;
        return a[3].length ? NSOrderedAscending : NSOrderedDescending;
    }
    return WVCompareNumericPart(a[3], b[3]);
}

static NSString *WVTrustedReleaseURL(NSString *tag) {
    return WVParseReleaseTag(tag) ? [@"https://github.com/Ry00ki/wallpaper-veil/releases/tag/" stringByAppendingString:tag] : nil;
}

static NSDictionary *WVUpdateError(NSString *message) {
    return @{@"state": @"error", @"message": message};
}

static NSDictionary *WVReleaseResponse(NSData *data, NSInteger status, NSDictionary *headers, NSError *networkError) {
    if (networkError) {
        return WVUpdateError(networkError.code == NSURLErrorTimedOut ?
            @"GitHub did not respond in time. Check your connection and try again." :
            @"Could not connect to GitHub. Check your internet connection and try again.");
    }
    NSString *remaining = nil, *retryAfter = nil;
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class]) continue;
        if ([key caseInsensitiveCompare:@"X-RateLimit-Remaining"] == NSOrderedSame) remaining = [headers[key] description];
        if ([key caseInsensitiveCompare:@"Retry-After"] == NSOrderedSame) retryAfter = [headers[key] description];
    }
    if (status == 429 || (status == 403 && ([remaining isEqualToString:@"0"] || retryAfter.length)))
        return WVUpdateError(@"GitHub's public API rate limit was reached. Try again later, or visit the repository's Releases page.");
    if (status == 403) return WVUpdateError(@"GitHub refused the update check. Its API may be temporarily restricted. Try again later or visit the repository's Releases page.");
    if (status == 404) return WVUpdateError(@"The GitHub releases feed is unavailable. Try again later or visit the repository's Releases page.");
    if (status != 200) return WVUpdateError([NSString stringWithFormat:@"GitHub returned HTTP %ld. Try again later.", (long)status]);
    if (data.length > 8 * 1024 * 1024) return WVUpdateError(@"GitHub's release response was too large. Visit the repository's Releases page.");
    id releases = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![releases isKindOfClass:NSArray.class]) return WVUpdateError(@"GitHub returned an unreadable releases list. Try again later.");
    return @{@"releases": releases};
}

static NSDictionary *WVEvaluateReleases(NSArray *releases, NSString *currentTag, NSString *channel) {
    NSArray *current = WVParseReleaseTag(currentTag);
    if (!current || (![channel isEqualToString:@"preview"] && ![channel isEqualToString:@"stable"]))
        return WVUpdateError(@"This build has no supported release tag or channel. Visit the repository's Releases page to compare versions.");
    NSDictionary *newest;
    NSArray *newestVersion;
    for (id item in releases) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *release = item;
        NSArray<NSString *> *version = WVParseReleaseTag(release[@"tag_name"]);
        if (!version || ![release[@"draft"] isKindOfClass:NSNumber.class] || [release[@"draft"] boolValue] ||
            ![release[@"prerelease"] isKindOfClass:NSNumber.class]) continue;
        BOOL preview = version[3].length > 0;
        if ([channel isEqualToString:@"stable"] && (preview || [release[@"prerelease"] boolValue])) continue;
        // A tag such as v1.0.0-beta.1 is never inferred from the API flags.
        if (!preview && [release[@"prerelease"] boolValue]) continue;
        NSString *trustedURL = WVTrustedReleaseURL(release[@"tag_name"]);
        if (![release[@"html_url"] isKindOfClass:NSString.class] || ![release[@"html_url"] isEqualToString:trustedURL]) continue;
        if (!newest || WVCompareReleaseVersions(version, newestVersion) == NSOrderedDescending) {
            newest = release;
            newestVersion = version;
        }
    }
    if (!newest) return @{@"state": @"no-release", @"message": [NSString stringWithFormat:@"No published %@ release with a supported version tag was found.", channel]};
    NSString *latestTag = newest[@"tag_name"];
    NSString *latestURL = WVTrustedReleaseURL(latestTag);
    NSComparisonResult order = WVCompareReleaseVersions(newestVersion, current);
    if (order == NSOrderedDescending)
        return @{@"state": @"available", @"latestTag": latestTag, @"latestURL": latestURL,
            @"message": [NSString stringWithFormat:@"%@ is available. Open its GitHub release page to review and download it.", latestTag]};
    if (order == NSOrderedSame)
        return @{@"state": @"current", @"latestTag": latestTag, @"latestURL": latestURL,
            @"message": [NSString stringWithFormat:@"You're up to date. %@ is the newest published release for this channel.", currentTag]};
    return @{@"state": @"ahead", @"latestTag": latestTag, @"latestURL": latestURL,
        @"message": [NSString stringWithFormat:@"This build (%@) is newer than GitHub's newest published release (%@).", currentTag, latestTag]};
}

static BOOL WVReleasePageHasNext(NSDictionary *headers, NSUInteger count) {
    for (id key in headers) {
        if ([key isKindOfClass:NSString.class] && [key caseInsensitiveCompare:@"Link"] == NSOrderedSame) {
            NSString *link = [headers[key] description];
            NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"rel\\s*=\\s*[\"']?next(?:[\"';,\\s]|$)" options:NSRegularExpressionCaseInsensitive error:NULL];
            if ([pattern firstMatchInString:link options:0 range:NSMakeRange(0, link.length)]) return YES;
        }
    }
    // Asking once more for a full page also protects against a missing Link header.
    return count >= 100;
}
#endif
