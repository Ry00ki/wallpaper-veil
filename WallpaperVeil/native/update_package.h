#ifndef WV_UPDATE_PACKAGE_H
#define WV_UPDATE_PACKAGE_H
#import "update_transaction.h"
#import "update_check.h"
#import <Security/Security.h>
#include <zlib.h>

static const uint64_t WVUPMaxZIP=64*1024*1024, WVUPMaxOutput=256*1024*1024, WVUPMaxFile=64*1024*1024;
static uint16_t WVUP16(const uint8_t *p){return (uint16_t)(p[0]|p[1]<<8);}
static uint32_t WVUP32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static BOOL WVUPRange(uint64_t start,uint64_t size,uint64_t total){return start<=total&&size<=total-start;}
static NSString *WVUPPath(id value,NSError **error) {
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>1024)return WVUPError(error,@"An archive path is invalid");
    NSString *path=value;
    if([path hasSuffix:@"/"])path=[path substringToIndex:path.length-1];
    NSCharacterSet *bad=[NSCharacterSet characterSetWithCharactersInString:@"\\:\0"];
    if([path hasPrefix:@"/"]||[path rangeOfCharacterFromSet:bad].location!=NSNotFound||
       [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return WVUPError(error,@"An archive path is unsafe");
    NSArray *parts=[path componentsSeparatedByString:@"/"];
    if(parts.count>32||![parts.firstObject isEqual:@"Wallpaper Veil.app"])return WVUPError(error,@"The archive must contain only Wallpaper Veil.app");
    for(NSString *part in parts)if(!part.length||[part isEqual:@"."]||[part isEqual:@".."])return WVUPError(error,@"An archive path traverses outside its directory");
    return path;
}
static NSString *WVUPAlias(NSString *path) {
    return [path.decomposedStringWithCanonicalMapping stringByFoldingWithOptions:NSCaseInsensitiveSearch|NSWidthInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
}
static BOOL WVUPExtras(const uint8_t *bytes,NSUInteger size,NSError **error) {
    NSUInteger at=0;
    while(at<size){if(!WVUPRange(at,4,size))return WVUPCheck(NO,error,@"Malformed archive extra field");uint16_t kind=WVUP16(bytes+at),length=WVUP16(bytes+at+2);at+=4;
        if(!WVUPRange(at,length,size)||!(kind==0x5855||kind==0x5455||kind==0x7875))return WVUPCheck(NO,error,@"Unsupported archive extra field");at+=length;}
    return YES;
}
static BOOL WVUPEntryData(NSData *archive,NSDictionary *entry,int output,NSMutableData *capture,NSError **error) {
    uint64_t size=[entry[@"size"] unsignedLongLongValue],compressed=[entry[@"compressed"] unsignedLongLongValue],offset=[entry[@"offset"] unsignedLongLongValue];
    const uint8_t *input=(const uint8_t *)archive.bytes+offset;uint64_t written=0;uLong crc=crc32(0,NULL,0);
    if([entry[@"method"] intValue]==0){
        if(size!=compressed)return WVUPCheck(NO,error,@"Stored archive entry sizes disagree");
        crc=crc32(crc,input,(uInt)size);written=size;
        if(capture)[capture appendBytes:input length:(NSUInteger)size];
        if(output>=0&&!WVUPWriteAll(output,input,(size_t)size))return WVUPCheck(NO,error,@"Could not write the staged update");
    }else{
        z_stream stream={0};stream.next_in=(Bytef *)input;stream.avail_in=(uInt)compressed;
        if(inflateInit2(&stream,-MAX_WBITS)!=Z_OK)return WVUPCheck(NO,error,@"Could not initialize update decompression");
        int result;uint8_t buffer[65536];BOOL ok=YES;
        do{stream.next_out=buffer;stream.avail_out=sizeof(buffer);result=inflate(&stream,Z_NO_FLUSH);
            NSUInteger chunk=sizeof(buffer)-stream.avail_out;written+=chunk;
            if(written>size||written>WVUPMaxFile||!(result==Z_OK||result==Z_STREAM_END)||(!chunk&&!stream.avail_in&&result!=Z_STREAM_END)){ok=NO;break;}
            crc=crc32(crc,buffer,(uInt)chunk);if(capture)[capture appendBytes:buffer length:chunk];
            if(output>=0&&!WVUPWriteAll(output,buffer,chunk)){ok=NO;break;}
        }while(result!=Z_STREAM_END);
        if(stream.total_in!=compressed||stream.total_out!=size)ok=NO;inflateEnd(&stream);
        if(!ok)return WVUPCheck(NO,error,@"An update entry is truncated, oversized or could not be decompressed");
    }
    return WVUPCheck(written==size&&crc==[entry[@"crc"] unsignedIntValue],error,@"An update entry failed its size or CRC check");
}
static NSString *WVUPResolveLink(NSString *name,NSDictionary *links,NSError **error) {
    NSMutableArray *pending=[[name componentsSeparatedByString:@"/"] mutableCopy],*parts=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    while(pending.count){NSString *part=pending.firstObject;[pending removeObjectAtIndex:0];if(!part.length||[part isEqual:@"."])continue;
        if([part isEqual:@".."]) {if(parts.count<=1)return WVUPError(error,@"An update symlink escapes the app");[parts removeLastObject];continue;}
        [parts addObject:part];NSString *current=[parts componentsJoinedByString:@"/"];NSString *target=links[current];
        if(target){if([seen containsObject:current]||seen.count>64)return WVUPError(error,@"An update symlink is cyclic");[seen addObject:current];[parts removeLastObject];NSIndexSet *indices=[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,[target componentsSeparatedByString:@"/"].count)];[pending insertObjects:[target componentsSeparatedByString:@"/"] atIndexes:indices];}
    }
    NSString *resolved=[parts componentsJoinedByString:@"/"];
    return [resolved isEqual:@"Wallpaper Veil.app"]||[resolved hasPrefix:@"Wallpaper Veil.app/"]?resolved:WVUPError(error,@"An update symlink escapes its app");
}
// Preflight and full CRC/output validation complete before any extraction.
static NSDictionary *WVInspectUpdateZIP(NSURL *url,NSError **error) {
    struct stat file;if(lstat(url.fileSystemRepresentation,&file)||!S_ISREG(file.st_mode)||file.st_size<22||file.st_size>WVUPMaxZIP)return WVUPError(error,@"The update ZIP is unsafe or exceeds 64 MiB");
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:error];if(!data||data.length!=(NSUInteger)file.st_size)return nil;
    const uint8_t *b=data.bytes;NSUInteger end=NSNotFound;
    for(NSUInteger back=0;back<=MIN(data.length-22,(NSUInteger)65535);back++){NSUInteger at=data.length-22-back;if(WVUP32(b+at)==0x06054b50&&WVUP16(b+at+20)==back){end=at;break;}}
    if(end==NSNotFound)return WVUPError(error,@"The update ZIP has no complete directory");
    uint16_t count=WVUP16(b+end+10);uint32_t cdSize=WVUP32(b+end+12),cd=WVUP32(b+end+16);
    if(WVUP16(b+end+4)||WVUP16(b+end+6)||WVUP16(b+end+8)!=count||!count||count>4096||!WVUPRange(cd,cdSize,end)||(uint64_t)cd+cdSize!=end)return WVUPError(error,@"Unsupported split, ZIP64 or oversized update directory");
    NSMutableArray *entries=[NSMutableArray array],*spans=[NSMutableArray array];NSMutableDictionary *names=[NSMutableDictionary dictionary],*aliases=[NSMutableDictionary dictionary],*links=[NSMutableDictionary dictionary];NSMutableSet *allPaths=[NSMutableSet set];uint64_t total=0,at=cd;
    for(NSUInteger i=0;i<count;i++){
        if(!WVUPRange(at,46,end)||WVUP32(b+at)!=0x02014b50)return WVUPError(error,@"Malformed update central directory");
        uint16_t flags=WVUP16(b+at+8),method=WVUP16(b+at+10),nameSize=WVUP16(b+at+28),extra=WVUP16(b+at+30),comment=WVUP16(b+at+32);
        uint32_t crc=WVUP32(b+at+16),compressed=WVUP32(b+at+20),size=WVUP32(b+at+24),local=WVUP32(b+at+42),mode=WVUP32(b+at+38)>>16;
        if(WVUP16(b+at+6)>20||WVUP16(b+at+34)||flags&~(8|0x800)||(method!=0&&method!=8)||!nameSize||nameSize>1024||extra>4096||comment>4096||size>WVUPMaxFile||!WVUPRange(at+46,(uint64_t)nameSize+extra+comment,end))return WVUPError(error,@"Unsupported or oversized update entry");
        if(!WVUPExtras(b+at+46+nameSize,extra,error))return nil;
        NSData *nameBytes=[data subdataWithRange:NSMakeRange((NSUInteger)at+46,nameSize)];NSString *raw=[[NSString alloc]initWithData:nameBytes encoding:NSUTF8StringEncoding];NSString *name=WVUPPath(raw,error);if(!name)return nil;
        if(names[name])return WVUPError(error,@"Duplicate update archive entry");
        uint32_t kind=mode&S_IFMT;BOOL directory=[raw hasSuffix:@"/"];
        if((mode&07000)||(kind&&kind!=S_IFREG&&kind!=S_IFDIR&&kind!=S_IFLNK)||(kind==S_IFDIR&&!directory)||(directory&&kind&&kind!=S_IFDIR))return WVUPError(error,@"An update entry has an unsafe file type or permissions");
        if(!kind)kind=directory?S_IFDIR:S_IFREG;
        NSArray *parts=[name componentsSeparatedByString:@"/"];NSMutableArray *prefix=[NSMutableArray array];
        for(NSString *part in parts){[prefix addObject:part];NSString *path=[prefix componentsJoinedByString:@"/"],*alias=WVUPAlias(path);if(aliases[alias]&&![aliases[alias] isEqual:path])return WVUPError(error,@"Ambiguous case or Unicode update path");aliases[alias]=path;[allPaths addObject:path];}
        total+=size;if(total>WVUPMaxOutput)return WVUPError(error,@"The update expands beyond 256 MiB");
        if(!WVUPRange(local,30,cd)||WVUP32(b+local)!=0x04034b50||WVUP16(b+local+4)>20||WVUP16(b+local+6)!=flags||WVUP16(b+local+8)!=method||WVUP16(b+local+26)!=nameSize)return WVUPError(error,@"Update local and central headers disagree");
        uint16_t localExtra=WVUP16(b+local+28);uint64_t offset=(uint64_t)local+30+nameSize+localExtra;
        if(localExtra>4096||!WVUPRange((uint64_t)local+30,(uint64_t)nameSize+localExtra,cd)||memcmp(b+local+30,nameBytes.bytes,nameSize)||!WVUPExtras(b+local+30+nameSize,localExtra,error)||!WVUPRange(offset,compressed,cd))return WVUPError(error,@"Update entry bounds or names disagree");
        uint32_t localCRC=WVUP32(b+local+14),localCompressed=WVUP32(b+local+18),localSize=WVUP32(b+local+22);uint64_t finish=offset+compressed;
        if(flags&8){if((localCRC&&localCRC!=crc)||(localCompressed&&localCompressed!=compressed)||(localSize&&localSize!=size))return WVUPError(error,@"Update descriptor header mismatch");
            if(!WVUPRange(finish,12,cd))return WVUPError(error,@"Truncated update data descriptor");if(WVUP32(b+finish)==0x08074b50)finish+=4;
            if(!WVUPRange(finish,12,cd)||WVUP32(b+finish)!=crc||WVUP32(b+finish+4)!=compressed||WVUP32(b+finish+8)!=size)return WVUPError(error,@"Update data descriptor mismatch");finish+=12;
        }else if(localCRC!=crc||localCompressed!=compressed||localSize!=size)return WVUPError(error,@"Update local entry sizes disagree");
        if((kind==S_IFDIR&&(size||compressed))||(kind==S_IFLNK&&size>4096))return WVUPError(error,@"Invalid update directory or symlink size");
        NSDictionary *entry=@{@"name":name,@"kind":@(kind),@"mode":@((kind==S_IFDIR||(mode&0111))?0755:0644),@"size":@(size),@"compressed":@(compressed),@"offset":@(offset),@"method":@(method),@"crc":@(crc)};
        NSMutableData *target=kind==S_IFLNK?[NSMutableData data]:nil;
        if(!WVUPEntryData(data,entry,-1,target,error))return nil;
        if(target){NSString *link=[[NSString alloc]initWithData:target encoding:NSUTF8StringEncoding];if(!link.length||[link hasPrefix:@"/"]||[link rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\:\0"]].location!=NSNotFound||[link rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return WVUPError(error,@"Unsafe update symlink target");links[name]=link;}
        names[name]=entry;[entries addObject:entry];[spans addObject:@[@(local),@(finish)]];at+=46+nameSize+extra+comment;
    }
    if(at!=end)return WVUPError(error,@"The update directory length disagrees with its records");
    [spans sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *c){return [a[0] compare:c[0]];}];uint64_t prior=0;
    for(NSArray *span in spans){if([span[0] unsignedLongLongValue]<prior)return WVUPError(error,@"Overlapping update ZIP entries");prior=[span[1] unsignedLongLongValue];}
    for(NSString *name in names){NSArray *parts=[name componentsSeparatedByString:@"/"];for(NSUInteger n=1;n<parts.count;n++){NSString *parent=[[parts subarrayWithRange:NSMakeRange(0,n)] componentsJoinedByString:@"/"];NSDictionary *e=names[parent];if(e&&[e[@"kind"] unsignedIntValue]!=S_IFDIR)return WVUPError(error,@"An update entry descends through a file or symlink");}}
    for(NSString *name in links){NSString *resolved=WVUPResolveLink(name,links,error);if(!resolved||![allPaths containsObject:resolved])return WVUPError(error,@"Dangling or unsafe update symlink");}
    if(!names[@"Wallpaper Veil.app/Contents/Info.plist"]||!names[@"Wallpaper Veil.app/Contents/Helpers/Wallpaper Veil Runtime.app/Contents/Info.plist"])return WVUPError(error,@"The ZIP is not a complete Wallpaper Veil application");
    return @{@"entries":entries,@"links":links,@"data":data,@"outputBytes":@(total),@"sha256":WVUPSHAData(data)};
}
static int WVUPParent(int root,NSArray<NSString *> *parts,NSError **error) {
    int fd=dup(root);if(fd<0)return -1;
    for(NSUInteger i=0;i+1<parts.count;i++){
        const char *part=parts[i].fileSystemRepresentation;
        if(mkdirat(fd,part,0700)&&errno!=EEXIST){close(fd);WVUPError(error,@"Could not create update directories");return -1;}
        int next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);fd=next;
        if(fd<0){WVUPError(error,@"An update directory changed during extraction");return -1;}
    }
    return fd;
}
static BOOL WVExtractInspectedUpdateZIP(NSDictionary *manifest,NSURL *directory,NSError **error) {
    if(!WVUPPrivateDirectory(directory,error))return NO;
    NSArray *existing=[NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:error];
    if(!existing||existing.count)return WVUPCheck(NO,error,@"Update extraction requires an empty private directory");
    int root=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)return WVUPCheck(NO,error,@"Could not open update staging");
    BOOL ok=YES;NSMutableSet *directories=[NSMutableSet set];
    for(NSDictionary *entry in manifest[@"entries"]){
        NSString *name=entry[@"name"];NSArray *parts=[name componentsSeparatedByString:@"/"];uint32_t kind=[entry[@"kind"] unsignedIntValue];
        for(NSUInteger i=1;i<parts.count;i++)[directories addObject:[[parts subarrayWithRange:NSMakeRange(0,i)] componentsJoinedByString:@"/"]];
        if(kind==S_IFLNK)continue;
        int parent=WVUPParent(root,parts,error);if(parent<0){ok=NO;break;}
        const char *base=[parts.lastObject fileSystemRepresentation];
        if(kind==S_IFDIR){[directories addObject:name];if(mkdirat(parent,base,0700)&&errno!=EEXIST)ok=NO;int fd=openat(parent,base,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)ok=NO;else close(fd);}
        else{int fd=openat(parent,base,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            if(fd<0)ok=NO;else{ok=WVUPEntryData(manifest[@"data"],entry,fd,nil,error)&&fchmod(fd,[entry[@"mode"] unsignedShortValue])==0&&fsync(fd)==0;close(fd);}}
        close(parent);if(!ok)break;
    }
    if(ok)for(NSString *name in manifest[@"links"]){NSArray *parts=[name componentsSeparatedByString:@"/"];int parent=WVUPParent(root,parts,error);if(parent<0){ok=NO;break;}
        ok=symlinkat([manifest[@"links"][name] fileSystemRepresentation],parent,[parts.lastObject fileSystemRepresentation])==0;close(parent);if(!ok)break;}
    if(ok)for(NSString *name in directories){NSURL *url=[directory URLByAppendingPathComponent:name];int fd=open(url.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||fchmod(fd,0755)){if(fd>=0)close(fd);ok=NO;break;}close(fd);}
    if(ok)ok=fsync(root)==0;close(root);
    return WVUPCheck(ok,error,@"The update could not be safely extracted");
}
static BOOL WVExtractUpdateZIP(NSURL *archive,NSURL *directory,NSError **error) {
    NSDictionary *manifest=WVInspectUpdateZIP(archive,error);return manifest&&WVExtractInspectedUpdateZIP(manifest,directory,error);
}
static id WVUPReadObject(NSURL *url,BOOL plist,NSError **error) {
    int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat s;
    if(fd<0)return WVUPError(error,@"Required application metadata is missing");
    if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_size<2||s.st_size>1024*1024){close(fd);return WVUPError(error,@"Application metadata is unsafe or oversized");}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];size_t done=0;while(done<data.length){ssize_t n=read(fd,(uint8_t *)data.mutableBytes+done,data.length-done);if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=n;}close(fd);
    if(done!=data.length)return WVUPError(error,@"Application metadata is incomplete");
    id value=plist?[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error]:[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [value isKindOfClass:NSDictionary.class]?value:WVUPError(error,@"Application metadata has an invalid shape");
}
#ifdef WV_UPDATE_PACKAGE_TESTING
static BOOL (^WVUPTestSignature)(NSURL *,NSError **);
static BOOL WVUPTestSkipArchitectures=NO;
#endif
static BOOL WVUPValidSignature(NSURL *app,NSError **error) {
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestSignature)return WVUPTestSignature(app,error);
#endif
    SecStaticCodeRef code=NULL;OSStatus status=SecStaticCodeCreateWithPath((__bridge CFURLRef)app,kSecCSDefaultFlags,&code);CFErrorRef detail=NULL;
    if(status==errSecSuccess)status=SecStaticCodeCheckValidityWithErrors(code,kSecCSStrictValidate|kSecCSCheckNestedCode|kSecCSCheckAllArchitectures,NULL,&detail);
    if(code)CFRelease(code);if(detail)CFRelease(detail);
    return WVUPCheck(status==errSecSuccess,error,@"The application's complete code signature is not valid");
}
static NSString *WVUPTeam(NSURL *app) {
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(WVUPTestSignature)return @"";
#endif
    SecStaticCodeRef code=NULL;CFDictionaryRef info=NULL;NSString *team=@"";
    if(SecStaticCodeCreateWithPath((__bridge CFURLRef)app,kSecCSDefaultFlags,&code)==errSecSuccess&&
       SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info)==errSecSuccess){
        id value=((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
        if([value isKindOfClass:NSString.class])team=[value copy];
    }
    if(info)CFRelease(info);if(code)CFRelease(code);return team;
}
static BOOL WVUPValidatePublisher(NSURL *app,NSString *team,NSError **error) {
    if(!team.length)return YES; // Current ad hoc releases trust the pinned GitHub asset digest.
    if(![[NSPredicate predicateWithFormat:@"SELF MATCHES %@",@"[A-Z0-9]{10}"] evaluateWithObject:team])return WVUPCheck(NO,error,@"The publisher signing identity is invalid");
    NSString *rule=[NSString stringWithFormat:@"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"%@\"",team];
    SecRequirementRef requirement=NULL;SecStaticCodeRef code=NULL;OSStatus status=SecRequirementCreateWithString((__bridge CFStringRef)rule,kSecCSDefaultFlags,&requirement);
    if(status==errSecSuccess)status=SecStaticCodeCreateWithPath((__bridge CFURLRef)app,kSecCSDefaultFlags,&code);
    if(status==errSecSuccess)status=SecStaticCodeCheckValidity(code,kSecCSStrictValidate|kSecCSCheckNestedCode|kSecCSCheckAllArchitectures,requirement);
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);
    return WVUPCheck(status==errSecSuccess,error,@"The publisher is not the expected Apple-anchored Developer ID signer");
}
static BOOL WVUPSignerContinuity(NSString *oldTeam,NSString *newTeam){return !oldTeam.length||[oldTeam isEqual:newTeam];}
static NSDictionary *WVUPBundleIdentity(NSURL *app,NSError **error) {
    struct stat s;if(lstat(app.fileSystemRepresentation,&s)||!S_ISDIR(s.st_mode))return WVUPError(error,@"Expected a real application directory");
    NSURL *runtime=[app URLByAppendingPathComponent:@"Contents/Helpers/Wallpaper Veil Runtime.app" isDirectory:YES];
    NSDictionary *outer=WVUPReadObject([app URLByAppendingPathComponent:@"Contents/Info.plist"],YES,error),*inner=WVUPReadObject([runtime URLByAppendingPathComponent:@"Contents/Info.plist"],YES,error);
    if(!outer||!inner)return nil;
    if(![outer[@"CFBundleIdentifier"] isEqual:@"com.ry00ki.wallpaperveil.launcher"]||![inner[@"CFBundleIdentifier"] isEqual:@"com.ry00ki.wallpaperveil"]||![outer[@"CFBundleExecutable"] isEqual:@"WallpaperVeil"]||![inner[@"CFBundleExecutable"] isEqual:@"WallpaperVeilRuntime"])return WVUPError(error,@"The update has the wrong application identity");
    NSDictionary *provenance=WVUPReadObject([app URLByAppendingPathComponent:@"Contents/Resources/wallpaper-veil-build.json"],NO,error),*nested=WVUPReadObject([runtime URLByAppendingPathComponent:@"Contents/Resources/wallpaper-veil-build.json"],NO,error);
    if(!provenance||![provenance isEqual:nested])return WVUPError(error,@"The signed application provenance does not match between bundles");
    NSDictionary *source=provenance[@"source"];
    if(![source isKindOfClass:NSDictionary.class]||![source[@"worktree_status"] isKindOfClass:NSArray.class])return WVUPError(error,@"The signed source provenance is invalid");
    NSDictionary *fields=@{@"CFBundleShortVersionString":@"version",@"CFBundleVersion":@"build",@"WVReleaseTag":@"release_tag",@"WVReleaseChannel":@"release_channel"};
    for(NSString *field in fields){id value=provenance[fields[field]];if(![value isKindOfClass:NSString.class]||![value length]||![outer[field] isEqual:value]||![inner[field] isEqual:value])return WVUPError(error,@"Application versions and signed provenance disagree");}
    NSArray *tag=WVParseReleaseTag(provenance[@"release_tag"]);NSString *version=[@[tag?tag[0]:@"",tag?tag[1]:@"",tag?tag[2]:@""] componentsJoinedByString:@"."];
    BOOL preview=tag&&[tag[3] length]>0;NSString *build=provenance[@"build"];
    NSCharacterSet *digits=[NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    if(!tag||![version isEqual:provenance[@"version"]]||![provenance[@"release_channel"] isEqual:preview?@"preview":@"stable"]||![build length]||[build hasPrefix:@"0"]||[build rangeOfCharacterFromSet:digits.invertedSet].location!=NSNotFound||!WVUPHex(provenance[@"source"][@"local_head"],40)||![provenance[@"source"][@"worktree_status"] isEqual:@[]]||![provenance[@"bundle_id"] isEqual:@"com.ry00ki.wallpaperveil.launcher"]||![provenance[@"runtime_bundle_id"] isEqual:@"com.ry00ki.wallpaperveil"])return WVUPError(error,@"The signed release identity is incomplete or unsupported");
    NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;NSString *current=[NSString stringWithFormat:@"%ld.%ld.%ld",(long)os.majorVersion,(long)os.minorVersion,(long)os.patchVersion];
    for(NSDictionary *info in @[outer,inner]){NSString *minimum=info[@"LSMinimumSystemVersion"];if(![minimum isKindOfClass:NSString.class]||![[NSPredicate predicateWithFormat:@"SELF MATCHES %@",@"[0-9]+(?:\\.[0-9]+){0,2}"] evaluateWithObject:minimum]||[minimum compare:current options:NSNumericSearch]==NSOrderedDescending)return WVUPError(error,@"This update requires a newer macOS version");}
    BOOL architectures=YES;
#ifdef WV_UPDATE_PACKAGE_TESTING
    if(!WVUPTestSkipArchitectures)
#endif
    for(NSURL *bundle in @[app,runtime]){NSArray *arches=[NSBundle bundleWithURL:bundle].executableArchitectures;architectures=architectures&&[arches containsObject:@(NSBundleExecutableArchitectureARM64)]&&[arches containsObject:@(NSBundleExecutableArchitectureX86_64)];}
    if(!architectures||!WVUPValidSignature(app,error))return WVUPError(error,@"The update signature or universal executable is invalid");
    NSString *team=WVUPTeam(app);
    if(![team isEqual:WVUPTeam(runtime)]||!WVUPValidatePublisher(app,team,error)||!WVUPValidatePublisher(runtime,team,error))return nil;
    NSDictionary *hashes=provenance[@"bundled_lua_hashes"];if(![hashes isKindOfClass:NSDictionary.class]||hashes.count<1||hashes.count>64)return WVUPError(error,@"The application code inventory is missing");
    NSMutableSet *declared=[NSMutableSet set];
    for(NSString *path in hashes){if(![path isKindOfClass:NSString.class]||!WVUPHex(hashes[path],64)||![path hasPrefix:@"WallpaperVeil/"]||![path hasSuffix:@".lua"]||[path componentsSeparatedByString:@"/"].count!=2||[path containsString:@".."]||[path containsString:@"\\"]||[path containsString:@":"])return WVUPError(error,@"The application code inventory has an unsafe path");
        NSURL *file=[runtime URLByAppendingPathComponent:[@"Contents/Resources/" stringByAppendingString:path]];
        if(![WVUPSHAFile(file,error) isEqual:hashes[path]])return WVUPError(error,@"Bundled application code does not match its signed provenance");[declared addObject:path.lastPathComponent];}
    NSArray *actual=[NSFileManager.defaultManager contentsOfDirectoryAtPath:[runtime URLByAppendingPathComponent:@"Contents/Resources/WallpaperVeil"].path error:error];NSMutableSet *lua=[NSMutableSet set];for(NSString *path in actual)if([path hasSuffix:@".lua"])[lua addObject:path];
    if(!actual||![declared isEqual:lua]||!WVUPHex(provenance[@"bundled_setup_sha256"],64)||![WVUPSHAFile([runtime URLByAppendingPathComponent:@"Contents/Resources/setup.lua"],error) isEqual:provenance[@"bundled_setup_sha256"]])return WVUPError(error,@"The bootstrap or application code inventory disagrees");
    NSString *launcher=WVUPSHAFile([app URLByAppendingPathComponent:@"Contents/MacOS/WallpaperVeil"],error),*engine=WVUPSHAFile([runtime URLByAppendingPathComponent:@"Contents/MacOS/WallpaperVeilRuntime"],error);
    if(!launcher||!engine)return nil;
    return @{@"tag":provenance[@"release_tag"],@"version":provenance[@"version"],@"channel":provenance[@"release_channel"],@"build":build,@"sourceCommit":provenance[@"source"][@"local_head"],@"launcherSHA256":launcher,@"runtimeSHA256":engine,@"provenance":provenance,@"teamID":team};
}
static NSDictionary *WVValidateUpdateBundle(NSURL *app,NSDictionary *release,NSError **error) {
    NSDictionary *identity=WVUPBundleIdentity(app,error);if(!identity)return nil;
    if(![release isKindOfClass:NSDictionary.class])return WVUPError(error,@"The selected release descriptor is invalid");
    NSDictionary *receipt=release[@"buildReceipt"];
    if(![receipt isKindOfClass:NSDictionary.class])return WVUPError(error,@"The release's verified build receipt is missing");
    for(NSString *key in @[@"tag",@"channel",@"version"])if(![identity[key] isEqual:release[key]])return WVUPError(error,@"The application does not belong to the selected release");
    for(NSString *key in identity[@"provenance"])if(![identity[@"provenance"][key] isEqual:receipt[key]])return WVUPError(error,@"The signed build provenance differs from its release receipt");
    if(![identity[@"build"] isEqual:receipt[@"build"]]||![identity[@"launcherSHA256"] isEqual:receipt[@"signed_launcher_sha256"]]||![identity[@"runtimeSHA256"] isEqual:receipt[@"signed_engine_sha256"]])return WVUPError(error,@"The signed executable hashes do not match the release receipt");
    return identity;
}
static BOOL WVUPValidateReplacement(NSDictionary *request,NSError **error) {
    NSURL *directory=[NSURL fileURLWithPath:request[@"replacementDirectory"] isDirectory:YES];
    if(!WVUPPrivateDirectory(directory,error))return NO;
    NSDictionary *marker=WVReadPrivateUpdateJSON([directory URLByAppendingPathComponent:@".wallpaper-veil-update.json"],error);
    return WVUPCheck([marker[@"nonce"] isEqual:request[@"nonce"]]&&[marker[@"jobDir"] isEqual:request[@"jobDir"]],error,@"The private update staging owner changed");
}
static BOOL WVDiscardPreparedUpdate(NSDictionary *request,NSError **error) {
    NSURL *job=[NSURL fileURLWithPath:request[@"jobDir"]?:@""];NSDictionary *stored=WVUpdateRequestForJob(job,error);if(!stored||![stored[@"nonce"] isEqual:request[@"nonce"]])return NO;
    NSDictionary *journal=WVReadPrivateUpdateJSON([job URLByAppendingPathComponent:@"journal.json"],error);
    if(![journal[@"phase"] isEqual:@"prepared"])return WVUPCheck(NO,error,@"An active installer owns this update; it cannot be discarded");
    NSURL *replacement=[NSURL fileURLWithPath:stored[@"replacementDirectory"] isDirectory:YES];if(!WVUPValidateReplacement(stored,error))return NO;
    if(![NSFileManager.defaultManager removeItemAtURL:replacement error:error])return NO;
    return [NSFileManager.defaultManager removeItemAtURL:job error:error];
}
static BOOL WVUPCanReplace(NSURL *target,NSError **error) {
    struct stat app,parent;NSURL *directory=target.URLByDeletingLastPathComponent;
    return WVUPCheck(lstat(target.fileSystemRepresentation,&app)==0&&S_ISDIR(app.st_mode)&&
        lstat(directory.fileSystemRepresentation,&parent)==0&&S_ISDIR(parent.st_mode)&&
        !(app.st_flags&(UF_IMMUTABLE|SF_IMMUTABLE))&&
        access(directory.fileSystemRepresentation,W_OK|X_OK)==0,error,
        @"The installation folder is not writable. Download the verified app and move it to your Applications folder manually");
}
static NSDictionary *WVPrepareUpdate(NSURL *zipURL,NSDictionary *release,NSURL *targetApp,NSURL *jobsRoot,pid_t oldPID,NSError **error) {
    if(![release isKindOfClass:NSDictionary.class]||![targetApp.lastPathComponent isEqual:@"Wallpaper Veil.app"]||oldPID<=1)return WVUPError(error,@"Choose the installed Wallpaper Veil application");
    if(!WVUPCanReplace(targetApp,error))return nil;
    NSDictionary *old=WVUPBundleIdentity(targetApp,error);if(!old)return nil;
    NSDictionary *manifest=WVInspectUpdateZIP(zipURL,error);if(!manifest)return nil;
    struct stat zip;if(lstat(zipURL.fileSystemRepresentation,&zip)||![manifest[@"sha256"] isEqual:release[@"sha256"]]||![[NSNumber numberWithLongLong:zip.st_size] isEqual:release[@"size"]])return WVUPError(error,@"The downloaded ZIP no longer matches its release digest and size");
    if(![NSFileManager.defaultManager createDirectoryAtURL:jobsRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]||!WVUPPrivateDirectory(jobsRoot,error))return nil;
    NSURL *job=[jobsRoot URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".noindex"] isDirectory:YES];
    if(![NSFileManager.defaultManager createDirectoryAtURL:job withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error])return nil;
    NSURL *replacement=[NSFileManager.defaultManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:targetApp create:YES error:error];
    if(!replacement){[NSFileManager.defaultManager removeItemAtURL:job error:nil];return nil;}
    chmod(replacement.fileSystemRepresentation,0700);
    BOOL ok=WVUPPrivateDirectory(replacement,error)&&WVExtractInspectedUpdateZIP(manifest,replacement,error);
    NSURL *candidate=[replacement URLByAppendingPathComponent:@"Wallpaper Veil.app" isDirectory:YES];NSDictionary *new=ok?WVValidateUpdateBundle(candidate,release,error):nil;
    if(new&&(WVCompareReleaseVersions(WVParseReleaseTag(new[@"tag"]),WVParseReleaseTag(old[@"tag"]))!=NSOrderedDescending||WVCompareNumericPart(new[@"build"],old[@"build"])!=NSOrderedDescending)){WVUPError(error,@"An update must be newer than the installed release");new=nil;}
    if(new&&!WVUPSignerContinuity(old[@"teamID"],new[@"teamID"])){WVUPError(error,@"The update changes or removes the installed publisher signing identity");new=nil;}
    struct stat original,staged;
    if(new&&(lstat(targetApp.fileSystemRepresentation,&original)||lstat(candidate.fileSystemRepresentation,&staged)||original.st_dev!=staged.st_dev)){WVUPError(error,@"The update cannot be staged on the installation volume");new=nil;}
    NSURL *helper=[job URLByAppendingPathComponent:@"WallpaperVeilUpdater"],*bundledHelper=[targetApp URLByAppendingPathComponent:@"Contents/Helpers/WallpaperVeilUpdater"];
    struct stat helperInfo;if(new&&(lstat(bundledHelper.fileSystemRepresentation,&helperInfo)||!S_ISREG(helperInfo.st_mode)||!(helperInfo.st_mode&0111))){WVUPError(error,@"The installed updater helper is missing or unsafe");new=nil;}
    if(new&&![NSFileManager.defaultManager copyItemAtURL:bundledHelper toURL:helper error:error])new=nil;
    if(new&&(!WVUPValidSignature(helper,error)||chmod(helper.fileSystemRepresentation,0700)))new=nil;
    NSString *helperHash=new?WVUPSHAFile(helper,error):nil;if(new&&!helperHash)new=nil;
    uint8_t random[32];if(new&&SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)!=errSecSuccess){WVUPError(error,@"Could not create an update transaction token");new=nil;}
    if(!new){[NSFileManager.defaultManager removeItemAtURL:replacement error:nil];[NSFileManager.defaultManager removeItemAtURL:job error:nil];return nil;}
    NSMutableString *nonce=[NSMutableString string];for(NSUInteger i=0;i<sizeof(random);i++)[nonce appendFormat:@"%02x",random[i]];
    NSDictionary *request=@{@"schema":@1,@"jobDir":job.URLByStandardizingPath.path,@"helperPath":helper.path,@"nonce":nonce,@"targetApp":targetApp.URLByStandardizingPath.path,@"candidateApp":candidate.path,@"replacementDirectory":replacement.path,@"release":release,@"tag":new[@"tag"],@"build":new[@"build"],@"newBuild":new[@"build"],@"sourceCommit":new[@"sourceCommit"],@"oldPID":@(oldPID),@"oldTag":old[@"tag"],@"oldBuild":old[@"build"],@"oldLauncherSHA256":old[@"launcherSHA256"],@"oldRuntimeSHA256":old[@"runtimeSHA256"],@"newLauncherSHA256":new[@"launcherSHA256"],@"newRuntimeSHA256":new[@"runtimeSHA256"],@"helperSHA256":helperHash,@"oldTeamID":old[@"teamID"],@"newTeamID":new[@"teamID"],@"createdAt":@([NSDate.date timeIntervalSince1970])};
    if(!WVWritePrivateUpdateJSON(@{@"nonce":nonce,@"jobDir":request[@"jobDir"]},[replacement URLByAppendingPathComponent:@".wallpaper-veil-update.json"],error)||!WVWritePrivateUpdateJSON(request,[job URLByAppendingPathComponent:@"request.json"],error)||!WVWritePrivateUpdateJSON(@{@"phase":@"prepared",@"nonce":nonce},[job URLByAppendingPathComponent:@"journal.json"],error)){
        [NSFileManager.defaultManager removeItemAtURL:replacement error:nil];[NSFileManager.defaultManager removeItemAtURL:job error:nil];return nil;}
    return request;
}
#endif
