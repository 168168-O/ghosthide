#import <Foundation/Foundation.h>
@class AppEntry;

@interface HideManager : NSObject
+ (instancetype)shared;
- (BOOL)isHidden:(AppEntry *)e;
- (BOOL)hide:(AppEntry *)e;
- (BOOL)show:(AppEntry *)e;
// 打开 App：已隐藏的会先临时登记、启动后自动重新藏回去
- (BOOL)openEntry:(AppEntry *)e;
// 当前记录了几个隐藏
- (NSUInteger)hiddenCount;
// 一键全部恢复（返回失败的个数）
- (NSUInteger)restoreAll;
// 最近一次失败的人话原因（nil 表示上次成功）
- (NSString *)lastError;
// 自检：返回可读的诊断文本，用于排查“为什么没生效”
- (NSString *)diagnose;
@end
