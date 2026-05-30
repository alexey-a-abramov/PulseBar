//
//  Log.h — file logging + crash traces.
//  Writes to ~/Library/Logs/PulseBar/pulsebar.log (and stderr), installs an
//  uncaught-exception handler and crash-signal handlers that dump a backtrace.
//
#import <Foundation/Foundation.h>

void      PBLogInit(void);                                  // call once at startup
void      PBLogv(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#define   PBLog(...) PBLogv(__VA_ARGS__)
NSString *PBLogDirectory(void);
NSString *PBLogFile(void);

// Append one agent turn as a JSON line to conversations.jsonl (for later analysis).
void      PBLogConversation(NSString *prompt, NSString *modelRaw, NSString *action, NSString *reply);
NSString *PBConversationsFile(void);
