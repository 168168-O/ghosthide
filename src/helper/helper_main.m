#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <spawn.h>
#import <signal.h>
#import <string.h>
#import <errno.h>
#import <unistd.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <Security/Security.h>

// iOS SDK 不允许直接链接 SecTask API，运行时 dlsym 解析
typedef struct CF_BRIDGED_TYPE(id) SecTask *SecTaskRef;
static SecTaskRef (*pSecTaskCreateWithSelfForCheck)(CFTypeRef);
static CFTypeRef (*pSecTaskCopyValueForEntitlement)(SecTaskRef, CFStringRef, CFErrorRef *);
static BOOL gSecTaskResolved = NO;

static void resolveSecTask(void) {
    if (gSecTaskResolved) return;
    gSecTaskResolved = YES;
    dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    pSecTaskCreateWithSelfForCheck =
        (SecTaskRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "SecTaskCreateWithSelfForCheck");
    pSecTaskCopyValueForEntitlement =
        (CFTypeRef (*)(SecTaskRef, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
}

extern char **environ;

// 返回码（与 App 侧 HideManager 一致）
//   0 成功 /   1 API 返回 NO /   2 参数错误 /  10 没有 root
//  11 拿不到工作区 / 12 方法不存在 / 13 内部异常 / 14 刷新桌面需要 root

// ---------------- 诊断 ----------------

// helper 把实测数据写到这个文件，App（有 no-sandbox）能读
#define DIAG_PATH "/var/tmp/ghosthide-diag.txt"

static void diagLine(NSString *s) {
    FILE *f = fopen(DIAG_PATH, "a");
    if (!f) return;
    fprintf(f, "%s\n", s.UTF8String ?: "");
    fclose(f);
}

// 读取自己实际生效的权限（安装后系统认的那个，而不是我们嵌入的）
static NSString *entValue(NSString *key) {
    resolveSecTask();
    if (!pSecTaskCreateWithSelfForCheck || !pSecTaskCopyValueForEntitlement) return @"SecTask不可用";
    SecTaskRef task = pSecTaskCreateWithSelfForCheck(NULL);
    if (!task) return @"SecTask创建失败";
    CFTypeRef v = pSecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
    CFRelease(task);
    if (!v) return @"无";
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        return ((__bridge NSNumber *)v).boolValue ? @"有" : @"无";
    }
    return [NSString stringWithFormat:@"%@", (__bridge id)v];
}

static void writeDiagReport(void) {
    FILE *f = fopen(DIAG_PATH, "w");   // 每次覆盖
    if (f) fclose(f);

    diagLine([NSString stringWithFormat:@"geteuid=%d（0=root）", geteuid()]);
    diagLine([NSString stringWithFormat:@"实际生效 platform-application=%@", entValue(@"platform-application")]);
    diagLine([NSString stringWithFormat:@"实际生效 persona-mgmt=%@", entValue(@"com.apple.private.persona-mgmt")]);
    diagLine([NSString stringWithFormat:@"实际生效 no-sandbox=%@", entValue(@"com.apple.private.security.no-sandbox")]);
    diagLine([NSString stringWithFormat:@"实际生效 canmaplsdatabase=%@", entValue(@"com.apple.private.coreservices.canmaplsdatabase")]);
    diagLine([NSString stringWithFormat:@"实际生效 container-manager=%@", entValue(@"com.apple.private.security.container-manager")]);
    diagLine([NSString stringWithFormat:@"实际生效 MobileContainerManager=%@", entValue(@"com.apple.private.MobileContainerManager.allowed")]);
}

// ---------------- respring ----------------

static pid_t find_springboard_pid(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return -1;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -1;
    }

    pid_t found = -1;
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return found;
}

static int respring_now(void) {
    if (geteuid() != 0) return 14;

    pid_t sb = find_springboard_pid();
    if (sb > 0 && kill(sb, SIGKILL) == 0) return 0;

    const char *candidates[] = { "/usr/bin/killall", "/bin/killall" };
    int lastErr = ENOENT;
    for (int i = 0; i < 2; i++) {
        if (access(candidates[i], X_OK) != 0) continue;
        pid_t pid = 0;
        char *argv[] = { (char *)candidates[i], "-9", "SpringBoard", NULL };
        int rc = posix_spawn(&pid, candidates[i], NULL, NULL, argv, environ);
        if (rc != 0) { lastErr = rc; continue; }
        int status = 0;
        waitpid(pid, &status, 0);
        return 0;
    }
    return lastErr;
}

// ---------------- 工作区与容器 ----------------

static id loadWorkspace(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) return nil;
    if (![wsClass respondsToSelector:@selector(defaultWorkspace)]) return nil;
    return [wsClass performSelector:@selector(defaultWorkspace)];
}

static void loadMCM(void) {
    dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
}

// App 数据容器路径（TrollStore 注册字典里需要）
static NSString *containerPathForBid(NSString *bid) {
    Class cls = NSClassFromString(@"MCMAppDataContainer");
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL, NSString *, BOOL, id, id *) = (id (*)(id, SEL, NSString *, BOOL, id, id *))objc_msgSend;
    id container = fn(cls, sel, bid, YES, nil, nil);
    if (!container) return nil;
    SEL usel = NSSelectorFromString(@"url");
    if (![container respondsToSelector:usel]) return nil;
    id (*ufn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSURL *u = ufn(container, usel);
    return u.path;
}

// ---------------- 注册（照抄 TrollStore RootHelper/uicache.m 的配方） ----------------

static NSDictionary *buildRegisterDictionary(NSString *path, NSString *bid) {
    NSString *container = containerPathForBid(bid);

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"ApplicationType"] = @"User";
    d[@"CFBundleIdentifier"] = bid;
    d[@"CodeInfoIdentifier"] = bid;
    d[@"CompatibilityState"] = @0;
    d[@"IsContainerized"] = @(container != nil);
    if (container) {
        d[@"Container"] = container;
        d[@"EnvironmentVariables"] = @{
            @"CFFIXED_USER_HOME": container,
            @"HOME": container,
            @"TMPDIR": [container stringByAppendingPathComponent:@"tmp"]
        };
    }
    d[@"IsDeletable"] = @YES;
    d[@"Path"] = path;
    d[@"SignerOrganization"] = @"Apple Inc.";
    d[@"SignatureVersion"] = @132352;
    d[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
    d[@"IsAdHocSigned"] = @YES;
    d[@"LSInstallType"] = @1;
    d[@"HasMIDBasedSINF"] = @0;
    d[@"MissingSINF"] = @0;
    d[@"FamilyID"] = @0;
    d[@"IsOnDemandInstallCapable"] = @0;
    return d;
}

// 注册：按可靠度从高到低尝试 4 条通道
static int doRegister(NSString *appPath) {
    loadMCM();
    id ws = loadWorkspace();
    if (!ws) return 11;

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length == 0) return 2;

    // 通道 1：TrollStore 官方同款 registerApplicationDictionary
    SEL dictSel = NSSelectorFromString(@"registerApplicationDictionary:");
    if ([ws respondsToSelector:dictSel]) {
        NSDictionary *d = buildRegisterDictionary(appPath, bid);
        BOOL (*fn)(id, SEL, NSDictionary *) = (BOOL (*)(id, SEL, NSDictionary *))objc_msgSend;
        @try {
            if (fn(ws, dictSel, d)) {
                diagLine([NSString stringWithFormat:@"register OK via dictionary (%@)", bid]);
                return 0;
            }
            diagLine([NSString stringWithFormat:@"register dictionary returned NO (%@)", bid]);
        } @catch (NSException *e) {
            diagLine([NSString stringWithFormat:@"register dictionary exception: %@", e.name]);
        }
    }

    // 通道 2/3：常规注册接口
    SEL modern = NSSelectorFromString(@"registerApplication:withOptions:error:");
    if ([ws respondsToSelector:modern]) {
        BOOL (*fn)(id, SEL, NSURL *, NSDictionary *, NSError **) =
            (BOOL (*)(id, SEL, NSURL *, NSDictionary *, NSError **))objc_msgSend;
        NSError *err = nil;
        @try {
            if (fn(ws, modern, [NSURL fileURLWithPath:appPath],
                   @{@"LBLaunchOrigin": @"GhostHide"}, &err)) {
                diagLine([NSString stringWithFormat:@"register OK via withOptions (%@)", bid]);
                return 0;
            }
            diagLine([NSString stringWithFormat:@"register withOptions NO: %@",
                      err.localizedDescription ?: @"（无错误信息）"]);
        } @catch (NSException *e) {}
    }
    SEL legacy = NSSelectorFromString(@"registerApplication:");
    if ([ws respondsToSelector:legacy]) {
        BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
        @try {
            if (fn(ws, legacy, [NSURL fileURLWithPath:appPath])) {
                diagLine([NSString stringWithFormat:@"register OK via legacy (%@)", bid]);
                return 0;
            }
        } @catch (NSException *e) {}
    }

    // 通道 4：LSRegisterURL（LaunchServices 底层 C 接口）
    Boolean (*lsRegisterURL)(CFURLRef, Boolean) =
        (Boolean (*)(CFURLRef, Boolean))dlsym(RTLD_DEFAULT, "LSRegisterURL");
    if (lsRegisterURL) {
        if (lsRegisterURL((__bridge CFURLRef)[NSURL fileURLWithPath:appPath], true)) {
            diagLine([NSString stringWithFormat:@"register OK via LSRegisterURL (%@)", bid]);
            return 0;
        }
        diagLine(@"LSRegisterURL returned false");
    } else {
        diagLine(@"LSRegisterURL symbol not found");
    }

    return 1;
}

// 注销
static int doUnregister(NSString *appPath) {
    id ws = loadWorkspace();
    if (!ws) return 11;

    SEL sel = NSSelectorFromString(@"unregisterApplication:");
    if (![ws respondsToSelector:sel]) return 12;
    BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
    @try {
        return fn(ws, sel, [NSURL fileURLWithPath:appPath]) ? 0 : 1;
    } @catch (NSException *e) {
        return 13;
    }
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
                writeDiagReport();
                return (geteuid() == 0) ? 0 : 10;
            }

            if (argc < 3) return 2;
            NSString *appPath = argv[2] ? [NSString stringWithUTF8String:argv[2]] : nil;
            if (appPath.length == 0) return 2;
            if (![appPath hasSuffix:@".app"]) return 2;

            BOOL wantHide = [cmd isEqualToString:@"hide"];
            BOOL wantShow = [cmd isEqualToString:@"show"];
            if (!wantHide && !wantShow) return 2;

            if (geteuid() != 0) {
                writeDiagReport();   // 没 root 也要留下实测数据
                return 10;
            }

            return wantShow ? doRegister(appPath) : doUnregister(appPath);
        } @catch (NSException *e) {
            return 13;
        } @catch (...) {
            return 13;
        }
    }
}
