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
#import <dlfcn.h>
#import <signal.h>

static NSTouchBarItemIdentifier const kBarItemID = @"com.fun.pulsebar.main";
static NSTouchBarItemIdentifier const kStripID   = @"com.fun.pulsebar.strip";

@interface AppDelegate () <BarActionDelegate, SettingsDelegate>
@property (nonatomic, strong) NSTouchBar           *fullBar;
@property (nonatomic, strong) NSCustomTouchBarItem  *barItem;
@property (nonatomic, strong) BarView              *barView;
@property (nonatomic, strong) NSCustomTouchBarItem  *stripItem;
@property (nonatomic, strong) NSButton             *stripButton;
@property (nonatomic, strong) NSStatusItem         *statusItem;
@property (nonatomic, strong) NSTimer              *timer;
@property (nonatomic, strong) dispatch_source_t     sigTerm, sigInt;
@property (nonatomic, strong) Pomodoro             *pomo;
@property (nonatomic, strong) SettingsWindowController *settings;
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
}

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self installSignalHandlers];
    [self loadDFR];
    CtlMediaInit();

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    self.pomo = [Pomodoro new];
    self.pomo.workMinutes  = [ud objectForKey:@"work"]  ? [ud integerForKey:@"work"]  : 25;
    self.pomo.breakMinutes = [ud objectForKey:@"break"] ? [ud integerForKey:@"break"] : 5;
    __weak AppDelegate *ws = self;
    self.pomo.onComplete = ^(BOOL wasWork) { [ws pomodoroFinished:wasWork]; };

    [self buildBars];
    [self buildStatusItem];
    [self attachToTouchBar];

    if ([ud boolForKey:@"fullBar"]) [self applyFullBar:YES];   // re-apply saved takeover

    [self tick];
    self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

    const char *sq = getenv("PULSEBAR_SELFQUIT");
    if (sq) { double s = atof(sq); if (s > 0) [self performSelector:@selector(quit) withObject:nil afterDelay:s]; }
    NSLog(@"[PulseBar] launched (spi=%@)", _spiOK ? @"available" : @"UNAVAILABLE");
}

- (void)applicationWillTerminate:(NSNotification *)note { [self detach]; }

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
    self.barView = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, 30)];
    self.barView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.barView.widthAnchor  constraintEqualToConstant:1004].active = YES;
    [self.barView.heightAnchor constraintEqualToConstant:30].active   = YES;
    self.barView.actionDelegate = self;
    self.barView.pomodoro = self.pomo;

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
    self.statusItem.button.title = @"▦";
    NSMenu *menu = [[NSMenu alloc] init];
    [[menu addItemWithTitle:@"PulseBar — live system monitor" action:nil keyEquivalent:@""] setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Settings…"               action:@selector(showSettings)   keyEquivalent:@","];
    [menu addItemWithTitle:@"Re-attach to Touch Bar"  action:@selector(attachToTouchBar) keyEquivalent:@"r"];
    [menu addItemWithTitle:@"Toggle CPU-core view"    action:@selector(toggleCores)     keyEquivalent:@"c"];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit PulseBar" action:@selector(quit) keyEquivalent:@"q"];
    for (NSMenuItem *it in menu.itemArray) if (it.action) it.target = self;
    self.statusItem.menu = menu;
}

#pragma mark - Touch Bar attach / detach

- (void)attachToTouchBar {
    Class TB = NSClassFromString(@"NSTouchBar");
    if ([NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) [NSTouchBarItem addSystemTrayItem:self.stripItem];
    if (_setPresence)  _setPresence(kStripID, YES);
    if (_showCloseBox) _showCloseBox(NO);

    if ([TB respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:self.fullBar systemTrayItemIdentifier:kStripID];
        _spiOK = YES; NSLog(@"[PulseBar] presented full Touch Bar (2-arg SPI)");
    } else if ([TB respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        [NSTouchBar presentSystemModalTouchBar:self.fullBar placement:1 systemTrayItemIdentifier:kStripID];
        _spiOK = YES; NSLog(@"[PulseBar] presented full Touch Bar (placement SPI)");
    } else {
        _spiOK = NO; NSLog(@"[PulseBar] Touch Bar SPI unavailable");
    }
}

- (void)detach {
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
    double cpu = StatsCPUPercent();
    int    n   = StatsPerCore(_cores, 128);
    MemInfo mem = StatsMemory();
    NetSample net = StatsNetwork();
    double gpu = StatsGPUPercent();
    DiskIO disk = StatsDiskIO();
    DiskSpace space = StatsDiskSpace();
    BatteryInfo bat = StatsBattery();
    if (_tick % 3 == 0) StatsTopProcess(_topBuf, sizeof(_topBuf), &_topCPU);
    _tick++;

    CtlMediaRefresh();
    NowPlaying np = CtlNowPlaying();
    float vol = CtlGetVolume(); BOOL mute = CtlGetMute(); float bright = CtlGetBrightness();

    [self.pomo tick:1.0];

    [self.barView updateWithCPU:cpu cores:_cores count:n mem:mem net:net gpu:gpu
                           disk:disk space:space battery:bat
                        topProc:([NSString stringWithUTF8String:_topBuf] ?: @"") topCPU:_topCPU
                     nowPlaying:np volume:vol mute:mute brightness:bright];
    self.stripButton.title = [NSString stringWithFormat:@"⟂ %.0f%%", cpu];
}

#pragma mark - BarActionDelegate

- (void)barSetVolume:(float)v   { if (CtlGetMute()) CtlSetMute(NO); CtlSetVolume(v); }
- (void)barToggleMute           { CtlSetMute(!CtlGetMute()); }
- (void)barSetBrightness:(float)v { CtlSetBrightness(v); }
- (void)barMediaPlayPause       { CtlMediaPlayPause(); }
- (void)barMediaNext            { CtlMediaNext(); }
- (void)barMediaPrev            { CtlMediaPrev(); }
- (void)barTogglePomodoro       { [self.pomo toggle]; }
- (void)barOpenSettings         { [self showSettings]; }

- (void)pomodoroFinished:(BOOL)wasWork {
    NSSound *s = [NSSound soundNamed:wasWork ? @"Glass" : @"Funk"];
    [s play];
}

#pragma mark - menu actions

- (void)toggleCores  { self.barView.showCores = !self.barView.showCores; [self.barView setNeedsDisplay:YES]; }
- (void)showSettings {
    if (!self.settings) self.settings = [[SettingsWindowController alloc] initWithDelegate:self];
    [self.settings present];
}
- (void)quit { [self detach]; [NSApp terminate:nil]; }

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
