#import <Foundation/Foundation.h>

// Spawn a binary as root (requires com.apple.private.persona-mgmt entitlement,
// same mechanism TrollStore itself uses in TSUtil.m).
// Returns process exit status, or posix_spawn error code (non-zero).
int spawnRoot(NSString *path, NSArray *args);
