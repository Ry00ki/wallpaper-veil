// Bundled native installer. Never changes preferences, permissions or brightness.
#import <AppKit/AppKit.h>
#import "update_package.h"
#include <stdio.h>
#include <sys/param.h>

static NSDictionary *request;
static NSURL *job;
static int updateLock=-1,launchLock=-1;
#ifdef WV_UPDATE_PACKAGE_TESTING
static BOOL (^WVUPTestLaunch)(BOOL,NSError **);
static BOOL (^WVUPTestStop)(NSError **);
static BOOL (^WVUPTestHealth)(NSError **);
#endif
static void pauseRunLoop(void){[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];}
static BOOL record(NSString *phase,NSString *message,NSError **error) {
    NSMutableDictionary *value=[@{@"schema":@1,@"nonce":request[@"nonce"],@"phase":phase,@"helperPID":@(getpid()),@"updatedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    if(message)value[@"message"]=message;
    return WVWritePrivateUpdateJSON(value,[job URLByAppendingPathComponent:@"journal.json"],error);
}
static void clearPointer(void){
    NSURL *pointer=[WVUpdateRuntimeDirectory() URLByAppendingPathComponent:@"active-update.json"];
    NSDictionary *active=WVReadPrivateUpdateJSON(pointer,NULL);
    if([active[@"jobDir"] isEqual:request[@"jobDir"]]&&[active[@"nonce"] isEqual:request[@"nonce"]])unlink(pointer.fileSystemRepresentation);
}
static BOOL acquireLocks(NSError **error) {
    NSURL *directory=WVUpdateRuntimeDirectory();
    if(![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]||!WVUPPrivateDirectory(directory,error))return NO;
    for(NSString *name in @[@"update.lock",@"launch.lock"]){
        int fd=open([directory URLByAppendingPathComponent:name].fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;
        if(fd<0||fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=getuid()||(s.st_mode&0077)){if(fd>=0)close(fd);return WVUPCheck(NO,error,@"The update lock is unsafe");}
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:[name isEqual:@"update.lock"]?3:10];BOOL locked=NO;
        do{if(flock(fd,LOCK_EX|LOCK_NB)==0){locked=YES;break;}if(errno!=EWOULDBLOCK&&errno!=EAGAIN)break;pauseRunLoop();}while(deadline.timeIntervalSinceNow>0);
        if(!locked){close(fd);return WVUPCheck(NO,error,@"Another launch or update is already in progress");}
        if([name isEqual:@"update.lock"])updateLock=fd;else launchLock=fd;
    }
    return YES;
}
static NSURL *targetURL(void){return [NSURL fileURLWithPath:request[@"targetApp"] isDirectory:YES];}
static NSURL *candidateURL(void){return [NSURL fileURLWithPath:request[@"candidateApp"] isDirectory:YES];}
static NSString *runtimePath(void){return [request[@"targetApp"] stringByAppendingPathComponent:@"Contents/Helpers/Wallpaper Veil Runtime.app/Contents/MacOS/WallpaperVeilRuntime"];}
static BOOL processMatches(pid_t pid,NSString *path){
    struct proc_bsdinfo info={0};int size=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info));
    return size==sizeof(info)&&info.pbi_uid==getuid()&&[WVUPProcessPath(pid) isEqual:path];
}
static BOOL bundleMatches(NSURL *app,BOOL newer,NSError **error){
    NSDictionary *identity=WVUPBundleIdentity(app,error);if(!identity)return NO;
    return WVUPCheck([identity[@"launcherSHA256"] isEqual:request[newer?@"newLauncherSHA256":@"oldLauncherSHA256"]]&&
        [identity[@"runtimeSHA256"] isEqual:request[newer?@"newRuntimeSHA256":@"oldRuntimeSHA256"]]&&
        [identity[@"tag"] isEqual:request[newer?@"tag":@"oldTag"]]&&
        [identity[@"build"] isEqual:request[newer?@"build":@"oldBuild"]],error,@"An application changed after update preparation");
}
static BOOL swapApps(NSError **error){
    NSURL *target=targetURL(),*candidate=candidateURL();struct stat a,b;
    if(lstat(target.fileSystemRepresentation,&a)||lstat(candidate.fileSystemRepresentation,&b)||!S_ISDIR(a.st_mode)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev)return WVUPCheck(NO,error,@"The update applications are no longer on the same volume");
    int targetFD=open(target.URLByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    int candidateFD=open(candidate.URLByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(targetFD<0||candidateFD<0){if(targetFD>=0)close(targetFD);if(candidateFD>=0)close(candidateFD);return WVUPCheck(NO,error,@"The update installation directory is unavailable");}
    BOOL ok=renameatx_np(targetFD,target.lastPathComponent.fileSystemRepresentation,candidateFD,candidate.lastPathComponent.fileSystemRepresentation,RENAME_SWAP)==0;
    if(ok){fsync(targetFD);fsync(candidateFD);}close(targetFD);close(candidateFD);
    return WVUPCheck(ok,error,@"The installation does not permit an atomic same-volume update");
}
static BOOL launchTarget(BOOL transaction,NSError **error){
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestLaunch)return WVUPTestLaunch(transaction,error);
#endif
    if(launchLock>=0){close(launchLock);launchLock=-1;}
    NSWorkspaceOpenConfiguration *configuration=NSWorkspaceOpenConfiguration.configuration;
    configuration.activates=NO;configuration.addsToRecentItems=NO;configuration.createsNewApplicationInstance=NO;
    if(transaction)configuration.arguments=@[@"--update-relaunch",request[@"jobDir"],request[@"nonce"]];
    __block BOOL completed=NO,success=NO;__block NSError *failure=nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:targetURL() configuration:configuration completionHandler:^(NSRunningApplication *app,NSError *problem){failure=problem;success=app!=nil&&!problem;completed=YES;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];while(!completed&&deadline.timeIntervalSinceNow>0)pauseRunLoop();
    if(!completed||!success){if(error)*error=failure?:[NSError errorWithDomain:@"com.ry00ki.wallpaperveil.update" code:2 userInfo:@{NSLocalizedDescriptionKey:@"macOS could not open the updated application; it may need user approval"}];return NO;}
    return YES;
}
static BOOL healthMatches(NSError **error){
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestHealth)return WVUPTestHealth(error);
#endif
    NSDictionary *health=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"health.json"],NULL);if(!health)return NO;
    if(![health[@"pid"] isKindOfClass:NSNumber.class])return NO;
    pid_t pid=[health[@"pid"] intValue];if(!processMatches(pid,runtimePath()))return NO;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSDictionary *process=@{@"pid":@(pid),@"executablePath":app.executableURL.path?:@"",@"bundlePath":app.bundleURL.path?:@"",@"bundleID":app.bundleIdentifier?:@"",@"launchTime":@(app.launchDate?app.launchDate.timeIntervalSince1970:0)};
    if(!WVUpdateHealthReceiptMatches(health,request,process))return NO;
    return bundleMatches(targetURL(),YES,error);
}
static BOOL stopCandidate(NSError **error){
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestStop)return WVUPTestStop(error);
#endif
    NSMutableArray *owned=[NSMutableArray array];
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ry00ki.wallpaperveil"]){
        if(app.terminated)continue;
        if([app.executableURL.path isEqual:runtimePath()]&&processMatches(app.processIdentifier,runtimePath())){
            if(app.processIdentifier==[request[@"oldPID"] intValue])return WVUPCheck(NO,error,@"The original runtime unexpectedly remained active");
            [owned addObject:app];[app terminate];
        }
    }
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];BOOL alive;
    do{alive=NO;for(NSRunningApplication *app in owned)if(!app.terminated)alive=YES;if(alive)pauseRunLoop();}while(alive&&deadline.timeIntervalSinceNow>0);
    return WVUPCheck(!alive,error,@"The failed update is still running; the previous app was retained for recovery");
}
static BOOL rollback(NSString *cause,NSError **error){
    if(!record(@"rollingBack",cause,error))return NO;
    if(!bundleMatches(targetURL(),YES,error)||!bundleMatches(candidateURL(),NO,error)||!stopCandidate(error)||!swapApps(error)||!bundleMatches(targetURL(),NO,error)){
        record(@"recoveryRequired",(error&&*error)?(*error).localizedDescription:cause,NULL);return NO;
    }
    if(!record(@"rolledBack",cause,error))return NO;
    // A rollback launch has no candidate health ACK. Clear the gate first so
    // the original launcher may start normally, using its existing single lock.
    clearPointer();if(updateLock>=0){close(updateLock);updateLock=-1;}
    return launchTarget(NO,error);
}
static BOOL commit(NSError **error){
    if(!record(@"committed",@"The new application completed normal startup",error))return NO;
    clearPointer();
    // The previous application is retained in private staging until this point.
    // A failed cleanup is harmless and never changes the installed app.
    NSURL *replacement=[NSURL fileURLWithPath:request[@"replacementDirectory"] isDirectory:YES];
    if(WVUPValidateReplacement(request,NULL))[NSFileManager.defaultManager removeItemAtURL:replacement error:NULL];
    return YES;
}
static BOOL resumeExisting(NSError **error){
    clearPointer();
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestLaunch)return launchTarget(NO,error);
#endif
    if(updateLock>=0){close(updateLock);updateLock=-1;}
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.ry00ki.wallpaperveil"])
        if(!app.terminated&&[app.executableURL.path isEqual:runtimePath()])return YES;
    return launchTarget(NO,error);
}
static BOOL recover(NSError **error){
    NSDictionary *journal=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"journal.json"],error);if(!journal||![journal[@"nonce"] isEqual:request[@"nonce"]])return NO;
    NSString *phase=journal[@"phase"];
    if(![@[@"prepared",@"waiting",@"cancelled",@"swapping",@"swapped",@"launching",@"rollingBack",@"committed",@"rolledBack",@"recoveryRequired"] containsObject:phase?:@""])return WVUPCheck(NO,error,@"The update journal has an unknown phase");
    if([@[@"prepared",@"waiting",@"cancelled"] containsObject:phase]){
        if(!bundleMatches(targetURL(),NO,error))return NO;
        record(@"cancelled",@"The interrupted update did not replace the application",NULL);return resumeExisting(error);
    }
    if([phase isEqual:@"committed"]){if(!bundleMatches(targetURL(),YES,error))return NO;return resumeExisting(error);}
    if([phase isEqual:@"rolledBack"]){if(!bundleMatches(targetURL(),NO,error))return NO;return resumeExisting(error);}
    // A swap and journal save can be interrupted between instructions. Derive
    // the state from BOTH exact bundle identities before choosing any action.
    if(bundleMatches(targetURL(),NO,NULL)&&bundleMatches(candidateURL(),YES,NULL)){
        record(@"rolledBack",@"The original app was already restored",NULL);return resumeExisting(error);
    }
    if(bundleMatches(targetURL(),YES,NULL)&&bundleMatches(candidateURL(),NO,NULL)){
        if(healthMatches(NULL))return commit(error);
        return rollback(@"The interrupted update had no verified startup acknowledgement",error);
    }
    return WVUPCheck(NO,error,@"The interrupted update has unexpected app identities; its backup was retained");
}
int main(int argc,const char *argv[]){@autoreleasepool{
    umask(0077);NSError *error=nil;NSDictionary *active=nil,*journal=nil;NSDate *deadline=nil;pid_t oldPID=0;
    if(argc!=3||(strcmp(argv[1],"--install")&&strcmp(argv[1],"--recover"))){fprintf(stderr,"Usage: WallpaperVeilUpdater --install JOBDIR | --recover JOBDIR\n");return 64;}
    BOOL recovery=strcmp(argv[1],"--recover")==0;job=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
    request=WVUpdateRequestForJob(job,&error);
    if(!request||![WVUPProcessPath(getpid()) isEqual:request[@"helperPath"]]||![WVUPSHAFile([NSURL fileURLWithPath:request[@"helperPath"]],&error) isEqual:request[@"helperSHA256"]]||!WVUPValidSignature([NSURL fileURLWithPath:request[@"helperPath"]],&error)||!acquireLocks(&error))goto failed;
    active=@{@"schema":@1,@"jobDir":request[@"jobDir"],@"nonce":request[@"nonce"],@"helperPID":@(getpid()),@"targetApp":request[@"targetApp"]};
    if(!WVWritePrivateUpdateJSON(active,[WVUpdateRuntimeDirectory() URLByAppendingPathComponent:@"active-update.json"],&error))goto failed;
    if(recovery){if(recover(&error))return 0;goto failed;}
    journal=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"journal.json"],&error);
    if(![journal[@"phase"] isEqual:@"prepared"]||![journal[@"nonce"] isEqual:request[@"nonce"]]||!bundleMatches(targetURL(),NO,&error)||!WVUPCanReplace(targetURL(),&error)||!WVUPValidateReplacement(request,&error)||!WVValidateUpdateBundle(candidateURL(),request[@"release"],&error)||!bundleMatches(candidateURL(),YES,&error))goto failed;
    oldPID=[request[@"oldPID"] intValue];
    if(!processMatches(oldPID,runtimePath())){WVUPError(&error,@"The original runtime no longer matches the update request");goto failed;}
    if(!record(@"waiting",@"Ready for the original runtime to quit",&error)||!WVWritePrivateUpdateJSON(@{@"nonce":request[@"nonce"],@"helperPID":@(getpid()),@"ready":@YES},[job URLByAppendingPathComponent:@"ready.json"],&error))goto failed;
    deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(kill(oldPID,0)==0&&deadline.timeIntervalSinceNow>0){if(!processMatches(oldPID,runtimePath())){WVUPError(&error,@"The original process identity changed before exit");goto failed;}pauseRunLoop();}
    if(kill(oldPID,0)==0){record(@"cancelled",@"The original runtime did not quit",NULL);WVUPError(&error,@"The original application did not quit within 20 seconds");goto failed;}
    if(!bundleMatches(targetURL(),NO,&error)||!bundleMatches(candidateURL(),YES,&error)||!record(@"swapping",nil,&error)||!swapApps(&error))goto failed;
    if(!record(@"swapped",nil,&error)){rollback(@"The replacement journal could not be saved",&error);goto failed;}
    if(!record(@"launching",nil,&error)||!launchTarget(YES,&error)){
        NSString *cause=error.localizedDescription?:@"The updated app could not be launched";rollback(cause,&error);goto failed;
    }
    deadline=[NSDate dateWithTimeIntervalSinceNow:45];
    while(deadline.timeIntervalSinceNow>0){if(healthMatches(NULL)){if(commit(&error))return 0;goto failed;}pauseRunLoop();}
    rollback(@"The updated app did not confirm normal startup within 45 seconds",&error);
    if(!error)WVUPError(&error,@"The update failed normal startup and the original application was restored");
failed:
    if(request){NSDictionary *state=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"journal.json"],NULL);NSString *phase=state[@"phase"];
        if([@[@"prepared",@"waiting",@"cancelled",@"rolledBack"] containsObject:phase])clearPointer();
        if([phase isEqual:@"swapping"]&&bundleMatches(targetURL(),NO,NULL)&&bundleMatches(candidateURL(),YES,NULL)){
            record(@"cancelled",@"The atomic replacement failed; the original app was retained",NULL);resumeExisting(NULL);
        }
        WVWritePrivateUpdateJSON(@{@"ok":@NO,@"nonce":request[@"nonce"],@"message":error.localizedDescription?:@"The update could not be completed",@"phase":phase?:@"error"},[job URLByAppendingPathComponent:@"result.json"],NULL);
    }
    fprintf(stderr,"Wallpaper Veil update: %s\n",(error.localizedDescription?:@"The update could not be completed").UTF8String);return 1;
}}
