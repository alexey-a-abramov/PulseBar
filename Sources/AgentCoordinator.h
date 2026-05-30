//
//  AgentCoordinator.h — owns the PBAgent + its chat window and turns the
//  model's chosen action into a real Mac action. Keeps the agent wiring and
//  push-to-talk state out of AppDelegate.
//
#import <AppKit/AppKit.h>

// System actions the coordinator can't do itself (they live in AppDelegate).
@protocol PBAgentHost <NSObject>
- (void)agentLaunch:(NSString *)path args:(NSArray<NSString *> *)args;
- (void)agentRunShortcut:(NSString *)name;   // "lock" | "displaysleep" | "darkmode" | "missioncontrol"
@end

@interface PBAgentCoordinator : NSObject
- (instancetype)initWithHost:(id<PBAgentHost>)host;
- (void)openAgent;              // open the chat window (no recording)
- (void)agentDown;              // orb pressed — start/stop voice capture
- (void)agentUp:(BOOL)wasHold;  // orb released (wasHold = walkie-talkie)
@end
