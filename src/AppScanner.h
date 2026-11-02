#import <Foundation/Foundation.h>

@interface AppEntry : NSObject
@property (copy) NSString *name;
@property (copy) NSString *bid;
@property (copy) NSString *path;
@end

@interface AppScanner : NSObject
+ (NSArray *)scan;
@end
