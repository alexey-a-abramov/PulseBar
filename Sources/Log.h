//
//  Log.h — file logging + crash traces.
//  Writes to ~/Library/Logs/PulseBar/pulsebar.log (and stderr), installs an
//  uncaught-exception handler and crash-signal handlers that dump a backtrace.
//
#import <Foundation/Foundation.h>

void      PBLogInit(void);                                  // call once at startup
void      PBLogv(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);  // → file + stderr + os_log(subsystem com.fun.pulsebar)
#define   PBLog(...) PBLogv(__VA_ARGS__)
NSString *PBLogDirectory(void);
NSString *PBLogFile(void);

// Crash reporting. Signal/exception handlers write a stack trace to
// PBCrashReportFile(); on the next launch PBTakePendingCrashReport() returns it
// (once) so the app can show it, archiving the file rather than deleting it.
NSString *PBCrashReportFile(void);
NSString *PBTakePendingCrashReport(void);

// Append one agent turn as a JSON line to conversations.jsonl (for later analysis).
void      PBLogConversation(NSString *prompt, NSString *modelRaw, NSString *action, NSString *reply);
NSString *PBConversationsFile(void);
