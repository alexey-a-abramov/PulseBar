//
//  AgentCoordinator.m
//
#import "AgentCoordinator.h"
#import "Agent.h"
#import "AgentWindowController.h"
#import "Controls.h"
#import "AppIndex.h"
#import "Queries.h"
#import "PBDefaults.h"
#import "Log.h"

static const NSTimeInterval kAutoCloseDelay = 0.8;   // let the user glimpse the result before closing

@interface PBAgentCoordinator () <PBAgentRunner>
@end

@implementation PBAgentCoordinator {
    __weak id<PBAgentHost> _host;
    PBAgent               *_agent;
    AgentWindowController *_window;
    BOOL                   _startedThisPress;   // this press began a listening session
    BOOL                   _openedByThisPress;  // this press made a hidden window visible
    BOOL                   _ephemeralTurn;      // a press-opened turn that may auto-close on success
    NSDate                *_lastActivityAt;     // for the inactivity session reset
}

- (instancetype)initWithHost:(id<PBAgentHost>)host {
    if ((self = [super init])) _host = host;
    return self;
}

- (AgentWindowController *)ensureWindow {
    if (!_agent)  {
        _agent = [PBAgent new]; _agent.runner = self;
        _agent.appResolver = ^NSString *(NSString *q) { return [[PBAppIndex shared] bestMatchFor:q].name; };
    }
    if (!_window) {
        _window = [[AgentWindowController alloc] initWithAgent:_agent];
        __weak typeof(self) ws = self;
        _window.onTurnComplete = ^(BOOL actionRan) { [ws handleTurnComplete:actionRan]; };
        _window.onWindowClosed = ^{ typeof(self) s = ws; if (s) s->_ephemeralTurn = NO; };   // user closed → not ephemeral
    }
    return _window;
}

// Start a fresh dialogue if it's been idle longer than the configured timeout.
- (void)maybeResetSession {
    NSInteger mins = PBDefaultsInteger(PBKeyAgentSessionTimeout, PBDefaultAgentSessionTimeoutMin);
    if (mins <= 0 || !_lastActivityAt) return;
    if ([[NSDate date] timeIntervalSinceDate:_lastActivityAt] >= mins * 60) {
        [_agent resetSession];
        [_window clearTranscript];
        PBLog(@"agent: new session (idle > %ld min)", (long)mins);
    }
}

- (void)openAgent {
    AgentWindowController *w = [self ensureWindow];
    [self maybeResetSession];
    _ephemeralTurn = NO; _openedByThisPress = NO;   // interactive: never auto-close
    [w present];
    _lastActivityAt = [NSDate date];
}

// Orb press → push-to-talk. Tap toggles; hold = walkie-talkie (release sends).
// A press that OPENS a hidden window is "ephemeral" — it auto-closes once a real
// command runs. Opening interactively (menu) or onto an already-open window is not.
- (void)agentDown {
    AgentWindowController *w = [self ensureWindow];
    [self maybeResetSession];
    BOOL wasVisible = w.window.isVisible;
    if (w.listening) {                              // already recording → stop & send
        _startedThisPress = NO;
        [w stopAndSend];
    } else {                                        // idle → open + record
        _startedThisPress = YES;
        _openedByThisPress = !wasVisible;
        _ephemeralTurn = _openedByThisPress;
        [w presentAndListen];
    }
    _lastActivityAt = [NSDate date];
}
- (void)agentUp:(BOOL)wasHold {
    if (_startedThisPress && wasHold && _window.listening) [_window stopAndSend];  // walkie-talkie release
    _startedThisPress = NO;
}

// A turn finished. Stamp activity; if this was a press-opened turn AND a real
// command ran, close the window after a beat so the user sees the confirmation.
- (void)handleTurnComplete:(BOOL)actionRan {
    _lastActivityAt = [NSDate date];
    if (!(_ephemeralTurn && actionRan)) return;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoCloseDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = ws; if (!s) return;
        if (s->_ephemeralTurn && !s->_window.listening) { s->_ephemeralTurn = NO; [s->_window.window orderOut:nil]; }
    });
}

// PBAgentRunner — turn the model's chosen action into a real Mac action.
- (NSString *)agentRunAction:(NSString *)action args:(NSDictionary *)args {
    PBLog(@"agent action: %@ %@", action, args);
    if ([action isEqualToString:@"open_app"])        { NSString *n = args[@"name"]; if (!n.length) return @"Which app?"; NSString *target = [[PBAppIndex shared] bestMatchFor:n].name ?: n; [_host agentLaunch:@"/usr/bin/open" args:@[@"-a", target]]; return [NSString stringWithFormat:@"Opening %@.", target]; }
    if ([action isEqualToString:@"set_volume"])      { float p = [args[@"percent"] floatValue]; if (CtlGetMute()) CtlSetMute(NO); CtlSetVolume(p / 100.0f); return [NSString stringWithFormat:@"Volume set to %.0f%%.", p]; }
    if ([action isEqualToString:@"set_brightness"])  { float p = [args[@"percent"] floatValue]; CtlSetBrightness(p / 100.0f); return [NSString stringWithFormat:@"Brightness set to %.0f%%.", p]; }
    if ([action isEqualToString:@"media"])           { NSString *cmd = args[@"cmd"]; if ([cmd isEqualToString:@"next"]) CtlMediaNext(); else if ([cmd isEqualToString:@"prev"] || [cmd isEqualToString:@"previous"]) CtlMediaPrev(); else CtlMediaPlayPause(); return @"Done."; }
    if ([action isEqualToString:@"lock"])            { [_host agentRunShortcut:@"lock"]; return @"Locking the screen."; }
    if ([action isEqualToString:@"sleep_display"])   { [_host agentRunShortcut:@"displaysleep"]; return @"Putting the display to sleep."; }
    if ([action isEqualToString:@"dark_mode"])       { [_host agentRunShortcut:@"darkmode"]; return @"Toggled dark mode."; }
    if ([action isEqualToString:@"mission_control"]) { [_host agentRunShortcut:@"missioncontrol"]; return @"Opening Mission Control."; }
    if ([action isEqualToString:@"run_shortcut"])    { NSString *n = args[@"name"]; if (n) [_host agentLaunch:@"/usr/bin/shortcuts" args:@[@"run", n]]; return [NSString stringWithFormat:@"Running shortcut “%@”.", n ?: @""]; }

    // --- Controls: relative + mute ---
    if ([action isEqualToString:@"toggle_mute"])     { BOOL m = !CtlGetMute(); CtlSetMute(m); return m ? @"Muted." : @"Unmuted."; }
    if ([action isEqualToString:@"adjust_volume"])   { BOOL up = [args[@"dir"] isEqualToString:@"up"]; float v = CtlGetVolume() + (up ? 0.1f : -0.1f); v = MAX(0, MIN(1, v)); if (up && CtlGetMute()) CtlSetMute(NO); CtlSetVolume(v); return [NSString stringWithFormat:@"Volume %@ to %.0f%%.", up ? @"up" : @"down", v * 100]; }
    if ([action isEqualToString:@"adjust_brightness"]) { BOOL up = [args[@"dir"] isEqualToString:@"up"]; float b = CtlGetBrightness(); if (b < 0) b = 0.5f; b += up ? 0.1f : -0.1f; b = MAX(0, MIN(1, b)); CtlSetBrightness(b); return [NSString stringWithFormat:@"Brightness %@ to %.0f%%.", up ? @"up" : @"down", b * 100]; }

    // --- Bar self-management ---
    if ([action isEqualToString:@"set_mode"])        { NSString *m = args[@"mode"]; [_host agentSetMode:m]; return [NSString stringWithFormat:@"Switched to %@ mode.", m ?: @""]; }
    if ([action isEqualToString:@"toggle_pomodoro"]) { [_host agentTogglePomodoro]; return @"Toggled the Pomodoro timer."; }
    if ([action isEqualToString:@"toggle_caffeine"]) { [_host agentToggleCaffeine]; return @"Toggled keep-awake."; }
    if ([action isEqualToString:@"show_mirror"])     { [_host agentSetMirrorVisible:YES]; return @"Showing the desktop mirror."; }
    if ([action isEqualToString:@"hide_mirror"])     { [_host agentSetMirrorVisible:NO];  return @"Hiding the desktop mirror."; }
    if ([action isEqualToString:@"open_settings"])   { [_host agentOpenSettings]; return @"Opening settings."; }
    if ([action isEqualToString:@"open_layout_editor"]) { [_host agentOpenLayoutEditor]; return @"Opening the layout editor."; }
    if ([action isEqualToString:@"set_tile"])        { id sv = args[@"show"]; NSNumber *show = sv ? @([sv boolValue]) : nil;
                                                       [_host agentSetTile:args[@"tile"] show:show size:args[@"size"]];
                                                       return [NSString stringWithFormat:@"Updated the %@ tile.", args[@"tile"] ?: @""]; }

    // --- Misc safe ---
    if ([action isEqualToString:@"web_search"])      { NSString *q = args[@"query"]; if (q.length) { NSString *enc = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]; [_host agentLaunch:@"/usr/bin/open" args:@[[@"https://www.google.com/search?q=" stringByAppendingString:enc]]]; } return [NSString stringWithFormat:@"Searching the web for “%@”.", q ?: @""]; }
    if ([action isEqualToString:@"do_not_disturb"])  { return @"I can't toggle Focus yet — try it from Control Center."; }

    // --- Query: read-only status, answered for the user (no side effects) ---
    if ([action isEqualToString:@"get_status"])      { NSString *a = [PBQueries answer:args[@"what"]]; return a ?: @"I don't have that information."; }

    return nil;
}

@end
