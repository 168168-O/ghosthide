#import <UIKit/UIKit.h>

@interface AppEntry : NSObject
@property (copy) NSString *name;
@property (copy) NSString *bid;
@property (copy) NSString *path;
@property (strong) UIImage *icon;         // 从 App 包里直接读出来的图标
@property (assign) BOOL isInputMethod;   // 键盘类 App，隐藏后可能无法打字
@property (assign) BOOL registered;      // 系统当前是否登记了它（NO = 此刻处于隐藏态）
@end

@interface AppScanner : NSObject
+ (NSArray *)scan;
@end
