#import "AppScanner.h"

@implementation AppEntry
@end

@implementation AppScanner

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
            id name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: item;
            e.name = [name isKindOfClass:[NSString class]] ? name : item;
            [result addObject:e];
        }
    }

    [result sortUsingComparator:^NSComparisonResult(AppEntry *a, AppEntry *b) {
        return [(a.name ?: @"") compare:(b.name ?: @"") options:NSCaseInsensitiveSearch];
    }];
    return result;
}

@end
