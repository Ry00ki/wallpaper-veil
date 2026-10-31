#ifndef WV_UPDATE_NOTIFICATIONS_H
#define WV_UPDATE_NOTIFICATIONS_H
#import <Foundation/Foundation.h>
#import "update_check.h"

// Only app-owned keys. The injectable store supports objectForKey:,
// setObject:forKey: and synchronize; production passes its own NSUserDefaults.
static NSString * const WVStartupChecksKey = @"wallpaperVeil.updates.checkAtStartup";
static NSString * const WVSkippedTagsKey = @"wallpaperVeil.updates.skippedTags";

static BOOL WVNotificationBoolean(id value, BOOL *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    if (result) *result = [value boolValue];
    return YES;
}
static BOOL WVNotificationError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"WallpaperVeil.UpdateNotifications" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static BOOL WVStartupChecksEnabled(id store) {
    if (!store) return NO;
    @try {
        id value = [store objectForKey:WVStartupChecksKey];
        if (!value) return YES;
        BOOL enabled = NO;
        return WVNotificationBoolean(value, &enabled) && enabled;
    } @catch (NSException *exception) { (void)exception; return NO; }
}
static BOOL WVSaveStartupChecksEnabled(id store, BOOL enabled, NSError **error) {
    if (error) *error = nil;
    if (!store) return WVNotificationError(error, @"Update preferences are unavailable.");
    @try {
        [store setObject:@(enabled) forKey:WVStartupChecksKey];
        BOOL synchronized = [store synchronize];
        BOOL observed = NO;
        if (!synchronized || !WVNotificationBoolean([store objectForKey:WVStartupChecksKey], &observed) || observed != enabled)
            return WVNotificationError(error, @"The startup update preference could not be saved and verified.");
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        return WVNotificationError(error, @"The startup update preference could not be saved and verified.");
    }
}
static NSArray<NSString *> *WVValidatedSkippedTags(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *tags = [NSMutableArray array];
    for (id tag in value) {
        if (!WVParseReleaseTag(tag)) continue;
        [tags removeObject:tag]; [tags addObject:[tag copy]];
        if (tags.count > 16) [tags removeObjectAtIndex:0];
    }
    return [tags copy];
}
static NSArray<NSString *> *WVSkippedUpdateTags(id store) {
    if (!store) return @[];
    @try { return WVValidatedSkippedTags([store objectForKey:WVSkippedTagsKey]); }
    @catch (NSException *exception) { (void)exception; return @[]; }
}
static BOOL WVRememberSkippedUpdate(id store, NSString *tag, NSError **error) {
    if (error) *error = nil;
    if (!store || !WVParseReleaseTag(tag)) return WVNotificationError(error, @"The skipped update version is invalid.");
    @try {
        NSMutableArray *tags = [WVValidatedSkippedTags([store objectForKey:WVSkippedTagsKey]) mutableCopy];
        [tags removeObject:tag]; [tags addObject:[tag copy]];
        if (tags.count > 16) [tags removeObjectAtIndex:0];
        NSArray *saved = [tags copy];
        [store setObject:saved forKey:WVSkippedTagsKey];
        BOOL synchronized = [store synchronize];
        if (!synchronized || ![[store objectForKey:WVSkippedTagsKey] isEqual:saved])
            return WVNotificationError(error, @"The skipped update version could not be saved and verified.");
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        return WVNotificationError(error, @"The skipped update version could not be saved and verified.");
    }
}

// Startup-only selection. Manual About uses the unchanged catalog directly and
// may install a skipped tag when it is newer. Never fall back from a skipped
// highest eligible release to an older notification.
static NSDictionary *WVStartupNotification(NSDictionary *catalog, NSString *currentTag,
                                           NSString *installedChannel, NSArray *skips) {
    NSArray<NSString *> *current = WVParseReleaseTag(currentTag);
    if (![catalog isKindOfClass:NSDictionary.class] || !current ||
        ![@[@"stable", @"preview"] containsObject:installedChannel]) return nil;
    NSArray *channels = [installedChannel isEqual:@"stable"] ? @[@"stable"] : @[@"stable", @"preview"];
    NSDictionary *selected;
    NSArray *highest;
    NSString *selectedChannel;
    for (NSString *channel in channels) {
        id row = catalog[channel];
        if (![row isKindOfClass:NSDictionary.class] || ![row[@"state"] isEqual:@"available"]) continue;
        if (![row[@"canInstall"] isKindOfClass:NSNumber.class] || ![row[@"canInstall"] isEqual:@YES]) continue;
        NSDictionary *descriptor = row[@"descriptor"];
        NSArray<NSString *> *version = WVParseReleaseTag(row[@"latestTag"]);
        if (!version || !WVValidateDownloadDescriptor(descriptor) ||
            ![descriptor[@"tag"] isEqual:row[@"latestTag"]] || ![descriptor[@"channel"] isEqual:channel] ||
            WVCompareReleaseVersions(version, current) != NSOrderedDescending) continue;
        if (!selected || WVCompareReleaseVersions(version, highest) == NSOrderedDescending) {
            selected = row; highest = version; selectedChannel = channel;
        }
    }
    if (!selected || ([skips isKindOfClass:NSArray.class] && [skips containsObject:selected[@"latestTag"]])) return nil;
    NSMutableDictionary *result = [selected mutableCopy];
    result[@"channel"] = selectedChannel; result[@"tag"] = selected[@"latestTag"];
    if (![NSJSONSerialization isValidJSONObject:result]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}
#endif
