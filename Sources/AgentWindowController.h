//
//  AgentWindowController.h — ChatGPT-style window for the PulseBar agent.
//
#import <AppKit/AppKit.h>
#import "Agent.h"

@interface AgentWindowController : NSWindowController
@property (nonatomic, readonly) BOOL listening;
// Fired after a turn finishes (bubbles shown); actionRan == a real command executed.
@property (nonatomic, copy) void (^onTurnComplete)(BOOL actionRan);
// Fired when the user closes the window (so the coordinator can drop ephemeral state).
@property (nonatomic, copy) void (^onWindowClosed)(void);
- (instancetype)initWithAgent:(PBAgent *)agent;
- (void)present;
- (void)presentAndListen;   // open + start voice capture (push-to-talk)
- (void)stopAndSend;        // stop capture and send the transcript
- (void)clearTranscript;    // drop the conversation bubbles, keep the greeting (new session)
// Show a complete turn (used when a walkie-talkie result is too long for the HUD):
// present the window and append the you/action/reply bubbles without re-asking.
- (void)showTurnUser:(NSString *)user action:(NSString *)interp reply:(NSString *)reply;
@end
