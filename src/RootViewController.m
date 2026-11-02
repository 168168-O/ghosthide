#import "RootViewController.h"
#import "AppScanner.h"
#import "HideManager.h"
#import "SpawnRoot.h"
#import <LocalAuthentication/LocalAuthentication.h>

@interface RootViewController ()
@property (strong) NSMutableArray *apps;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GhostHide";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(respring)];
    self.apps = [[AppScanner scan] mutableCopy];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL unlocked = NO;
    if (unlocked) return;
    LAContext *ctx = [LAContext new];
    NSError *err = nil;
    if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&err]) {
        [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:@"解锁 GhostHide"
                          reply:^(BOOL ok, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) { unlocked = YES; }
                else { [self suspend]; }
            });
        }];
    }
}

- (void)suspend {
    [[UIApplication sharedApplication] performSelector:NSSelectorFromString(@"suspend")];
    exit(0);
}

- (void)respring {
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
                        stringByAppendingPathComponent:@"ghosthelper"];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        spawnRoot(helper, @[@"respring"]);
    });
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
    AppEntry *e = self.apps[ip.row];
    c.textLabel.text = e.name;
    c.detailTextLabel.text = e.bid;

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

- (void)toggled:(UISwitch *)sw {
    AppEntry *e = self.apps[sw.tag];
    BOOL wantHide = sw.on;
    sw.enabled = NO;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        HideManager *mgr = [HideManager shared];
        BOOL ok = wantHide ? [mgr hide:e] : [mgr show:e];
        dispatch_async(dispatch_get_main_queue(), ^{
            sw.enabled = YES;
            if (!ok) [sw setOn:!wantHide animated:YES];
            NSString *msg = ok
                ? (wantHide ? @"已隐藏：桌面 / App 资源库 / 设置 / 搜索 全部消失。\nApp 数据完好，随时可恢复。"
                            : @"已恢复显示。")
                : @"操作失败，请重试。";
            UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

@end
