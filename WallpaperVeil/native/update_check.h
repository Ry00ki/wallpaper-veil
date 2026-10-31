#ifndef WV_UPDATE_CHECK_H
#define WV_UPDATE_CHECK_H
#import <Foundation/Foundation.h>
#include <limits.h>
#include <string.h>

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

// Installable catalogs are independent. Preview never falls back to stable.
static const unsigned long long WVMaximumUpdateBytes = 256ULL * 1024 * 1024;
static const unsigned long long WVMaximumReceiptBytes = 1024ULL * 1024;

static BOOL WVUpdatePositiveInteger(id value, unsigned long long maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [value objCType];
    if (!type || strchr("fd", type[0])) return NO;
    NSString *text = [value stringValue];
    if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound || [text hasPrefix:@"0"]) return NO;
    return [value unsignedLongLongValue] > 0 && [value unsignedLongLongValue] <= maximum;
}

static BOOL WVUpdateSHA256(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound;
}

static NSString *WVUpdateAssetURL(NSString *tag, NSString *name) {
    if (!WVParseReleaseTag(tag) || ![@[@"wallpaper-veil.zip", @"wallpaper-veil-preview.zip", @"wallpaper-veil-build.json"] containsObject:name]) return nil;
    return [NSString stringWithFormat:@"https://github.com/Ry00ki/wallpaper-veil/releases/download/%@/%@", tag, name];
}

static BOOL WVUpdateDownloadURLAllowed(NSURL *url, NSDictionary *asset, BOOL redirect) {
    if (![url isKindOfClass:NSURL.class] || ![url.scheme isEqualToString:@"https"] || url.user.length || url.password.length || url.port || url.fragment.length) return NO;
    if ([url.absoluteString isEqualToString:asset[@"url"]]) return YES;
    return redirect && [url.host isEqualToString:@"release-assets.githubusercontent.com"] && url.path.length > 1;
}

static BOOL WVValidateUpdateAsset(NSDictionary *asset, NSString *tag, BOOL receipt) {
    if (![asset isKindOfClass:NSDictionary.class]) return NO;
    NSString *name = asset[@"name"];
    if (![name isKindOfClass:NSString.class]) return NO;
    NSArray<NSString *> *version = WVParseReleaseTag(tag);
    if (!version) return NO;
    NSString *expectedName = receipt ? @"wallpaper-veil-build.json" : version[3].length ? @"wallpaper-veil-preview.zip" : @"wallpaper-veil.zip";
    if (![name isEqualToString:expectedName]) return NO;
    NSString *url = WVUpdateAssetURL(tag, name);
    return WVUpdatePositiveInteger(asset[@"assetID"], LLONG_MAX)
        && WVUpdatePositiveInteger(asset[@"size"], receipt ? WVMaximumReceiptBytes : WVMaximumUpdateBytes)
        && WVUpdateSHA256(asset[@"sha256"]) && [asset[@"url"] isKindOfClass:NSString.class]
        && [asset[@"url"] isEqualToString:url];
}

static BOOL WVValidateDownloadDescriptor(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSArray<NSString *> *parts = WVParseReleaseTag(value[@"tag"]);
    if (!parts || !WVUpdatePositiveInteger(value[@"releaseID"], LLONG_MAX)) return NO;
    NSString *channel = parts[3].length ? @"preview" : @"stable";
    NSString *version = [[parts subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@"."];
    return [value[@"channel"] isKindOfClass:NSString.class] && [value[@"version"] isKindOfClass:NSString.class]
        && [value[@"channel"] isEqualToString:channel] && [value[@"version"] isEqualToString:version]
        && WVValidateUpdateAsset(value, value[@"tag"], NO)
        && WVValidateUpdateAsset(value[@"receiptAsset"], value[@"tag"], YES);
}

static NSDictionary *WVUpdateAssetDescriptor(NSDictionary *release, BOOL receipt) {
    NSArray *assets = release[@"assets"];
    if (![assets isKindOfClass:NSArray.class]) return nil;
    NSDictionary *chosen;
    for (id item in assets) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = item[@"name"];
        BOOL matches = receipt ? [name isEqual:@"wallpaper-veil-build.json"] : [@[@"wallpaper-veil.zip", @"wallpaper-veil-preview.zip"] containsObject:name];
        if (!matches) continue;
        if (chosen) return nil; // Ambiguity is never resolved by feed order.
        chosen = item;
    }
    if (!chosen || ![chosen[@"state"] isEqual:@"uploaded"]) return nil;
    NSString *digest = chosen[@"digest"];
    if (![digest isKindOfClass:NSString.class] || ![digest hasPrefix:@"sha256:"]) return nil;
    NSDictionary *asset = @{@"assetID": chosen[@"id"] ?: NSNull.null, @"name": chosen[@"name"] ?: NSNull.null,
        @"size": chosen[@"size"] ?: NSNull.null, @"sha256": [digest substringFromIndex:7],
        @"url": chosen[@"browser_download_url"] ?: NSNull.null};
    return WVValidateUpdateAsset(asset, release[@"tag_name"], receipt) ? asset : nil;
}

static NSDictionary *WVUpdateCatalogChannel(NSArray *releases, NSString *currentTag, NSString *channel) {
    NSArray *current = WVParseReleaseTag(currentTag);
    if (!current) return WVUpdateError(@"This build has no supported release version.");
    NSDictionary *newest;
    NSArray *newestVersion;
    BOOL ambiguous = NO;
    for (id item in releases) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSArray<NSString *> *version = WVParseReleaseTag(item[@"tag_name"]);
        if (!version || ![item[@"draft"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)item[@"draft"]) != CFBooleanGetTypeID()
            || [item[@"draft"] boolValue] || ![item[@"prerelease"] isKindOfClass:NSNumber.class]
            || CFGetTypeID((__bridge CFTypeRef)item[@"prerelease"]) != CFBooleanGetTypeID()) continue;
        BOOL preview = version[3].length > 0;
        if (preview != [channel isEqual:@"preview"] || preview != [item[@"prerelease"] boolValue]
            || ![item[@"html_url"] isEqual:WVTrustedReleaseURL(item[@"tag_name"])]) continue;
        NSComparisonResult order = newest ? WVCompareReleaseVersions(version, newestVersion) : NSOrderedDescending;
        if (newest && order == NSOrderedSame && ![newest isEqual:item]) ambiguous = YES;
        if (!newest || order == NSOrderedDescending) { newest = item; newestVersion = version; ambiguous = NO; }
    }
    if (ambiguous) return WVUpdateError(@"GitHub returned ambiguous release metadata. Check again.");
    if (!newest) return @{@"state": @"no-release", @"canInstall": @NO,
        @"message": [NSString stringWithFormat:@"No published %@ release is available.", channel]};
    NSString *tag = newest[@"tag_name"];
    NSDictionary *zip = WVUpdateAssetDescriptor(newest, NO), *receipt = WVUpdateAssetDescriptor(newest, YES);
    NSMutableDictionary *result = [@{@"latestTag": tag, @"latestURL": WVTrustedReleaseURL(tag), @"canInstall": @NO} mutableCopy];
    if (!zip || !receipt || !WVUpdatePositiveInteger(newest[@"id"], LLONG_MAX)) {
        result[@"state"] = @"error";
        result[@"message"] = @"This release has no unambiguous ZIP and build receipt with GitHub SHA-256 digests. Check again later.";
        return result;
    }
    NSMutableDictionary *descriptor = [zip mutableCopy];
    descriptor[@"tag"] = tag; descriptor[@"channel"] = channel; descriptor[@"releaseID"] = newest[@"id"];
    descriptor[@"version"] = [[newestVersion subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@"."];
    descriptor[@"receiptAsset"] = receipt;
    // Serialize once so caller-owned mutable API objects cannot change a selection.
    result[@"descriptor"] = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:descriptor options:0 error:NULL] options:0 error:NULL];
    NSComparisonResult order = WVCompareReleaseVersions(newestVersion, current);
    result[@"state"] = order == NSOrderedDescending ? @"available" : order == NSOrderedSame ? @"current" : @"ahead";
    result[@"canInstall"] = @(order == NSOrderedDescending);
    result[@"message"] = order == NSOrderedDescending ? [NSString stringWithFormat:@"%@ is ready to download and install.", tag] :
        order == NSOrderedSame ? @"You're up to date for this channel." : @"The selected channel is older than this installation. No downgrade will be installed.";
    return result;
}

static NSDictionary *WVUpdateCatalog(NSArray *releases, NSString *currentTag) {
    if (![releases isKindOfClass:NSArray.class]) return @{@"stable": WVUpdateError(@"Invalid release catalog."), @"preview": WVUpdateError(@"Invalid release catalog.")};
    return @{@"stable": WVUpdateCatalogChannel(releases, currentTag, @"stable"),
             @"preview": WVUpdateCatalogChannel(releases, currentTag, @"preview")};
}

#endif
