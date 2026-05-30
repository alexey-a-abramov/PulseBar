//
//  AgentWindowController.h — ChatGPT-style window for the PulseBar agent.
//
#import <AppKit/AppKit.h>
#import "Agent.h"

@interface AgentWindowController : NSWindowController
@property (nonatomic, readonly) BOOL listening;
- (instancetype)initWithAgent:(PBAgent *)agent;
- (void)present;
- (void)presentAndListen;   // open + start voice capture (push-to-talk)
- (void)stopAndSend;        // stop capture and send the transcript
@end
