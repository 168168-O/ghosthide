#import "SpawnRoot.h"
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <string.h>

extern char **environ;

int spawnRoot(NSString *path, NSArray *args) {
    NSMutableArray *argvM = [NSMutableArray arrayWithObject:path];
    for (NSString *a in args) [argvM addObject:a];

    char **argv = (char **)malloc((argvM.count + 1) * sizeof(char *));
    for (NSUInteger i = 0; i < argvM.count; i++) {
        argv[i] = strdup([argvM[i] UTF8String]);
    }
    argv[argvM.count] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t allSignals;
    sigfillset(&allSignals);
    posix_spawnattr_setsigmask(&attr, &allSignals);
    sigset_t defaultSignals;
    sigemptyset(&defaultSignals);
    posix_spawnattr_setsigdefault(&attr, &defaultSignals);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);

    pid_t pid = 0;
    int status = posix_spawn(&pid, [path UTF8String], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    for (NSUInteger i = 0; i < argvM.count; i++) free(argv[i]);
    free(argv);

    if (status != 0) return status;

    int ret = 0;
    waitpid(pid, &ret, 0);
    return ret;
}
