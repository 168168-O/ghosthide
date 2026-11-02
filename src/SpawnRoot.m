#import "SpawnRoot.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <unistd.h>

extern char **environ;

// 私有 API：给子进程指定 persona，从而以 root 身份运行。
// TrollStore 自己就是这么拿 root 的（见其 Shared/TSUtil.m 的 spawnRoot），
// 前提是宿主 App 带 com.apple.private.persona-mgmt 权限（我们的 app-entitlements 里有）。
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static int spawnWithPersona(NSString *path, char **argv, BOOL usePersona, pid_t *outPid) {
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return EAGAIN;

    if (usePersona) {
        // 依次尝试 persona 99 / 0：不同系统上 root persona 的编号不同
        int rc = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        if (rc != 0) rc = posix_spawnattr_set_persona_np(&attr, 0, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        if (rc == 0) {
            posix_spawnattr_set_persona_uid_np(&attr, 0);
            posix_spawnattr_set_persona_gid_np(&attr, 0);
        }
    }

    sigset_t allSignals, defaultSignals;
    sigfillset(&allSignals);
    sigemptyset(&defaultSignals);
    posix_spawnattr_setsigmask(&attr, &allSignals);
    posix_spawnattr_setsigdefault(&attr, &defaultSignals);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [path fileSystemRepresentation], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc == 0 && outPid) *outPid = pid;
    return rc;
}

// 运行 helper，返回进程退出码；启动失败返回 errno。
// 先用 persona 提权跑（helper 里 geteuid()==0），失败再退回普通方式。
int spawnRoot(NSString *path, NSArray *args) {
    if (path.length == 0) return EINVAL;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return ENOENT;

    NSMutableArray *argvM = [NSMutableArray arrayWithObject:path];
    for (id a in args) {
        if ([a isKindOfClass:[NSString class]]) [argvM addObject:a];
    }

    NSUInteger n = argvM.count;
    char **argv = (char **)calloc(n + 1, sizeof(char *));
    if (!argv) return ENOMEM;

    for (NSUInteger i = 0; i < n; i++) {
        const char *c = [argvM[i] UTF8String];
        argv[i] = c ? strdup(c) : NULL;
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) free(argv[j]);
            free(argv);
            return ENOMEM;
        }
    }
    argv[n] = NULL;

    pid_t pid = 0;
    int rc = spawnWithPersona(path, argv, YES, &pid);
    if (rc != 0) {
        rc = spawnWithPersona(path, argv, NO, &pid);   // 退回普通 spawn
    }

    for (NSUInteger i = 0; i < n; i++) free(argv[i]);
    free(argv);

    if (rc != 0) return rc;

    int status = 0;
    pid_t w;
    do {
        w = waitpid(pid, &status, 0);
    } while (w == -1 && errno == EINTR);

    if (w == -1) return errno;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 126 + WTERMSIG(status);   // 被信号杀掉：126+ 表示异常
    return 0;
}
