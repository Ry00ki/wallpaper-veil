// Wallpaper Veil's narrow, app-owned desktop-widget preference bridge.
// Only the production wrappers choose the WindowManager domain/key. Resetting
// removes this one override; it neither restores a snapshot nor resets a domain.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const WVWidgetPreferenceDomain = @"com.apple.WindowManager";
static NSString * const WVWidgetPreferenceKey = @"StandardHideWidgets";

typedef struct {
    CFPropertyListRef (*copyValue)(CFStringRef, CFStringRef, CFStringRef, CFStringRef);
    void (*setValue)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef);
    Boolean (*synchronize)(CFStringRef, CFStringRef, CFStringRef);
} WVWidgetPreferenceBackend;

static const WVWidgetPreferenceBackend WVSystemWidgetPreferences = {
    CFPreferencesCopyValue, CFPreferencesSetValue, CFPreferencesSynchronize
};

static NSDictionary *WVWidgetPreferenceFailure(NSString *message) {
    return @{@"ok": @NO, @"error": message};
}

// Domain injection is for isolated native tests. It is not exposed to Lua.
static NSDictionary *WVReadWidgetPreferenceInDomain(NSString *domain, const WVWidgetPreferenceBackend *backend) {
    if (!domain.length || !backend || !backend->copyValue || !backend->synchronize)
        return WVWidgetPreferenceFailure(@"The desktop widget setting is unavailable");
    CFStringRef application = (__bridge CFStringRef)domain;
    if (!backend->synchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        return WVWidgetPreferenceFailure(@"Could not read the macOS desktop widget setting");
    CFPropertyListRef value = backend->copyValue((__bridge CFStringRef)WVWidgetPreferenceKey,
        application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!value) return @{@"ok": @YES, @"present": @NO};
    BOOL boolean = CFGetTypeID(value) == CFBooleanGetTypeID();
    BOOL numeric = boolean || (CFGetTypeID(value) == CFNumberGetTypeID() && !CFNumberIsFloatType((CFNumberRef)value));
    NSNumber *number = numeric ? (__bridge NSNumber *)value : nil;
    double hidden = number.doubleValue;
    BOOL valid = numeric && (hidden == 0.0 || hidden == 1.0);
    if (!valid) { CFRelease(value); return WVWidgetPreferenceFailure(@"The macOS desktop widget setting has an unsupported value"); }
    NSDictionary *result = @{@"ok": @YES, @"present": @YES, @"value": @((NSInteger)hidden),
        @"type": CFGetTypeID(value) == CFBooleanGetTypeID() ? @"boolean" : @"integer"};
    CFRelease(value);
    return result;
}

static NSDictionary *WVWriteWidgetPreferenceInDomain(NSString *domain, NSInteger hidden,
                                                     const WVWidgetPreferenceBackend *backend) {
    if (!domain.length || !backend || !backend->setValue || !backend->copyValue || !backend->synchronize ||
        (hidden != 0 && hidden != 1))
        return WVWidgetPreferenceFailure(@"The desktop widget visibility request is invalid");
    backend->setValue((__bridge CFStringRef)WVWidgetPreferenceKey, (__bridge CFPropertyListRef)@(hidden),
        (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *result = WVReadWidgetPreferenceInDomain(domain, backend);
    if (![result[@"ok"] boolValue] || ![result[@"present"] boolValue] || [result[@"value"] integerValue] != hidden)
        return WVWidgetPreferenceFailure(@"Could not verify the macOS desktop widget change");
    return result;
}

static NSDictionary *WVResetWidgetPreferenceInDomain(NSString *domain, const WVWidgetPreferenceBackend *backend) {
    if (!domain.length || !backend || !backend->setValue || !backend->copyValue || !backend->synchronize)
        return WVWidgetPreferenceFailure(@"The desktop widget defaults are unavailable");
    CFStringRef application = (__bridge CFStringRef)domain;
    backend->setValue((__bridge CFStringRef)WVWidgetPreferenceKey, NULL, application,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!backend->synchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        return WVWidgetPreferenceFailure(@"Could not save macOS desktop widget defaults");
    CFPropertyListRef remaining = backend->copyValue((__bridge CFStringRef)WVWidgetPreferenceKey,
        application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (remaining) { CFRelease(remaining); return WVWidgetPreferenceFailure(@"Could not verify macOS desktop widget defaults"); }
    return @{@"ok": @YES, @"present": @NO, @"resetVerified": @YES};
}

// Acceptance-only transient recovery. The app's defaults action never calls
// this helper and never stores an operating-system preference snapshot.
static NSDictionary *WVRestoreWidgetPreferenceForTestInDomain(NSString *domain, NSDictionary *state,
                                                              const WVWidgetPreferenceBackend *backend) {
    if (!domain.length || !backend || !backend->setValue || ![state[@"present"] isKindOfClass:NSNumber.class])
        return WVWidgetPreferenceFailure(@"The widget test recovery state is invalid");
    if (![state[@"present"] boolValue]) return WVResetWidgetPreferenceInDomain(domain, backend);
    NSString *kind = state[@"type"];
    NSNumber *value = state[@"value"];
    if ((![@"boolean" isEqual:kind] && ![@"integer" isEqual:kind]) ||
        ![value isKindOfClass:NSNumber.class] || (value.doubleValue != 0.0 && value.doubleValue != 1.0))
        return WVWidgetPreferenceFailure(@"The widget test recovery value is invalid");
    CFPropertyListRef original = [kind isEqual:@"boolean"]
        ? (value.boolValue ? kCFBooleanTrue : kCFBooleanFalse) : (__bridge CFPropertyListRef)@(value.integerValue);
    backend->setValue((__bridge CFStringRef)WVWidgetPreferenceKey, original,
        (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *result = WVReadWidgetPreferenceInDomain(domain, backend);
    if (![result[@"ok"] boolValue] || ![result[@"present"] boolValue] ||
        [result[@"value"] integerValue] != value.integerValue || ![result[@"type"] isEqual:kind])
        return WVWidgetPreferenceFailure(@"Could not verify the widget test recovery");
    return result;
}
