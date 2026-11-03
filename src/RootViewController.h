#import <UIKit/UIKit.h>

@interface RootViewController : UITableViewController
// 已通过计算器密码验证时为 YES（跳过二次验证）
@property (assign) BOOL unlocked;
@end
