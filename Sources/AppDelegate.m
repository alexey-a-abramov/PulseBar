//
//  AppDelegate.m — presents the system-wide Touch Bar, samples metrics, wires
//  actions, the full-bar takeover, the LaunchAgent, and the settings window.
//
#import "AppDelegate.h"
#import "PrivateAPI.h"
#import "BarView.h"
#import "Stats.h"
#import "Controls.h"
#import "Pomodoro.h"
#import "SettingsWindowController.h"
#import "Agent.h"
#import "AgentWindowController.h"
#import "Log.h"
#import <dlfcn.h>
#import <signal.h>
#import <ApplicationServices/ApplicationServices.h>

static NSTouchBarItemIdentifier const kBarItemID = @"com.fun.pulsebar.main";
static NSTouchBarItemIdentifier const kStripID   = @"com.fun.pulsebar.strip";

@interface AppDelegate () <BarActionDelegate, SettingsDelegate, NSWindowDelegate, PBAgentRunner>
@property (nonatomic, strong) NSTouchBar           *fullBar;
@property (nonatomic, strong) NSCustomTouchBarItem  *barItem;
@property (nonatomic, strong) BarView              *barView;
@property (nonatomic, strong) NSPanel              *mirrorPanel;
@property (nonatomic, strong) BarView              *mirrorBar;
@property (nonatomic, strong) NSCustomTouchBarItem  *stripItem;
@property (nonatomic, strong) NSButton             *stripButton;
@property (nonatomic, strong) NSStatusItem         *statusItem;
@property (nonatomic, strong) NSTimer              *timer;
@property (nonatomic, strong) dispatch_source_t     sigTerm, sigInt;
@property (nonatomic, strong) Pomodoro             *pomo;
@property (nonatomic, strong) SettingsWindowController *settings;
@property (nonatomic, strong) NSTask               *caffeine;
@property (nonatomic) BOOL                          showTopProc;
@property (nonatomic, strong) NSLayoutConstraint   *barWidth;
@property (nonatomic, strong) PBAgent              *agent;
@property (nonatomic, strong) AgentWindowController *agentWindow;
@end

@implementation AppDelegate {
    void *_dfr;
    DFRElementSetControlStripPresenceFn _setPresence;
    DFRSystemModalShowsCloseBoxFn       _showCloseBox;
    double      _cores[128];
    char        _topBuf[256];
    double      _topCPU;
    NSInteger   _tick;
    BOOL        _spiOK;
    BOOL        _terminating;
    id          _fnGlobalMon;
    id          _fnLocalMon;
    NSMenuItem *_fnItem;
    NSEventModifierFlags _prevFlags;
}

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    PBLogInit();
    [self installSignalHandlers];
    [self loadDFR];
    CtlMediaInit();

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    { NSString *mapp = [ud stringForKey:@"mediaApp"]; if (mapp.length) CtlSetMediaApp(mapp); }   // default Spotify
    self.pomo = [Pomodoro new];
    self.pomo.workMinutes  = [ud objectForKey:@"work"]  ? [ud integerForKey:@"work"]  : 25;
    self.pomo.breakMinutes = [ud objectForKey:@"break"] ? [ud integerForKey:@"break"] : 5;
    __weak AppDelegate *ws = self;
    self.pomo.onComplete = ^(BOOL wasWork) { [ws pomodoroFinished:wasWork]; };
    self.showTopProc = [ud objectForKey:@"showTopProc"] ? [ud boolForKey:@"showTopProc"] : YES;

    [self buildBars];
    [self.barView setMode:[ud integerForKey:@"mode"] animated:NO];   // restore last mode
    [self buildStatusItem];
    [self attachToTouchBar];

    if (getenv("PULSEBAR_SELFQUIT") == NULL) {          // never change system settings under test
        if (![ud objectForKey:@"fullBar"]) [ud setBool:YES forKey:@"fullBar"];  // full width by default
        if ([ud boolForKey:@"fullBar"]) [self applyFullBar:YES];                 // hide Control Strip
        if (![ud objectForKey:@"mirror"]) [ud setBool:YES forKey:@"mirror"];     // show desktop mirror
        if ([ud boolForKey:@"mirror"]) [self showMirror];
        if (![ud objectForKey:@"modifiers"]) [ud setBool:YES forKey:@"modifiers"];   // ⌘ recent · ⌥ app
        BOOL mods = [ud boolForKey:@"modifiers"];
        _fnItem.state = mods ? NSControlStateValueOn : NSControlStateValueOff;
        if (mods) [self enableModifiers];
    }

    [self registerSleepWake];
    [self resumeSampling];

    const char *sq = getenv("PULSEBAR_SELFQUIT");
    if (sq) { double s = atof(sq); if (s > 0) [self performSelector:@selector(quit) withObject:nil afterDelay:s]; }
    if (getenv("PULSEBAR_OPEN_AGENT")) [self barOpenAgent];   // test hook
    PBLog(@"launched (spi=%@)", _spiOK ? @"available" : @"UNAVAILABLE");
}

- (void)applicationWillTerminate:(NSNotification *)note { _terminating = YES; [self detach]; }

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

- (void)loadDFR {
    _dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (_dfr) {
        _setPresence  = (DFRElementSetControlStripPresenceFn)dlsym(_dfr, "DFRElementSetControlStripPresenceForIdentifier");
        _showCloseBox = (DFRSystemModalShowsCloseBoxFn)dlsym(_dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    }
}

#pragma mark - bars

- (void)buildBars {
    // Full Touch Bar is ~1085pt; the app region with Control Strip shown is ~1004pt.
    BOOL full = [NSUserDefaults.standardUserDefaults boolForKey:@"fullBar"];
    self.barView = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, full ? 1085 : 1004, 30)];
    self.barView.translatesAutoresizingMaskIntoConstraints = NO;
    self.barWidth = [self.barView.widthAnchor constraintEqualToConstant:(full ? 1085 : 1004)];
    self.barWidth.active = YES;
    [self.barView.heightAnchor constraintEqualToConstant:30].active = YES;
    self.barView.actionDelegate = self;
    self.barView.pomodoro = self.pomo;
    self.barView.animateModeSwitch = NO;   // don't hammer the live DFR with a 60fps transition

    self.barItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kBarItemID];
    self.barItem.view = self.barView;

    self.fullBar = [[NSTouchBar alloc] init];
    self.fullBar.delegate = self;
    self.fullBar.defaultItemIdentifiers = @[kBarItemID];

    self.stripButton = [NSButton buttonWithTitle:@"PulseBar" target:self action:@selector(attachToTouchBar)];
    self.stripButton.bezelStyle = NSBezelStyleRounded;
    self.stripButton.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    self.stripItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kStripID];
    self.stripItem.view = self.stripButton;
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    if ([identifier isEqualToString:kBarItemID]) return self.barItem;
    if ([identifier isEqualToString:kStripID])   return self.stripItem;
    return nil;
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    // Branded "pulse bars" mark (audio-level look), drawn as a template image.
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(20, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor blackColor] set];
        CGFloat heights[6] = { 5, 9, 14, 16, 8, 4 }, bw = 2.0, gap = 1.4, x = 1.5;
        for (int i = 0; i < 6; i++) {
            CGFloat h = heights[i];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, (16 - h) / 2, bw, h) xRadius:1 yRadius:1] fill];
            x += bw + gap;
        }
        return YES;
    }];
    icon.template = YES;
    self.statusItem.button.image = icon;
    NSMenu *menu = [[NSMenu alloc] init];
    [[menu addItemWithTitle:@"PulseBar — live system monitor" action:nil keyEquivalent:@""] setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Ask the Agent…"          action:@selector(barOpenAgent)   keyEquivalent:@"a"];
    [menu addItemWithTitle:@"Settings…"               action:@selector(showSettings)   keyEquivalent:@","];
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

- (void)buildMirror {
    CGFloat maxW = [NSScreen mainScreen].visibleFrame.size.width - 80;
    CGFloat scale = MIN(1.5, maxW / 1085.0); if (scale < 0.9) scale = 0.9;
    CGFloat w = 1085 * scale, h = 30 * scale;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel)
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"PulseBar — Touch Bar Mirror";
    p.level = NSFloatingWindowLevel; p.hidesOnDeactivate = NO; p.releasedWhenClosed = NO;
    p.movableByWindowBackground = YES; p.delegate = self;
    p.becomesKeyOnlyIfNeeded = YES;   // clicking it must NOT steal key focus / dismiss the system-modal Touch Bar

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    self.mirrorBar = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    self.mirrorBar.actionDelegate = self;
    self.mirrorBar.pomodoro = self.pomo;
    self.mirrorBar.animateModeSwitch = YES;
    self.mirrorBar.caffeinated = (self.caffeine != nil);
    [self.mirrorBar setMode:self.barView.mode animated:NO];
    [container addSubview:self.mirrorBar];
    self.mirrorBar.bounds = NSMakeRect(0, 0, 1085, 30);   // bounds < frame → scales the drawing up
    p.contentView = container;
    self.mirrorPanel = p;
}

- (void)showMirror {
    if (!self.mirrorPanel) [self buildMirror];
    NSRect sf = [NSScreen mainScreen].visibleFrame, wf = self.mirrorPanel.frame;
    [self.mirrorPanel setFrameOrigin:NSMakePoint(sf.origin.x + (sf.size.width - wf.size.width) / 2, sf.origin.y + 36)];
    [self.mirrorPanel orderFront:nil];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"mirror"];
}
- (void)hideMirror { [self.mirrorPanel orderOut:nil]; [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"mirror"]; }
- (void)toggleMirror { (self.mirrorPanel.isVisible) ? [self hideMirror] : [self showMirror]; }
- (void)windowWillClose:(NSNotification *)n {
    if (_terminating) return;   // don't persist "hidden" just because the app is quitting
    if (n.object == self.mirrorPanel) [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"mirror"];
}

#pragma mark - Touch Bar attach / detach

- (void)attachToTouchBar {
    Class TB = NSClassFromString(@"NSTouchBar");
    if ([NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) [NSTouchBarItem addSystemTrayItem:self.stripItem];
    if (_setPresence)  _setPresence(kStripID, YES);
    if (_showCloseBox) _showCloseBox(NO);

    if ([TB respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:self.fullBar systemTrayItemIdentifier:kStripID];
        _spiOK = YES; PBLog(@"presented full Touch Bar (2-arg SPI)");
    } else if ([TB respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:self.fullBar placement:1 systemTrayItemIdentifier:kStripID];
        _spiOK = YES; PBLog(@"presented full Touch Bar (placement SPI)");
    } else {
        _spiOK = NO; PBLog(@"Touch Bar SPI unavailable");
    }
}

- (void)detach {
    if (self.caffeine) { [self.caffeine terminate]; self.caffeine = nil; }
    Class TB = NSClassFromString(@"NSTouchBar");
    if (_setPresence) _setPresence(kStripID, NO);
    if ([TB respondsToSelector:@selector(dismissSystemModalTouchBar:)]) [NSTouchBar dismissSystemModalTouchBar:self.fullBar];
    if ([NSTouchBarItem respondsToSelector:@selector(removeSystemTrayItem:)]) [NSTouchBarItem removeSystemTrayItem:self.stripItem];
    // never leave the user stuck without a Control Strip
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"fullBar"]) {
        [self writeTBMode:([NSUserDefaults.standardUserDefaults stringForKey:@"tbBackup"] ?: @"appWithControlStrip")];
        [self restartTB];
    }
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

    NSString *tp = [NSString stringWithUTF8String:_topBuf] ?: @"";
    [self.barView updateWithCPU:cpu cores:_cores count:n mem:mem net:net gpu:gpu
                           disk:disk space:space battery:bat topProc:tp topCPU:_topCPU
                     nowPlaying:np volume:vol mute:mute brightness:bright];
    self.stripButton.title = [NSString stringWithFormat:@"⟂ %.0f%%", cpu];

    if (self.mirrorPanel.isVisible) {   // keep the desktop mirror in lock-step
        self.mirrorBar.uptime = self.barView.uptime;
        [self.mirrorBar updateWithCPU:cpu cores:_cores count:n mem:mem net:net gpu:gpu
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
- (void)barTogglePomodoro       { [self.pomo toggle]; }
- (void)barOpenSettings         { [self showSettings]; }
- (void)barOpenAgent {
    if (!self.agent) { self.agent = [PBAgent new]; self.agent.runner = self; }
    if (!self.agentWindow) self.agentWindow = [[AgentWindowController alloc] initWithAgent:self.agent];
    [self.agentWindow present];
}

// PBAgentRunner — turn the model's chosen action into a real Mac action.
- (NSString *)agentRunAction:(NSString *)action args:(NSDictionary *)args {
    PBLog(@"agent action: %@ %@", action, args);
    if ([action isEqualToString:@"open_app"])        { NSString *n = args[@"name"]; if (n) [self launch:@"/usr/bin/open" args:@[@"-a", n]]; return [NSString stringWithFormat:@"Opening %@.", n ?: @"app"]; }
    if ([action isEqualToString:@"set_volume"])      { float p = [args[@"percent"] floatValue]; if (CtlGetMute()) CtlSetMute(NO); CtlSetVolume(p / 100.0f); return [NSString stringWithFormat:@"Volume set to %.0f%%.", p]; }
    if ([action isEqualToString:@"set_brightness"])  { float p = [args[@"percent"] floatValue]; CtlSetBrightness(p / 100.0f); return [NSString stringWithFormat:@"Brightness set to %.0f%%.", p]; }
    if ([action isEqualToString:@"media"])           { NSString *cmd = args[@"cmd"]; if ([cmd isEqualToString:@"next"]) CtlMediaNext(); else if ([cmd isEqualToString:@"prev"] || [cmd isEqualToString:@"previous"]) CtlMediaPrev(); else [self barMediaPlayPause]; return @"Done."; }
    if ([action isEqualToString:@"lock"])            { [self barRunShortcut:@"lock"]; return @"Locking the screen."; }
    if ([action isEqualToString:@"sleep_display"])   { [self barRunShortcut:@"displaysleep"]; return @"Putting the display to sleep."; }
    if ([action isEqualToString:@"dark_mode"])       { [self barRunShortcut:@"darkmode"]; return @"Toggled dark mode."; }
    if ([action isEqualToString:@"mission_control"]) { [self barRunShortcut:@"missioncontrol"]; return @"Opening Mission Control."; }
    if ([action isEqualToString:@"run_shortcut"])    { NSString *n = args[@"name"]; if (n) [self launch:@"/usr/bin/shortcuts" args:@[@"run", n]]; return [NSString stringWithFormat:@"Running shortcut “%@”.", n ?: @""]; }
    return nil;
}

- (void)barDidChangeMode:(NSInteger)mode {
    [self.barView setMode:mode animated:self.barView.animateModeSwitch];        // touch bar: instant
    if (self.mirrorBar) [self.mirrorBar setMode:mode animated:self.mirrorBar.animateModeSwitch]; // mirror: animated
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"mode"];
}

- (void)barToggleCaffeine {
    if (self.caffeine) { [self.caffeine terminate]; self.caffeine = nil; }
    else {
        NSTask *t = [NSTask new]; t.launchPath = @"/usr/bin/caffeinate"; t.arguments = @[@"-disu"];
        @try { [t launch]; } @catch (id e) { t = nil; }
        self.caffeine = t;
    }
    self.barView.caffeinated = (self.caffeine != nil);
    self.mirrorBar.caffeinated = (self.caffeine != nil);
    [self.barView setNeedsDisplay:YES]; [self.mirrorBar setNeedsDisplay:YES];
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
    if (!AXIsProcessTrusted())
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
    if (_fnGlobalMon) return;
    __weak AppDelegate *ws = self;
    _fnGlobalMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^(NSEvent *e) { [ws modifierChanged:e.modifierFlags]; }];
    _fnLocalMon  = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) { [ws modifierChanged:e.modifierFlags]; return e; }];
    PBLog(@"modifier shortcuts enabled (Accessibility %@)", AXIsProcessTrusted() ? @"granted" : @"PENDING — grant in System Settings");
}
- (void)disableModifiers {
    if (_fnGlobalMon) { [NSEvent removeMonitor:_fnGlobalMon]; _fnGlobalMon = nil; }
    if (_fnLocalMon)  { [NSEvent removeMonitor:_fnLocalMon];  _fnLocalMon = nil; }
    [self hideAppOverlay];
}
// Debounced (~0.3s) so quick ⌘-/⌥-shortcuts don't trigger; only a deliberate hold does.
- (void)modifierChanged:(NSEventModifierFlags)flags {
    BOOL cmdNow = (flags & NSEventModifierFlagCommand) != 0, cmdWas = (_prevFlags & NSEventModifierFlagCommand) != 0;
    BOOL optNow = (flags & NSEventModifierFlagOption)  != 0, optWas = (_prevFlags & NSEventModifierFlagOption)  != 0;
    _prevFlags = flags;
    if (optNow && !optWas) [self performSelector:@selector(showAppOverlay) withObject:nil afterDelay:0.30];
    if (!optNow && optWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showAppOverlay) object:nil]; [self hideAppOverlay]; }
    if (cmdNow && !cmdWas) [self performSelector:@selector(switchRecent) withObject:nil afterDelay:0.30];
    if (!cmdNow && cmdWas) [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(switchRecent) object:nil];
}
- (void)switchRecent {
    NSInteger r = [self.barView recentMode];
    [self.barView setMode:r animated:self.barView.animateModeSwitch];
    [self.mirrorBar setMode:r animated:self.mirrorBar.animateModeSwitch];
    [NSUserDefaults.standardUserDefaults setInteger:r forKey:@"mode"];
}
- (void)showAppOverlay {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *name = app.localizedName ?: @"App"; NSImage *icon = app.icon;
    self.barView.appName = name;   self.barView.appIcon = icon;   self.barView.appOverlay = YES;
    self.mirrorBar.appName = name; self.mirrorBar.appIcon = icon; self.mirrorBar.appOverlay = YES;
    [self.barView setNeedsDisplay:YES]; [self.mirrorBar setNeedsDisplay:YES];
}
- (void)hideAppOverlay {
    if (!self.barView.appOverlay) return;
    self.barView.appOverlay = NO; self.mirrorBar.appOverlay = NO;
    [self.barView setNeedsDisplay:YES]; [self.mirrorBar setNeedsDisplay:YES];
}
- (void)toggleModifiers {
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:@"modifiers"];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"modifiers"];
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
- (void)quit { _terminating = YES; [self detach]; [NSApp terminate:nil]; }

#pragma mark - SettingsDelegate

- (BOOL)settingsFullBarEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:@"fullBar"]; }
- (void)settingsSetFullBar:(BOOL)on { [self applyFullBar:on]; }
- (BOOL)settingsLoginEnabled { return [[NSFileManager defaultManager] fileExistsAtPath:[self agentPath]]; }
- (void)settingsSetLogin:(BOOL)on { [self setLogin:on]; }
- (NSInteger)settingsWorkMinutes  { return self.pomo.workMinutes; }
- (NSInteger)settingsBreakMinutes { return self.pomo.breakMinutes; }
- (void)settingsSetWork:(NSInteger)w breakMin:(NSInteger)b {
    self.pomo.workMinutes = w; self.pomo.breakMinutes = b;
    [NSUserDefaults.standardUserDefaults setInteger:w forKey:@"work"];
    [NSUserDefaults.standardUserDefaults setInteger:b forKey:@"break"];
}
- (BOOL)settingsTopProcEnabled { return self.showTopProc; }
- (void)settingsSetTopProc:(BOOL)on {
    self.showTopProc = on;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"showTopProc"];
}
- (NSString *)settingsMediaApp { NSString *a = [NSUserDefaults.standardUserDefaults stringForKey:@"mediaApp"]; return a.length ? a : @"Spotify"; }
- (void)settingsSetMediaApp:(NSString *)app {
    NSString *a = [app stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!a.length) a = @"Spotify";
    CtlSetMediaApp(a);
    [NSUserDefaults.standardUserDefaults setObject:a forKey:@"mediaApp"];
}
- (void)settingsQuit { [self quit]; }

#pragma mark - full-bar takeover (reversible)

- (NSString *)run:(NSString *)path args:(NSArray<NSString *> *)args {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (id e) { return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (NSString *)readTBMode { return [self run:@"/usr/bin/defaults" args:@[@"read", @"com.apple.touchbar.agent", @"PresentationModeGlobal"]]; }
- (void)writeTBMode:(NSString *)m { [self run:@"/usr/bin/defaults" args:@[@"write", @"com.apple.touchbar.agent", @"PresentationModeGlobal", @"-string", m]]; }
- (void)restartTB { [self run:@"/usr/bin/killall" args:@[@"TouchBarServer"]]; [self run:@"/usr/bin/killall" args:@[@"ControlStrip"]]; }

- (void)applyFullBar:(BOOL)on {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (on) {
        NSString *cur = [self readTBMode];
        if (cur.length && ![cur isEqualToString:@"app"]) [ud setObject:cur forKey:@"tbBackup"];
        [self writeTBMode:@"app"];
    } else {
        [self writeTBMode:([ud stringForKey:@"tbBackup"] ?: @"appWithControlStrip")];
    }
    [ud setBool:on forKey:@"fullBar"];
    self.barWidth.constant = on ? 1085 : 1004;   // fill the freed Control-Strip space
    [self restartTB];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self attachToTouchBar]; });
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
