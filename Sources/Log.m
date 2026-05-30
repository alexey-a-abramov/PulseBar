//
//  Log.m
//
#import "Log.h"
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

static int       gFd = -1;
static NSString *gPath;

NSString *PBLogDirectory(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/PulseBar"]; }
NSString *PBLogFile(void)      { return [PBLogDirectory() stringByAppendingPathComponent:@"pulsebar.log"]; }

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
}

// Crash-signal handler — async-signal-safe (only write()/backtrace_symbols_fd).
static void onCrashSignal(int sig) {
    char hdr[64]; snprintf(hdr, sizeof(hdr), "\n*** PulseBar CRASH — signal %d ***\n", sig);
    writeStr(hdr);
    void *cb[128]; int n = backtrace(cb, 128);
    if (gFd >= 0) backtrace_symbols_fd(cb, n, gFd);
    backtrace_symbols_fd(cb, n, STDERR_FILENO);
    signal(sig, SIG_DFL); raise(sig);
}

static void onUncaughtException(NSException *e) {
    PBLog(@"*** UNCAUGHT EXCEPTION: %@: %@", e.name, e.reason);
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

    NSSetUncaughtExceptionHandler(&onUncaughtException);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) signal(sigs[i], onCrashSignal);

    PBLog(@"================ PulseBar started (pid %d) ================", getpid());
}
