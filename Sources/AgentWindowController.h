//
//  AgentWindowController.h — ChatGPT-style window for the PulseBar agent.
//
#import <AppKit/AppKit.h>
#import "Agent.h"

@interface AgentWindowController : NSWindowController
- (instancetype)initWithAgent:(PBAgent *)agent;
- (void)present;
@end
