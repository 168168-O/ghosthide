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

- (BOOL)isHidden:(AppEntry *)e {
    if (!e.bid) return NO;
    [_lock lock];
    BOOL v = (_map[e.bid] != nil);
    [_lock unlock];
    return v;
}

#pragma mark - 诊断

- (NSString *)diagnose {
    NSMutableString *s = [NSMutableString string];

    NSString *helper = [self helperPath];
    BOOL exists = helper && [[NSFileManager defaultManager] isExecutableFileAtPath:helper];
    [s appendFormat:@"helper 存在：%@\n", exists ? @"是" : @"否"];

    if (exists) {
        int r = spawnRoot(helper, @[ @"diag" ]);
        NSString *root = (r == 0) ? @"成功（root 可用）"
                                  : (r == 10 ? @"失败：没有 root 权限" : [NSString stringWithFormat:@"失败（code=%d）", r]);
        [s appendFormat:@"helper 提权：%@\n", root];
    }

    [s appendFormat:@"进程内工作区：%@\n", GHWorkspace() ? @"可用" : @"不可用"];
    [s appendFormat:@"已记录隐藏：%lu 个", (unsigned long)_map.count];
    return s;
}

- (NSString *)lastError { return self.lastErrorMessage; }

@end
