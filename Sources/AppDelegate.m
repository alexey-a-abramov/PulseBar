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
#import "PBProcess.h"
#import "PBLoginItem.h"
#import "PBBreakReminder.h"
#import "AppIndex.h"
#import "AgentCoordinator.h"
#import "VoiceNotes.h"
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
@property (nonatomic, strong) PBVoiceNotes         *voiceNotes;
@property (nonatomic, strong) PBLoginItem          *loginItem;
@property (nonatomic, strong) PBBreakReminder       *breakReminder;
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
    NSMenuItem *_profileDefaultItem, *_profileMinimumItem;   // Layout submenu radio items
    BOOL _applyingProfile;   // suppresses the "→ Custom" reclassification while a profile is being applied
}

// A layout profile is a one-tap bundle of these four knobs. Every profile reserves
// PBCloseBoxReserve px on the LEFT for the Touch Bar ✕ so the agent orb stays visible.
typedef struct { PBDensity density; BOOL tabsCollapsed; NSInteger safeLeft; NSInteger safeRight; } PBProfileSpec;
static PBProfileSpec profileSpec(PBLayoutProfile p) {
    switch (p) {
        case PBLayoutProfileMinimum:   // icon-only + collapsed tabs → maximum room for tiles
            return (PBProfileSpec){ PBDensityCompact, YES, PBCloseBoxReserve, PBDefaultSafeRight };
        case PBLayoutProfileDefault:   // the everyday rich layout
        default:
            return (PBProfileSpec){ PBDensityAuto,    NO,  PBCloseBoxReserve, PBDefaultSafeRight };
    }
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
    self.pomo.workMinutes  = PBDefaultsInteger(PBKeyWork,  PBDefaultWorkMinutes);
    self.pomo.breakMinutes = PBDefaultsInteger(PBKeyBreak, PBDefaultBreakMinutes);
    self.pomo.adaptiveLength = PBDefaultsBool(PBKeyAdaptive, YES);
    __weak AppDelegate *ws = self;
    self.pomo.onComplete = ^(BOOL wasWork) { [ws pomodoroFinished:wasWork]; };
    self.showTopProc = PBDefaultsBool(PBKeyShowTopProc, YES);

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
        if ([ud boolForKey:PBKeyModifiers]) [self enableModifiers];
        // First run of the profile era: adopt the ✕-aware Default layout so the agent
        // orb is visible out of the box. Existing custom fit/density is preserved once
        // PBKeyLayoutProfile exists (the user's own edits flip it to Custom).
        if (![ud objectForKey:PBKeyLayoutProfile]) [self applyLayoutProfile:PBLayoutProfileDefault];
        else [self syncLayoutProfileMenu];
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
    // When the frontmost app changes, macOS re-adds its close box (✕). We no
    // longer re-present the whole modal here (that re-attach flickered and felt
    // "weird"); we just quietly re-hide the ✕. The safe-area insets keep tiles and
    // the agent orb visible regardless, so reclaiming the bar isn't needed.
    [wc addObserver:self selector:@selector(activeAppChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
}
- (void)activeAppChanged:(NSNotification *)n {
    if (getenv("PULSEBAR_SELFQUIT")) return;   // don't fight the Touch Bar under test
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(suppressChrome) object:nil];
    [self performSelector:@selector(suppressChrome) withObject:nil afterDelay:0.12];   // coalesce rapid switches
    [self autoSwitchModeForApp:n.userInfo[NSWorkspaceApplicationKey]];
}

// Per-app auto-mode switch (off by default): when a mapped app comes to the
// front, switch the bar to the paired mode. A manual mode change still sticks
// until the next app switch — we only react to the app becoming frontmost.
- (void)autoSwitchModeForApp:(NSRunningApplication *)app {
    if (![NSUserDefaults.standardUserDefaults boolForKey:PBKeyAutoModeEnabled]) return;
    NSString *bid = app.bundleIdentifier;
    if (!bid.length) return;
    NSArray *rules = [NSUserDefaults.standardUserDefaults arrayForKey:PBKeyAutoModeRules];
    for (NSDictionary *r in rules) {
        if (![r[@"bundleID"] isEqualToString:bid]) continue;
        NSInteger m = [r[@"mode"] integerValue];
        if (m >= 0 && m < BarModeCount && m != self.barView.mode) {
            [self.barView setMode:m animated:self.barView.animateModeSwitch];
            [self barDidChangeMode:m];   // sync mirror + persisted last mode
        }
        return;
    }
}
- (void)suppressChrome { [self.presenter suppressCloseBox]; }
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
    // Apple's ✕ shifts the whole active area to the right, so the agent orb on the
    // trailing edge falls off-screen. We "squeeze" the layout from the RIGHT so the
    // orb lands back inside the visible area. The shift itself clears the ✕, so no
    // LEFT reserve is needed by default. Both are live-adjustable in Settings → Layout
    // (and via `defaults write com.fun.pulsebar safeAreaRight <px>`).
    self.barView.safeAreaLeftInset  = PBDefaultsInteger(PBKeySafeLeft,  PBDefaultSafeLeft);
    self.barView.safeAreaRightInset = PBDefaultsInteger(PBKeySafeRight, PBDefaultSafeRight);
    [BarView ensureLayoutSchema];   // migrate the legacy compact bool → density before reading it
    self.barView.density = (PBDensity)PBDefaultsInteger(PBKeyDensity, PBDensityAuto);
    self.barView.tabsCollapsed = [NSUserDefaults.standardUserDefaults boolForKey:PBKeyTabsCollapsed];
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
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *bld = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    NSString *header = [NSString stringWithFormat:@"PulseBar — system monitor · v%@ (build %@)", ver, bld];
    [[menu addItemWithTitle:header action:nil keyEquivalent:@""] setEnabled:NO];

    // Primary — talk to the agent.
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Ask the Agent…"             action:@selector(barOpenAgent)     keyEquivalent:@"a"];

    // Quick controls — switch layout, lock the screen. Everything else is in Settings.
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *layout = [[NSMenuItem alloc] initWithTitle:@"Layout" action:nil keyEquivalent:@""];
    NSMenu *layoutSub = [[NSMenu alloc] init];
    _profileDefaultItem = [layoutSub addItemWithTitle:@"Default" action:@selector(pickLayoutProfile:) keyEquivalent:@""];
    _profileDefaultItem.tag = PBLayoutProfileDefault;
    _profileMinimumItem = [layoutSub addItemWithTitle:@"Minimum" action:@selector(pickLayoutProfile:) keyEquivalent:@""];
    _profileMinimumItem.tag = PBLayoutProfileMinimum;
    [layoutSub addItem:[NSMenuItem separatorItem]];
    [layoutSub addItemWithTitle:@"Customize Layout…"     action:@selector(showLayoutEditor) keyEquivalent:@""];
    for (NSMenuItem *it in layoutSub.itemArray) it.target = self;
    layout.submenu = layoutSub;
    [menu addItem:layout];

    [menu addItemWithTitle:@"Lock Screen"                action:@selector(lockScreen)       keyEquivalent:@""];

    // Settings — the home for everything else (shortcuts, fit, auto-switch, notes, diagnostics…).
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Settings…"                  action:@selector(showSettings)     keyEquivalent:@","];

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit PulseBar"              action:@selector(quit)             keyEquivalent:@"q"];
    for (NSMenuItem *it in menu.itemArray) if (it.action) it.target = self;
    [self syncLayoutProfileMenu];
    self.statusItem.menu = menu;
}

// Radio-check the active profile in the Layout submenu (neither, when Custom).
- (void)syncLayoutProfileMenu {
    PBLayoutProfile p = (PBLayoutProfile)PBDefaultsInteger(PBKeyLayoutProfile, PBLayoutProfileDefault);
    _profileDefaultItem.state = (p == PBLayoutProfileDefault) ? NSControlStateValueOn : NSControlStateValueOff;
    _profileMinimumItem.state = (p == PBLayoutProfileMinimum) ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)pickLayoutProfile:(NSMenuItem *)item { [self applyLayoutProfile:(PBLayoutProfile)item.tag]; }

// Apply a profile's density+tabs+safe-area bundle atomically, persist which profile
// is active, and refresh the menu + any open Settings window. The _applyingProfile
// guard keeps the individual setters from reclassifying this as a "Custom" edit.
- (void)applyLayoutProfile:(PBLayoutProfile)p {
    if (p == PBLayoutProfileCustom) return;   // Custom is a reported state, not an applyable one
    PBProfileSpec s = profileSpec(p);
    _applyingProfile = YES;
    [self setDensity:s.density];
    [self setTabsCollapsed:s.tabsCollapsed];
    [self settingsSetSafeLeft:s.safeLeft];
    [self settingsSetSafeRight:s.safeRight];
    _applyingProfile = NO;
    [NSUserDefaults.standardUserDefaults setInteger:p forKey:PBKeyLayoutProfile];
    [self syncLayoutProfileMenu];
    [self.settings syncIfVisible];   // keep an open Settings window in step
}

// Any manual density/tabs/fit edit means the layout no longer matches a preset.
- (void)markLayoutProfileCustom {
    if (_applyingProfile) return;
    [NSUserDefaults.standardUserDefaults setInteger:PBLayoutProfileCustom forKey:PBKeyLayoutProfile];
    [self syncLayoutProfileMenu];
}

- (void)lockScreen { [self barRunShortcut:@"lock"]; }

#pragma mark - desktop mirror (companion window — exact, clickable copy of the bar)

// Apply a change to the live bar AND the desktop mirror together, then redraw
// both — so the two never drift out of sync (a recurring copy-paste bug source).
- (void)broadcast:(void (^)(BarView *bar))apply {
    apply(self.barView); [self.barView setNeedsDisplay:YES];
    if (self.mirror.bar) { apply(self.mirror.bar); [self.mirror.bar setNeedsDisplay:YES]; }
}

- (void)showMirror {
    if (!self.mirror) {
        self.mirror = [[PBMirrorController alloc] initWithActionDelegate:self pomodoro:self.pomo mode:self.barView.mode];
        self.mirror.bar.caffeinated = (self.caffeine != nil);
        // Mirror the live bar's safe area so the desktop copy is a faithful preview
        // of what the Touch Bar shows (and the reserved zones are visible here).
        self.mirror.bar.safeAreaLeftInset  = self.barView.safeAreaLeftInset;
        self.mirror.bar.safeAreaRightInset = self.barView.safeAreaRightInset;
        self.mirror.bar.density = self.barView.density;
        self.mirror.bar.tabsCollapsed = self.barView.tabsCollapsed;
    }
    [self.mirror show];
}
- (void)hideMirror   { [self.mirror hide]; }
- (void)toggleMirror { self.mirror.visible ? [self.mirror hide] : [self showMirror]; }

// Compact layout — icon-only active pill + icon-only action tiles. Applies to the
// live bar and the mirror, persists, and (unless mid-profile) flips to Custom.
- (void)setDensity:(PBDensity)d {
    [self broadcast:^(BarView *b){ b.density = d; }];
    [NSUserDefaults.standardUserDefaults setInteger:d forKey:PBKeyDensity];
    [self markLayoutProfileCustom];
}

// Collapse/expand the mode-tab strip (chevron on the bar, or Settings → Layout).
// Applies to both bars, persists, and (unless mid-profile) flips to Custom.
- (void)setTabsCollapsed:(BOOL)c {
    [self broadcast:^(BarView *b){ b.tabsCollapsed = c; }];
    [NSUserDefaults.standardUserDefaults setBool:c forKey:PBKeyTabsCollapsed];
    [self markLayoutProfileCustom];
}
- (void)barSetTabsCollapsed:(BOOL)c { [self setTabsCollapsed:c]; }   // chevron tapped on the bar

#pragma mark - Touch Bar attach / detach

- (void)attachToTouchBar { [self.presenter attach]; }   // lightweight present (used at launch)

// Menu "Re-take Over the Touch Bar": fully re-claim the bar, including evicting
// the system Control Strip (the brightness/sound/Siri region that can creep back
// after app or system events). This re-asserts the global takeover —
// PresentationModeGlobal=app + a TouchBarServer/ControlStrip restart — then
// re-presents, so the whole bar is ours again. (~1s flicker from the restart.)
- (void)reattachFully {
    if (getenv("PULSEBAR_SELFQUIT")) { [self.presenter attach]; return; }   // never change system settings under test
    [self applyFullBar:YES];   // sets PBKeyFullBar=YES, hides the Control Strip, restarts TB, re-presents
}

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

    // CPU temp + fan: private-SPI reads (IOHIDEventSystemClient + AppleSMC), cheap
    // but sampled at ~0.5 Hz (seeded on the first tick so the TTEMP tile isn't blank).
    if (_tick == 1 || _tick % 2 == 0) {
        PBThermalSample th = PBThermalRead();
        self.barView.thermal = th;
        self.mirror.bar.thermal = th;
    }

    // (No periodic re-assert: it re-presented the modal every ~10s, which read as
    // the bar "flickering"/jumping. The safe-area insets now keep the agent orb and
    // tiles visible even when macOS re-decorates our modal with its ✕, so reclaiming
    // the bar only on a real app switch — activeAppChanged: — is enough.)

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
        // Adaptive Pomodoro: while idle (and not manually set), the focus block
        // grows with the uninterrupted working session. See README.
        if (self.pomo.state == PomoIdle && self.pomo.adaptiveLength)
            self.pomo.workMinutes = [Pomodoro adaptiveWorkMinutes:session];
        [self.breakReminder update:session];
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
- (void)barCyclePomodoroLength  {
    [self.pomo cycleWorkLength];
    [NSUserDefaults.standardUserDefaults setInteger:self.pomo.workMinutes forKey:PBKeyWork];
}
// Focus side-note: hold to record, release to save (no chat, no agent).
- (void)barNoteDown {
    if (!self.voiceNotes) {
        self.voiceNotes = [PBVoiceNotes new];
        __weak AppDelegate *ws = self;
        self.voiceNotes.onStateChange = ^(BOOL rec) {
            [ws broadcast:^(BarView *b){ b.noteRecording = rec; }];
        };
    }
    [self.voiceNotes start];
}
- (void)barNoteUp { [self.voiceNotes stopAndSave]; }
- (void)barAcknowledgeBreak { [self.breakReminder acknowledge]; }
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
    BOOL on = (self.caffeine != nil);
    [self broadcast:^(BarView *b){ b.caffeinated = on; }];
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
- (void)launch:(NSString *)path args:(NSArray<NSString *> *)args { PBLaunchDetached(path, args); }

- (void)pomodoroFinished:(BOOL)wasWork {
    NSSound *s = [NSSound soundNamed:wasWork ? @"Glass" : @"Funk"];
    [s play];
}

#pragma mark - menu actions

- (void)openLog { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:PBLogFile()]]; }

#pragma mark - session break reminder (unmutable)

// Lazily build the reminder, wiring its show/hide to the bar + mirror banner.
- (PBBreakReminder *)breakReminder {
    if (!_breakReminder) {
        _breakReminder = [PBBreakReminder new];
        __weak AppDelegate *ws = self;
        _breakReminder.onShow = ^(NSString *txt) {
            ws.barView.breakReminderText = txt;   ws.barView.breakReminder = YES;
            ws.mirror.bar.breakReminderText = txt; ws.mirror.bar.breakReminder = YES;
            [ws.barView setNeedsDisplay:YES]; [ws.mirror.bar setNeedsDisplay:YES];
        };
        _breakReminder.onHide = ^{
            ws.barView.breakReminder = NO; ws.mirror.bar.breakReminder = NO;
            [ws.barView setNeedsDisplay:YES]; [ws.mirror.bar setNeedsDisplay:YES];
        };
    }
    return _breakReminder;
}

#pragma mark - modifier shortcuts (⌘ → recent mode · ⌥ → app overlay)

- (void)applyShortcutMasks {
    static NSEventModifierFlags const kMasks[] = {
        NSEventModifierFlagControl, NSEventModifierFlagOption, NSEventModifierFlagCommand, 0
    };
    NSInteger pi = PBDefaultsInteger(PBKeyShortcutPeekMod, 0);
    NSInteger oi = PBDefaultsInteger(PBKeyShortcutOverlayMod, 1);
    _modMonitor.peekMask    = kMasks[MAX(0, MIN(3, pi))];
    _modMonitor.overlayMask = kMasks[MAX(0, MIN(3, oi))];
}
- (void)enableModifiers {
    if (!_modMonitor) { _modMonitor = [PBModifierMonitor new]; _modMonitor.delegate = self; }
    [self applyShortcutMasks];
    BOOL trusted = [_modMonitor enable];
    PBLog(@"modifier shortcuts enabled (Accessibility %@)", trusted ? @"granted" : @"PENDING — grant in System Settings");
}
- (void)disableModifiers { [_modMonitor disable]; [self hideAppOverlay]; }

// PBModifierMonitorDelegate — apply a deliberate ⌃/⌥ hold to the bar(s).
// ⌃ is momentary: hold to peek the previous mode, release to snap back (the
// peek doesn't persist — the last *chosen* mode is what we restore on launch).
- (void)modifierMonitorEngageOption    { [self showAppOverlay]; }
- (void)modifierMonitorDisengageOption { [self hideAppOverlay]; }
- (void)modifierMonitorEngageControl   { [self.barView beginPeekMode]; [self.mirror.bar beginPeekMode]; }
- (void)modifierMonitorDisengageControl { [self.barView endPeekMode];  [self.mirror.bar endPeekMode]; }
- (void)showAppOverlay {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *name = app.localizedName ?: @"App"; NSImage *icon = app.icon;
    [self broadcast:^(BarView *b){ b.appName = name; b.appIcon = icon; b.appOverlay = YES; }];
}
- (void)hideAppOverlay {
    if (!self.barView.appOverlay) return;
    [self broadcast:^(BarView *b){ b.appOverlay = NO; }];
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
- (void)showShortcutsTab {
    if (!self.settings) self.settings = [[SettingsWindowController alloc] initWithDelegate:self];
    [self.settings presentTab:@"shortcuts"];
}
- (void)showLayoutEditor {
    if (!self.layoutEditor) self.layoutEditor = [LayoutEditorWindowController new];
    [self.layoutEditor present];
}
- (void)quit { [self.mirror suspendPersistence]; [self detach]; [NSApp terminate:nil]; }

#pragma mark - SettingsDelegate

- (BOOL)settingsFullBarEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:PBKeyFullBar]; }
- (void)settingsSetFullBar:(BOOL)on { [self applyFullBar:on]; }
- (PBLoginItem *)loginItem { if (!_loginItem) _loginItem = [PBLoginItem new]; return _loginItem; }
- (BOOL)settingsLoginEnabled { return [self.loginItem isEnabled]; }
- (void)settingsSetLogin:(BOOL)on { [self.loginItem setEnabled:on]; }
- (NSInteger)settingsWorkMinutes  { return self.pomo.workMinutes; }
- (NSInteger)settingsBreakMinutes { return self.pomo.breakMinutes; }
- (void)settingsSetWork:(NSInteger)w breakMin:(NSInteger)b {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL workChanged = (w != self.pomo.workMinutes);
    self.pomo.workMinutes = w; self.pomo.breakMinutes = b;
    [ud setInteger:w forKey:PBKeyWork];
    [ud setInteger:b forKey:PBKeyBreak];
    if (workChanged && self.pomo.adaptiveLength) {   // a manual Work choice sticks (matches the Focus tile)
        self.pomo.adaptiveLength = NO;
        [ud setBool:NO forKey:PBKeyAdaptive];
    }
}
- (BOOL)settingsTopProcEnabled { return self.showTopProc; }
- (void)settingsSetTopProc:(BOOL)on {
    self.showTopProc = on;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyShowTopProc];
}
- (BOOL)settingsMirrorVisible { return self.mirror.visible; }
- (void)settingsSetMirror:(BOOL)on { on ? [self showMirror] : [self hideMirror]; }
- (BOOL)settingsModifiersEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:PBKeyModifiers]; }
- (void)settingsSetModifiers:(BOOL)on {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyModifiers];
    if (on) [self enableModifiers]; else [self disableModifiers];
}
- (NSInteger)settingsShortcutPeekMod { return PBDefaultsInteger(PBKeyShortcutPeekMod, 0); }
- (void)settingsSetShortcutPeekMod:(NSInteger)mod {
    [NSUserDefaults.standardUserDefaults setInteger:mod forKey:PBKeyShortcutPeekMod];
    if (_modMonitor) [self applyShortcutMasks];
}
- (NSInteger)settingsShortcutOverlayMod { return PBDefaultsInteger(PBKeyShortcutOverlayMod, 1); }
- (void)settingsSetShortcutOverlayMod:(NSInteger)mod {
    [NSUserDefaults.standardUserDefaults setInteger:mod forKey:PBKeyShortcutOverlayMod];
    if (_modMonitor) [self applyShortcutMasks];
}
- (BOOL)settingsAdaptiveLength { return self.pomo.adaptiveLength; }
- (void)settingsSetAdaptive:(BOOL)on {
    self.pomo.adaptiveLength = on;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyAdaptive];
}
- (NSInteger)settingsBreakReminderMinutes {
    return PBDefaultsInteger(PBKeyBreakReminder, PBDefaultBreakReminderMinutes);
}
- (void)settingsSetBreakReminderMinutes:(NSInteger)m {
    [NSUserDefaults.standardUserDefaults setInteger:MAX(1, m) forKey:PBKeyBreakReminder];
    [self.breakReminder rearm];   // re-arm against the new threshold on the next tick
}
- (CGFloat)settingsSafeLeft  { return self.barView.safeAreaLeftInset; }
- (CGFloat)settingsSafeRight { return self.barView.safeAreaRightInset; }
- (void)settingsSetSafeLeft:(CGFloat)px {
    [self broadcast:^(BarView *b){ b.safeAreaLeftInset = px; }];
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)lround(px) forKey:PBKeySafeLeft];
    [self markLayoutProfileCustom];
}
- (void)settingsSetSafeRight:(CGFloat)px {
    [self broadcast:^(BarView *b){ b.safeAreaRightInset = px; }];
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)lround(px) forKey:PBKeySafeRight];
    [self markLayoutProfileCustom];
}
- (NSInteger)settingsDensity { return self.barView.density; }
- (void)settingsSetDensity:(NSInteger)d { [self setDensity:(PBDensity)d]; }
- (BOOL)settingsTabsCollapsed { return self.barView.tabsCollapsed; }
- (void)settingsSetTabsCollapsed:(BOOL)c { [self setTabsCollapsed:c]; }
- (NSInteger)settingsLayoutProfile { return PBDefaultsInteger(PBKeyLayoutProfile, PBLayoutProfileDefault); }
- (void)settingsSetLayoutProfile:(NSInteger)p { [self applyLayoutProfile:(PBLayoutProfile)p]; }
- (void)settingsReattachTouchBar { [self reattachFully]; }
- (void)settingsOpenLog { [self openLog]; }
- (BOOL)settingsAutoModeEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:PBKeyAutoModeEnabled]; }
- (void)settingsSetAutoModeEnabled:(BOOL)on { [NSUserDefaults.standardUserDefaults setBool:on forKey:PBKeyAutoModeEnabled]; }
- (NSArray<NSDictionary *> *)settingsAutoModeRules { return [NSUserDefaults.standardUserDefaults arrayForKey:PBKeyAutoModeRules] ?: @[]; }
- (void)settingsSetAutoModeRules:(NSArray<NSDictionary *> *)rules { [NSUserDefaults.standardUserDefaults setObject:(rules ?: @[]) forKey:PBKeyAutoModeRules]; }
- (NSString *)settingsAgentModel { return PBDefaultsString(PBKeyAgentModel, @"gemma3:4b"); }
- (void)settingsSetAgentModel:(NSString *)tag {
    if (!tag.length) return;
    [NSUserDefaults.standardUserDefaults setObject:tag forKey:PBKeyAgentModel];
    [[self agentCoord] setActiveModel:tag];
}
- (NSInteger)settingsAgentTimeoutMinutes { return PBDefaultsInteger(PBKeyAgentSessionTimeout, PBDefaultAgentSessionTimeoutMin); }
- (void)settingsSetAgentTimeoutMinutes:(NSInteger)m {
    [NSUserDefaults.standardUserDefaults setInteger:MAX(0, m) forKey:PBKeyAgentSessionTimeout];
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
    pb_bumpLayoutGen();   // any persisted-layout write invalidates the packVisible memo
    [self.barView setNeedsDisplay:YES];
    [self.mirror.bar setNeedsDisplay:YES];
}

#pragma mark - full-bar takeover (reversible)

- (void)applyFullBar:(BOOL)on { [self.presenter applyFullBar:on]; }

@end
