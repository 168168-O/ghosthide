#import "AppDelegate.h"
#import "CalculatorViewController.h"
#import <fcntl.h>
#import <unistd.h>

// 读取上次崩溃记录（由 main.m 的闪退记录器写入）
static NSString *GHLastCrash(void) {
    int fd = open("/var/tmp/gh_crash.txt", O_RDONLY);
    if (fd < 0) return nil;
    char buf[2048];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return nil;
    buf[n] = 0;
    return [NSString stringWithUTF8String:buf];
}

@implementation AppDelegate

// 桌面上它就是一个计算器；输密码（默认 0520）再按 = 才进隐藏列表
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    @try {
        self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.window.rootViewController = [[CalculatorViewController alloc] init];
        [self.window makeKeyAndVisible];

        // 上次闪退过？把原因显示出来（只显示一次，看完即删）
        NSString *last = GHLastCrash();
        if (last.length > 0) {
            unlink("/var/tmp/gh_crash.txt");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"上次启动异常记录"
                                     message:last
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
                [self.window.rootViewController presentViewController:a animated:YES completion:nil];
            });
        }
        return YES;
    } @catch (NSException *e) {
        // 启动都失败时，至少给一个能看到的提示
        self.window = self.window ?: [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.window.rootViewController = self.window.rootViewController ?: [[UIViewController alloc] init];
        self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
        [self.window makeKeyAndVisible];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"启动出错"
                                 message:[NSString stringWithFormat:@"%@\n%@", e.name, e.reason]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self.window.rootViewController presentViewController:a animated:YES completion:nil];
        });
        return YES;
    }
}

@end
