#define WV_UPDATE_PACKAGE_TESTING 1
#define main WVUpdaterMainNotRun
#import "../native/updater.m"
#undef main
int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc<3)return 64;NSError *error=nil;NSString *operation=[NSString stringWithUTF8String:argv[1]];NSURL *input=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];BOOL ok=NO;
    if([operation isEqual:@"inspect"]){NSDictionary *result=WVInspectUpdateZIP(input,&error);ok=result!=nil;if(ok)printf("%lu entries %llu output bytes\n",(unsigned long)[result[@"entries"] count],[result[@"outputBytes"] unsignedLongLongValue]);}
    else if([operation isEqual:@"extract"]&&argc==4)ok=WVExtractUpdateZIP(input,[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]] isDirectory:YES],&error);
    else if([operation isEqual:@"bundle"]&&argc==4){WVUPTestSkipArchitectures=YES;WVUPTestSignature=^BOOL(NSURL *url,NSError **e){(void)url;(void)e;return YES;};NSDictionary *release=WVUPReadObject([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]],NO,&error);ok=release&&WVValidateUpdateBundle(input,release,&error)!=nil;}
    else if([operation isEqual:@"signature"])ok=WVUPValidSignature(input,&error);
    else if([operation isEqual:@"swap"]&&argc==4){request=@{@"targetApp":input.path,@"candidateApp":[NSString stringWithUTF8String:argv[3]]};ok=swapApps(&error);}
    else if(([@[@"recover",@"rollback",@"launchFailure",@"health"] containsObject:operation])){
        WVUPTestSkipArchitectures=YES;WVUPTestSignature=^BOOL(NSURL *url,NSError **e){(void)url;(void)e;return YES;};
        request=WVUPReadObject(input,NO,&error);job=[NSURL fileURLWithPath:request[@"jobDir"] isDirectory:YES];
        WVUPTestRuntimeDirectory=[job URLByAppendingPathComponent:@"runtime" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:WVUPTestRuntimeDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
        WVUPTestLaunch=^BOOL(BOOL candidate,NSError **e){NSMutableArray *calls=[[NSArray arrayWithContentsOfURL:[job URLByAppendingPathComponent:@"launches.plist"]] mutableCopy]?:[NSMutableArray array];[calls addObject:candidate?@"new":@"old"];[calls writeToURL:[job URLByAppendingPathComponent:@"launches.plist"] atomically:YES];return candidate?WVUPCheck(NO,e,@"Synthetic launch failure"):YES;};
        WVUPTestStop=^BOOL(NSError **e){return WVUPCheck(![request[@"fixtureStopFailure"] boolValue],e,@"Synthetic candidate shutdown failure");};
        WVUPTestHealth=^BOOL(NSError **e){(void)e;return [request[@"fixtureHealthy"] boolValue];};
        if([operation isEqual:@"health"])ok=WVUpdateHealthReceiptMatches(request[@"fixtureHealth"],request,request[@"fixtureProcess"]);
        else if([operation isEqual:@"recover"])ok=recover(&error);
        else if([operation isEqual:@"rollback"])ok=rollback(@"Synthetic missing or invalid startup ACK",&error);
        else {if(!launchTarget(YES,&error)){error=nil;ok=rollback(@"Synthetic launch failure",&error);}}
    }
    else if([operation isEqual:@"writable"])ok=WVUPCanReplace(input,&error);
    else if([operation isEqual:@"publisher"]&&argc==4)ok=WVUPValidatePublisher(input,[NSString stringWithUTF8String:argv[3]],&error);
    else if([operation isEqual:@"signer"]&&argc==4)ok=WVUPSignerContinuity([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]]);
    else if([operation isEqual:@"request"])ok=WVUpdateRequestForJob(input,&error)!=nil;
    if(!ok)fprintf(stderr,"%s\n",(error.localizedDescription?:@"Invalid operation").UTF8String);return ok?0:1;
}}
