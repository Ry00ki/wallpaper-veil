#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const WVBundleID = @"com.ry00ki.wallpaperveil";
static NSString * const WVMigrationKey = @"WallpaperVeilScopedMigrationVersion";

static void fail(NSString *message, int code) {
    fprintf(stderr, "Wallpaper Veil: %s\n", message.UTF8String);
    exit(code);
}

static void privateDirectory(NSString *path) {
    NSFileManager *manager = NSFileManager.defaultManager;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno != ENOENT) fail(@"Cannot inspect its state directory", 73);
        NSError *error = nil;
        if (![manager createDirectoryAtPath:path withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
            fail([@"Cannot create its state directory: " stringByAppendingString:error.localizedDescription], 73);
        }
        if (lstat(path.fileSystemRepresentation, &info) != 0) fail(@"Cannot inspect its new state directory", 73);
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        fail(@"Its state directory must be an owned directory, not a symbolic link", 73);
    }
    if (chmod(path.fileSystemRepresentation, 0700) != 0) fail(@"Cannot protect its state directory", 73);
}

static int privateFile(NSString *path, int flags) {
    int descriptor = open(path.fileSystemRepresentation, flags | O_CREAT | O_NOFOLLOW, 0600);
    if (descriptor < 0) fail(@"Cannot open its private runtime file", 73);
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()) {
        close(descriptor);
        fail(@"Its runtime file must be a regular file owned by this user", 73);
    }
    if (fchmod(descriptor, 0600) != 0) fail(@"Cannot protect its runtime file", 73);
    return descriptor;
}

static void migratePreferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *own = [[defaults persistentDomainForName:WVBundleID] mutableCopy];
    if (!own) own = [NSMutableDictionary dictionary];
    if ([own[WVMigrationKey] integerValue] >= 1) return;
    NSDictionary *source = [defaults persistentDomainForName:@"org.hammerspoon.Hammerspoon"];
    NSUInteger copied = 0;
    for (id key in source) {
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"wallpaperVeil."] && !own[key]) {
            own[key] = source[key];
            copied++;
        }
    }
    own[WVMigrationKey] = @1;
    own[@"WallpaperVeilScopedMigrationCopiedKeys"] = @(copied);
    own[@"WallpaperVeilScopedMigrationDate"] = NSDate.date;
    [defaults setPersistentDomain:own forName:WVBundleID];
    if (![defaults synchronize]) fail(@"Could not save its migrated preferences", 74);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        umask(0077);
        BOOL verifyOnly = NO, selfTest = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--verify-only") == 0) verifyOnly = YES;
            else if (strcmp(argv[i], "--self-test") == 0) selfTest = YES;
            else if (strncmp(argv[i], "-psn_", 5) != 0) fail(@"Supported options: --verify-only, --self-test", 64);
        }
        if (verifyOnly && selfTest) fail(@"Choose either --verify-only or --self-test", 64);
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqualToString:@"com.ry00ki.wallpaperveil.launcher"]) {
            fail(@"Start the launcher inside the completed Wallpaper Veil.app bundle", 78);
        }
        NSURL *helperURL = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/Wallpaper Veil Runtime.app" isDirectory:YES];
        NSBundle *helper = [NSBundle bundleWithURL:helperURL];
        if (![helper.bundleIdentifier isEqualToString:WVBundleID] ||
            ![helper.executableURL.lastPathComponent isEqualToString:@"WallpaperVeilRuntime"]) {
            fail(@"The bundled native runtime application is missing or has the wrong identity", 78);
        }
        NSString *code = [helper.resourcePath stringByAppendingPathComponent:@"WallpaperVeil"];
        if (![NSFileManager.defaultManager fileExistsAtPath:[code stringByAppendingPathComponent:@"init.lua"]]) {
            fail(@"The bundled application code is missing", 78);
        }
        NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Wallpaper Veil"];
        NSString *runtime = [support stringByAppendingPathComponent:@"runtime"];
        NSString *logs = [support stringByAppendingPathComponent:@"logs"];
        privateDirectory(support); privateDirectory(runtime); privateDirectory(logs);
        int log = privateFile([logs stringByAppendingPathComponent:@"launcher.log"], O_WRONLY | O_APPEND | O_CLOEXEC);
        if (dup2(log, STDOUT_FILENO) < 0 || dup2(log, STDERR_FILENO) < 0) fail(@"Cannot attach its launcher log", 74);
        if (log > STDERR_FILENO) close(log);
        fprintf(stderr, "\nWallpaper Veil NSWorkspace launcher: %s; verify=%d; self-test=%d\n",
                NSDate.date.description.UTF8String, verifyOnly, selfTest);
        int lock = privateFile([runtime stringByAppendingPathComponent:@"launch.lock"], O_RDWR | O_CLOEXEC);
        if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
            if (errno == EWOULDBLOCK) fail(@"Another Wallpaper Veil launch is in progress", 75);
            fail(@"Cannot acquire its launch lock", 73);
        }
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:WVBundleID]) {
            if (app.terminated) continue;
            if (verifyOnly || selfTest) fail(@"Close Wallpaper Veil before running verification or self-test", 75);
            if (![app.bundleURL.URLByStandardizingPath isEqual:helperURL.URLByStandardizingPath]) {
                fail(@"A different Wallpaper Veil runtime is already running; quit it before this version", 75);
            }
            int pidFile = privateFile([support stringByAppendingPathComponent:@"runtime.pid"], O_WRONLY | O_TRUNC | O_CLOEXEC);
            if (dprintf(pidFile, "%d\n", app.processIdentifier) < 0) fail(@"Cannot record the existing runtime", 74);
            close(pidFile);
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            close(lock);
            return 0;
        }
        if (!verifyOnly) migratePreferences();
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.createsNewApplicationInstance = NO;
        configuration.activates = NO;
        configuration.addsToRecentItems = NO;
        configuration.environment = @{
            @"WV_APP_CODE": code,
            @"WV_APPLICATION_SUPPORT": support,
            @"WV_VERIFY_ONLY": verifyOnly ? @"1" : @"0",
            @"WV_SELF_TEST": selfTest ? @"1" : @"0"
        };
        configuration.arguments = @[
            @"-MJConfigFile", [runtime stringByAppendingPathComponent:@"init.lua"],
            @"-HSUploadCrashData", @"NO", @"-MJShowMenuIconKey", @"NO",
            @"-MJShowDockIconKey", @"NO", @"-HSAppleScriptEnabledKey", @"NO",
            @"-HSOpenConsoleOnDockClickKey", @"NO", @"-MJHasRunAlreadyKey", @"YES",
            @"-SUEnableAutomaticChecks", @"NO", @"-SUAutomaticallyUpdate", @"NO",
            @"-SUSendProfileInfo", @"NO", @"-SUHasLaunchedBefore", @"YES"
        ];
        NSLock *completionLock = [[NSLock alloc] init];
        __block BOOL completed = NO;
        __block NSRunningApplication *launched = nil;
        __block NSError *launchError = nil;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:helperURL configuration:configuration
            completionHandler:^(NSRunningApplication *app, NSError *error) {
                [completionLock lock];
                launched = app; launchError = error; completed = YES;
                [completionLock unlock];
            }];
        // Service the main run loop: NSWorkspace may deliver completion on it.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
        BOOL finished = NO;
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [completionLock lock]; finished = completed; [completionLock unlock];
            if (!finished) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [completionLock lock];
        NSRunningApplication *runtimeApp = launched;
        NSError *error = launchError;
        finished = completed;
        [completionLock unlock];
        if (!finished) fail(@"The native runtime launch did not finish within 30 seconds", 75);
        if (error || !runtimeApp || runtimeApp.processIdentifier <= 0) {
            fail([NSString stringWithFormat:@"Cannot launch its native application: %@", error.localizedDescription ?: @"no runtime process returned"], 71);
        }
        if (![runtimeApp.bundleIdentifier isEqualToString:WVBundleID]) fail(@"The launched native app has the wrong identity", 78);
        int pidFile = privateFile([support stringByAppendingPathComponent:@"runtime.pid"], O_WRONLY | O_TRUNC | O_CLOEXEC);
        if (dprintf(pidFile, "%d\n", runtimeApp.processIdentifier) < 0 || fsync(pidFile) != 0) fail(@"Cannot record its runtime process", 74);
        close(pidFile);
        fprintf(stderr, "Launched native runtime PID %d at %s\n", runtimeApp.processIdentifier, helperURL.path.fileSystemRepresentation);
        fflush(NULL);
        close(lock);
        return 0;
    }
}
