// An injected memory backend proves key/domain scope. No CFPreferences writes.
#import "../native/widget_preferences.h"
static NSMutableDictionary *values;
static BOOL syncOK = YES, discardWrites = NO;
static NSUInteger reads, writes, syncs, checks;
static NSString * const testDomain = @"com.ry00ki.wallpaperveil.test.widget-preferences";
static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void scope(CFStringRef key, CFStringRef domain, CFStringRef user, CFStringRef host) {
    check(CFEqual(key, (__bridge CFStringRef)WVWidgetPreferenceKey), @"only the explicit widget key is accessed");
    check(CFEqual(domain, (__bridge CFStringRef)testDomain), @"only the injected test domain is accessed");
    check(CFEqual(user, kCFPreferencesCurrentUser) && CFEqual(host, kCFPreferencesAnyHost), @"fixed user/host scope");
}
static CFPropertyListRef memoryCopy(CFStringRef key, CFStringRef domain, CFStringRef user, CFStringRef host) {
    scope(key, domain, user, host); reads++;
    id value = values[(__bridge NSString *)key];
    return value ? CFRetain((__bridge CFTypeRef)value) : NULL;
}
static void memorySet(CFStringRef key, CFPropertyListRef value, CFStringRef domain, CFStringRef user, CFStringRef host) {
    scope(key, domain, user, host); writes++;
    if (discardWrites) return;
    if (value) values[(__bridge NSString *)key] = (__bridge id)value;
    else [values removeObjectForKey:(__bridge NSString *)key];
}
static Boolean memorySync(CFStringRef domain, CFStringRef user, CFStringRef host) {
    check(CFEqual(domain, (__bridge CFStringRef)testDomain), @"synchronize stays in the test domain");
    check(CFEqual(user, kCFPreferencesCurrentUser) && CFEqual(host, kCFPreferencesAnyHost), @"synchronize uses fixed user/host");
    syncs++; return syncOK;
}
int main(void) { @autoreleasepool {
    WVWidgetPreferenceBackend backend = {memoryCopy, memorySet, memorySync};
    values = [@{@"unrelated": @"keep"} mutableCopy];
    NSDictionary *result = WVReadWidgetPreferenceInDomain(testDomain, &backend);
    check([result[@"ok"] boolValue] && ![result[@"present"] boolValue], @"absence is a valid readable state");
    check(writes == 0, @"read of absent key never materializes a default");
    for (NSNumber *value in @[@0, @1]) {
        result = WVWriteWidgetPreferenceInDomain(testDomain, value.integerValue, &backend);
        check([result[@"ok"] boolValue] && [result[@"value"] isEqual:value] && [result[@"type"] isEqual:@"integer"], @"both visibility values are verified");
        result = WVResetWidgetPreferenceInDomain(testDomain, &backend);
        check([result[@"ok"] boolValue] && [result[@"resetVerified"] boolValue] && ![result[@"present"] boolValue], @"reset deletes the key, not a hardcoded default");
        check(values[WVWidgetPreferenceKey] == nil && [values[@"unrelated"] isEqual:@"keep"], @"reset preserves every unrelated value");
    }
    result = WVResetWidgetPreferenceInDomain(testDomain, &backend);
    check([result[@"ok"] boolValue], @"repeating reset while absent is idempotent");
    NSUInteger previousWrites = writes;
    result = WVWriteWidgetPreferenceInDomain(testDomain, 2, &backend);
    check(![result[@"ok"] boolValue] && previousWrites == writes, @"invalid write is rejected without mutation");
    for (id bad in @[@2, @0.5, @0.0, @"0", @[]]) {
        values[WVWidgetPreferenceKey] = bad;
        result = WVReadWidgetPreferenceInDomain(testDomain, &backend);
        check(![result[@"ok"] boolValue] && [result[@"error"] length] > 0, @"unsupported values fail clearly");
    }
    values[WVWidgetPreferenceKey] = @YES;
    result = WVReadWidgetPreferenceInDomain(testDomain, &backend);
    check([result[@"type"] isEqual:@"boolean"] && [result[@"value"] isEqual:@1], @"typed read distinguishes boolean from integer");
    discardWrites = YES;
    result = WVResetWidgetPreferenceInDomain(testDomain, &backend);
    check(![result[@"ok"] boolValue] && ![result[@"resetVerified"] boolValue], @"surviving override cannot claim a successful reset");
    result = WVWriteWidgetPreferenceInDomain(testDomain, 0, &backend);
    check(![result[@"ok"] boolValue], @"write read-back mismatch fails");
    discardWrites = NO; syncOK = NO;
    result = WVResetWidgetPreferenceInDomain(testDomain, &backend);
    check(![result[@"ok"] boolValue] && [result[@"error"] length] > 0, @"synchronize failure cannot claim reset success");
    previousWrites = writes;
    result = WVReadWidgetPreferenceInDomain(testDomain, &backend);
    check(![result[@"ok"] boolValue] && writes == previousWrites, @"failed read never writes");
    syncOK = YES;
    for (NSDictionary *state in @[@{@"present":@YES,@"value":@0,@"type":@"boolean"},
            @{@"present":@YES,@"value":@1,@"type":@"boolean"},
            @{@"present":@YES,@"value":@0,@"type":@"integer"},
            @{@"present":@YES,@"value":@1,@"type":@"integer"}, @{@"present":@NO}]) {
        result = WVRestoreWidgetPreferenceForTestInDomain(testDomain, state, &backend);
        check([result[@"ok"] boolValue] && [result[@"present"] isEqual:state[@"present"]], @"transient acceptance cleanup handles present/absent");
        if ([state[@"present"] boolValue]) check([result[@"type"] isEqual:state[@"type"]] && [result[@"value"] isEqual:state[@"value"]], @"test cleanup preserves the original property-list type");
    }
    previousWrites = writes;
    result = WVRestoreWidgetPreferenceForTestInDomain(testDomain, @{@"present":@YES,@"value":@0,@"type":@"string"}, &backend);
    check(![result[@"ok"] boolValue] && writes == previousWrites, @"invalid test cleanup is rejected before mutation");
    check([values[@"unrelated"] isEqual:@"keep"] && reads > 0 && syncs > 0, @"all transactions preserve unrelated preferences");
    printf("%lu native widget-preference assertions passed\n", (unsigned long)checks);
} return 0; }
