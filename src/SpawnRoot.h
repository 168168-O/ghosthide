#import <Foundation/Foundation.h>

// Spawn a binary as root (requires com.apple.private.persona-mgmt entitlement,
// same mechanism TrollStore itself uses in TSUtil.m).
// Returns process exit status, or posix_spawn error code (non-zero).
int spawnRoot(NSString *path, NSArray *args);

// 自检：在本进程内实测 persona 提权是否被系统接受，
// 返回人话描述（含 set_persona_np 的返回码）。
NSString *personaProbe(void);
