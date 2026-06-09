//
//  AgentCoordinator.m
//
#import "AgentCoordinator.h"
#import "Agent.h"
#import "AgentWindowController.h"
#import "PBAgentHUD.h"
#import "PBSpeechCapture.h"
#import "Controls.h"
#import "AppIndex.h"
#import "Queries.h"
#import "PBDefaults.h"
#import "Log.h"

// A result this short (and single-line) fades in the HUD; anything longer or
// multi-line opens the chat window instead (the user reads it there).
static const NSUInteger kHUDResultMaxChars = 44;

@interface PBAgentCoordinator () <PBAgentRunner>
@end

@implementation PBAgentCoordinator {
    __weak id<PBAgentHost> _host;
    PBAgent               *_agent;
    AgentWindowController *_window;     // interactive chat + long results
    PBAgentHUD            *_hud;        // walkie-talkie recording + short results
    PBSpeechCapture       *_capture;    // push-to-talk voice
    BOOL                   _capturing;
    NSString              *_pendingUser;
    NSDate                *_lastActivityAt;
}

- (instancetype)initWithHost:(id<PBAgentHost>)host {
    if ((self = [super init])) _host = host;
    return self;
}

- (PBAgent *)ensureAgent {
    if (!_agent) {
        _agent = [PBAgent new]; _agent.runner = self;
        _agent.model = PBDefaultsString(PBKeyAgentModel, @"gemma3:4b");
        _agent.appResolver = ^NSString *(NSString *q) { return [[PBAppIndex shared] bestMatchFor:q].name; };
    }
    return _agent;
}

- (void)setActiveModel:(NSString *)tag { if (tag.length) [self ensureAgent].model = tag; }
- (AgentWindowController *)ensureWindow {
    [self ensureAgent];
    if (!_window) {
        _window = [[AgentWindowController alloc] initWithAgent:_agent];
        __weak typeof(self) ws = self;
        _window.onTurnComplete = ^(BOOL actionRan) { (void)actionRan; typeof(self) s = ws; if (s) s->_lastActivityAt = [NSDate date]; };
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

// Menu "Ask the Agent…" — interactive chat window; never a HUD, never auto-close.
- (void)openAgent {
    AgentWindowController *w = [self ensureWindow];
    [self maybeResetSession];
    [w present];
    _lastActivityAt = [NSDate date];
}

// Orb = pure walkie-talkie: press records into the HUD, release stops + executes.
- (void)agentDown {
    [self ensureAgent]; [self maybeResetSession];
    if (!_hud) _hud = [PBAgentHUD new];
    if (!_capture) {
        _capture = [PBSpeechCapture new];
        __weak typeof(self) ws = self;
        _capture.onPartial = ^(NSString *t) { typeof(self) s = ws; if (s) [s->_hud updatePartial:t]; };
        _capture.onError   = ^(NSString *m) { typeof(self) s = ws; if (!s) return; s->_capturing = NO; [s->_hud showResult:m]; };
    }
    _capturing = YES;
    [_hud showListening];
    [_capture start];
    _lastActivityAt = [NSDate date];
}
- (void)agentUp:(BOOL)wasHold {
    (void)wasHold;
    if (!_capturing) return;
    _capturing = NO;
    __weak typeof(self) ws = self;
    [_capture stop:^(NSString *final) {
        typeof(self) s = ws; if (!s) return;
        if (!final.length) { [s->_hud dismiss]; return; }   // nothing heard
        s->_pendingUser = final;
        [s->_hud showThinking];
        [s->_agent ask:final done:^(NSString *interp, NSString *reply) { [s routeResult:interp reply:reply]; }];
    }];
    _lastActivityAt = [NSDate date];
}

// Short single-line result → fade in the HUD; long/complex → open the chat window.
- (void)routeResult:(NSString *)interp reply:(NSString *)reply {
    _lastActivityAt = [NSDate date];
    NSString *r = reply ?: @"";
    BOOL complex = (r.length > kHUDResultMaxChars) || ([r rangeOfString:@"\n"].location != NSNotFound);
    if (complex) {
        [_hud dismiss];
        [[self ensureWindow] showTurnUser:_pendingUser action:interp reply:r];
    } else {
        [_hud showResult:r.length ? r : @"Done."];
    }
    _pendingUser = nil;
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
