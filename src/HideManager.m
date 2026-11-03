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
    NSMutableDictionary *_map;   // bundleID -> 原始 .app 路径
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

- (void)loadState {
    NSDictionary *d = nil;
    NSString *p = [self recordPath];
    if (p) d = [NSDictionary dictionaryWithContentsOfFile:p];
    _map = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary new];
    if (!_map) _map = [NSMutableDictionary new];
}

- (void)save {
    NSString *p = [self recordPath];
    if (!p) return;
    [_lock lock];
    NSDictionary *snapshot = [_map copy];
    [_lock unlock];
    [snapshot writeToFile:p atomically:YES];
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

- (int)runHelper:(NSString *)verb path:(NSString *)path {
    NSString *helper = [self helperPath];
    if (!helper) return 3;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:helper]) return 3;
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

    int r = [self runHelper:(wantHide ? @"hide" : @"show") path:e.path];

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

    // 1.5 秒后重新藏回去：正在运行的进程不受“注销登记”影响
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self hide:e];
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
