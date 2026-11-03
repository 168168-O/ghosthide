#import "AppDelegate.h"
#import "CalculatorViewController.h"

@implementation AppDelegate

// 桌面上它就是一个计算器；输密码（默认 0520）再按 = 才进隐藏列表
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[CalculatorViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
