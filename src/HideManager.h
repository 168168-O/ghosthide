#import <Foundation/Foundation.h>
@class AppEntry;

@interface HideManager : NSObject
+ (instancetype)shared;
- (BOOL)isHidden:(AppEntry *)e;
- (BOOL)hide:(AppEntry *)e;
- (BOOL)show:(AppEntry *)e;
@end
