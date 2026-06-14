//
//  SettingsWindowController.m — a sectioned, tabbed settings window:
//  General (bar/system/media), Focus (Pomodoro + break reminder), and Notes
//  (the side-note history, with CSV export).
//
#import "SettingsWindowController.h"
#import "BarView.h"      // nameForMode + BarModeCount (auto-mode rules)
#import "VoiceNotes.h"
#import "PBDefaults.h"
#import "PBOllama.h"
#import "Log.h"

// Flipped list view so the auto-mode rule rows lay out top→down.
@interface PBRulesView : NSView @end
@implementation PBRulesView - (BOOL)isFlipped { return YES; } @end

@interface SettingsWindowController () <NSTextFieldDelegate>
@end

@implementation SettingsWindowController {
    __weak id<SettingsDelegate> _delegate;
    NSButton   *_fullBar, *_login, *_topProc, *_mirror, *_adaptive;
    NSStepper  *_workStep, *_breakStep, *_breakReminderStep;
    NSTextField *_workVal, *_breakVal, *_breakReminderVal, *_mediaField, *_notesCount;
    NSTextView *_notesView;
    NSTabView  *_tabs;
    NSSlider   *_leftSlider, *_rightSlider;
    NSTextField *_leftVal, *_rightVal;
    NSSegmentedControl *_densitySeg;
    NSButton   *_collapseTabs;
    NSButton   *_autoModeCheck;
    NSView     *_rulesHost;
    NSTextField *_rulesEmpty;
    NSMutableArray<NSMutableDictionary *> *_rules;
    NSPopUpButton *_modelPopup, *_downloadPopup;
    NSTextField *_modelStatus, *_dlStatus;
    NSButton   *_downloadBtn;
    NSProgressIndicator *_dlProgress;
    NSStepper  *_agentTimeoutStep; NSTextField *_agentTimeoutVal;
    PBOllama   *_pull;
    // Shortcuts tab
    NSButton   *_shortcutsEnable;
    NSSegmentedControl *_peekSeg, *_overlaySeg;
    NSTextField *_shortcutConflictLabel;
}

static const CGFloat kW = 470, kH = 452;

- (instancetype)initWithDelegate:(id<SettingsDelegate>)delegate {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kW, kH)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"PulseBar Settings";
    w.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:w])) {
        _delegate = delegate;
        [self build];
    }
    return self;
}

#pragma mark - small builders

static NSTextField *label(NSString *s, NSRect f, CGFloat sz, BOOL bold) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.frame = f; t.font = bold ? [NSFont boldSystemFontOfSize:sz] : [NSFont systemFontOfSize:sz];
    return t;
}
static NSTextField *help(NSString *s, NSRect f) {
    NSTextField *t = label(s, f, 10, NO);
    t.textColor = [NSColor secondaryLabelColor];
    t.maximumNumberOfLines = 2;
    return t;
}
// A bold section header with a hairline rule beneath it.
- (void)section:(NSString *)title in:(NSView *)c at:(CGFloat)y {
    [c addSubview:label(title, NSMakeRect(20, y, kW - 40, 18), 12, YES)];
    NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(20, y - 4, kW - 40, 1)];
    rule.boxType = NSBoxSeparator;
    [c addSubview:rule];
}

#pragma mark - build

- (void)build {
    NSView *c = self.window.contentView;

    _tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(8, 46, kW - 16, kH - 56)];
    [c addSubview:_tabs];

    [_tabs addTabViewItem:[self generalTab]];
    [_tabs addTabViewItem:[self layoutTab]];
    [_tabs addTabViewItem:[self shortcutsTab]];
    [_tabs addTabViewItem:[self modesTab]];
    [_tabs addTabViewItem:[self focusTab]];
    [_tabs addTabViewItem:[self agentTab]];
    [_tabs addTabViewItem:[self notesTab]];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit PulseBar" target:self action:@selector(doQuit:)];
    quit.frame = NSMakeRect(kW - 140, 10, 124, 28); quit.bezelStyle = NSBezelStyleRounded;
    [c addSubview:quit];
}

- (NSView *)pageView {
    return [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW - 28, kH - 96)];
}

- (NSTabViewItem *)generalTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    it.label = @"General";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height;

    [self section:@"Touch Bar" in:c at:top - 22];
    _fullBar = [NSButton checkboxWithTitle:@"Take over the entire Touch Bar (hide Control Strip)"
                                    target:self action:@selector(toggleFullBar:)];
    _fullBar.frame = NSMakeRect(20, top - 48, kW - 60, 20); [c addSubview:_fullBar];
    [c addSubview:help(@"Fills the whole bar & stays put across apps. You'll use PulseBar's\nown volume/brightness instead of the system Control Strip.",
                       NSMakeRect(40, top - 84, kW - 80, 32))];

    _mirror = [NSButton checkboxWithTitle:@"Show the desktop mirror window"
                                   target:self action:@selector(toggleMirror:)];
    _mirror.frame = NSMakeRect(20, top - 106, kW - 60, 20); [c addSubview:_mirror];

    [self section:@"System" in:c at:top - 138];
    _topProc = [NSButton checkboxWithTitle:@"Show top CPU process (uses a little more CPU)"
                                    target:self action:@selector(toggleTopProc:)];
    _topProc.frame = NSMakeRect(20, top - 164, kW - 60, 20); [c addSubview:_topProc];
    _login = [NSButton checkboxWithTitle:@"Start PulseBar at login" target:self action:@selector(toggleLogin:)];
    _login.frame = NSMakeRect(20, top - 186, kW - 60, 20); [c addSubview:_login];

    [self section:@"Media" in:c at:top - 218];
    [c addSubview:label(@"Play/pause target", NSMakeRect(20, top - 244, 120, 18), 11, NO)];
    _mediaField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, top - 246, 160, 22)];
    _mediaField.placeholderString = @"Spotify"; _mediaField.delegate = self; [c addSubview:_mediaField];
    [c addSubview:help(@"e.g. Spotify, Music, TV — the app the bar controls in Media mode.",
                       NSMakeRect(20, top - 268, kW - 40, 16))];
    return it;
}

- (NSTabViewItem *)layoutTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"layout"];
    it.label = @"Layout";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    // Density — the first-order layout choice.
    [self section:@"Density" in:c at:top - 22];
    _densitySeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Auto", @"Full", @"Compact"]
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self action:@selector(densityChanged:)];
    _densitySeg.frame = NSMakeRect(20, top - 54, 240, 24); [c addSubview:_densitySeg];
    _collapseTabs = [NSButton checkboxWithTitle:@"Collapse mode tabs (show only the active pill; tap › to expand)"
                                         target:self action:@selector(collapseTabsChanged:)];
    _collapseTabs.frame = NSMakeRect(276, top - 52, W - 296, 22); [c addSubview:_collapseTabs];
    [c addSubview:help(@"Auto goes icon-only before any tile has to be hidden when the bar is tight;\nFull and Compact pin the look. Collapsing the tabs frees their width for tiles.",
                       NSMakeRect(20, top - 90, W - 40, 32))];

    // Fit — insets that keep tiles clear of system chrome.
    [self section:@"Fit to your Touch Bar" in:c at:top - 118];
    [c addSubview:help(@"Apple's ✕ shifts the bar right; its Control Strip can cover the right edge.\nPreview live on the Desktop Mirror as you adjust.",
                       NSMakeRect(20, top - 158, W - 40, 32))];

    [c addSubview:label(@"Right squeeze", NSMakeRect(20, top - 184, 100, 18), 11, NO)];
    _rightSlider = [NSSlider sliderWithValue:PBDefaultSafeRight minValue:0 maxValue:232 target:self action:@selector(changeRight:)];
    _rightSlider.frame = NSMakeRect(125, top - 186, W - 125 - 66, 20); _rightSlider.continuous = YES;
    [c addSubview:_rightSlider];
    _rightVal = label([NSString stringWithFormat:@"%ld px", (long)PBDefaultSafeRight], NSMakeRect(W - 58, top - 184, 50, 18), 11, NO); [c addSubview:_rightVal];

    [c addSubview:label(@"Left reserve", NSMakeRect(20, top - 212, 100, 18), 11, NO)];
    _leftSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:120 target:self action:@selector(changeLeft:)];
    _leftSlider.frame = NSMakeRect(125, top - 214, W - 125 - 66, 20); _leftSlider.continuous = YES;
    [c addSubview:_leftSlider];
    _leftVal = label(@"0 px", NSMakeRect(W - 58, top - 212, 50, 18), 11, NO); [c addSubview:_leftVal];

    [c addSubview:label(@"Preset", NSMakeRect(20, top - 244, 50, 18), 11, NO)];
    NSArray *presets = @[@"Edge to Edge", @"Control Strip", @"Strip Expanded"];
    CGFloat px = 80;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSButton *b = [NSButton buttonWithTitle:presets[i] target:self action:@selector(applyFitPreset:)];
        b.bezelStyle = NSBezelStyleRounded; b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:11]; b.tag = (NSInteger)i;
        [b sizeToFit]; NSRect bf = b.frame; bf.origin = NSMakePoint(px, top - 248); b.frame = bf;
        [c addSubview:b]; px += bf.size.width + 8;
    }
    [c addSubview:help(@"Edge to Edge = use everything · Control Strip = clear the collapsed strip\n(default) · Strip Expanded = clear the expanded strip.",
                       NSMakeRect(20, top - 286, W - 40, 32))];

    // Tiles — per-tile arrangement lives in the editor.
    [self section:@"Tiles" in:c at:top - 314];
    NSButton *arrange = [NSButton buttonWithTitle:@"Arrange & Resize Tiles…" target:self action:@selector(editLayout:)];
    arrange.frame = NSMakeRect(20, top - 348, 190, 26); arrange.bezelStyle = NSBezelStyleRounded; [c addSubview:arrange];
    [c addSubview:help(@"Tip: long-press the active mode pill on the bar to drag-reorder tiles in place.",
                       NSMakeRect(20, top - 370, W - 40, 16))];
    return it;
}

// Configure which modifier key triggers peek / overlay, with conflict detection.
- (NSTabViewItem *)shortcutsTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"shortcuts"];
    it.label = @"Shortcuts";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    [self section:@"Modifier shortcuts" in:c at:top - 22];
    _shortcutsEnable = [NSButton checkboxWithTitle:@"Enable modifier-key shortcuts  (requires Accessibility permission)"
                                            target:self action:@selector(shortcutsEnableChanged:)];
    _shortcutsEnable.frame = NSMakeRect(20, top - 52, W - 40, 20); [c addSubview:_shortcutsEnable];
    [c addSubview:help(@"Hold a modifier key to trigger a bar action from any app. macOS will prompt\nfor Accessibility on first use; grant it in System Settings → Privacy.",
                       NSMakeRect(40, top - 88, W - 60, 32))];

    NSArray *modLabels = @[@"⌃  Control", @"⌥  Option", @"⌘  Command", @"Off"];

    [self section:@"Peek previous mode" in:c at:top - 116];
    [c addSubview:help(@"Hold this key to glance at your last mode; release to snap back.", NSMakeRect(20, top - 152, W - 40, 16))];
    _peekSeg = [NSSegmentedControl segmentedControlWithLabels:modLabels
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                       target:self action:@selector(peekModChanged:)];
    _peekSeg.frame = NSMakeRect(20, top - 178, 360, 24); [c addSubview:_peekSeg];

    [self section:@"App actions overlay" in:c at:top - 210];
    [c addSubview:help(@"Hold this key for quick hide/quit actions on the frontmost app.", NSMakeRect(20, top - 246, W - 40, 16))];
    _overlaySeg = [NSSegmentedControl segmentedControlWithLabels:modLabels
                                                    trackingMode:NSSegmentSwitchTrackingSelectOne
                                                          target:self action:@selector(overlayModChanged:)];
    _overlaySeg.frame = NSMakeRect(20, top - 272, 360, 24); [c addSubview:_overlaySeg];

    // Conflict / warning label — shown only when a conflict or ⌘ is detected.
    _shortcutConflictLabel = [NSTextField labelWithString:@""];
    _shortcutConflictLabel.frame = NSMakeRect(20, top - 308, W - 40, 32);
    _shortcutConflictLabel.font = [NSFont systemFontOfSize:11];
    _shortcutConflictLabel.textColor = [NSColor systemRedColor];
    _shortcutConflictLabel.maximumNumberOfLines = 2;
    _shortcutConflictLabel.hidden = YES;
    [c addSubview:_shortcutConflictLabel];

    [self section:@"Menu keyboard shortcuts" in:c at:top - 330];
    [c addSubview:help(@"These are fixed macOS menu-bar shortcuts.", NSMakeRect(20, top - 350, W - 40, 16))];
    NSArray *refs = @[@"⌘ A  —  Ask the Agent…", @"⌘ ,  —  Settings…", @"⌘ Q  —  Quit PulseBar"];
    CGFloat ry = top - 372;
    for (NSString *r in refs) {
        [c addSubview:label(r, NSMakeRect(20, ry, W - 40, 16), 11, NO)];
        ry -= 18;
    }
    return it;
}

- (void)shortcutsEnableChanged:(NSButton *)b {
    [_delegate settingsSetModifiers:(b.state == NSControlStateValueOn)];
}
- (void)peekModChanged:(NSSegmentedControl *)s {
    [_delegate settingsSetShortcutPeekMod:s.selectedSegment];
    [self updateShortcutConflict];
}
- (void)overlayModChanged:(NSSegmentedControl *)s {
    [_delegate settingsSetShortcutOverlayMod:s.selectedSegment];
    [self updateShortcutConflict];
}
- (void)updateShortcutConflict {
    NSInteger pi = _peekSeg.selectedSegment, oi = _overlaySeg.selectedSegment;
    NSString *msg = nil;
    if (pi != 3 && oi != 3 && pi == oi)
        msg = @"⚠️  Both shortcuts share the same modifier — they'll both fire at once. Pick different keys.";
    else if (pi == 2 || oi == 2)
        msg = @"⚠️  ⌘ Command is heavily used by macOS; system shortcuts may interfere. Consider ⌃ or ⌥ instead.";
    _shortcutConflictLabel.stringValue = msg ?: @"";
    _shortcutConflictLabel.hidden = (msg == nil);
}

// Auto-switch the bar's mode per frontmost app (off by default).
- (NSTabViewItem *)modesTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"modes"];
    it.label = @"Auto-Switch";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    [self section:@"Switch mode per app" in:c at:top - 22];
    _autoModeCheck = [NSButton checkboxWithTitle:@"Switch the bar's mode automatically when you change apps"
                                          target:self action:@selector(autoModeToggled:)];
    _autoModeCheck.frame = NSMakeRect(20, top - 52, W - 40, 22); [c addSubview:_autoModeCheck];
    [c addSubview:help(@"Pair an app with a mode below. When that app comes to the front, the bar switches to its\nmode. A manual switch still sticks until you change apps again. Off by default.",
                       NSMakeRect(20, top - 86, W - 40, 32))];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 52, W - 40, top - 150)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder; scroll.autohidesScrollers = YES;
    _rulesHost = [[PBRulesView alloc] initWithFrame:NSMakeRect(0, 0, W - 40, top - 150)];
    scroll.documentView = _rulesHost; [c addSubview:scroll];
    _rulesEmpty = label(@"No rules yet — add an app below.", NSMakeRect(12, top - 184, W - 64, 18), 11, NO);
    _rulesEmpty.textColor = [NSColor secondaryLabelColor]; [_rulesHost addSubview:_rulesEmpty];

    NSButton *add = [NSButton buttonWithTitle:@"Add App Rule…" target:self action:@selector(addAppRule:)];
    add.frame = NSMakeRect(20, 14, 150, 28); add.bezelStyle = NSBezelStyleRounded; [c addSubview:add];
    return it;
}

// Rebuild the rule rows from _rules into the (flipped) list host.
- (void)reloadRules {
    for (NSView *v in [_rulesHost.subviews copy]) if (v != _rulesEmpty) [v removeFromSuperview];
    _rulesEmpty.hidden = (_rules.count > 0);
    CGFloat W = _rulesHost.frame.size.width, rowH = 30;
    _rulesHost.frame = NSMakeRect(0, 0, W, MAX(_rulesHost.superview.bounds.size.height, _rules.count * rowH + 8));
    CGFloat y = 6;
    for (NSInteger i = 0; i < (NSInteger)_rules.count; i++) {
        NSDictionary *r = _rules[i];
        [_rulesHost addSubview:label(r[@"name"] ?: r[@"bundleID"], NSMakeRect(12, y + 6, W - 12 - 230, 18), 12, NO)];

        NSPopUpButton *modePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(W - 220, y + 3, 150, 24)];
        for (NSInteger m = 0; m < BarModeCount; m++) [modePop addItemWithTitle:[BarView nameForMode:m]];
        [modePop selectItemAtIndex:MAX(0, MIN(BarModeCount - 1, [r[@"mode"] integerValue]))];
        modePop.target = self; modePop.action = @selector(ruleModeChanged:); modePop.tag = i;
        [_rulesHost addSubview:modePop];

        NSButton *del = [NSButton buttonWithTitle:@"✕" target:self action:@selector(removeRule:)];
        del.frame = NSMakeRect(W - 56, y + 3, 28, 24); del.bezelStyle = NSBezelStyleRounded; del.tag = i;
        [_rulesHost addSubview:del];
        y += rowH;
    }
}

- (void)autoModeToggled:(NSButton *)b { [_delegate settingsSetAutoModeEnabled:(b.state == NSControlStateValueOn)]; }

- (void)addAppRule:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
    p.allowedFileTypes = @[@"app"]; p.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    p.prompt = @"Add"; p.message = @"Choose an app to pair with a mode";
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    NSString *bid = [NSBundle bundleWithURL:p.URL].bundleIdentifier;
    NSString *name = p.URL.lastPathComponent.stringByDeletingPathExtension;
    if (!bid.length) return;
    for (NSMutableDictionary *r in _rules) if ([r[@"bundleID"] isEqualToString:bid]) return;   // dedup
    [_rules addObject:[@{ @"bundleID": bid, @"name": name, @"mode": @(0) } mutableCopy]];
    [_delegate settingsSetAutoModeRules:_rules];
    [self reloadRules];
}

- (void)ruleModeChanged:(NSPopUpButton *)p {
    if (p.tag < 0 || p.tag >= (NSInteger)_rules.count) return;
    _rules[p.tag][@"mode"] = @(p.indexOfSelectedItem);
    [_delegate settingsSetAutoModeRules:_rules];
}

- (void)removeRule:(NSButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)_rules.count) return;
    [_rules removeObjectAtIndex:b.tag];
    [_delegate settingsSetAutoModeRules:_rules];
    [self reloadRules];
}

- (NSTabViewItem *)focusTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"focus"];
    it.label = @"Focus";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height;

    [self section:@"Pomodoro" in:c at:top - 22];
    [c addSubview:label(@"Work", NSMakeRect(20, top - 50, 50, 18), 11, NO)];
    _workStep = [[NSStepper alloc] initWithFrame:NSMakeRect(110, top - 52, 20, 24)];
    _workStep.minValue = 1; _workStep.maxValue = 120; _workStep.increment = 1;
    _workStep.target = self; _workStep.action = @selector(changeWork:); [c addSubview:_workStep];
    _workVal = label(@"25 min", NSMakeRect(135, top - 50, 90, 18), 11, NO); [c addSubview:_workVal];

    [c addSubview:label(@"Break", NSMakeRect(20, top - 76, 50, 18), 11, NO)];
    _breakStep = [[NSStepper alloc] initWithFrame:NSMakeRect(110, top - 78, 20, 24)];
    _breakStep.minValue = 1; _breakStep.maxValue = 60; _breakStep.increment = 1;
    _breakStep.target = self; _breakStep.action = @selector(changeBreak:); [c addSubview:_breakStep];
    _breakVal = label(@"5 min", NSMakeRect(135, top - 76, 90, 18), 11, NO); [c addSubview:_breakVal];

    _adaptive = [NSButton checkboxWithTitle:@"Adaptive focus length (grows with your session)"
                                     target:self action:@selector(toggleAdaptive:)];
    _adaptive.frame = NSMakeRect(20, top - 104, kW - 60, 20); [c addSubview:_adaptive];
    [c addSubview:help(@"While idle, the suggested focus block lengthens the longer you've\nbeen working. Setting Work manually turns this off.",
                       NSMakeRect(40, top - 140, kW - 80, 32))];

    [self section:@"Break reminder" in:c at:top - 172];
    [c addSubview:label(@"Remind me after", NSMakeRect(20, top - 200, 110, 18), 11, NO)];
    _breakReminderStep = [[NSStepper alloc] initWithFrame:NSMakeRect(135, top - 202, 20, 24)];
    _breakReminderStep.minValue = 5; _breakReminderStep.maxValue = 240; _breakReminderStep.increment = 5;
    _breakReminderStep.target = self; _breakReminderStep.action = @selector(changeBreakReminder:);
    [c addSubview:_breakReminderStep];
    _breakReminderVal = label(@"80 min", NSMakeRect(160, top - 200, 90, 18), 11, NO); [c addSubview:_breakReminderVal];
    [c addSubview:help(@"After this much unbroken work, the bar shows a full-width nudge to\ntake a break. It can't be muted and repeats every 15 min until you stop.",
                       NSMakeRect(20, top - 240, kW - 40, 32))];
    return it;
}

- (NSTabViewItem *)agentTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"agent"];
    it.label = @"Agent";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    [self section:@"Model" in:c at:top - 22];
    [c addSubview:label(@"Active model", NSMakeRect(20, top - 50, 90, 18), 11, NO)];
    _modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(112, top - 53, 220, 26)];
    _modelPopup.target = self; _modelPopup.action = @selector(modelChanged:); [c addSubview:_modelPopup];
    _modelStatus = label(@"checking Ollama…", NSMakeRect(20, top - 78, W - 40, 16), 10, NO);
    _modelStatus.textColor = [NSColor secondaryLabelColor]; [c addSubview:_modelStatus];

    [self section:@"Download a model" in:c at:top - 110];
    _downloadPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, top - 141, 210, 26)];
    for (NSDictionary *m in [PBOllama curatedModels]) {
        NSString *noteStr = [m[@"note"] length] ? [@"  ·  " stringByAppendingString:m[@"note"]] : @"";
        [_downloadPopup addItemWithTitle:[NSString stringWithFormat:@"%@  ·  %@%@", m[@"name"], m[@"size"], noteStr]];
        _downloadPopup.lastItem.representedObject = m[@"tag"];
    }
    [c addSubview:_downloadPopup];
    _downloadBtn = [NSButton buttonWithTitle:@"Download" target:self action:@selector(downloadModel:)];
    _downloadBtn.frame = NSMakeRect(238, top - 142, 100, 28); _downloadBtn.bezelStyle = NSBezelStyleRounded; [c addSubview:_downloadBtn];
    _dlProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, top - 166, W - 40, 12)];
    _dlProgress.style = NSProgressIndicatorStyleBar; _dlProgress.indeterminate = NO;
    _dlProgress.minValue = 0; _dlProgress.maxValue = 1; _dlProgress.hidden = YES; [c addSubview:_dlProgress];
    _dlStatus = label(@"", NSMakeRect(20, top - 184, W - 40, 16), 10, NO);
    _dlStatus.textColor = [NSColor secondaryLabelColor]; [c addSubview:_dlStatus];
    [c addSubview:help(@"Models run locally via Ollama — on-device & private. Downloads are several GB.",
                       NSMakeRect(20, top - 202, W - 40, 16))];

    [self section:@"Session" in:c at:top - 232];
    [c addSubview:label(@"New dialogue after", NSMakeRect(20, top - 260, 120, 18), 11, NO)];
    _agentTimeoutStep = [[NSStepper alloc] initWithFrame:NSMakeRect(145, top - 262, 20, 24)];
    _agentTimeoutStep.minValue = 0; _agentTimeoutStep.maxValue = 120; _agentTimeoutStep.increment = 1;
    _agentTimeoutStep.target = self; _agentTimeoutStep.action = @selector(changeAgentTimeout:); [c addSubview:_agentTimeoutStep];
    _agentTimeoutVal = label(@"5 min idle", NSMakeRect(170, top - 260, 150, 18), 11, NO); [c addSubview:_agentTimeoutVal];
    [c addSubview:help(@"Forget the conversation after this much inactivity (0 = never).",
                       NSMakeRect(20, top - 282, W - 40, 16))];
    return it;
}

- (void)refreshModels {
    NSString *active = [_delegate settingsAgentModel];
    [PBOllama listInstalled:^(NSArray<NSString *> *names, BOOL up) {
        [self->_modelPopup removeAllItems];
        if (!up) {
            self->_modelStatus.stringValue = @"⚠︎ Ollama not running"; self->_modelStatus.textColor = [NSColor systemOrangeColor];
            [self->_modelPopup addItemWithTitle:active]; return;
        }
        NSArray *sorted = [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSString *n in sorted) [self->_modelPopup addItemWithTitle:n];
        if ([sorted containsObject:active]) [self->_modelPopup selectItemWithTitle:active];
        else { [self->_modelPopup insertItemWithTitle:active atIndex:0]; [self->_modelPopup selectItemAtIndex:0]; }
        self->_modelStatus.stringValue = [NSString stringWithFormat:@"● %lu model%@ installed · on-device",
                                          (unsigned long)sorted.count, sorted.count == 1 ? @"" : @"s"];
        self->_modelStatus.textColor = [NSColor systemGreenColor];
    }];
}
- (void)modelChanged:(NSPopUpButton *)p { if (p.titleOfSelectedItem.length) [_delegate settingsSetAgentModel:p.titleOfSelectedItem]; }
- (void)downloadModel:(id)s {
    NSString *tag = _downloadPopup.selectedItem.representedObject;
    if (!tag.length || _pull) return;
    _downloadBtn.enabled = NO; _downloadPopup.enabled = NO;
    _dlProgress.hidden = NO; _dlProgress.doubleValue = 0;
    _dlStatus.stringValue = [NSString stringWithFormat:@"Starting %@…", tag];
    _pull = [PBOllama new];
    [_pull pull:tag onProgress:^(double frac, NSString *status) {
        self->_dlProgress.doubleValue = frac;
        self->_dlStatus.stringValue = frac > 0 ? [NSString stringWithFormat:@"Downloading %@ — %.0f%%", tag, frac * 100] : (status ?: @"");
    } done:^(BOOL ok, NSString *err) {
        self->_downloadBtn.enabled = YES; self->_downloadPopup.enabled = YES; self->_dlProgress.hidden = YES; self->_pull = nil;
        if (ok) { self->_dlStatus.stringValue = [NSString stringWithFormat:@"✓ %@ ready — now active", tag];
                  [self->_delegate settingsSetAgentModel:tag]; [self refreshModels]; }
        else     self->_dlStatus.stringValue = [NSString stringWithFormat:@"⚠︎ %@", err ?: @"download failed"];
    }];
}
- (void)changeAgentTimeout:(NSStepper *)s {
    NSInteger m = s.integerValue;
    _agentTimeoutVal.stringValue = m <= 0 ? @"never" : [NSString stringWithFormat:@"%ld min idle", (long)m];
    [_delegate settingsSetAgentTimeoutMinutes:m];
}

- (NSTabViewItem *)notesTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"notes"];
    it.label = @"Notes";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    [self section:@"Side-notes" in:c at:top - 22];
    _notesCount = label(@"", NSMakeRect(20, top - 44, W - 40, 16), 10, NO);
    _notesCount.textColor = [NSColor secondaryLabelColor]; [c addSubview:_notesCount];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 44, W - 40, top - 96)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
    scroll.autohidesScrollers = YES;
    _notesView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    _notesView.editable = NO; _notesView.richText = YES;
    _notesView.textContainerInset = NSMakeSize(8, 8);
    _notesView.font = [NSFont systemFontOfSize:11];
    scroll.documentView = _notesView;
    [c addSubview:scroll];

    NSButton *exportB = [NSButton buttonWithTitle:@"Export CSV…" target:self action:@selector(exportNotes:)];
    exportB.frame = NSMakeRect(20, 10, 120, 26); exportB.bezelStyle = NSBezelStyleRounded; [c addSubview:exportB];
    NSButton *refreshB = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(reloadNotes)];
    refreshB.frame = NSMakeRect(148, 10, 88, 26); refreshB.bezelStyle = NSBezelStyleRounded; [c addSubview:refreshB];
    return it;
}

#pragma mark - present / sync

- (void)present {
    [self syncFromDelegate];
    [self reloadNotes];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)presentTab:(NSString *)identifier {
    [self present];
    if (identifier) [_tabs selectTabViewItemWithIdentifier:identifier];
}

- (void)syncFromDelegate {
    _fullBar.state  = [_delegate settingsFullBarEnabled]   ? NSControlStateValueOn : NSControlStateValueOff;
    _mirror.state   = [_delegate settingsMirrorVisible]    ? NSControlStateValueOn : NSControlStateValueOff;
    _login.state    = [_delegate settingsLoginEnabled]     ? NSControlStateValueOn : NSControlStateValueOff;
    _shortcutsEnable.state = [_delegate settingsModifiersEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _peekSeg.selectedSegment    = [_delegate settingsShortcutPeekMod];
    _overlaySeg.selectedSegment = [_delegate settingsShortcutOverlayMod];
    [self updateShortcutConflict];
    _topProc.state  = [_delegate settingsTopProcEnabled]   ? NSControlStateValueOn : NSControlStateValueOff;
    _adaptive.state = [_delegate settingsAdaptiveLength]   ? NSControlStateValueOn : NSControlStateValueOff;
    NSInteger wm = [_delegate settingsWorkMinutes], bm = [_delegate settingsBreakMinutes], rm = [_delegate settingsBreakReminderMinutes];
    _workStep.integerValue = wm; _breakStep.integerValue = bm; _breakReminderStep.integerValue = rm;
    _workVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)wm];
    _breakVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)bm];
    _breakReminderVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)rm];
    _mediaField.stringValue = [_delegate settingsMediaApp] ?: @"";
    CGFloat sl = [_delegate settingsSafeLeft], sr = [_delegate settingsSafeRight];
    _leftSlider.doubleValue = sl; _rightSlider.doubleValue = sr;
    _leftVal.stringValue  = [NSString stringWithFormat:@"%ld px", (long)lround(sl)];
    _rightVal.stringValue = [NSString stringWithFormat:@"%ld px", (long)lround(sr)];
    _densitySeg.selectedSegment = [_delegate settingsDensity];   // PBDensity ordinals match segment order
    _collapseTabs.state = [_delegate settingsTabsCollapsed] ? NSControlStateValueOn : NSControlStateValueOff;
    _autoModeCheck.state = [_delegate settingsAutoModeEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _rules = [NSMutableArray array];
    for (NSDictionary *r in [_delegate settingsAutoModeRules]) [_rules addObject:[r mutableCopy]];
    [self reloadRules];
    NSInteger atm = [_delegate settingsAgentTimeoutMinutes];
    _agentTimeoutStep.integerValue = atm;
    _agentTimeoutVal.stringValue = atm <= 0 ? @"never" : [NSString stringWithFormat:@"%ld min idle", (long)atm];
    [self refreshModels];
}

#pragma mark - notes history

- (void)reloadNotes {
    NSString *raw = [NSString stringWithContentsOfFile:[PBVoiceNotes notesFile] encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSDictionary *> *notes = [NSMutableArray array];
    for (NSString *line in [(raw ?: @"") componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class]) [notes addObject:j];
    }
    _notesCount.stringValue = notes.count
        ? [NSString stringWithFormat:@"%lu note%@ · newest first", (unsigned long)notes.count, notes.count == 1 ? @"" : @"s"]
        : @"No side-notes yet.";

    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"EEE d MMM · HH:mm"; }
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSDictionary *tsAttr = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightSemibold],
                              NSForegroundColorAttributeName: [NSColor secondaryLabelColor] };
    NSDictionary *txtAttr = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                               NSForegroundColorAttributeName: [NSColor labelColor] };
    for (NSDictionary *n in [notes reverseObjectEnumerator]) {
        NSString *when = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[n[@"ts"] doubleValue]]];
        NSString *text = [n[@"text"] isKindOfClass:NSString.class] ? n[@"text"] : @"";
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[when stringByAppendingString:@"\n"] attributes:tsAttr]];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text stringByAppendingString:@"\n\n"] attributes:txtAttr]];
    }
    if (!notes.count)
        out = [[NSMutableAttributedString alloc] initWithString:@"\nHold the NOTE tile in Focus mode and speak to capture a hands-free side-note. It's stored locally and shows up here." attributes:txtAttr];
    [_notesView.textStorage setAttributedString:out];
}

- (void)exportNotes:(id)s {
    NSString *path = [PBVoiceNotes exportCSV];
    if (path) [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:PBLogDirectory()];
    else {
        NSAlert *a = [NSAlert new];
        a.messageText = @"No side-notes to export";
        a.informativeText = @"Hold the NOTE tile in Focus mode and speak to capture a side-note first.";
        [a beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

#pragma mark - actions

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if (n.object == _mediaField) [_delegate settingsSetMediaApp:_mediaField.stringValue];
}
- (void)toggleFullBar:(NSButton *)b { [_delegate settingsSetFullBar:(b.state == NSControlStateValueOn)]; }
- (void)toggleMirror:(NSButton *)b  { [_delegate settingsSetMirror:(b.state == NSControlStateValueOn)]; }
- (void)toggleLogin:(NSButton *)b   { [_delegate settingsSetLogin:(b.state == NSControlStateValueOn)]; [self syncFromDelegate]; }
- (void)toggleTopProc:(NSButton *)b { [_delegate settingsSetTopProc:(b.state == NSControlStateValueOn)]; }
- (void)toggleAdaptive:(NSButton *)b { [_delegate settingsSetAdaptive:(b.state == NSControlStateValueOn)]; }
- (void)changeWork:(NSStepper *)s {
    _workVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)s.integerValue];
    [_delegate settingsSetWork:s.integerValue breakMin:_breakStep.integerValue];
    _adaptive.state = [_delegate settingsAdaptiveLength] ? NSControlStateValueOn : NSControlStateValueOff;   // manual Work turns adaptive off
}
- (void)changeBreak:(NSStepper *)s {
    _breakVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)s.integerValue];
    [_delegate settingsSetWork:_workStep.integerValue breakMin:s.integerValue];
}
- (void)changeBreakReminder:(NSStepper *)s {
    _breakReminderVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)s.integerValue];
    [_delegate settingsSetBreakReminderMinutes:s.integerValue];
}
- (void)changeLeft:(NSSlider *)s {
    _leftVal.stringValue = [NSString stringWithFormat:@"%ld px", (long)lround(s.doubleValue)];
    [_delegate settingsSetSafeLeft:(CGFloat)s.doubleValue];
}
- (void)changeRight:(NSSlider *)s {
    _rightVal.stringValue = [NSString stringWithFormat:@"%ld px", (long)lround(s.doubleValue)];
    [_delegate settingsSetSafeRight:(CGFloat)s.doubleValue];
}
// Fit presets: insets only — density is orthogonal and never touched here.
- (void)applyFitPreset:(NSButton *)b {
    CGFloat l = 0, r = PBDefaultSafeRight;             // tag 1 "Control Strip" (the default)
    if (b.tag == 0)      { l = 0; r = 0;   }           // "Edge to Edge"
    else if (b.tag == 2) { l = 0; r = 232; }           // "Strip Expanded"
    _leftSlider.doubleValue = l; _rightSlider.doubleValue = r;
    [self changeLeft:_leftSlider]; [self changeRight:_rightSlider];
}
- (void)densityChanged:(NSSegmentedControl *)s { [_delegate settingsSetDensity:s.selectedSegment]; }
- (void)collapseTabsChanged:(NSButton *)b { [_delegate settingsSetTabsCollapsed:(b.state == NSControlStateValueOn)]; }
- (void)editLayout:(id)s { [_delegate settingsEditLayout]; }
- (void)doQuit:(id)s { [_delegate settingsQuit]; }

@end
