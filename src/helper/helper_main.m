#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

// 返回码（与 App 侧 HideManager 一致）
//   0 成功 /   1 API 返回 NO /   2 参数错误 /  10 没有 root
//  11 拿不到工作区 / 12 方法不存在 / 13 内部异常

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

static id loadWorkspace(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return nil;
    if (![wsClass respondsToSelector:@selector(defaultWorkspace)]) return nil;
    return [wsClass performSelector:@selector(defaultWorkspace)];
}

int main(int argc, char **argv, char **envp) {
    @autoreleasepool {
        @try {
            if (argc < 2) return 2;
            NSString *cmd = argv[1] ? [NSString stringWithUTF8String:argv[1]] : nil;
            if (!cmd) return 2;

            if ([cmd isEqualToString:@"respring"]) {
                return respring_now();
            }

            if ([cmd isEqualToString:@"diag"]) {
                return (geteuid() == 0) ? 0 : 10;
            }

            if (argc < 3) return 2;
            NSString *appPath = argv[2] ? [NSString stringWithUTF8String:argv[2]] : nil;
            if (appPath.length == 0) return 2;
            if (![appPath hasSuffix:@".app"]) return 2;

            BOOL wantHide = [cmd isEqualToString:@"hide"];
            BOOL wantShow = [cmd isEqualToString:@"show"];
            if (!wantHide && !wantShow) return 2;

            if (geteuid() != 0) return 10;

            id ws = loadWorkspace();
            if (!ws) return 11;

            NSURL *appURL = [NSURL fileURLWithPath:appPath];
            if (!appURL) return 2;

            BOOL ok = NO;
            if (wantHide) {
                SEL sel = NSSelectorFromString(@"unregisterApplication:");
                if (![ws respondsToSelector:sel]) return 12;
                BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
                ok = fn(ws, sel, appURL);
            } else {
                SEL modern = NSSelectorFromString(@"registerApplication:withOptions:error:");
                if ([ws respondsToSelector:modern]) {
                    BOOL (*fn)(id, SEL, NSURL *, NSDictionary *, NSError **) =
                        (BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend;
                    NSError *err = nil;
                    ok = fn(ws, modern, appURL, @{@"LBLaunchOrigin": @"GhostHide"}, &err);
                } else {
                    SEL legacy = NSSelectorFromString(@"registerApplication:");
                    if (![ws respondsToSelector:legacy]) return 12;
                    BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
                    ok = fn(ws, legacy, appURL);
                }
            }
            return ok ? 0 : 1;
        } @catch (NSException *e) {
            return 13;
        } @catch (...) {
            return 13;
        }
    }
}
