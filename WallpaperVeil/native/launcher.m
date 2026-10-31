#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const WVBundleID = @"com.ry00ki.wallpaperveil";
static NSString * const WVLauncherBundleID = @"com.ry00ki.wallpaperveil.launcher";
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

static int writeLoginJSON(NSDictionary *value, int code) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "Wallpaper Veil: Cannot encode login-item status\n");
        return 74;
    }
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF) return 74;
    return code;
}

static int loginFailure(NSString *command, NSString *message, int code) {
    return writeLoginJSON(@{
        @"schema": @1, @"ok": @NO, @"command": command,
        @"targetBundleID": WVLauncherBundleID, @"service": @"mainApp",
        @"error": @{@"description": message}
    }, code);
}

static NSString *loginStatusName(SMAppServiceStatus status) {
    switch (status) {
        case SMAppServiceStatusNotRegistered: return @"notRegistered";
        case SMAppServiceStatusEnabled: return @"enabled";
        case SMAppServiceStatusRequiresApproval: return @"requiresApproval";
        case SMAppServiceStatusNotFound: return @"notFound";
    }
    return @"unknown";
}

static int handleLoginCommand(NSString *command, NSBundle *bundle) {
    if (@available(macOS 13.0, *)) {
        // mainAppService always refers to this process's MAIN bundle. This code
        // must execute in the outer launcher, never in the nested native app:
        // login must pass through the controlled NSWorkspace startup below.
        SMAppService *service = SMAppService.mainAppService;
        SMAppServiceStatus before = service.status;
        BOOL accepted = YES, changed = NO;
        NSError *error = nil;
        if ([command isEqualToString:@"--enable-login"]) {
            // Preserve a pending approval instead of repeatedly registering or
            // trying to override a decision made in System Settings.
            if (before != SMAppServiceStatusEnabled && before != SMAppServiceStatusRequiresApproval) {
                accepted = [service registerAndReturnError:&error];
                changed = accepted;
            }
        } else if ([command isEqualToString:@"--disable-login"]) {
            if (before != SMAppServiceStatusNotRegistered) {
                accepted = [service unregisterAndReturnError:&error];
                changed = accepted;
            }
        }
        SMAppServiceStatus status = service.status;
        BOOL registered = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval;
        NSMutableDictionary *result = [@{
            @"schema": @1, @"ok": @(accepted), @"command": command,
            @"supported": @YES, @"service": @"mainApp",
            @"targetBundleID": WVLauncherBundleID, @"targetBundlePath": bundle.bundlePath,
            @"status": @(status), @"statusString": loginStatusName(status),
            @"previousStatusString": loginStatusName(before),
            @"registration": registered ? @"registered" :
                (status == SMAppServiceStatusNotRegistered ? @"notRegistered" : @"unavailable"),
            @"registered": @(registered), @"enabled": [NSNumber numberWithBool:(status == SMAppServiceStatusEnabled)],
            @"approvalNeeded": [NSNumber numberWithBool:(status == SMAppServiceStatusRequiresApproval)],
            @"requiresApproval": [NSNumber numberWithBool:(status == SMAppServiceStatusRequiresApproval)], @"changed": @(changed)
        } mutableCopy];
        if (error) result[@"error"] = @{
            @"domain": error.domain, @"code": @(error.code), @"description": error.localizedDescription
        };
        return writeLoginJSON(result, accepted ? 0 : 1);
    }
    return writeLoginJSON(@{
        @"schema": @1, @"ok": @NO, @"command": command,
        @"supported": @NO, @"service": @"mainApp", @"targetBundleID": WVLauncherBundleID,
        @"statusString": @"unsupported", @"enabled": @NO, @"registered": @NO,
        @"approvalNeeded": @NO, @"requiresApproval": @NO, @"changed": @NO,
        @"error": @{@"description": @"Launch at login requires macOS 13 or later"}
    }, 69);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        umask(0077);
        BOOL verifyOnly = NO, selfTest = NO, uiTest = NO;
        NSString *loginCommand = nil;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--verify-only") == 0) verifyOnly = YES;
            else if (strcmp(argv[i], "--self-test") == 0) selfTest = YES;
            else if (strcmp(argv[i], "--ui-test") == 0) uiTest = YES;
            else if (strcmp(argv[i], "--login-status") == 0 || strcmp(argv[i], "--enable-login") == 0 ||
                     strcmp(argv[i], "--disable-login") == 0) {
                NSString *requested = [NSString stringWithUTF8String:argv[i]];
                if (loginCommand) return loginFailure(requested, @"Choose one login-item command", 64);
                loginCommand = requested;
            }
            else if (strncmp(argv[i], "-psn_", 5) != 0) fail(@"Supported options: --verify-only, --self-test, --ui-test, --login-status, --enable-login, --disable-login", 64);
        }
        if (loginCommand && (verifyOnly || selfTest || uiTest))
            return loginFailure(loginCommand, @"Login-item commands cannot be combined with verification modes", 64);
        if ((int)verifyOnly + (int)selfTest + (int)uiTest > 1) fail(@"Choose one verification mode", 64);
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqualToString:WVLauncherBundleID]) {
            if (loginCommand) return loginFailure(loginCommand, @"Run this command from the outer Wallpaper Veil.app launcher", 78);
            fail(@"Start the launcher inside the completed Wallpaper Veil.app bundle", 78);
        }
        // Status/control calls never launch the helper, migrate preferences,
        // create application-state files, or redirect their JSON stdout.
        if (loginCommand) return handleLoginCommand(loginCommand, bundle);
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
            if (verifyOnly || selfTest || uiTest) fail(@"Close Wallpaper Veil before running verification or self-test", 75);
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
            @"WV_SELF_TEST": selfTest ? @"1" : @"0",
            @"WV_UI_TEST": uiTest ? @"1" : @"0"
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
