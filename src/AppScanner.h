#import <Foundation/Foundation.h>

@interface AppEntry : NSObject
@property (copy) NSString *name;
@property (copy) NSString *bid;
@property (copy) NSString *path;
@property (assign) BOOL isInputMethod;   // 键盘类 App，隐藏后可能无法打字
@end

@interface AppScanner : NSObject
+ (NSArray *)scan;
@end
