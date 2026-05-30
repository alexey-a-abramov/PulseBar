//
//  Log.m
//
#import "Log.h"
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <os/log.h>

static int        gFd = -1;
static NSString  *gPath;
static os_log_t   gLog;            // mirrors to Console.app / `log stream`
static const char *gCrashPathC;    // C path for the async-signal-safe handler

NSString *PBLogDirectory(void)  { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/PulseBar"]; }
NSString *PBLogFile(void)       { return [PBLogDirectory() stringByAppendingPathComponent:@"pulsebar.log"]; }
NSString *PBCrashReportFile(void) { return [PBLogDirectory() stringByAppendingPathComponent:@"last-crash.txt"]; }

NSString *PBTakePendingCrashReport(void) {
    NSString *path = PBCrashReportFile();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return nil;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    // Archive (don't delete) so it's shown once but stays on disk for reference.
    NSString *seen = [PBLogDirectory() stringByAppendingPathComponent:@"last-crash.seen.txt"];
    [fm removeItemAtPath:seen error:nil];
    [fm moveItemAtPath:path toPath:seen error:nil];
    return contents.length ? contents : nil;
}

static void writeStr(const char *c) {
    if (!c) return; size_t len = strlen(c);
    if (gFd >= 0) { ssize_t r = write(gFd, c, len); (void)r; }
    ssize_t r2 = write(STDERR_FILENO, c, len); (void)r2;
}

void PBLogv(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; }
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];
    writeStr(line.UTF8String);
    os_log(gLog ?: OS_LOG_DEFAULT, "%{public}s", msg.UTF8String);   // watch live: log stream --predicate 'subsystem == "com.fun.pulsebar"'
}

// Crash-signal handler — async-signal-safe (open/write/backtrace_symbols_fd/close).
static void onCrashSignal(int sig) {
    char hdr[80]; int hl = snprintf(hdr, sizeof(hdr), "\n*** PulseBar CRASH — signal %d ***\n", sig);
    writeStr(hdr);
    void *cb[128]; int n = backtrace(cb, 128);
    if (gFd >= 0) backtrace_symbols_fd(cb, n, gFd);
    backtrace_symbols_fd(cb, n, STDERR_FILENO);
    // Persist a standalone crash report so the next launch can show it.
    if (gCrashPathC) {
        int cfd = open(gCrashPathC, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (cfd >= 0) {
            char rh[96]; int rl = snprintf(rh, sizeof(rh), "PulseBar crashed with signal %d.\n\nBacktrace:\n", sig);
            ssize_t w = write(cfd, rh, (size_t)rl); (void)w;
            backtrace_symbols_fd(cb, n, cfd);
            close(cfd);
        }
    }
    (void)hl;
    signal(sig, SIG_DFL); raise(sig);
}

static void onUncaughtException(NSException *e) {
    PBLog(@"*** UNCAUGHT EXCEPTION: %@: %@", e.name, e.reason);
    NSMutableString *r = [NSMutableString stringWithFormat:@"PulseBar quit due to an uncaught exception.\n\n%@: %@\n\nStack:\n",
                          e.name, e.reason ?: @"(no reason)"];
    for (NSString *frame in e.callStackSymbols) [r appendFormat:@"%@\n", frame];
    [r writeToFile:PBCrashReportFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    for (NSString *frame in e.callStackSymbols) writeStr([[frame stringByAppendingString:@"\n"] UTF8String]);
}

NSString *PBConversationsFile(void) { return [PBLogDirectory() stringByAppendingPathComponent:@"conversations.jsonl"]; }

void PBLogConversation(NSString *prompt, NSString *raw, NSString *action, NSString *reply) {
    NSDictionary *turn = @{ @"ts": @([[NSDate date] timeIntervalSince1970]),
                            @"prompt": prompt ?: @"", @"model": raw ?: @"",
                            @"action": action ?: @"", @"reply": reply ?: @"" };
    NSData *d = [NSJSONSerialization dataWithJSONObject:turn options:0 error:nil];
    if (!d) return;
    NSString *path = PBConversationsFile();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

void PBLogInit(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:PBLogDirectory() withIntermediateDirectories:YES attributes:nil error:nil];
    gPath = PBLogFile();

    // rotate if larger than 1 MB
    NSDictionary *attr = [fm attributesOfItemAtPath:gPath error:nil];
    if (attr && attr.fileSize > 1024 * 1024) {
        [fm removeItemAtPath:[gPath stringByAppendingString:@".1"] error:nil];
        [fm moveItemAtPath:gPath toPath:[gPath stringByAppendingString:@".1"] error:nil];
    }
    gFd = open(gPath.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    gLog = os_log_create("com.fun.pulsebar", "app");
    gCrashPathC = strdup(PBCrashReportFile().fileSystemRepresentation);

    NSSetUncaughtExceptionHandler(&onUncaughtException);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) signal(sigs[i], onCrashSignal);

    PBLog(@"================ PulseBar started (pid %d) ================", getpid());
}
