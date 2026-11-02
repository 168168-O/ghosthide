#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

// iOS SDK 把 system() 标记为不可用，改用 posix_spawn 调 killall
static int respring_now(void) {
    pid_t pid = 0;
    char *argv[] = { "/usr/bin/killall", "-9", "SpringBoard", NULL };
    int rc = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
    if (rc != 0) return rc;
    int status = 0;
    waitpid(pid, &status, 0);
    return 0;
}

// GhostHide root helper
// Usage: ghosthelper hide <appPath> | show <appPath> | respring
// Runs as root (spawned via persona-mgmt), unsandboxed.

static BOOL callRegister(id workspace, NSURL *appURL) {
    SEL modern = NSSelectorFromString(@"registerApplication:withOptions:error:");
    if ([workspace respondsToSelector:modern]) {
        BOOL (*fn)(id, SEL, NSURL *, NSDictionary *, NSError **) =
            (BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend;
        NSError *err = nil;
        return fn(workspace, modern, appURL, @{@"LBLaunchOrigin": @"GhostHide"}, &err);
    }
    SEL legacy = NSSelectorFromString(@"registerApplication:");
    BOOL (*fn2)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
    return fn2(workspace, legacy, appURL);
}

static BOOL callUnregister(id workspace, NSURL *appURL) {
    SEL sel = NSSelectorFromString(@"unregisterApplication:");
    BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
    return fn(workspace, sel, appURL);
}

int main(int argc, char **argv, char **envp) {
    @autoreleasepool {
        if (argc < 2) return -1;
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"respring"]) {
            return respring_now();
        }

        if (argc < 3) return -2;
        NSString *appPath = [NSString stringWithUTF8String:argv[2]];
        if (![appPath hasSuffix:@".app"]) return -3;

        // Load LaunchServices so LSApplicationWorkspace is available
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) return -4;
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (!ws) return -5;

        NSURL *appURL = [NSURL fileURLWithPath:appPath];
        BOOL ok = NO;

        if ([cmd isEqualToString:@"hide"]) {
            ok = callUnregister(ws, appURL);
        } else if ([cmd isEqualToString:@"show"]) {
            ok = callRegister(ws, appURL);
        } else {
            return -6;
        }
        return ok ? 0 : 1;
    }
}
