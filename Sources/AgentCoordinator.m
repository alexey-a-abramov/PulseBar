//
//  AgentCoordinator.m
//
#import "AgentCoordinator.h"
#import "Agent.h"
#import "AgentWindowController.h"
#import "Controls.h"
#import "Log.h"

@interface PBAgentCoordinator () <PBAgentRunner>
@end

@implementation PBAgentCoordinator {
    __weak id<PBAgentHost> _host;
    PBAgent               *_agent;
    AgentWindowController *_window;
    BOOL                   _startedThisPress;
}

- (instancetype)initWithHost:(id<PBAgentHost>)host {
    if ((self = [super init])) _host = host;
    return self;
}

- (AgentWindowController *)ensureWindow {
    if (!_agent)  { _agent = [PBAgent new]; _agent.runner = self; }
    if (!_window) _window = [[AgentWindowController alloc] initWithAgent:_agent];
    return _window;
}

- (void)openAgent { [[self ensureWindow] present]; }

// Orb press → push-to-talk. Tap toggles; hold = walkie-talkie (release sends).
- (void)agentDown {
    AgentWindowController *w = [self ensureWindow];
    if (w.listening) { _startedThisPress = NO; [w stopAndSend]; }   // already listening → stop
    else             { _startedThisPress = YES; [w presentAndListen]; }  // idle → open + record
}
- (void)agentUp:(BOOL)wasHold {
    if (_startedThisPress && wasHold && _window.listening) [_window stopAndSend];  // walkie-talkie release
    _startedThisPress = NO;
}

// PBAgentRunner — turn the model's chosen action into a real Mac action.
- (NSString *)agentRunAction:(NSString *)action args:(NSDictionary *)args {
    PBLog(@"agent action: %@ %@", action, args);
    if ([action isEqualToString:@"open_app"])        { NSString *n = args[@"name"]; if (n) [_host agentLaunch:@"/usr/bin/open" args:@[@"-a", n]]; return [NSString stringWithFormat:@"Opening %@.", n ?: @"app"]; }
    if ([action isEqualToString:@"set_volume"])      { float p = [args[@"percent"] floatValue]; if (CtlGetMute()) CtlSetMute(NO); CtlSetVolume(p / 100.0f); return [NSString stringWithFormat:@"Volume set to %.0f%%.", p]; }
    if ([action isEqualToString:@"set_brightness"])  { float p = [args[@"percent"] floatValue]; CtlSetBrightness(p / 100.0f); return [NSString stringWithFormat:@"Brightness set to %.0f%%.", p]; }
    if ([action isEqualToString:@"media"])           { NSString *cmd = args[@"cmd"]; if ([cmd isEqualToString:@"next"]) CtlMediaNext(); else if ([cmd isEqualToString:@"prev"] || [cmd isEqualToString:@"previous"]) CtlMediaPrev(); else CtlMediaPlayPause(); return @"Done."; }
    if ([action isEqualToString:@"lock"])            { [_host agentRunShortcut:@"lock"]; return @"Locking the screen."; }
    if ([action isEqualToString:@"sleep_display"])   { [_host agentRunShortcut:@"displaysleep"]; return @"Putting the display to sleep."; }
    if ([action isEqualToString:@"dark_mode"])       { [_host agentRunShortcut:@"darkmode"]; return @"Toggled dark mode."; }
    if ([action isEqualToString:@"mission_control"]) { [_host agentRunShortcut:@"missioncontrol"]; return @"Opening Mission Control."; }
    if ([action isEqualToString:@"run_shortcut"])    { NSString *n = args[@"name"]; if (n) [_host agentLaunch:@"/usr/bin/shortcuts" args:@[@"run", n]]; return [NSString stringWithFormat:@"Running shortcut “%@”.", n ?: @""]; }
    return nil;
}

@end
