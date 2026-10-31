#ifndef WV_UPDATE_TRANSACTION_H
#define WV_UPDATE_TRANSACTION_H
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <libproc.h>
#include <math.h>
#include <limits.h>

static id WVUPError(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"com.ry00ki.wallpaperveil.update" code:1
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"The update could not be completed"}];
    return nil;
}
static BOOL WVUPCheck(BOOL value, NSError **error, NSString *message) {
    if (!value) WVUPError(error,message); return value;
}
static BOOL WVUPHex(id value, NSUInteger length) {
    if (![value isKindOfClass:NSString.class] || [value length]!=length) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL WVUPInteger(id value,double maximum) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&
        isfinite([value doubleValue])&&[value doubleValue]>0&&floor([value doubleValue])==[value doubleValue]&&[value doubleValue]<=maximum;
}
static BOOL WVUPPrivateDirectory(NSURL *url, NSError **error) {
    struct stat s;
    return WVUPCheck(url.isFileURL && lstat(url.fileSystemRepresentation,&s)==0 && S_ISDIR(s.st_mode) &&
        s.st_uid==getuid() && (s.st_mode&0077)==0,error,@"The update directory must be private, owned and not a symbolic link");
}
static BOOL WVUPWriteAll(int fd,const void *bytes,size_t length) {
    const uint8_t *p=bytes;
    while(length) { ssize_t n=write(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;length-=n; }
    return YES;
}
static NSDictionary *WVReadPrivateUpdateJSON(NSURL *url, NSError **error) {
    int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat s;
    if(fd<0)return WVUPError(error,@"The update record could not be opened");
    if(fstat(fd,&s)!=0||!S_ISREG(s.st_mode)||s.st_uid!=getuid()||(s.st_mode&0077)||s.st_size<2||s.st_size>1024*1024) {
        close(fd);return WVUPError(error,@"The update record is unsafe or too large");
    }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];size_t done=0;
    while(done<data.length) {ssize_t n=read(fd,(uint8_t *)data.mutableBytes+done,data.length-done);if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=n;}
    close(fd);if(done!=data.length)return WVUPError(error,@"The update record is incomplete");
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [value isKindOfClass:NSDictionary.class]?value:WVUPError(error,@"The update record is unreadable");
}
static BOOL WVWritePrivateUpdateJSON(NSDictionary *value, NSURL *url, NSError **error) {
    if(!WVUPPrivateDirectory(url.URLByDeletingLastPathComponent,error))return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:error];
    if(!data||data.length>1024*1024)return NO;
    NSURL *temporary=[url.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".record-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return WVUPCheck(NO,error,@"The update record could not be created");
    BOOL ok=WVUPWriteAll(fd,data.bytes,data.length)&&fsync(fd)==0;close(fd);
    if(ok)ok=rename(temporary.fileSystemRepresentation,url.fileSystemRepresentation)==0;
    if(!ok)unlink(temporary.fileSystemRepresentation);
    int parent=open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(ok&&parent>=0)ok=fsync(parent)==0;
    if(parent>=0)close(parent);
    return WVUPCheck(ok,error,@"The update record could not be saved");
}
static NSString *WVUPSHAData(NSData *data) {
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);
    const uint8_t *p=data.bytes;NSUInteger left=data.length;
    while(left){CC_LONG size=(CC_LONG)MIN(left,(NSUInteger)1024*1024);CC_SHA256_Update(&ctx,p,size);left-=size;p+=size;}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&ctx);
    NSMutableString *result=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[result appendFormat:@"%02x",digest[i]];return result;
}
static NSString *WVUPSHAFile(NSURL *url,NSError **error) {
    int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat s;
    if(fd<0)return WVUPError(error,@"An update file could not be opened");
    if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_size<0||s.st_size>256*1024*1024){close(fd);return WVUPError(error,@"An update file is unsafe or too large");}
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char buffer[65536];ssize_t n;
    while((n=read(fd,buffer,sizeof(buffer)))!=0){if(n<0&&errno==EINTR)continue;if(n<0){close(fd);return WVUPError(error,@"An update file could not be read");}CC_SHA256_Update(&ctx,buffer,(CC_LONG)n);}
    close(fd);unsigned char digest[32];CC_SHA256_Final(digest,&ctx);NSMutableString *result=[NSMutableString string];
    for(NSUInteger i=0;i<32;i++)[result appendFormat:@"%02x",digest[i]];return result;
}
#ifdef WV_UPDATE_PACKAGE_TESTING
static NSURL *WVUPTestRuntimeDirectory;
#endif
static NSURL *WVUpdateRuntimeDirectory(void) {
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestRuntimeDirectory)return WVUPTestRuntimeDirectory;
#endif
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Wallpaper Veil/runtime"] isDirectory:YES];
}
static NSString *WVUPProcessPath(pid_t pid) {
    if(pid<=1)return nil;char path[PROC_PIDPATHINFO_MAXSIZE];int size=proc_pidpath(pid,path,sizeof(path));
    return size>0?[NSString stringWithUTF8String:path]:nil;
}
static NSDictionary *WVUpdateRequestForJob(NSURL *job,NSError **error) {
    if(!WVUPPrivateDirectory(job,error))return nil;
    NSDictionary *r=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"request.json"],error);
    if(!r)return nil;
    for(NSString *key in @[@"jobDir",@"helperPath",@"targetApp",@"candidateApp",@"replacementDirectory",@"tag",@"build",@"sourceCommit",@"oldLauncherSHA256",@"newLauncherSHA256",@"oldRuntimeSHA256",@"newRuntimeSHA256",@"helperSHA256"])
        if(![r[key] isKindOfClass:NSString.class]||![r[key] length])return WVUPError(error,@"The update request is incomplete");
    if(!WVUPInteger(r[@"schema"],1)||![r[@"schema"] isEqual:@1]||!WVUPHex(r[@"nonce"],64)||!WVUPHex(r[@"sourceCommit"],40)||
       ![r[@"jobDir"] isEqual:job.URLByStandardizingPath.path]||
       ![r[@"helperPath"] isEqual:[job URLByAppendingPathComponent:@"WallpaperVeilUpdater"].path]||
       ![r[@"targetApp"] hasSuffix:@"/Wallpaper Veil.app"]||
       ![r[@"candidateApp"] isEqual:[r[@"replacementDirectory"] stringByAppendingPathComponent:@"Wallpaper Veil.app"]])
        return WVUPError(error,@"The update request has an invalid identity");
    for(NSString *key in @[@"targetApp",@"candidateApp",@"replacementDirectory",@"helperPath",@"jobDir"])
        if(![r[key] hasPrefix:@"/"]||![r[key] isEqual:[r[key] stringByStandardizingPath]])return WVUPError(error,@"The update request has an unsafe absolute path");
    if(![r[@"release"] isKindOfClass:NSDictionary.class]||!WVUPInteger(r[@"oldPID"],INT_MAX)||[r[@"oldPID"] intValue]<=1||![r[@"createdAt"] isKindOfClass:NSNumber.class]||!isfinite([r[@"createdAt"] doubleValue])||[r[@"createdAt"] doubleValue]<=0)return WVUPError(error,@"The update request has an invalid release or process identity");
    for(NSString *key in @[@"oldLauncherSHA256",@"newLauncherSHA256",@"oldRuntimeSHA256",@"newRuntimeSHA256",@"helperSHA256"])
        if(!WVUPHex(r[key],64))return WVUPError(error,@"The update request has an invalid file identity");
    return r;
}
// Pure receipt comparison; process facts are observed independently by the helper.
static BOOL WVUpdateHealthReceiptMatches(NSDictionary *health,NSDictionary *r,NSDictionary *process) {
    if(![health isKindOfClass:NSDictionary.class]||![process isKindOfClass:NSDictionary.class])return NO;
    NSNumber *pid=health[@"pid"];
    if(![pid isKindOfClass:NSNumber.class]||pid.intValue<=1||[pid isEqual:r[@"oldPID"]])return NO;
    NSString *executable=[r[@"targetApp"] stringByAppendingPathComponent:@"Contents/Helpers/Wallpaper Veil Runtime.app/Contents/MacOS/WallpaperVeilRuntime"];
    NSString *bundle=[r[@"targetApp"] stringByAppendingPathComponent:@"Contents/Helpers/Wallpaper Veil Runtime.app"];
    for(NSString *key in @[@"nonce",@"tag",@"build",@"sourceCommit"])if(![health[key] isEqual:r[key]])return NO;
    return [health[@"ok"] isEqual:@YES]&&[health[@"installedAppPath"] isEqual:r[@"targetApp"]]&&
        [health[@"executablePath"] isEqual:executable]&&[process[@"pid"] isEqual:pid]&&
        [process[@"executablePath"] isEqual:executable]&&[process[@"bundlePath"] isEqual:bundle]&&
        [process[@"bundleID"] isEqual:@"com.ry00ki.wallpaperveil"]&&
        [process[@"launchTime"] isKindOfClass:NSNumber.class]&&[process[@"launchTime"] doubleValue]>=[r[@"createdAt"] doubleValue]-1;
}
// Shared with the outer launcher: normal launches block on update.lock. Only
// this nonce-bound launch may proceed while the exact copied helper is alive.
static BOOL WVAuthorizeUpdateLaunch(NSURL *job,NSString *nonce,NSURL *bundle,NSError **error) {
    NSDictionary *r=WVUpdateRequestForJob(job,error);if(!r)return NO;
    NSDictionary *active=WVReadPrivateUpdateJSON([WVUpdateRuntimeDirectory() URLByAppendingPathComponent:@"active-update.json"],error);
    NSDictionary *journal=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"journal.json"],error);
    if(!WVUPInteger(active[@"helperPID"],INT_MAX))return WVUPCheck(NO,error,@"The installer process identity is invalid");
    pid_t helper=[active[@"helperPID"] intValue];
    if(!WVUPCheck([journal[@"phase"] isEqual:@"launching"]&&[journal[@"nonce"] isEqual:nonce]&&[r[@"nonce"] isEqual:nonce]&&[r[@"targetApp"] isEqual:bundle.URLByStandardizingPath.path]&&
        [active[@"jobDir"] isEqual:r[@"jobDir"]]&&[active[@"nonce"] isEqual:nonce]&&
        [active[@"targetApp"] isEqual:r[@"targetApp"]]&&[WVUPProcessPath(helper) isEqual:r[@"helperPath"]],error,@"The update launch is not owned by the active installer"))return NO;
    int fd=open([WVUpdateRuntimeDirectory() URLByAppendingPathComponent:@"update.lock"].fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return WVUPCheck(NO,error,@"The update launch lock is unavailable");
    BOOL held=flock(fd,LOCK_EX|LOCK_NB)!=0&&(errno==EWOULDBLOCK||errno==EAGAIN);close(fd);
    return WVUPCheck(held&&[WVUPSHAFile([job URLByAppendingPathComponent:@"WallpaperVeilUpdater"],error) isEqual:r[@"helperSHA256"]],error,@"The update helper or its lock changed");
}
#endif
