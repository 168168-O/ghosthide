#import "AppScanner.h"

@implementation AppEntry
@end

@implementation AppScanner

+ (NSArray *)scan {
    NSMutableArray *result = [NSMutableArray new];
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *myBid = [[NSBundle mainBundle] bundleIdentifier];

    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *plistPath = [dir stringByAppendingPathComponent:item];
            plistPath = [plistPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (!info) continue;
            NSString *bid = info[@"CFBundleIdentifier"];
            if (!bid || [bid isEqualToString:myBid]) continue;

            AppEntry *e = [AppEntry new];
            e.bid = bid;
            e.path = [dir stringByAppendingPathComponent:item];
            e.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: item;
            [result addObject:e];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(AppEntry *a, AppEntry *b) {
        return [a.name compare:b.name options:NSCaseInsensitiveSearch];
    }];
    return result;
}

@end
