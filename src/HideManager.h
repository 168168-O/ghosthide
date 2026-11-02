#import <Foundation/Foundation.h>
@class AppEntry;

@interface HideManager : NSObject
+ (instancetype)shared;
- (BOOL)isHidden:(AppEntry *)e;
- (BOOL)hide:(AppEntry *)e;
- (BOOL)show:(AppEntry *)e;
// 最近一次失败的人话原因（nil 表示上次成功）
- (NSString *)lastError;
// 自检：返回可读的诊断文本，用于排查“为什么没生效”
- (NSString *)diagnose;
@end
