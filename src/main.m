#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <execinfo.h>

// ============ 闪退记录器 ============
// 崩溃时把原因写进 /var/tmp/gh_crash.txt，下次启动弹窗显示，方便远程定位。
#define GH_CRASH_PATH "/var/tmp/gh_crash.txt"

static void gh_write_crash(const char *tag, const char *detail1, void *ctx) {
    int fd = open(GH_CRASH_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "类型: %s\n", tag);
    write(fd, buf, n);
    if (detail1) {
        n = snprintf(buf, sizeof(buf), "详情: %s\n", detail1);
        write(fd, buf, n);
    }
    if (ctx) {
        void *bt[16];
        int frames = backtrace(bt, 16);
        n = snprintf(buf, sizeof(buf), "调用栈地址: ");
        write(fd, buf, n);
        for (int i = 0; i < frames; i++) {
            n = snprintf(buf, sizeof(buf), "%p ", bt[i]);
            write(fd, buf, n);
        }
        n = snprintf(buf, sizeof(buf), "\n");
        write(fd, buf, n);
    }
    close(fd);
}

static void gh_exception_handler(NSException *exception) {
    gh_write_crash("OC异常(NSException)",
                   exception.reason.UTF8String, NULL);
}

static void gh_signal_handler(int sig) {
    const char *names[] = {"未知", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL(非法指令)",
                           "SIGTRAP", "SIGABRT(主动中止)", "SIGEMT", "SIGFPE(浮点错误)",
                           "SIGKILL", "SIGBUS(总线错误)", "SIGSEGV(野指针)",
                           "SIGSYS", "SIGPIPE"};
    const char *name = (sig > 0 && sig < 14) ? names[sig] : "其他信号";
    char buf[64];
    snprintf(buf, sizeof(buf), "信号编号 %d (%s)", sig, name);
    gh_write_crash("系统信号", buf, (void *)1);
    // 恢复默认处理，让系统正常终止
    signal(sig, SIG_DFL);
    raise(sig);
}

static void gh_install_crash_reporter(void) {
    NSSetUncaughtExceptionHandler(gh_exception_handler);
    int sigs[] = {SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP};
    for (int i = 0; i < 6; i++) signal(sigs[i], gh_signal_handler);
}
// ============ 闪退记录器结束 ============

int main(int argc, char** argv) {
    @autoreleasepool {
        gh_install_crash_reporter();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
