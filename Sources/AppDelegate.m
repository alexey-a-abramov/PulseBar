//
//  AppDelegate.m — presents the system-wide Touch Bar, samples metrics, wires
//  actions, the full-bar takeover, the LaunchAgent, and the settings window.
//
#import "AppDelegate.h"
#import "PrivateAPI.h"
#import "PBDefaults.h"
#import "TouchBarPresenter.h"
#import "MirrorController.h"
#import "BarView.h"
#import "Stats.h"
#import "Controls.h"
#import "Pomodoro.h"
#import "SettingsWindowController.h"
#import "LayoutEditorWindowController.h"
#import "CrashReporter.h"
#import "ModifierMonitor.h"
#import "AppIndex.h"
#import "AgentCoordinator.h"
#import "Log.h"
#import <dlfcn.h>
#import <signal.h>
#import <ApplicationServices/ApplicationServices.h>

@interface AppDelegate () <BarActionDelegate, SettingsDelegate, PBAgentHost, PBModifierMonitorDelegate>
@property (nonatomic, strong) PBTouchBarPresenter  *presenter;
@property (nonatomic, strong) BarView              *barView;
@property (nonatomic, strong) PBMirrorController   *mirror;
@property (nonatomic, strong) NSStatusItem         *statusItem;
@property (nonatomic, strong) NSTimer              *timer;
@property (nonatomic, strong) dispatch_source_t     sigTerm, sigInt;
@property (nonatomic, strong) Pomodoro             *pomo;
@property (nonatomic, strong) SettingsWindowController *settings;
@property (nonatomic, strong) LayoutEditorWindowController *layoutEditor;
@property (nonatomic, strong) NSTask               *caffeine;
@property (nonatomic) BOOL                          showTopProc;
@end

@implementation AppDelegate {
    double      _cores[128];
    char        _topBuf[256];
    double      _topCPU;
    NSInteger   _tick;
    double      _sessionStart, _lastActive;   // active working-session tracking (system input idle)
    PBModifierMonitor *_modMonitor;
    PBAgentCoordinator *_agentCoord;
    NSMenuItem *_fnItem;
}

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    PBLogInit();
    // Surface a crash from a previous run (esp. a launch failure) with a copyable stack.
    NSString *pending = PBTakePendingCrashReport();
    if (pending) [PBCrashReporter presentReport:pending title:@"PulseBar quit unexpectedly last time" allowContinue:YES];

    @try {
        [self launch];
    } @catch (NSException *e) {
        NSMutableString *r = [NSMutableString stringWithFormat:@"PulseBar failed to launch.\n\n%@: %@\n\nStack:\n",
                              e.name, e.reason ?: @"(no reason)"];
        for (NSString *f in e.callStackSymbols) [r appendFormat:@"%@\n", f];
        [r writeToFile:PBCrashReportFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        PBLog(@"launch failed: %@: %@", e.name, e.reason);
        [PBCrashReporter presentReport:r title:@"PulseBar failed to launch" allowContinue:NO];
    }
}

- (void)launch {
    [self installSignalHandlers];
    CtlMediaInit();

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    { NSString *mapp = [ud stringForKey:PBKeyMediaApp]; if (mapp.length) CtlSetMediaApp(mapp); }   // default Spotify
    self.pomo = [Pomodoro new];
    self.pomo.workMinutes  = [ud objectForKey:PBKeyWork]  ? [ud integerForKey:PBKeyWork]  : 25;
    self.pomo.breakMinutes = [ud objectForKey:PBKeyBreak] ? [ud integerForKey:PBKeyBreak] : 5;
    __weak AppDelegate *ws = self;
    self.pomo.onComplete = ^(BOOL wasWork) { [ws pomodoroFinished:wasWork]; };
    self.showTopProc = [ud objectForKey:PBKeyShowTopProc] ? [ud boolForKey:PBKeyShowTopProc] : YES;

    [self buildBars];
    [self.barView setMode:[ud integerForKey:PBKeyMode] animated:NO];   // restore last mode
    [self buildStatusItem];
    [self attachToTouchBar];

    if (getenv("PULSEBAR_SELFQUIT") == NULL) {          // never change system settings under test
        if (![ud objectForKey:PBKeyFullBar]) [ud setBool:YES forKey:PBKeyFullBar];  // full width by default
        if ([ud boolForKey:PBKeyFullBar]) [self applyFullBar:YES];                 // hide Control Strip
        if (![ud objectForKey:PBKeyMirror]) [ud setBool:YES forKey:PBKeyMirror];     // show desktop mirror
        if ([ud boolForKey:PBKeyMirror]) [self showMirror];
        if (![ud objectForKey:PBKeyModifiers]) [ud setBool:YES forKey:PBKeyModifiers];   // ⌘ recent · ⌥ app
        BOOL mods = [ud boolForKey:PBKeyModifiers];
        _fnItem.state = mods ? NSControlStateValueOn : NSControlStateValueOff;
        if (mods) [self enableModifiers];
    }

    [self registerSleepWake];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(layoutChanged:)
                                                 name:PBLayoutChangedNotification object:nil];
    [self resumeSampling];

    const char *sq = getenv("PULSEBAR_SELFQUIT");
    if (sq) { double s = atof(sq); if (s > 0) [self performSelector:@selector(quit) withObject:nil afterDelay:s]; }
    if (getenv("PULSEBAR_OPEN_AGENT")) [self barOpenAgent];   // test hook
    PBLog(@"launched (spi=%@)", self.presenter.spiAvailable ? @"available" : @"UNAVAILABLE");
}

- (void)applicationWillTerminate:(NSNotification *)note { [self.mirror suspendPersistence]; [self detach]; }

// Pause all sampling while the screen / system is asleep (the bar isn't exposed),
// so PulseBar uses zero CPU when you can't see it.
- (void)registerSleepWake {
    NSNotificationCenter *wc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wc addObserver:self selector:@selector(pauseSampling)  name:NSWorkspaceScreensDidSleepNotification object:nil];
    [wc addObserver:self selector:@selector(resumeSampling) name:NSWorkspaceScreensDidWakeNotification  object:nil];
    [wc addObserver:self selector:@selector(pauseSampling)  name:NSWorkspaceWillSleepNotification       object:nil];
    [wc addObserver:self selector:@selector(resumeSampling) name:NSWorkspaceDidWakeNotification          object:nil];
}
- (void)pauseSampling { [self.timer invalidate]; self.timer = nil; }
- (void)resumeSampling {
    if (self.timer) return;
    [self tick];
    self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)installSignalHandlers {
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN);
    self.sigTerm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.sigTerm, ^{ [self quit]; }); dispatch_resume(self.sigTerm);
    self.sigInt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.sigInt, ^{ [self quit]; }); dispatch_resume(self.sigInt);
}

#pragma mark - bars

- (void)buildBars {
    // The Touch Bar app area is ~1004pt; the presenter pins this width (see note there).
    self.barView = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, 30)];
    self.barView.actionDelegate = self;
    self.barView.pomodoro = self.pomo;
    self.barView.animateModeSwitch = NO;   // don't hammer the live DFR with a 60fps transition
    self.presenter = [[PBTouchBarPresenter alloc] initWithContentView:self.barView];
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    // Branded "pulse" mark: an ECG/heartbeat line, drawn as a template image.
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(22, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        CGFloat m = 7.5;   // baseline
        NSPoint pts[] = { {1,m}, {6,m}, {7.5,m+2}, {9,m-3.5}, {10.5,m+6}, {12,m-5}, {13.5,m}, {16,m}, {21,m} };
        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = 1.6; p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
        [p moveToPoint:pts[0]];
        for (int i = 1; i < (int)(sizeof(pts) / sizeof(pts[0])); i++) [p lineToPoint:pts[i]];
        [[NSColor blackColor] set]; [p stroke];
        return YES;
    }];
    icon.template = YES;
    self.statusItem.button.image = icon;
    NSMenu *menu = [[NSMenu alloc] init];
    [[menu addItemWithTitle:@"PulseBar — live system monitor" action:nil keyEquivalent:@""] setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Ask the Agent…"          action:@selector(barOpenAgent)   keyEquivalent:@"a"];
    [menu addItemWithTitle:@"Settings…"               action:@selector(showSettings)   keyEquivalent:@","];
    [menu addItemWithTitle:@"Customize layout…"       action:@selector(showLayoutEditor) keyEquivalent:@""];
    [menu addItemWithTitle:@"Show / Hide Desktop Mirror" action:@selector(toggleMirror) keyEquivalent:@"m"];
    [menu addItemWithTitle:@"Re-attach to Touch Bar"  action:@selector(attachToTouchBar) keyEquivalent:@"r"];
    [menu addItemWithTitle:@"Toggle CPU-core view"    action:@selector(toggleCores)     keyEquivalent:@"c"];
    [menu addItemWithTitle:@"Open Log"                action:@selector(openLog)         keyEquivalent:@"l"];
    _fnItem = [menu addItemWithTitle:@"Modifier shortcuts  (⌘ recent · ⌥ app)" action:@selector(toggleModifiers) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit PulseBar" action:@selector(quit) keyEquivalent:@"q"];
    for (NSMenuItem *it in menu.itemArray) if (it.action) it.target = self;
    self.statusItem.menu = menu;
}

#pragma mark - desktop mirror (companion window — exact, clickable copy of the bar)

- (void)showMirror {
    if (!self.mirror) {
        self.mirror = [[PBMirrorController alloc] initWithActionDelegate:self pomodoro:self.pomo mode:self.barView.mode];
        self.mirror.bar.caffeinated = (self.caffeine != nil);
    }
    [self.mirror show];
}
- (void)hideMirror   { [self.mirror hide]; }
- (void)toggleMirror { self.mirror.visible ? [self.mirror hide] : [self showMirror]; }

#pragma mark - Touch Bar attach / detach

- (void)attachToTouchBar { [self.presenter attach]; }

- (void)detach {
    if (self.caffeine) { [self.caffeine terminate]; self.caffeine = nil; }
    [self.presenter detach];
}

#pragma mark - sampling

- (void)tick {
    // Only sample what the active mode actually shows — keeps idle modes cheap.
    NSInteger mode = self.barView.mode;
    BOOL sys = (mode == BarModeSystem);
    BOOL med = (mode == BarModeMedia || mode == BarModeClassic);

    double cpu      = StatsCPUPercent();   // cheap; also drives the Control-Strip %
    MemInfo mem     = StatsMemory();       // cheap
    BatteryInfo bat = StatsBattery();      // battery tile is pinned in every mode

    int n = 0; double gpu = -1;
    NetSample net = {0, 0}; DiskIO disk = {0, 0}; DiskSpace space = {0, 0};
    if (sys) {
        n     = StatsPerCore(_cores, 128);
        gpu   = StatsGPUPercent();
        net   = StatsNetwork();
        disk  = StatsDiskIO();
        space = StatsDiskSpace();
        self.barView.uptime = StatsUptimeSeconds();
        if (self.showTopProc) { if (_tick % 3 == 0) StatsTopProcess(_topBuf, sizeof(_topBuf), &_topCPU); }
        else { _topBuf[0] = '\0'; _topCPU = 0; }
    } else { _topBuf[0] = '\0'; _topCPU = 0; }
    _tick++;

    NowPlaying np; memset(&np, 0, sizeof(np));
    float vol = 0, bright = 0; BOOL mute = NO;
    if (med) { CtlMediaRefresh(); np = CtlNowPlaying(); vol = CtlGetVolume(); mute = CtlGetMute(); bright = CtlGetBrightness(); }

    [self.pomo tick:1.0];

    // Active working session: time since the last >5-min input gap. CG idle time
    // is system-wide (keyboard/mouse/Touch Bar) and needs no permission.
    {
        double now = NSProcessInfo.processInfo.systemUptime;
        double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
        double lastInput = now - idle;
        const double kGap = 300;   // a gap longer than this ends the session
        if (_sessionStart <= 0 || (lastInput - _lastActive) > kGap) _sessionStart = lastInput;
        _lastActive = lastInput;
        double session = (idle < kGap) ? (now - _sessionStart) : (_lastActive - _sessionStart);
        self.barView.sessionSeconds = session;
        self.mirror.bar.sessionSeconds = session;
    }

    NSString *tp = [NSString stringWithUTF8String:_topBuf] ?: @"";
    [self.barView updateWithCPU:cpu cores:_cores count:n mem:mem net:net gpu:gpu
                           disk:disk space:space battery:bat topProc:tp topCPU:_topCPU
                     nowPlaying:np volume:vol mute:mute brightness:bright];
    [self.presenter setStripTitle:[NSString stringWithFormat:@"⟂ %.0f%%", cpu]];

    if (self.mirror.visible) {   // keep the desktop mirror in lock-step
        self.mirror.bar.uptime = self.barView.uptime;
        [self.mirror.bar updateWithCPU:cpu cores:_cores count:n mem:mem net:net gpu:gpu
                                 disk:disk space:space battery:bat topProc:tp topCPU:_topCPU
                           nowPlaying:np volume:vol mute:mute brightness:bright];
    }
}

#pragma mark - BarActionDelegate

- (void)barSetVolume:(float)v   { if (CtlGetMute()) CtlSetMute(NO); CtlSetVolume(v); }
- (void)barToggleMute           { CtlSetMute(!CtlGetMute()); }
- (void)barSetBrightness:(float)v { CtlSetBrightness(v); }
- (void)barMediaPlayPause { PBLog(@"media play/pause (%@)", CtlMediaApp()); CtlMediaPlayPause(); }
- (void)barMediaNext            { PBLog(@"action media next"); CtlMediaNext(); }
- (void)barMediaPrev            { PBLog(@"action media prev"); CtlMediaPrev(); }
- (void)barMediaSeek:(float)f   { PBLog(@"action media seek %.0f%%", f * 100); CtlMediaSeek(f); }
- (void)barTogglePomodoro       { [self.pomo toggle]; }
- (void)barOpenSettings         { [self showSettings]; }
- (PBAgentCoordinator *)agentCoord {
    if (!_agentCoord) _agentCoord = [[PBAgentCoordinator alloc] initWithHost:self];
    return _agentCoord;
}
- (void)barOpenAgent       { [[self agentCoord] openAgent]; }
- (void)barAgentDown       { [[self agentCoord] agentDown]; }      // push-to-talk: start/stop
- (void)barAgentUp:(BOOL)wasHold { [[self agentCoord] agentUp:wasHold]; }  // walkie-talkie release

// PBAgentHost — system actions the coordinator delegates back to us.
- (void)agentLaunch:(NSString *)path args:(NSArray<NSString *> *)args { [self launch:path args:args]; }
- (void)agentRunShortcut:(NSString *)name { [self barRunShortcut:name]; }

// Launcher-tile actions (Actions/app palette).
- (void)barLaunchApp:(NSString *)query {
    PBAppEntry *e = [[PBAppIndex shared] bestMatchFor:query];
    [self launch:@"/usr/bin/open" args:@[@"-a", e.path ?: query]];
    PBLog(@"launch app: %@ -> %@", query, e.path ?: @"(unresolved)");
}
- (void)barRunTerminalCommand:(NSString *)cmd {
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell", cmd];
    [self launch:@"/usr/bin/osascript" args:@[@"-e", src]];
    PBLog(@"run in terminal: %@", cmd);
}

// PulseBar self-management driven by voice/agent.
- (void)agentSetMode:(NSString *)mode {
    NSDictionary *map = @{ @"system": @(BarModeSystem), @"media": @(BarModeMedia),
                           @"productivity": @(BarModeProductivity), @"classic": @(BarModeClassic),
                           @"shortcuts": @(BarModeShortcuts) };
    NSNumber *m = map[mode.lowercaseString];
    if (m) [self barDidChangeMode:m.integerValue];
}
- (void)agentTogglePomodoro { [self barTogglePomodoro]; }
- (void)agentToggleCaffeine { [self barToggleCaffeine]; }
- (void)agentSetMirrorVisible:(BOOL)visible { visible ? [self showMirror] : [self hideMirror]; }
- (void)agentOpenSettings { [self showSettings]; }
- (void)agentOpenLayoutEditor { [self showLayoutEditor]; }
- (void)agentSetTile:(NSString *)token show:(NSNumber *)show size:(NSString *)size {
    if ([BarView setOverrideForMode:self.barView.mode tileToken:token show:show size:size])
        [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
}

- (void)barDidChangeMode:(NSInteger)mode {
    [self.barView setMode:mode animated:self.barView.animateModeSwitch];        // touch bar: instant
    if (self.mirror.bar) [self.mirror.bar setMode:mode animated:self.mirror.bar.animateModeSwitch]; // mirror: animated
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:PBKeyMode];
}

- (void)barToggleCaffeine {
    if (self.caffeine) { [self.caffeine terminate]; self.caffeine = nil; }
    else {
        NSTask *t = [NSTask new]; t.launchPath = @"/usr/bin/caffeinate"; t.arguments = @[@"-disu"];
        @try { [t launch]; } @catch (id e) { t = nil; }
        self.caffeine = t;
    }
    self.barView.caffeinated = (self.caffeine != nil);
    self.mirror.bar.caffeinated = (self.caffeine != nil);
    [self.barView setNeedsDisplay:YES]; [self.mirror.bar setNeedsDisplay:YES];
}

- (void)barRunShortcut:(NSString *)a {
    if      ([a isEqualToString:@"lock"])           [self launch:@"/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession" args:@[@"-suspend"]];
    else if ([a isEqualToString:@"displaysleep"])   [self launch:@"/usr/bin/pmset" args:@[@"displaysleepnow"]];
    else if ([a isEqualToString:@"screenshot"])     [self launch:@"/usr/sbin/screencapture" args:@[@"-ic"]];
    else if ([a isEqualToString:@"darkmode"])       [self launch:@"/usr/bin/osascript" args:@[@"-e", @"tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]];
    else if ([a isEqualToString:@"missioncontrol"]) [self launch:@"/usr/bin/open" args:@[@"-a", @"Mission Control"]];
    else if ([a isEqualToString:@"newnote"])        [self launch:@"/usr/bin/open" args:@[@"-a", @"Notes"]];
    else if ([a isEqualToString:@"launchpad"])      [self launch:@"/usr/bin/open" args:@[@"-a", @"Launchpad"]];
    else if ([a isEqualToString:@"activity"])       [self launch:@"/usr/bin/open" args:@[@"-a", @"Activity Monitor"]];
    else if ([a isEqualToString:@"newreminder"])    [self launch:@"/usr/bin/open" args:@[@"-a", @"Reminders"]];
}

// fire-and-forget (don't block the main thread, unlike -run:args:)
- (void)launch:(NSString *)path args:(NSArray<NSString *> *)args {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    @try { [t launch]; } @catch (id e) {}
}

- (void)pomodoroFinished:(BOOL)wasWork {
    NSSound *s = [NSSound soundNamed:wasWork ? @"Glass" : @"Funk"];
    [s play];
}

#pragma mark - menu actions

- (void)toggleCores  { self.barView.showCores = !self.barView.showCores; [self.barView setNeedsDisplay:YES]; }
- (void)openLog { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:PBLogFile()]]; }

#pragma mark - modifier shortcuts (⌘ → recent mode · ⌥ → app overlay)

- (void)enableModifiers {
    if (!_modMonitor) { _modMonitor = [PBModifierMonitor new]; _modMonitor.delegate = self; }
    BOOL trusted = [_modMonitor enable];
    PBLog(@"modifier shortcuts enabled (Accessibility %@)", trusted ? @"granted" : @"PENDING — grant in System Settings");
}
- (void)disableModifiers { [_modMonitor disable]; [self hideAppOverlay]; }

// PBModifierMonitorDelegate — apply a deliberate ⌘/⌥ hold to the bar(s).
- (void)modifierMonitorEngageOption    { [self showAppOverlay]; }
- (void)modifierMonitorDisengageOption { [self hideAppOverlay]; }
- (void)modifierMonitorEngageCommand   { [self switchRecent]; }

- (void)switchRecent {
    NSInteger r = [self.barView recentMode];
    [self.barView setMode:r animated:self.barView.animateModeSwitch];
    [self.mirror.bar setMode:r animated:self.mirror.bar.animateModeSwitch];
    [NSUserDefaults.standardUserDefaults setInteger:r forKey:PBKeyMode];
}
- (void)showAppOverlay {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *name = app.localizedName ?: @"App"; NSImage *icon = app.icon;
    self.barView.appName = name;   self.barView.appIcon = icon;   self.barView.appOverlay = YES;
    self.mirror.bar.appName = name; self.mirror.bar.appIcon = icon; self.mirror.bar.appOverlay = YES;
    [self.barView setNeedsDisplay:YES]; [self.mirror.bar setNeedsDisplay:YES];
}
- (void)hideAppOverlay {
    if (!self.barView.appOverlay) return;
    self.barView.appOverlay = NO; self.mirror.bar.appOverlay = NO;
    [self.barView setNeedsDisplay:YES]; [self.mirror.bar setNeedsDisplay:YES];
}
- (void)toggleModifiers {
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:PBKeyModifiers];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyModifiers];
    _fnItem.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if (on) [self enableModifiers]; else [self disableModifiers];
}
- (void)barAppAction:(NSString *)a {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    if ([a isEqualToString:@"hide"]) [app hide];
    else if ([a isEqualToString:@"quit"]) [app terminate];
    [self hideAppOverlay];
}
- (void)barSendFunctionKey:(NSInteger)n { (void)n; }   // Fn → F-keys is handled natively now
- (void)showSettings {
    if (!self.settings) self.settings = [[SettingsWindowController alloc] initWithDelegate:self];
    [self.settings present];
}
- (void)showLayoutEditor {
    if (!self.layoutEditor) self.layoutEditor = [LayoutEditorWindowController new];
    [self.layoutEditor present];
}
- (void)quit { [self.mirror suspendPersistence]; [self detach]; [NSApp terminate:nil]; }

#pragma mark - SettingsDelegate

- (BOOL)settingsFullBarEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:PBKeyFullBar]; }
- (void)settingsSetFullBar:(BOOL)on { [self applyFullBar:on]; }
- (BOOL)settingsLoginEnabled { return [[NSFileManager defaultManager] fileExistsAtPath:[self agentPath]]; }
- (void)settingsSetLogin:(BOOL)on { [self setLogin:on]; }
- (NSInteger)settingsWorkMinutes  { return self.pomo.workMinutes; }
- (NSInteger)settingsBreakMinutes { return self.pomo.breakMinutes; }
- (void)settingsSetWork:(NSInteger)w breakMin:(NSInteger)b {
    self.pomo.workMinutes = w; self.pomo.breakMinutes = b;
    [NSUserDefaults.standardUserDefaults setInteger:w forKey:PBKeyWork];
    [NSUserDefaults.standardUserDefaults setInteger:b forKey:PBKeyBreak];
}
- (BOOL)settingsTopProcEnabled { return self.showTopProc; }
- (void)settingsSetTopProc:(BOOL)on {
    self.showTopProc = on;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyShowTopProc];
}
- (NSString *)settingsMediaApp { NSString *a = [NSUserDefaults.standardUserDefaults stringForKey:PBKeyMediaApp]; return a.length ? a : @"Spotify"; }
- (void)settingsSetMediaApp:(NSString *)app {
    NSString *a = [app stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!a.length) a = @"Spotify";
    CtlSetMediaApp(a);
    [NSUserDefaults.standardUserDefaults setObject:a forKey:PBKeyMediaApp];
}
- (void)settingsEditLayout { [self showLayoutEditor]; }
- (void)settingsQuit { [self quit]; }

// Redraw the live bar (and mirror) when the size editor saves a change.
- (void)layoutChanged:(NSNotification *)n {
    [self.barView setNeedsDisplay:YES];
    [self.mirror.bar setNeedsDisplay:YES];
}

#pragma mark - full-bar takeover (reversible)

- (void)applyFullBar:(BOOL)on { [self.presenter applyFullBar:on]; }

// Run a process and capture trimmed stdout (used by the login-item helpers).
- (NSString *)run:(NSString *)path args:(NSArray<NSString *> *)args {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (id e) { return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - login item (LaunchAgent)

- (NSString *)agentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.fun.pulsebar.plist"];
}
- (void)setLogin:(BOOL)on {
    NSString *p = [self agentPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSDictionary *plist = @{ @"Label": @"com.fun.pulsebar",
                                 @"ProgramArguments": @[exe],
                                 @"RunAtLoad": @YES,
                                 @"KeepAlive": @NO };
        [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [plist writeToFile:p atomically:YES];
        [self run:@"/bin/launchctl" args:@[@"load", @"-w", p]];
    } else {
        [self run:@"/bin/launchctl" args:@[@"unload", @"-w", p]];
        [fm removeItemAtPath:p error:nil];
    }
}

@end
