//
//  TouchBarPresenter.m
//
#import "TouchBarPresenter.h"
#import "PrivateAPI.h"
#import "PBDefaults.h"
#import "Log.h"
#import <dlfcn.h>

static NSTouchBarItemIdentifier const kBarItemID = @"com.fun.pulsebar.main";
static NSTouchBarItemIdentifier const kStripID   = @"com.fun.pulsebar.strip";

@interface PBTouchBarPresenter () <NSTouchBarDelegate>
@end

@implementation PBTouchBarPresenter {
    void *_dfr;
    DFRElementSetControlStripPresenceFn _setPresence;
    DFRSystemModalShowsCloseBoxFn       _showCloseBox;
    BOOL                  _spiOK;
    NSTouchBar           *_fullBar;
    NSCustomTouchBarItem *_barItem, *_stripItem;
    NSButton             *_stripButton;
    NSLayoutConstraint   *_widthC;
}

- (instancetype)initWithContentView:(NSView *)content {
    if ((self = [super init])) {
        [self loadDFR];

        // The visible Touch Bar app area is ~1004pt. Even in full takeover, the
        // system-tray item occupies the right edge, so the modal content stays
        // ~1004 — sizing wider just pushes the right cluster off-screen. We fill
        // the whole panel and let BarView reserve safe margins for the system
        // close box (left) and the right-edge panel — see BarView.safeArea*Inset.
        content.translatesAutoresizingMaskIntoConstraints = NO;
        _widthC = [content.widthAnchor constraintEqualToConstant:1004];
        _widthC.active = YES;
        [content.heightAnchor constraintEqualToConstant:30].active = YES;

        _barItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kBarItemID];
        _barItem.view = content;

        _fullBar = [[NSTouchBar alloc] init];
        _fullBar.delegate = self;
        _fullBar.defaultItemIdentifiers = @[kBarItemID];

        _stripButton = [NSButton buttonWithTitle:@"PulseBar" target:self action:@selector(attach)];
        _stripButton.bezelStyle = NSBezelStyleRounded;
        _stripButton.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
        _stripItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kStripID];
        _stripItem.view = _stripButton;

        // Suppress Apple's close box (✕) at SETUP, before the first present. MTMR
        // does exactly this once and the ✕ never appears; calling it only after
        // presenting (as we used to) is unreliable. It's a global DFR flag, so it
        // persists to every later present.
        if (_showCloseBox) _showCloseBox(NO);
    }
    return self;
}

- (BOOL)spiAvailable { return _spiOK; }

- (void)loadDFR {
    _dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (_dfr) {
        _setPresence  = (DFRElementSetControlStripPresenceFn)dlsym(_dfr, "DFRElementSetControlStripPresenceForIdentifier");
        _showCloseBox = (DFRSystemModalShowsCloseBoxFn)dlsym(_dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    }
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    if ([identifier isEqualToString:kBarItemID]) return _barItem;
    if ([identifier isEqualToString:kStripID])   return _stripItem;
    return nil;
}

- (void)setStripTitle:(NSString *)title { _stripButton.title = title; }

- (void)attach {
    Class TB = NSClassFromString(@"NSTouchBar");
    if ([NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) [NSTouchBarItem addSystemTrayItem:_stripItem];
    if (_setPresence)  _setPresence(kStripID, YES);

    // Re-assert close-box suppression before presenting too (belt and braces).
    [self hideCloseBox];

    // When taking over, present with placement:1 — this hides the system Control
    // Strip (the brightness/sound/Siri region) NATIVELY, with no defaults write and
    // no TouchBarServer restart (so no flicker). This is how MTMR hides it. The
    // plain 2-arg present keeps the Control Strip, so we only use it when the
    // takeover is off (or the placement SPI is missing).
    BOOL takeover = [NSUserDefaults.standardUserDefaults boolForKey:PBKeyFullBar];
    BOOL hasPlacement = [TB respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)];
    BOOL has2arg      = [TB respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)];
    if (takeover && hasPlacement) {
        [NSTouchBar presentSystemModalTouchBar:_fullBar placement:1 systemTrayItemIdentifier:kStripID];
        _spiOK = YES; PBLog(@"presented full Touch Bar (placement:1 — Control Strip hidden natively)");
    } else if (has2arg) {
        [NSTouchBar presentSystemModalTouchBar:_fullBar systemTrayItemIdentifier:kStripID];
        _spiOK = YES; PBLog(@"presented full Touch Bar (2-arg SPI — Control Strip visible)");
    } else if (hasPlacement) {
        [NSTouchBar presentSystemModalTouchBar:_fullBar placement:1 systemTrayItemIdentifier:kStripID];
        _spiOK = YES; PBLog(@"presented full Touch Bar (placement SPI)");
    } else {
        _spiOK = NO; PBLog(@"Touch Bar SPI unavailable");
    }

    // And once more after presenting (and on the next runloop turn) to be sure the
    // ✕ stays hidden if the system re-decorated the modal on present.
    [self hideCloseBox];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self hideCloseBox]; });
}

- (void)hideCloseBox {
    if (_showCloseBox) _showCloseBox(NO);
    else PBLog(@"close-box SPI unavailable (DFRSystemModalShowsCloseBoxWhenFrontMost not found)");
}

// Re-hide Apple's ✕ without re-presenting the modal. Cheap and invisible — used
// on app switches in place of a full re-attach (which flickered).
- (void)suppressCloseBox { if (_spiOK) [self hideCloseBox]; }

- (void)detach {
    Class TB = NSClassFromString(@"NSTouchBar");
    if (_setPresence) _setPresence(kStripID, NO);
    if ([TB respondsToSelector:@selector(dismissSystemModalTouchBar:)]) [NSTouchBar dismissSystemModalTouchBar:_fullBar];
    if ([NSTouchBarItem respondsToSelector:@selector(removeSystemTrayItem:)]) [NSTouchBarItem removeSystemTrayItem:_stripItem];
    // never leave the user stuck without a Control Strip
    if ([NSUserDefaults.standardUserDefaults boolForKey:PBKeyFullBar]) {
        [self writeTBMode:([NSUserDefaults.standardUserDefaults stringForKey:PBKeyTBBackup] ?: @"appWithControlStrip")];
        [self restartTB];
    }
}

#pragma mark - full-bar takeover (reversible)

static NSString *pbRun(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (id e) { return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (NSString *)readTBMode { return pbRun(@"/usr/bin/defaults", @[@"read", @"com.apple.touchbar.agent", @"PresentationModeGlobal"]); }
- (void)writeTBMode:(NSString *)m { pbRun(@"/usr/bin/defaults", @[@"write", @"com.apple.touchbar.agent", @"PresentationModeGlobal", @"-string", m]); }
- (void)restartTB { pbRun(@"/usr/bin/killall", @[@"TouchBarServer"]); pbRun(@"/usr/bin/killall", @[@"ControlStrip"]); }

- (void)applyFullBar:(BOOL)on {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (on) {
        NSString *cur = [self readTBMode];
        if (cur.length && ![cur isEqualToString:@"app"]) [ud setObject:cur forKey:PBKeyTBBackup];
        [self writeTBMode:@"app"];
    } else {
        [self writeTBMode:([ud stringForKey:PBKeyTBBackup] ?: @"appWithControlStrip")];
    }
    [ud setBool:on forKey:PBKeyFullBar];   // takeover toggles Control-Strip persistence, not width
    [self restartTB];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self attach]; });
}

@end
