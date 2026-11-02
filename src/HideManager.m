#import "HideManager.h"
#import "AppScanner.h"
#import "SpawnRoot.h"

@implementation HideManager {
    NSMutableDictionary *_map; // bundleID -> original app path
}

+ (instancetype)shared {
    static HideManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [HideManager new];
        [m loadState];
    });
    return m;
}

- (NSString *)recordPath {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [doc stringByAppendingPathComponent:@"hidden.plist"];
}

- (void)loadState {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self recordPath]];
    _map = d ? [d mutableCopy] : [NSMutableDictionary new];
}

- (void)save {
    [_map writeToFile:[self recordPath] atomically:YES];
}

- (NSString *)helperPath {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"ghosthelper"];
}

- (BOOL)isHidden:(AppEntry *)e {
    return _map[e.bid] != nil;
}

- (BOOL)hide:(AppEntry *)e {
    int r = spawnRoot([self helperPath], @[@"hide", e.path]);
    if (r == 0) {
        _map[e.bid] = e.path;
        [self save];
    }
    return r == 0;
}

- (BOOL)show:(AppEntry *)e {
    NSString *path = _map[e.bid] ?: e.path;
    int r = spawnRoot([self helperPath], @[@"show", path]);
    if (r == 0) {
        [_map removeObjectForKey:e.bid];
        [self save];
    }
    return r == 0;
}

@end
