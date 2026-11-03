#import "AppScanner.h"
#import <dlfcn.h>
#import <objc/message.h>

@implementation AppEntry
@end

@implementation AppScanner

// iOS 上很多国产 App 的 Info.plist 里 CFBundleDisplayName 是空的，
// 真实名字放在 zh-Hans.lproj/InfoPlist.strings 里（截图里 com.tencent.xin 那行就是这情况）。
static NSString *nameFromStringsFile(NSString *appPath, NSString *key) {
    NSArray *langs = @[ @"zh-Hans", @"zh-Hant", @"zh_CN", @"Base", @"en" ];
    for (NSString *lang in langs) {
        NSString *p = [[appPath stringByAppendingPathComponent:
                        [lang stringByAppendingPathExtension:@"lproj"]]
                       stringByAppendingPathComponent:@"InfoPlist.strings"];
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            id v = [d isKindOfClass:[NSDictionary class]] ? d[key] : nil;
            if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
        } @catch (...) {
            // 坏文件跳过
        }
    }
    return nil;
}

static NSString *localizedNameFromProxy(NSString *bid) {
    static Class proxyClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    });
    if (!proxyClass) return nil;

    @try {
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (![proxyClass respondsToSelector:sel]) return nil;
        id (*fn)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
        id proxy = fn(proxyClass, sel, bid);
        if (!proxy) return nil;

        SEL nsel = NSSelectorFromString(@"localizedName");
        if ([proxy respondsToSelector:nsel]) {
            id (*nf)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id n = nf(proxy, nsel);
            if ([n isKindOfClass:[NSString class]] && [n length] > 0) return n;
        }
    } @catch (...) {
    }
    return nil;
}

// 系统是否还登记着这个 App：查不到 proxy 说明它被注销了（隐藏态）
static BOOL proxyExists(NSString *bid) {
    static Class proxyClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        proxyClass = NSClassFromString(@"LSApplicationProxy");
    });
    if (!proxyClass) return YES;   // 查不了就别误判成“已隐藏”
    @try {
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (![proxyClass respondsToSelector:sel]) return YES;
        id (*fn)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
        return fn(proxyClass, sel, bid) != nil;
    } @catch (...) {
        return YES;
    }
}

// 键盘类 App 一旦被隐藏，打字可能直接失效，列表里要标出来
static BOOL isKeyboardApp(NSString *appPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plugins = [appPath stringByAppendingPathComponent:@"PlugIns"];
    NSArray *items = [fm contentsOfDirectoryAtPath:plugins error:nil];
    if (![items isKindOfClass:[NSArray class]]) return NO;
    for (NSString *it in items) {
        if (![it hasSuffix:@".appex"]) continue;
        NSString *plist = [[plugins stringByAppendingPathComponent:it]
                           stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plist];
        NSDictionary *ext = [d isKindOfClass:[NSDictionary class]] ? d[@"NSExtension"] : nil;
        id pid = [ext isKindOfClass:[NSDictionary class]] ? ext[@"NSExtensionPointIdentifier"] : nil;
        if ([pid isKindOfClass:[NSString class]] && [pid isEqualToString:@"com.apple.keyboard-service"]) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray *)scan {
    NSMutableArray *result = [NSMutableArray new];
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];

    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    if (![uuids isKindOfClass:[NSArray class]]) return result;   // 读不到就当空列表，不崩

    for (NSString *uuid in uuids) {
        if (![uuid isKindOfClass:[NSString class]]) continue;
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (![items isKindOfClass:[NSArray class]]) continue;

        for (NSString *item in items) {
            if (![item isKindOfClass:[NSString class]]) continue;
            if (![item hasSuffix:@".app"]) continue;

            NSString *appPath = [dir stringByAppendingPathComponent:item];
            NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![info isKindOfClass:[NSDictionary class]]) continue;

            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            if (myBid && [bid isEqualToString:myBid]) continue;

            // 安全阀：系统自带 App 一律不列出。藏掉系统 App 会搞坏手机（电话、设置等）。
            if ([bid hasPrefix:@"com.apple."]) continue;
            if (![fm isExecutableFileAtPath:
                    [appPath stringByAppendingPathComponent:
                        info[@"CFBundleExecutable"] ?: @""]]) continue;

            AppEntry *e = [AppEntry new];
            e.bid = bid;
            e.path = appPath;

            // 名字：系统代理本地化名 → Info.plist → 语言包 strings → 文件夹名
            NSString *name = localizedNameFromProxy(bid);
            if (!name) {
                for (NSString *key in @[ @"CFBundleDisplayName", @"CFBundleName" ]) {
                    id v = info[key];
                    if ([v isKindOfClass:[NSString class]] && [v length] > 0) { name = v; break; }
                }
            }
            if (!name) name = nameFromStringsFile(appPath, @"CFBundleDisplayName");
            if (!name) name = nameFromStringsFile(appPath, @"CFBundleName");
            if (!name) name = [item stringByDeletingPathExtension];
            e.name = ([name isKindOfClass:[NSString class]] && [name length] > 0) ? name : item;

            e.isInputMethod = isKeyboardApp(appPath);
            e.registered = proxyExists(bid);
            [result addObject:e];
        }
    }

    [result sortUsingComparator:^NSComparisonResult(AppEntry *a, AppEntry *b) {
        return [(a.name ?: @"") compare:(b.name ?: @"") options:NSCaseInsensitiveSearch];
    }];
    return result;
}

@end
