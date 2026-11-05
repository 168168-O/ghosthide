#import "RootViewController.h"
#import "AppScanner.h"
#import "HideManager.h"
#import "SpawnRoot.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <stdlib.h>

@interface RootViewController ()
@property (strong) NSMutableArray *apps;
@property (assign) BOOL busy;
- (void)reloadApps;
- (void)alert:(NSString *)msg;
- (void)respring;
- (void)doRepair:(AppEntry *)e;
- (void)doBackup:(AppEntry *)e;
- (void)doRestoreData:(AppEntry *)e;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"工具箱";
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
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"自检"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showDiagnose)],
        [[UIBarButtonItem alloc] initWithTitle:@"改密码"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(changePasswordTapped)]
    ];

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

#pragma mark - 改密码

- (void)changePasswordTapped {
    if (self.presentedViewController) return;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"修改进入密码"
                         message:@"新的密码至少 3 位。以后打开计算器，输入它再按 = 就能进来。\n\n请务必记牢，忘了就只能重装本工具。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"新密码";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.secureTextEntry = YES;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *v = a.textFields.firstObject.text ?: @"";
        if (v.length >= 3) {
            [[NSUserDefaults standardUserDefaults] setObject:v forKey:@"gh_secret_code"];
            [self alert:@"密码已保存。"];
        } else {
            [self alert:@"密码至少 3 位，这次没有改动。"];
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 全部恢复

- (void)restoreAllTapped {
    // 以系统实际状态为准（列表里"已隐藏"的），不依赖本地记录
    NSMutableArray *hidden = [NSMutableArray array];
    for (AppEntry *e in self.apps) {
        if ([[HideManager shared] isHidden:e]) [hidden addObject:e];
    }

    if (hidden.count == 0) {
        [self alert:@"列表里没有处于隐藏状态的 App，不用恢复。\n\n如果桌面少了图标，先下拉刷新一下列表再看。"];
        return;
    }
    if (self.presentedViewController) return;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"全部恢复"
                         message:[NSString stringWithFormat:
                            @"把 %lu 个隐藏的 App 全部恢复成正常显示？\n恢复后桌面图标会回来，数据一点不动。",
                            (unsigned long)hidden.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"全部恢复"
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        [weakSelf doRestoreHidden:hidden];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRestoreHidden:(NSArray *)hidden {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger failed = [[HideManager shared] restoreApps:hidden];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            [self reloadApps];
            if (failed == 0) {
                [self alert:[NSString stringWithFormat:
                    @"已恢复 %lu 个。\n如果桌面图标没立刻回来，锁屏再点亮一次。",
                    (unsigned long)hidden.count]];
            } else {
                [self alert:[NSString stringWithFormat:
                    @"%lu 个里有 %lu 个没恢复成功。\n再点一次「全部恢复」；还不行就点「自检」把内容发我。",
                    (unsigned long)hidden.count, (unsigned long)failed]];
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

    // 图标（头像）：直接显示从 App 包里读出的图，圆角像桌面图标
    c.imageView.image = e.icon;
    c.imageView.layer.cornerRadius = 12;
    c.imageView.layer.masksToBounds = YES;

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
                [self offerRepairForEntry:e reason:reason];
            }
        });
    });
}

#pragma mark - 修复

// 打不开时给出「修复」：按隐藏前拍的注册信息原样重新登记，数据一点不动
- (void)offerRepairForEntry:(AppEntry *)e reason:(NSString *)reason {
    if (self.presentedViewController) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"「%@」打不开", e.name ?: e.bid]
                         message:[NSString stringWithFormat:
                            @"%@\n\n如果是隐藏后又恢复的 App，点「修复」可以按它原来的登记信息重新写回去（数据、账号都不动）。",
                            reason ?: @"原因未知。"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"修复" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [self doRepair:e];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRepair:(AppEntry *)e {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [[HideManager shared] repair:e];
        NSString *reason = [[HideManager shared] lastError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            [self reloadApps];
            if (ok) {
                [self offerRespringAfterRepair:e];
            } else {
                [self alert:[NSString stringWithFormat:@"修复没成功。\n%@\n\n可以先点「备份数据」把信息保住，再去 App Store 重新安装（备份能还原回来）。",
                                                        reason ?: @"原因未知。"]];
            }
        });
    });
}

// 修复只是把登记写回去，SpringBoard 还拿着旧的图标缓存，
// 必须刷新一次桌面（respring）才会真正认这个 App——这是「修完还是点不开」的关键一步。
- (void)offerRespringAfterRepair:(AppEntry *)e {
    if (self.presentedViewController) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"登记信息已写回"
                         message:[NSString stringWithFormat:
                            @"「%@」的登记已经按原来的信息写回去了。\n\n最后一步：刷新桌面。刷新时这个工具箱会退出、桌面闪一下，都是正常的。刷新完再点「%@」试试。",
                            e.name ?: e.bid, e.name ?: e.bid]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"刷新桌面" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [self respring]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

// 左滑「修复」：任何一行都能手动按原登记信息重新写回（不需要等打不开才出现）
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row < 0 || (NSUInteger)ip.row >= self.apps.count) return nil;
    AppEntry *e = self.apps[(NSUInteger)ip.row];
    UIContextualAction *fix = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"修复"
                          handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        done(YES);
        [self doRepair:e];
    }];
    fix.backgroundColor = [UIColor systemOrangeColor];

    // 备份数据：怕丢信息时先点这个，整份复制到安全目录
    UIContextualAction *bak = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"备份数据"
                          handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        done(YES);
        [self doBackup:e];
    }];
    bak.backgroundColor = [UIColor systemBlueColor];

    // 还原数据：从最近一次备份复制回去
    UIContextualAction *rest = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"还原数据"
                          handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        done(YES);
        [self confirmRestoreData:e];
    }];
    rest.backgroundColor = [UIColor systemGrayColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[ rest, bak, fix ]];
}

#pragma mark - 备份 / 还原

- (void)doBackup:(AppEntry *)e {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [[HideManager shared] backupData:e];
        NSString *info = [[HideManager shared] lastBackupInfo];
        NSString *reason = [[HideManager shared] lastError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            if (ok) {
                [self alert:[NSString stringWithFormat:
                    @"「%@」的数据已经整份备份好了。\n\n%@\n\n备份存在手机里，即使这个 App 之后出问题、重装，也能从这里还原回来。",
                    e.name ?: e.bid, info.length ? info : @""]];
            } else {
                [self alert:[NSString stringWithFormat:@"备份没成功。\n%@",
                             reason ?: @"原因未知。"]];
            }
        });
    });
}

- (void)confirmRestoreData:(AppEntry *)e {
    if (self.presentedViewController) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"还原数据？"
                         message:[NSString stringWithFormat:
                            @"会用最近一次备份覆盖「%@」当前的数据。\n\n只在确实丢了东西的时候用；平时不要点。",
                            e.name ?: e.bid]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [self doRestoreData:e]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRestoreData:(AppEntry *)e {
    if (self.busy) return;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [[HideManager shared] restoreData:e];
        NSString *info = [[HideManager shared] lastBackupInfo];
        NSString *reason = [[HideManager shared] lastError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.busy = NO;
            [self alert:ok
                ? [NSString stringWithFormat:@"数据已从备份还原。\n\n%@", info.length ? info : @""]
                : [NSString stringWithFormat:@"还原没成功。\n%@", reason ?: @"原因未知。"]];
        });
    });
}

- (void)toggled:(UISwitch *)sw {
    if (sw.tag < 0 || (NSUInteger)sw.tag >= self.apps.count) {  // 越界保护
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
