#import <Foundation/Foundation.h>
#import "../native/update_notifications.h"

@interface WVMemoryUpdateStore : NSObject
@property NSMutableDictionary *values;
@property BOOL rejectWrites;
@property BOOL failSync;
@property BOOL failReads;
@property BOOL failAfterWrite;
@property BOOL throwWrites;
@property NSUInteger writes;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (BOOL)synchronize;
@end
@implementation WVMemoryUpdateStore
- (instancetype)init { if ((self=[super init])) _values=[NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key {
    if(self.failReads || (self.failAfterWrite && self.writes)) @throw [NSException exceptionWithName:@"FixtureReadFailure" reason:@"injected" userInfo:nil];
    return self.values[key];
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if(self.throwWrites) @throw [NSException exceptionWithName:@"FixtureWriteFailure" reason:@"injected" userInfo:nil];
    self.writes++;if(!self.rejectWrites)self.values[key]=value;
}
- (BOOL)synchronize { return !self.failSync; }
@end
static NSUInteger assertions;
static void check(BOOL passed, NSString *message) {
    assertions++; if(!passed){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static NSDictionary *release(NSString *tag, BOOL preview) {
    NSString *name=preview?@"wallpaper-veil-preview.zip":@"wallpaper-veil.zip";
    NSString *digest=[@"sha256:" stringByAppendingString:[@"" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]];
    return @{@"id":@1,@"tag_name":tag,@"draft":@NO,@"prerelease":@(preview),@"html_url":WVTrustedReleaseURL(tag),@"assets":@[
        @{@"id":@2,@"name":name,@"size":@100,@"state":@"uploaded",@"digest":digest,@"browser_download_url":WVUpdateAssetURL(tag,name)},
        @{@"id":@3,@"name":@"wallpaper-veil-build.json",@"size":@200,@"state":@"uploaded",@"digest":digest,@"browser_download_url":WVUpdateAssetURL(tag,@"wallpaper-veil-build.json")}]};
}
int main(void){@autoreleasepool{
    WVMemoryUpdateStore *store=[WVMemoryUpdateStore new];NSError *error=nil;
    check(WVStartupChecksEnabled(store),@"missing startup choice defaults enabled");
    check(WVSaveStartupChecksEnabled(store,NO,&error)&&!error&&!WVStartupChecksEnabled(store),@"explicit disable saved/read back");
    WVMemoryUpdateStore *reloaded=[WVMemoryUpdateStore new];reloaded.values=store.values;
    check(!WVStartupChecksEnabled(reloaded),@"disabled choice survives store recreation");
    check(WVSaveStartupChecksEnabled(reloaded,YES,&error)&&WVStartupChecksEnabled(store),@"enable survives store recreation");
    for(id value in @[@"false",@1,@{},@[],NSNull.null]){
        store.values[WVStartupChecksKey]=value;
        check(!WVStartupChecksEnabled(store),@"malformed startup preference fails closed");
    }
    store.failReads=YES;check(!WVStartupChecksEnabled(store),@"unreadable preference disables automatic check");store.failReads=NO;
    for(NSString *failure in @[@"sync",@"reject",@"write",@"readback"]){
        WVMemoryUpdateStore *broken=[WVMemoryUpdateStore new];broken.values[WVStartupChecksKey]=@NO;
        broken.failSync=[failure isEqual:@"sync"];broken.rejectWrites=[failure isEqual:@"reject"];
        broken.throwWrites=[failure isEqual:@"write"];broken.failAfterWrite=[failure isEqual:@"readback"];
        error=nil;check(!WVSaveStartupChecksEnabled(broken,YES,&error)&&error!=nil,@"startup persistence failure reported honestly");
    }
    check(!WVSaveStartupChecksEnabled(nil,NO,&error)&&error,@"missing store cannot report saved");
    store=[WVMemoryUpdateStore new];
    check(WVSkippedUpdateTags(store).count==0,@"missing skip history empty");
    NSMutableString *tag=[@"v1.0.0-preview.1" mutableCopy];
    check(WVRememberSkippedUpdate(store,tag,&error)&&!error,@"valid skip persisted");[tag appendString:@"changed"];
    check([WVSkippedUpdateTags(store) isEqual:@[@"v1.0.0-preview.1"]],@"stored tag is immutable snapshot");
    reloaded=[WVMemoryUpdateStore new];reloaded.values=store.values;
    check([WVSkippedUpdateTags(reloaded) isEqual:@[@"v1.0.0-preview.1"]],@"skip survives recreated store");
    check(WVRememberSkippedUpdate(reloaded,@"v1.0.0-preview.1",&error)&&WVSkippedUpdateTags(store).count==1,@"skip duplicates do not accumulate");
    for(id bad in @[@"v01.0.0",@"v1.0.0-beta.1",@"../../bad",NSNull.null,@1]){
        error=nil;check(!WVRememberSkippedUpdate(store,bad,&error)&&error,@"invalid skipped version rejected");
    }
    for(NSUInteger i=1;i<=18;i++)check(WVRememberSkippedUpdate(store,[NSString stringWithFormat:@"v2.0.%lu",(unsigned long)i],&error),@"skip written");
    NSArray *skips=WVSkippedUpdateTags(store);
    check(skips.count==16&&[skips.firstObject isEqual:@"v2.0.3"]&&[skips.lastObject isEqual:@"v2.0.18"],@"skip history bounded to most recent sixteen");
    store.values[WVSkippedTagsKey]=@[@"bad",@"v3.0.0",@1,@"v3.0.0",@"v3.0.1"];
    check([WVSkippedUpdateTags(store) isEqual:@[@"v3.0.0",@"v3.0.1"]],@"malformed skip entries sanitized and deduplicated");
    store.values[WVSkippedTagsKey]=@"invalid";check(WVSkippedUpdateTags(store).count==0,@"malformed skip container ignored");
    for(NSString *failure in @[@"sync",@"reject",@"write",@"readback"]){
        WVMemoryUpdateStore *broken=[WVMemoryUpdateStore new];
        broken.failSync=[failure isEqual:@"sync"];broken.rejectWrites=[failure isEqual:@"reject"];
        broken.throwWrites=[failure isEqual:@"write"];broken.failAfterWrite=[failure isEqual:@"readback"];
        error=nil;check(!WVRememberSkippedUpdate(broken,@"v1.0.0",&error)&&error,@"skip persistence failure reported honestly");
    }
    WVMemoryUpdateStore *unreadable=[WVMemoryUpdateStore new];unreadable.failReads=YES;
    check(!WVRememberSkippedUpdate(unreadable,@"v1.0.0",&error)&&error&&unreadable.writes==0,@"unreadable skip history is not overwritten");
    NSString *current=@"v1.0.0-preview.1";
    NSDictionary *catalog=WVUpdateCatalog(@[release(@"v1.0.0",NO),release(@"v1.1.0-preview.1",YES)],current);
    NSDictionary *notice=WVStartupNotification(catalog,current,@"preview",@[]);
    check([notice[@"tag"] isEqual:@"v1.1.0-preview.1"]&&[notice[@"channel"] isEqual:@"preview"],@"preview installation chooses highest across strict catalogs");
    notice=WVStartupNotification(catalog,current,@"stable",@[]);
    check([notice[@"tag"] isEqual:@"v1.0.0"]&&[notice[@"channel"] isEqual:@"stable"],@"stable installation only notifies stable");
    check(!WVStartupNotification(catalog,current,@"preview",@[@"v1.1.0-preview.1"]),@"skipped highest has no fallback older notification");
    check(WVStartupNotification(catalog,current,@"preview",@[@"v1.0.0"])!=nil,@"skipped older stable does not hide newer preview");
    NSDictionary *promotion=WVUpdateCatalog(@[release(@"v1.0.0",NO)],current);
    notice=WVStartupNotification(promotion,current,@"preview",@[current]);
    check([notice[@"tag"] isEqual:@"v1.0.0"],@"skipped preview does not hide stable promotion");
    NSDictionary *newVersion=WVUpdateCatalog(@[release(@"v1.1.0-preview.2",YES)],current);
    check(WVStartupNotification(newVersion,current,@"preview",@[@"v1.1.0-preview.1"])!=nil,@"new tag can notify after skipping previous tag");
    check([catalog[@"preview"][@"canInstall"] boolValue],@"notification skip does not mutate manual catalog eligibility");
    NSDictionary *old=WVUpdateCatalog(@[release(@"v0.9.0",NO)],current);
    check(!WVStartupNotification(old,current,@"preview",@[]),@"older catalog never notifies");
    NSDictionary *same=WVUpdateCatalog(@[release(current,YES)],current);
    check(!WVStartupNotification(same,current,@"preview",@[]),@"current catalog never notifies");
    NSMutableDictionary *forged=[old[@"stable"] mutableCopy];forged[@"canInstall"]=@YES;forged[@"state"]=@"available";
    check(!WVStartupNotification(@{@"stable":forged},current,@"stable",@[]),@"version independently rechecked despite canInstall");
    forged=[catalog[@"stable"] mutableCopy];forged[@"canInstall"]=@"true";
    check(!WVStartupNotification(@{@"stable":forged},current,@"stable",@[]),@"malformed canInstall cannot notify");
    check(!WVStartupNotification(catalog,@"invalid",@"preview",@[])&&!WVStartupNotification(catalog,current,@"nightly",@[]),@"invalid installed metadata fails closed");
    check(!WVStartupNotification(@{@"stable":NSNull.null},current,@"stable",@[]),@"malformed catalog row ignored");
    store=[WVMemoryUpdateStore new];WVSaveStartupChecksEnabled(store,NO,NULL);
    NSDictionary *disabled=WVStartupChecksEnabled(store)?WVStartupNotification(catalog,current,@"preview",@[]):nil;
    check(!disabled,@"global disabled check skips notification path");
    printf("PASS: %lu native notification assertions\n",(unsigned long)assertions);
}return 0;}
