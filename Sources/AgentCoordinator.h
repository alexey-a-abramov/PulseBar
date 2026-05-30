//
//  AgentCoordinator.h — owns the PBAgent + its chat window and turns the
//  model's chosen action into a real Mac action. Keeps the agent wiring and
//  push-to-talk state out of AppDelegate.
//
#import <AppKit/AppKit.h>

// Actions the coordinator can't do itself (they live in AppDelegate / the bar).
@protocol PBAgentHost <NSObject>
// System / launching
- (void)agentLaunch:(NSString *)path args:(NSArray<NSString *> *)args;
- (void)agentRunShortcut:(NSString *)name;   // "lock" | "displaysleep" | "darkmode" | "missioncontrol"
// PulseBar self-management (voice-drivable control of the bar itself)
- (void)agentSetMode:(NSString *)mode;       // "system"|"media"|"productivity"|"classic"|"shortcuts"
- (void)agentTogglePomodoro;
- (void)agentToggleCaffeine;
- (void)agentSetMirrorVisible:(BOOL)visible;
- (void)agentOpenSettings;
- (void)agentOpenLayoutEditor;
// Show/hide or resize a tile in the current mode. show/size may be nil (= leave as-is).
- (void)agentSetTile:(NSString *)token show:(NSNumber *)show size:(NSString *)size;
@end

@interface PBAgentCoordinator : NSObject
- (instancetype)initWithHost:(id<PBAgentHost>)host;
- (void)openAgent;              // open the chat window (no recording)
- (void)agentDown;              // orb pressed — start/stop voice capture
- (void)agentUp:(BOOL)wasHold;  // orb released (wasHold = walkie-talkie)
@end
