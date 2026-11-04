#import "HideManager.h"
#import "AppScanner.h"
#import "SpawnRoot.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <unistd.h>

// 返回码约定（与 helper 保持一致）
//  0  成功
//  1  API 返回 NO
//  2  参数错误
//  3  helper 无法启动（权限/路径）
// 10  没有 root 权限
// 11  LSApplicationWorkspace 拿不到
// 12  系统方法不存在
// 13  helper 内部异常

@interface HideManager ()
@property (copy) NSString *lastErrorMessage;
@end

@implementation HideManager {
    NSMutableDictionary *_map;      // bundleID -> 原始 .app 路径
    NSMutableDictionary *_registry; // bundleID -> 隐藏前拍下的真实注册信息（快照）
    NSLock *_lock;
}

+ (instancetype)shared {
    static HideManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [HideManager new];
    });
    return m;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [NSLock new];
        [self loadState];
    }
    return self;
}

#pragma mark - 状态

- (NSString *)recordPath {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!doc) return nil;
    return [doc stringByAppendingPathComponent:@"hidden.plist"];
}

- (NSString *)registryPath {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!doc) return nil;
    return [doc stringByAppendingPathComponent:@"gh_registry.plist"];
}

- (void)loadState {
    NSDictionary *d = nil;
    NSString *p = [self recordPath];
    if (p) d = [NSDictionary dictionaryWithContentsOfFile:p];
    _map = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary new];
    if (!_map) _map = [NSMutableDictionary new];

    NSDictionary *r = nil;
    NSString *rp = [self registryPath];
    if (rp) r = [NSDictionary dictionaryWithContentsOfFile:rp];
    _registry = [r isKindOfClass:[NSDictionary class]] ? [r mutableCopy] : [NSMutableDictionary new];
    if (!_registry) _registry = [NSMutableDictionary new];
}

- (void)save {
    NSString *p = [self recordPath];
    if (!p) return;
    [_lock lock];
    NSDictionary *snapshot = [_map copy];
    NSDictionary *reg = [_registry copy];
    [_lock unlock];
    [snapshot writeToFile:p atomically:YES];
    NSString *rp = [self registryPath];
    if (rp) [reg writeToFile:rp atomically:YES];
}

#pragma mark - 注册信息快照（关键：恢复时按原样还原，而不是猜）

// 隐藏前把这个 App 在系统里的真实登记信息拍下来，恢复时照抄回去
- (NSDictionary *)captureRegistryForBid:(NSString *)bid {
    if (bid.length == 0) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return nil;

    @try {
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (![proxyClass respondsToSelector:sel]) return nil;
        id (*fn)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
        id proxy = fn(proxyClass, sel, bid);
        if (!proxy) return nil;

        NSMutableDictionary *d = [NSMutableDictionary dictionary];

        // 数据容器（最重要：接错了 App 就读不到自己的数据）
        SEL dsel = NSSelectorFromString(@"dataContainerURL");
        if ([proxy respondsToSelector:dsel]) {
            id (*df)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            NSURL *u = df(proxy, dsel);
            if ([u isKindOfClass:[NSURL class]] && u.path.length) d[@"Container"] = u.path;
        }

        NSDictionary *strKeys = @{
            @"applicationType": @"ApplicationType",
            @"signerIdentity": @"SignerIdentity",
            @"signerOrganization": @"SignerOrganization",
            @"codeInfoIdentifier": @"CodeInfoIdentifier"
        };
        for (NSString *getter in strKeys) {
            SEL g = NSSelectorFromString(getter);
            if (![proxy respondsToSelector:g]) continue;
            id (*gf)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id v = gf(proxy, g);
            if ([v isKindOfClass:[NSString class]] && [v length]) d[strKeys[getter]] = v;
        }

        SEL vsel = NSSelectorFromString(@"signatureVersion");
        if ([proxy respondsToSelector:vsel]) {
            id (*vf)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id v = vf(proxy, vsel);
            if ([v isKindOfClass:[NSNumber class]]) d[@"SignatureVersion"] = v;
        }

        SEL hsel = NSSelectorFromString(@"isAdHocSigned");
        if ([proxy respondsToSelector:hsel]) {
            BOOL (*hf)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            d[@"IsAdHocSigned"] = @(hf(proxy, hsel));
        }

        return d.count ? d : nil;
    } @catch (...) {
        return nil;
    }
}

// 把某一项的快照写成临时文件，交给 helper 读
- (NSString *)writeSnapshotFileForBid:(NSString *)bid {
    NSDictionary *snap = nil;
    [_lock lock];
    snap = [_registry[bid] copy];
    [_lock unlock];
    if (![snap isKindOfClass:[NSDictionary class]] || snap.count == 0) return nil;

    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"gh_snap.plist"];
    if (![snap writeToFile:tmp atomically:YES]) return nil;
    return tmp;
}

- (NSString *)helperPath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"ghosthelper"];
}

#pragma mark - 进程内直调（不依赖 root，失败就返回 NO，不会崩）

static id GHWorkspace(void) {
    static id ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        if (!h) return;
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (!cls) return;
        if (![cls respondsToSelector:@selector(defaultWorkspace)]) return;
        ws = [cls performSelector:@selector(defaultWorkspace)];
    });
    return ws;
}

static BOOL GHApplyInProcess(NSString *path, BOOL wantHide) {
    if (path.length == 0) return NO;
    @try {
        id ws = GHWorkspace();
        if (!ws) return NO;
        NSURL *url = [NSURL fileURLWithPath:path];
        if (!url) return NO;
        SEL sel = NSSelectorFromString(wantHide ? @"unregisterApplication:"
                                               : @"registerApplication:");
        if (![ws respondsToSelector:sel]) return NO;
        BOOL (*fn)(id, SEL, NSURL *) = (BOOL (*)(id, SEL, NSURL *))objc_msgSend;
        return fn(ws, sel, url);
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 打开

// 请系统启动一个 App（只有在“系统登记着它”的时候才会成功）
static BOOL GHOpenBundle(NSString *bid) {
    if (bid.length == 0) return NO;
    @try {
        id ws = GHWorkspace();
        if (!ws) return NO;
        SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![ws respondsToSelector:sel]) return NO;
        BOOL (*fn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
        return fn(ws, sel, bid);
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 执行

- (int)runHelper:(NSString *)verb path:(NSString *)path extra:(NSString *)extra {
    NSString *helper = [self helperPath];
    if (!helper) return 3;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:helper]) return 3;
    if (extra.length) return spawnRoot(helper, @[ verb, path, extra ]);
    return spawnRoot(helper, @[ verb, path ]);
}

- (NSString *)reasonForCode:(int)r {
    switch (r) {
        case 0:  return nil;
        case 1:  return @"系统接口返回失败（该 App 可能受保护，或注册状态已被别的工具改过）。";
        case 2:  return @"参数不合法。";
        case 3:  return @"找不到内置的 ghosthelper，安装包可能不完整。";
        case 10: return @"helper 没拿到 root 权限，系统拒绝注销应用。";
        case 11: return @"系统里找不到 LSApplicationWorkspace。";
        case 12: return @"当前系统版本缺少所需方法。";
        case 13: return @"helper 内部异常（已捕获，未崩溃）。";
        case 14: return @"刷新桌面需要 root，当前没拿到。";
        default:
            if (r > 13) return [NSString stringWithFormat:@"启动 helper 失败（errno=%d）。", r];
            return [NSString stringWithFormat:@"未知错误（code=%d）。", r];
    }
}

- (BOOL)perform:(BOOL)wantHide entry:(AppEntry *)e {
    if (!e || e.path.length == 0 || e.bid.length == 0) {
        self.lastErrorMessage = @"这个 App 的信息不完整，已跳过。";
        return NO;
    }

    // 隐藏前先把这个 App 的真实注册信息拍快照（容器、签名身份等），
    // 恢复时照原样写回去，避免「恢复后 App 打不开」。
    if (wantHide) {
        NSDictionary *snap = [self captureRegistryForBid:e.bid];
        if (snap.count) {
            [_lock lock];
            _registry[e.bid] = snap;
            [_lock unlock];
            [self save];
        }
    }

    NSString *snapPath = wantHide ? nil : [self writeSnapshotFileForBid:e.bid];
    int r = [self runHelper:(wantHide ? @"hide" : @"show") path:e.path extra:snapPath];

    BOOL ok = (r == 0);
    if (!ok) {
        // root 路线失败时，再试一次进程内直调（platform-application 下有时可直接成功）
        ok = GHApplyInProcess(e.path, wantHide);
        self.lastErrorMessage = ok ? nil : [self reasonForCode:r];
    } else {
        self.lastErrorMessage = nil;
    }

    if (ok) {
        [_lock lock];
        if (wantHide) _map[e.bid] = e.path;
        else [_map removeObjectForKey:e.bid];
        [_lock unlock];
        [self save];
    }
    return ok;
}

// 修复：先注销掉可能写错的旧登记，再按快照原样登记回去
- (BOOL)repair:(AppEntry *)e {
    if (!e || e.path.length == 0 || e.bid.length == 0) {
        self.lastErrorMessage = @"这个 App 的信息不完整。";
        return NO;
    }
    if (!_registry[e.bid]) {
        NSDictionary *snap = [self captureRegistryForBid:e.bid];
        if (snap.count) {
            [_lock lock];
            _registry[e.bid] = snap;
            [_lock unlock];
            [self save];
        }
    }
    NSString *snapPath = [self writeSnapshotFileForBid:e.bid];
    int r = [self runHelper:@"repair" path:e.path extra:snapPath];
    BOOL ok = (r == 0);
    self.lastErrorMessage = ok ? nil : [self reasonForCode:r];
    if (ok) {
        [_lock lock];
        [_map removeObjectForKey:e.bid];
        [_lock unlock];
        [self save];
    }
    return ok;
}

- (BOOL)hide:(AppEntry *)e { return [self perform:YES entry:e]; }
- (BOOL)show:(AppEntry *)e { return [self perform:NO  entry:e]; }

// 打开：没藏的直接开；藏着的先临时登记回来、启动后再自动藏回去
- (BOOL)openEntry:(AppEntry *)e {
    if (!e || e.bid.length == 0) {
        self.lastErrorMessage = @"这个 App 的信息不完整，没法打开。";
        return NO;
    }

    if (![self isHidden:e]) {
        BOOL ok = GHOpenBundle(e.bid);
        self.lastErrorMessage = ok ? nil : @"系统拒绝启动它。可以先从桌面点一次，再回来隐藏。";
        return ok;
    }

    // 已隐藏：先恢复登记，否则系统里根本没有它，启动必然失败
    if (![self show:e]) return NO;          // show 里已经写好失败原因
    usleep(400 * 1000);                      // 等系统把登记写进去

    BOOL ok = GHOpenBundle(e.bid);
    if (!ok) self.lastErrorMessage = @"临时恢复成功，但系统没能启动它。";

    // 等 App 真的起来再藏回去：大 App（Gmail/微信这类）启动要好几秒，
    // 太早注销会把正在启动的进程打断，表现就是「点了打不开」。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // 只有这时它还在「登记着」，才说明是临时恢复状态，可以藏回去
        [self hide:e];
    });
    return ok;
}

- (NSUInteger)hiddenCount {
    [_lock lock];
    NSUInteger n = _map.count;
    [_lock unlock];
    return n;
}

- (NSUInteger)restoreAll {
    NSDictionary *snapshot;
    [_lock lock];
    snapshot = [_map copy];
    [_lock unlock];

    NSUInteger failed = 0;
    for (NSString *bid in snapshot) {
        AppEntry *e = [AppEntry new];
        e.bid = bid;
        e.path = snapshot[bid];
        if (![self show:e]) failed++;
    }
    return failed;
}

// 按实际列表恢复（列表由 AppScanner 扫出，隐藏态不依赖本地记录）
- (NSUInteger)restoreApps:(NSArray *)apps {
    NSUInteger failed = 0;
    for (AppEntry *e in apps) {
        if (![e isKindOfClass:[AppEntry class]]) continue;
        if (![self show:e]) failed++;
    }
    return failed;
}

- (BOOL)isHidden:(AppEntry *)e {
    if (!e.bid) return NO;
    [_lock lock];
    BOOL recorded = (_map[e.bid] != nil);
    [_lock unlock];
    if (recorded) return YES;

    // 记录可能丢（重装 App 等），用系统状态兜底：系统里查不到登记，就是被注销了
    if (e.registered) return NO;
    return e.path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:e.path];
}

#pragma mark - 诊断

- (NSString *)diagnose {
    NSMutableString *s = [NSMutableString string];

    NSString *helper = [self helperPath];
    BOOL exists = helper && [[NSFileManager defaultManager] isExecutableFileAtPath:helper];
    [s appendFormat:@"helper 存在：%@\n", exists ? @"是" : @"否"];

    // App 进程自身实测 persona 是否被接受（不用等 helper 就能判断提权为什么失败）
    [s appendFormat:@"提权探测：%@\n", personaProbe()];

    if (exists) {
        int r = spawnRoot(helper, @[ @"diag" ]);
        [s appendFormat:@"helper 提权：%@\n",
            (r == 0) ? @"成功（root 可用）" :
            (r == 10 ? @"失败：没拿到 root" :
            [NSString stringWithFormat:@"失败（code=%d）", r])];

        // helper 在 /var/tmp 留下的实测数据（实际生效的权限）
        NSString *diagFile = @"/var/tmp/ghosthide-diag.txt";
        NSString *content = [NSString stringWithContentsOfFile:diagFile
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (content.length) {
            [s appendFormat:@"—— helper 实测 ——\n%@\n", content];
        } else {
            [s appendString:@"（helper 没能写入诊断文件，多半也没有 no-sandbox 权限）\n"];
        }
    }

    [s appendFormat:@"进程内工作区：%@\n", GHWorkspace() ? @"可用" : @"不可用"];
    [s appendFormat:@"已记录隐藏：%lu 个", (unsigned long)_map.count];
    return s;
}

- (NSString *)lastError { return self.lastErrorMessage; }

@end
