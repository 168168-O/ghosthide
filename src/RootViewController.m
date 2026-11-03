#import "RootViewController.h"
#import "AppScanner.h"
#import "HideManager.h"
#import "SpawnRoot.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <stdlib.h>

@interface RootViewController ()
@property (strong) NSMutableArray *apps;
@property (assign) BOOL unlocked;
@property (assign) BOOL busy;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"GhostHide";
    self.apps = [NSMutableArray new];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(respring)],
        [[UIBarButtonItem alloc] initWithTitle:@"全部恢复"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(restoreAllTapped)]
    ];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"自检"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showDiagnose)];

    // 下拉刷新列表（扫描放在子线程，避免卡界面）
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reloadApps) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self reloadApps];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.unlocked) return;
    [self askForAuth];
}

#pragma mark - 解锁

- (void)askForAuth {
    LAContext *ctx = [LAContext new];
    NSError *err = nil;

    // 设备没有设密码时，canEvaluatePolicy 会失败：此时不应该把用户关在门外
    if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&err]) {
        self.unlocked = YES;
        return;
    }

    __weak typeof(self) weakSelf = self;
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication
        localizedReason:@"解锁 GhostHide"
                  reply:^(BOOL ok, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (ok) {
                self.unlocked = YES;
            } else {
                [self leaveApp];
            }
        });
    }];
}

// 验证失败就退出，不用私有 API，避免 unrecognized selector 崩溃
- (void)leaveApp {
    if ([[UIApplication sharedApplication] respondsToSelector:NSSelectorFromString(@"suspend")]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [[UIApplication sharedApplication] performSelector:NSSelectorFromString(@"suspend")];
        #pragma clang diagnostic pop
    }
    exit(0);
}

#pragma mark - 数据

- (void)reloadApps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *list = [AppScanner scan];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.apps = [list isKindOfClass:[NSArray class]] ? [list mutableCopy] : [NSMutableArray new];
            [self.tableView reloadData];
            [self.refreshControl endRefreshing];
        });
    });
}

- (void)respring {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *helper = [[[NSBundle mainBundle] bundlePath]
                            stringByAppendingPathComponent:@"ghosthelper"];
        int r = [[NSFileManager defaultManager] isExecutableFileAtPath:helper]
                    ? spawnRoot(helper, @[ @"respring" ]) : 3;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            if (r == 0) return;   // 成功就不打扰
            NSString *msg;
            if (r == 14) {
                msg = @"隐藏和恢复都是即时生效的，一般不需要点刷新。\n如果图标还留在桌面上，锁屏再点亮一次即可。";
            } else {
                msg = [NSString stringWithFormat:
                    @"刷新桌面没成功（code=%d）。\n锁屏再点亮一次，效果一样。", r];
            }
            [self alert:msg];
        });
    });
}

- (void)showDiagnose {
    [self alert:[[HideManager shared] diagnose]];
}

#pragma mark - 全部恢复

- (void)restoreAllTapped {
    NSUInteger n = [[HideManager shared] hiddenCount];
    if (n == 0) {
        [self alert:@"现在没有隐藏任何 App，不用恢复。"];
        return;
    }
    if (self.presentedViewController) return;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"全部恢复"
                         message:[NSString stringWithFormat:
                            @"把 %lu 个 App 全部恢复成正常显示？\n恢复后桌面图标会立刻回来，数据一点不动。",
                            (unsigned long)n]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"全部恢复"
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        [weakSelf doRestoreAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRestoreAll {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger failed = [[HideManager shared] restoreAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            [self reloadApps];
            if (failed == 0) {
                [self alert:@"已全部恢复。\n如果桌面图标没立刻回来，锁屏再点亮一次。"];
            } else {
                [self alert:[NSString stringWithFormat:
                    @"有 %lu 个没能恢复。\n再点一次「全部恢复」；如果还是不行，把 App 名发我。",
                    (unsigned long)failed]];
            }
        });
    });
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    if (self.presentedViewController) return;  // 避免重复弹窗导致崩溃
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cellId = @"cell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:cellId];

    if (ip.row < 0 || (NSUInteger)ip.row >= self.apps.count) return c;  // 越界保护

    AppEntry *e = self.apps[(NSUInteger)ip.row];
    NSString *title = e.name.length ? e.name : @"（未知）";
    if (e.isInputMethod) title = [title stringByAppendingString:@"（输入法）"];
    c.textLabel.text = title;

    BOOL hidden = [[HideManager shared] isHidden:e];
    if (hidden) {
        c.detailTextLabel.text = @"已隐藏 · 点这一行直接打开";
        c.detailTextLabel.textColor = [UIColor systemBlueColor];
    } else {
        c.detailTextLabel.text = e.bid ?: @"";
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    UISwitch *sw = (UISwitch *)c.accessoryView;
    if (![sw isKindOfClass:[UISwitch class]]) {
        sw = [UISwitch new];
        [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    }
    sw.tag = ip.row;
    [sw setOn:[[HideManager shared] isHidden:e] animated:NO];
    return c;
}

// 点一下这一行 = 直接打开这个 App（藏着的也能开）
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row < 0 || (NSUInteger)ip.row >= self.apps.count) return;
    if (self.busy) return;

    AppEntry *e = self.apps[(NSUInteger)ip.row];
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        HideManager *mgr = [HideManager shared];
        BOOL ok = [mgr openEntry:e];
        NSString *reason = [mgr lastError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            if (!ok) {
                [self alert:[NSString stringWithFormat:@"没能打开「%@」。\n%@",
                                                        e.name ?: e.bid, reason ?: @"原因未知。"]];
            }
        });
    });
}

- (void)toggled:(UISwitch *)sw {    if (sw.tag < 0 || (NSUInteger)sw.tag >= self.apps.count) {  // 越界保护
        [sw setOn:!sw.on animated:YES];
        return;
    }
    AppEntry *e = self.apps[(NSUInteger)sw.tag];
    BOOL wantHide = sw.on;
    sw.enabled = NO;

    __weak typeof(self) weakSelf = self;
    __weak UISwitch *weakSw = sw;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        HideManager *mgr = [HideManager shared];
        BOOL ok = wantHide ? [mgr hide:e] : [mgr show:e];
        NSString *reason = [mgr lastError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            UISwitch *s = weakSw;
            if (!self || !s) return;
            s.enabled = YES;
            if (!ok) [s setOn:!wantHide animated:YES];

            NSString *msg;
            if (ok) {
                msg = wantHide
                    ? @"已隐藏：桌面、App 资源库、设置、搜索里都看不到了。\n\n你自己要用它：在这个列表里点一下它的名字就能打开，用完自动再藏回去。"
                    : @"已恢复显示。";
            } else {
                msg = [NSString stringWithFormat:@"这个 App 没能隐藏。\n%@", reason ?: @"原因未知。"];
            }
            [self.tableView reloadData];
            [self alert:msg];
        });
    });
}

@end
