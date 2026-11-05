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
// 关键：优先拿「已经存在的」容器，绝不新建——新建出来的是空壳，
// App 启动后读不到自己的数据，就会表现为「点了没反应 / 一开就退出」。
static NSString *containerPathForBid(NSString *bid) {
    Class cls = NSClassFromString(@"MCMAppDataContainer");
    if (cls) {
        SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
        if ([cls respondsToSelector:sel]) {
            id (*fn)(id, SEL, NSString *, BOOL, id, id *) = (id (*)(id, SEL, NSString *, BOOL, id, id *))objc_msgSend;
            @try {
                id container = fn(cls, sel, bid, NO, nil, nil);   // NO = 只查，不建
                if (container) {
                    SEL usel = NSSelectorFromString(@"url");
                    if ([container respondsToSelector:usel]) {
                        id (*ufn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                        NSURL *u = ufn(container, usel);
                        if (u.path.length) return u.path;
                    }
                }
            } @catch (...) {
            }
        }
    }

    // 兜底：直接扫数据容器元数据，按 MCMMetadataIdentifier 找
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    for (NSString *uuid in uuids) {
        NSString *meta = [[[root stringByAppendingPathComponent:uuid]
                           stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"] copy];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        id ident = [d isKindOfClass:[NSDictionary class]] ? d[@"MCMMetadataIdentifier"] : nil;
        if ([ident isKindOfClass:[NSString class]] && [ident isEqualToString:bid]) {
            return [root stringByAppendingPathComponent:uuid];
        }
    }
    return nil;
}

// ---------------- 数据备份 / 还原（“里面还有很多信息”的保险） ----------------

#define BACKUP_ROOT @"/var/mobile/Library/GhostHide/backups"
#define BACKUP_INFO_PATH "/var/tmp/ghosthide-backup.txt"

static NSString *bidForAppPath(NSString *appPath) {
    if (appPath.length == 0) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [appPath stringByAppendingPathComponent:@"Info.plist"]];
    id bid = [info isKindOfClass:[NSDictionary class]] ? info[@"CFBundleIdentifier"] : nil;
    return ([bid isKindOfClass:[NSString class]] && [bid length]) ? bid : nil;
}

static void writeBackupInfo(NSString *s) {
    FILE *f = fopen(BACKUP_INFO_PATH, "w");
    if (!f) return;
    fprintf(f, "%s\n", s.UTF8String ?: "");
    fclose(f);
}

// 把 App 的数据目录整份复制出来，存到 /var/mobile/Library/GhostHide/backups/<bid>/<时间戳>
static int doBackup(NSString *appPath) {
    NSString *bid = bidForAppPath(appPath);
    if (!bid.length) return 2;
    NSString *container = containerPathForBid(bid);
    if (!container.length) {
        writeBackupInfo(@"找不到这个 App 的数据目录，可能它已经被卸载了");
        return 2;
    }

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    NSString *dest = [[BACKUP_ROOT stringByAppendingPathComponent:bid]
                      stringByAppendingPathComponent:stamp];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&err]) {
        writeBackupInfo([NSString stringWithFormat:@"创建备份目录失败：%@",
                         err.localizedDescription ?: @"未知原因"]);
        return 13;
    }

    NSArray *items = [fm contentsOfDirectoryAtPath:container error:nil];
    NSUInteger okCount = 0, badCount = 0;
    for (NSString *it in items) {
        if (![it isKindOfClass:[NSString class]]) continue;
        if ([it isEqualToString:@"tmp"]) continue;   // 临时文件不备份
        NSString *src = [container stringByAppendingPathComponent:it];
        NSString *dst = [dest stringByAppendingPathComponent:it];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) okCount++;
        else badCount++;
    }

    writeBackupInfo([NSString stringWithFormat:@"%@|%lu|%lu", dest,
                     (unsigned long)okCount, (unsigned long)badCount]);
    diagLine([NSString stringWithFormat:@"backup %@ -> %@ (%lu ok / %lu fail)",
              bid, dest, (unsigned long)okCount, (unsigned long)badCount]);
    return okCount > 0 ? 0 : 1;
}

static NSString *latestBackupForBid(NSString *bid) {
    NSString *root = [BACKUP_ROOT stringByAppendingPathComponent:bid];
    NSArray *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    NSString *latest = nil;
    for (NSString *s in subs) {
        if (![s isKindOfClass:[NSString class]]) continue;
        if (!latest || [s compare:latest] == NSOrderedDescending) latest = s;
    }
    return latest.length ? [root stringByAppendingPathComponent:latest] : nil;
}

// 把最近一次备份复制回 App 的数据目录（同名项覆盖）
static int doRestoreData(NSString *appPath) {
    NSString *bid = bidForAppPath(appPath);
    if (!bid.length) return 2;
    NSString *src = latestBackupForBid(bid);
    if (!src.length) {
        writeBackupInfo(@"这个 App 还没有备份");
        return 2;
    }
    NSString *container = containerPathForBid(bid);
    if (!container.length) {
        writeBackupInfo(@"App 的数据目录不存在，先恢复 App 再还原数据");
        return 2;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:src error:nil];
    NSUInteger okCount = 0, badCount = 0;
    for (NSString *it in items) {
        if (![it isKindOfClass:[NSString class]]) continue;
        NSString *s = [src stringByAppendingPathComponent:it];
        NSString *d = [container stringByAppendingPathComponent:it];
        if ([fm fileExistsAtPath:d]) [fm removeItemAtPath:d error:nil];
        if ([fm copyItemAtPath:s toPath:d error:nil]) okCount++;
        else badCount++;
    }
    writeBackupInfo([NSString stringWithFormat:@"%@|%lu|%lu", src,
                     (unsigned long)okCount, (unsigned long)badCount]);
    diagLine([NSString stringWithFormat:@"restore %@ <- %@ (%lu ok / %lu fail)",
              bid, src, (unsigned long)okCount, (unsigned long)badCount]);
    return okCount > 0 ? 0 : 1;
}

// ---------------- 注册（配方来自 TrollStore RootHelper/uicache.m，逐字段对齐） ----------------

// 从 App 可执行文件的代码签名里读权限声明（照抄 TrollStore TSUtil.m getStaticCodeRef/dumpEntitlements）
static NSDictionary *dumpEntitlementsAtPath(NSString *binaryPath) {
    if (binaryPath.length == 0) return nil;
    static OSStatus (*pCreate)(CFURLRef, uint32_t, CFDictionaryRef, void **) = NULL;
    static OSStatus (*pCopyInfo)(void *, uint32_t, CFDictionaryRef *) = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        pCreate = (OSStatus (*)(CFURLRef, uint32_t, CFDictionaryRef, void **))
            dlsym(RTLD_DEFAULT, "SecStaticCodeCreateWithPathAndAttributes");
        pCopyInfo = (OSStatus (*)(void *, uint32_t, CFDictionaryRef *))
            dlsym(RTLD_DEFAULT, "SecCodeCopySigningInformation");
    }
    if (!pCreate || !pCopyInfo) return nil;
    NSURL *u = [NSURL fileURLWithPath:binaryPath];
    void *code = NULL;
    OSStatus r = pCreate((__bridge CFURLRef)u, 0 /*kSecCSDefaultFlags*/, NULL, &code);
    if (r != 0 || !code) return nil;
    CFDictionaryRef info = NULL;
    NSDictionary *out = nil;
    // 2 = kSecCSRequirementInformation；"entitlements-dict" = kSecCodeInfoEntitlementsDict
    if (pCopyInfo(code, 2, &info) == 0 && info) {
        CFDictionaryRef ent = CFDictionaryGetValue(info, CFSTR("entitlements-dict"));
        if (ent && CFGetTypeID(ent) == CFDictionaryGetTypeID()) {
            out = [(__bridge NSDictionary *)ent copy];
        }
        CFRelease(info);
    }
    CFRelease((CFTypeRef)code);
    return out;
}

// App Group 容器（照抄 uicache.m constructGroupsContainersForEntitlements）
static NSDictionary *groupContainersForEntitlements(NSDictionary *ent, BOOL system) {
    if (![ent isKindOfClass:[NSDictionary class]]) return nil;
    NSString *key = system ? @"com.apple.security.system-groups"
                           : @"com.apple.security.application-groups";
    NSString *clsName = system ? @"MCMSystemDataContainer" : @"MCMSharedDataContainer";
    NSArray *ids = ent[key];
    if (![ids isKindOfClass:[NSArray class]] || ids.count == 0) return nil;
    Class cls = NSClassFromString(clsName);
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(id, SEL, NSString *, BOOL, id, id *) = (id (*)(id, SEL, NSString *, BOOL, id, id *))objc_msgSend;
    id (*ufn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *gid in ids) {
        if (![gid isKindOfClass:[NSString class]] || gid.length == 0) continue;
        @try {
            id c = fn(cls, sel, gid, YES, nil, nil);
            NSURL *u = c ? ufn(c, NSSelectorFromString(@"url")) : nil;
            if (u.path.length) out[gid] = u.path;
        } @catch (...) {}
    }
    return out.count ? [out copy] : nil;
}

static NSString *teamIdentifierForEntitlements(NSDictionary *ent) {
    if (![ent isKindOfClass:[NSDictionary class]]) return nil;
    NSString *t = ent[@"com.apple.developer.team-identifier"];
    return ([t isKindOfClass:[NSString class]] && t.length) ? t : nil;
}

// PlugIns 注册信息（照抄 uicache.m 的 _LSBundlePlugins 段；Gmail 的 ShareExtension 靠它）
static NSDictionary *pluginsForApp(NSString *appPath, NSString *ownerBid) {
    NSString *pluginsPath = [appPath stringByAppendingPathComponent:@"PlugIns"];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:nil];
    if (items.count == 0) return nil;
    NSMutableDictionary *bundlePlugins = [NSMutableDictionary dictionary];
    for (NSString *name in items) {
        if (![name isKindOfClass:[NSString class]]) continue;
        NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:name];
        NSDictionary *pi = [NSDictionary dictionaryWithContentsOfFile:
                            [pluginPath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *pbid = pi[@"CFBundleIdentifier"];
        if (![pbid isKindOfClass:[NSString class]] || pbid.length == 0) continue;
        NSString *exe = pi[@"CFBundleExecutable"] ?: pbid;
        NSDictionary *pent = dumpEntitlementsAtPath([pluginPath stringByAppendingPathComponent:exe]);

        id pluginContainer = nil;
        Class cls = NSClassFromString(@"MCMPluginKitPluginDataContainer");
        SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
        if (cls && [cls respondsToSelector:sel]) {
            id (*fn)(id, SEL, NSString *, BOOL, id, id *) = (id (*)(id, SEL, NSString *, BOOL, id, id *))objc_msgSend;
            @try { pluginContainer = fn(cls, sel, pbid, YES, nil, nil); } @catch (...) {}
        }
        NSString *pcPath = nil;
        if (pluginContainer) {
            SEL usel = NSSelectorFromString(@"url");
            if ([pluginContainer respondsToSelector:usel]) {
                id (*ufn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                pcPath = ufn(pluginContainer, usel).path;
            }
        }

        NSMutableDictionary *pd = [NSMutableDictionary dictionary];
        if (pent) pd[@"Entitlements"] = pent;
        pd[@"ApplicationType"] = @"PluginKitPlugin";
        pd[@"CFBundleIdentifier"] = pbid;
        pd[@"CodeInfoIdentifier"] = pbid;
        pd[@"CompatibilityState"] = @0;
        pd[@"IsContainerized"] = @(pcPath != nil);
        if (pcPath) {
            pd[@"Container"] = pcPath;
            pd[@"EnvironmentVariables"] = @{
                @"CFFIXED_USER_HOME": pcPath,
                @"HOME": pcPath,
                @"TMPDIR": [pcPath stringByAppendingPathComponent:@"tmp"]
            };
        }
        pd[@"Path"] = pluginPath;
        pd[@"PluginOwnerBundleID"] = ownerBid;
        pd[@"SignerOrganization"] = @"Apple Inc.";
        pd[@"SignatureVersion"] = @132352;
        pd[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
        NSString *pteam = teamIdentifierForEntitlements(pent);
        if (pteam) pd[@"TeamIdentifier"] = pteam;

        NSDictionary *pagc = groupContainersForEntitlements(pent, NO);
        NSDictionary *psgc = groupContainersForEntitlements(pent, YES);
        NSMutableDictionary *pgc = [NSMutableDictionary new];
        if (pagc) [pgc addEntriesFromDictionary:pagc];
        if (psgc) [pgc addEntriesFromDictionary:psgc];
        if (pgc.count) {
            if (pagc.count) pd[@"HasAppGroupContainers"] = @YES;
            if (psgc.count) pd[@"HasSystemGroupContainers"] = @YES;
            pd[@"GroupContainers"] = [pgc copy];
        }
        bundlePlugins[pbid] = pd;
    }
    return bundlePlugins.count ? [bundlePlugins copy] : nil;
}

static NSDictionary *buildRegisterDictionary(NSString *path0, NSString *bid, NSDictionary *snap) {
    // 路径标准化（uicache.m 同款：解析符号链接 + 规整）
    NSString *path = path0.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (path.length == 0) path = path0;

    // 权限直接从二进制的代码签名里读（官方做法）
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exeName = infoPlist[@"CFBundleExecutable"] ?: bid;
    NSDictionary *ent = dumpEntitlementsAtPath([path stringByAppendingPathComponent:exeName]);

    // 数据容器：优先快照里的真实路径，其次查已存在的（绝不新建空壳）
    NSString *container = nil;
    id snapContainer = [snap isKindOfClass:[NSDictionary class]] ? snap[@"Container"] : nil;
    if ([snapContainer isKindOfClass:[NSString class]] && [snapContainer length] > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:snapContainer]) {
        container = snapContainer;
    } else {
        container = containerPathForBid(bid);
    }

    id (^pick)(NSString *) = ^id(NSString *key) {
        id v = [snap isKindOfClass:[NSDictionary class]] ? snap[key] : nil;
        return v ?: nil;
    };

    // ApplicationType：用户目录下的是 User（兼容 /var 与 /private/var 两种前缀）
    BOOL asUser = [path hasPrefix:@"/var/containers"] || [path hasPrefix:@"/private/var/containers"];
    BOOL isRemovableSystemApp = [[NSFileManager defaultManager] fileExistsAtPath:
        [@"/System/Library/AppSignatures" stringByAppendingPathComponent:bid]];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // ★ 关键：App Store App 的权限必须原样写回，否则启动校验失败（Gmail 打不开的主因）
    if (ent) d[@"Entitlements"] = ent;

    d[@"ApplicationType"] = (asUser && !isRemovableSystemApp) ? @"User" : @"System";
    d[@"CFBundleIdentifier"] = bid;
    d[@"CodeInfoIdentifier"] = ([pick(@"CodeInfoIdentifier") isKindOfClass:[NSString class]] &&
                                [(NSString *)pick(@"CodeInfoIdentifier") length] > 0)
                               ? pick(@"CodeInfoIdentifier") : bid;
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

    d[@"SignerOrganization"] = [pick(@"SignerOrganization") isKindOfClass:[NSString class]]
                                 ? pick(@"SignerOrganization") : @"Apple Inc.";
    d[@"SignatureVersion"] = [pick(@"SignatureVersion") isKindOfClass:[NSNumber class]]
                               ? pick(@"SignatureVersion") : @132352;
    d[@"SignerIdentity"] = [pick(@"SignerIdentity") isKindOfClass:[NSString class]]
                             ? pick(@"SignerIdentity") : @"Apple iPhone OS Application Signing";
    // ad-hoc 标记：快照里是什么就写什么；没有快照按官方默认 YES
    if ([pick(@"IsAdHocSigned") respondsToSelector:@selector(boolValue)]) {
        if ([pick(@"IsAdHocSigned") boolValue]) d[@"IsAdHocSigned"] = @YES;
    } else {
        d[@"IsAdHocSigned"] = @YES;
    }
    d[@"LSInstallType"] = @1;
    d[@"HasMIDBasedSINF"] = @0;
    d[@"MissingSINF"] = @0;
    d[@"FamilyID"] = @0;
    d[@"IsOnDemandInstallCapable"] = @0;

    // ★ TeamIdentifier（官方从权限里取）
    NSString *team = teamIdentifierForEntitlements(ent);
    if (team) d[@"TeamIdentifier"] = team;

    // ★ App Group 容器（Google 系等 App 共享数据靠它）
    NSDictionary *agc = groupContainersForEntitlements(ent, NO);
    NSDictionary *sgc = groupContainersForEntitlements(ent, YES);
    NSMutableDictionary *gc = [NSMutableDictionary new];
    if (agc) [gc addEntriesFromDictionary:agc];
    if (sgc) [gc addEntriesFromDictionary:sgc];
    if (gc.count) {
        if (agc.count) d[@"HasAppGroupContainers"] = @YES;
        if (sgc.count) d[@"HasSystemGroupContainers"] = @YES;
        d[@"GroupContainers"] = [gc copy];
    }

    // ★ 插件（Gmail 的 ShareExtension 等，注册不完整会导致 LS 记录残缺）
    NSDictionary *pl = pluginsForApp(path, bid);
    if (pl) d[@"_LSBundlePlugins"] = pl;

    diagLine([NSString stringWithFormat:@"dict: ent=%@ team=%@ groups=%lu plugins=%lu container=%@",
              ent ? @"YES" : @"no", team ?: @"-",
              (unsigned long)gc.count, (unsigned long)pl.count, container ?: @"-"]);

    return d;
}

// 注册：按可靠度从高到低尝试 4 条通道
static int doRegister(NSString *appPath, NSDictionary *snap) {
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
        NSDictionary *d = buildRegisterDictionary(appPath, bid, snap);
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

            // 第三个参数（可选）：隐藏前拍的注册信息快照 plist
            NSDictionary *snap = nil;
            if (argc >= 4 && argv[3]) {
                NSString *snapPath = [NSString stringWithUTF8String:argv[3]];
                if (snapPath.length) {
                    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:snapPath];
                    if ([d isKindOfClass:[NSDictionary class]]) snap = d;
                }
            }

            BOOL wantHide = [cmd isEqualToString:@"hide"];
            BOOL wantShow = [cmd isEqualToString:@"show"];
            BOOL wantRepair = [cmd isEqualToString:@"repair"];
            BOOL wantBackup = [cmd isEqualToString:@"backup"];
            BOOL wantRestoreData = [cmd isEqualToString:@"restoredata"];
            if (!wantHide && !wantShow && !wantRepair && !wantBackup && !wantRestoreData) return 2;

            if (geteuid() != 0) {
                writeDiagReport();   // 没 root 也要留下实测数据
                return 10;
            }

            if (wantBackup) return doBackup(appPath);
            if (wantRestoreData) return doRestoreData(appPath);

            if (wantRepair) {
                // 修复 = 先注销掉可能错误的旧记录，再按快照原样登记回去
                doUnregister(appPath);
                return doRegister(appPath, snap);
            }
            return wantShow ? doRegister(appPath, snap) : doUnregister(appPath);
        } @catch (NSException *e) {
            return 13;
        } @catch (...) {
            return 13;
        }
    }
}
