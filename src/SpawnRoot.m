#import "SpawnRoot.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>

extern char **environ;

// 运行 helper，返回进程退出码；启动失败返回 errno。
// TrollStore 会在安装时把 Info.plist 里 TSRootBinaries 列出的二进制提升为 root，
// 所以这里只需要正常 spawn，helper 自己就是 root 身份。
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

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) {
        for (NSUInteger i = 0; i < n; i++) free(argv[i]);
        free(argv);
        return EAGAIN;
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
