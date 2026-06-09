//
//  SettingsWindowController.m — a sectioned, tabbed settings window:
//  General (bar/system/media), Focus (Pomodoro + break reminder), and Notes
//  (the side-note history, with CSV export).
//
#import "SettingsWindowController.h"
#import "VoiceNotes.h"
#import "PBDefaults.h"
#import "PBOllama.h"
#import "Log.h"

@interface SettingsWindowController () <NSTextFieldDelegate>
@end

@implementation SettingsWindowController {
    __weak id<SettingsDelegate> _delegate;
    NSButton   *_fullBar, *_login, *_topProc, *_mirror, *_mods, *_adaptive;
    NSStepper  *_workStep, *_breakStep, *_breakReminderStep;
    NSTextField *_workVal, *_breakVal, *_breakReminderVal, *_mediaField, *_notesCount;
    NSTextView *_notesView;
    NSTabView  *_tabs;
    NSSlider   *_leftSlider, *_rightSlider;
    NSTextField *_leftVal, *_rightVal;
    NSButton   *_compactCheck;
    NSPopUpButton *_modelPopup, *_downloadPopup;
    NSTextField *_modelStatus, *_dlStatus;
    NSButton   *_downloadBtn;
    NSProgressIndicator *_dlProgress;
    NSStepper  *_agentTimeoutStep; NSTextField *_agentTimeoutVal;
    PBOllama   *_pull;
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
    [_tabs addTabViewItem:[self fitTab]];
    [_tabs addTabViewItem:[self focusTab]];
    [_tabs addTabViewItem:[self agentTab]];
    [_tabs addTabViewItem:[self notesTab]];

    NSButton *layout = [NSButton buttonWithTitle:@"Customize layout…" target:self action:@selector(editLayout:)];
    layout.frame = NSMakeRect(16, 10, 160, 28); layout.bezelStyle = NSBezelStyleRounded;
    [c addSubview:layout];

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

    _mods = [NSButton checkboxWithTitle:@"Modifier shortcuts  (⌃ peek previous mode · ⌥ app actions)"
                                 target:self action:@selector(toggleMods:)];
    _mods.frame = NSMakeRect(20, top - 128, kW - 60, 20); [c addSubview:_mods];
    [c addSubview:help(@"Hold ⌃ to glance at your last mode (release to snap back); hold ⌥\nfor quick hide/quit actions on the frontmost app.",
                       NSMakeRect(40, top - 164, kW - 80, 32))];

    [self section:@"System" in:c at:top - 196];
    _topProc = [NSButton checkboxWithTitle:@"Show top CPU process (uses a little more CPU)"
                                    target:self action:@selector(toggleTopProc:)];
    _topProc.frame = NSMakeRect(20, top - 222, kW - 60, 20); [c addSubview:_topProc];
    _login = [NSButton checkboxWithTitle:@"Start PulseBar at login" target:self action:@selector(toggleLogin:)];
    _login.frame = NSMakeRect(20, top - 244, kW - 60, 20); [c addSubview:_login];

    [self section:@"Media" in:c at:top - 276];
    [c addSubview:label(@"Play/pause target", NSMakeRect(20, top - 302, 120, 18), 11, NO)];
    _mediaField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, top - 304, 160, 22)];
    _mediaField.placeholderString = @"Spotify"; _mediaField.delegate = self; [c addSubview:_mediaField];
    [c addSubview:help(@"e.g. Spotify, Music, TV — the app the bar controls in Media mode.",
                       NSMakeRect(20, top - 326, kW - 40, 16))];
    return it;
}

- (NSTabViewItem *)fitTab {
    NSTabViewItem *it = [[NSTabViewItem alloc] initWithIdentifier:@"fit"];
    it.label = @"Fit";
    NSView *c = [self pageView]; it.view = c;
    CGFloat top = c.frame.size.height, W = c.frame.size.width;

    [self section:@"Fit to your Touch Bar" in:c at:top - 22];
    [c addSubview:help(@"Apple's ✕ shifts the bar to the right and its Control Strip can crowd the\nedges. Nudge the active area so every tile — and the agent orb — stays visible.",
                       NSMakeRect(20, top - 64, W - 40, 32))];

    // Right squeeze (the one that brings the agent orb back into view)
    [c addSubview:label(@"Right squeeze", NSMakeRect(20, top - 98, 100, 18), 11, NO)];
    _rightSlider = [NSSlider sliderWithValue:PBDefaultSafeRight minValue:0 maxValue:232 target:self action:@selector(changeRight:)];
    _rightSlider.frame = NSMakeRect(125, top - 100, W - 125 - 66, 20); _rightSlider.continuous = YES;
    [c addSubview:_rightSlider];
    _rightVal = label([NSString stringWithFormat:@"%ld px", (long)PBDefaultSafeRight], NSMakeRect(W - 58, top - 98, 50, 18), 11, NO); [c addSubview:_rightVal];
    [c addSubview:help(@"Clears the system Control Strip on the right (≈110px collapsed, up to ≈232px expanded) so tiles and the agent orb aren't covered.",
                       NSMakeRect(20, top - 120, W - 40, 16))];

    // Left reserve (usually 0 — the shift already clears the ✕)
    [c addSubview:label(@"Left reserve", NSMakeRect(20, top - 152, 100, 18), 11, NO)];
    _leftSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:120 target:self action:@selector(changeLeft:)];
    _leftSlider.frame = NSMakeRect(125, top - 154, W - 125 - 66, 20); _leftSlider.continuous = YES;
    [c addSubview:_leftSlider];
    _leftVal = label(@"0 px", NSMakeRect(W - 58, top - 152, 50, 18), 11, NO); [c addSubview:_leftVal];
    [c addSubview:help(@"Space kept on the left for the ✕ (usually 0 — the shift already clears it).",
                       NSMakeRect(20, top - 174, W - 40, 16))];

    _compactCheck = [NSButton checkboxWithTitle:@"Compact layout — icon-only mode pill & action tiles"
                                         target:self action:@selector(toggleCompact:)];
    _compactCheck.frame = NSMakeRect(20, top - 200, W - 40, 20); [c addSubview:_compactCheck];
    [c addSubview:help(@"Drops text labels so more fits in a tight bar. The active mode shows as a\ncoloured icon; the agent orb always stays visible.",
                       NSMakeRect(40, top - 236, W - 60, 32))];

    NSButton *reset = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetFit:)];
    reset.frame = NSMakeRect(20, top - 274, 90, 26); reset.bezelStyle = NSBezelStyleRounded; [c addSubview:reset];
    [c addSubview:help(@"Tip: open the Desktop Mirror (menu → Show Desktop Mirror) to preview live.",
                       NSMakeRect(118, top - 270, W - 130, 30))];
    return it;
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
    _mods.state     = [_delegate settingsModifiersEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _login.state    = [_delegate settingsLoginEnabled]     ? NSControlStateValueOn : NSControlStateValueOff;
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
    _compactCheck.state = [_delegate settingsCompact] ? NSControlStateValueOn : NSControlStateValueOff;
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
- (void)toggleMods:(NSButton *)b    { [_delegate settingsSetModifiers:(b.state == NSControlStateValueOn)]; }
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
- (void)resetFit:(id)sender {
    _leftSlider.doubleValue = PBDefaultSafeLeft; _rightSlider.doubleValue = PBDefaultSafeRight;
    [self changeLeft:_leftSlider]; [self changeRight:_rightSlider];
}
- (void)toggleCompact:(NSButton *)b { [_delegate settingsSetCompact:(b.state == NSControlStateValueOn)]; }
- (void)editLayout:(id)s { [_delegate settingsEditLayout]; }
- (void)doQuit:(id)s { [_delegate settingsQuit]; }

@end
