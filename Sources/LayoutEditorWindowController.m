//
//  LayoutEditorWindowController.m
//
#import "LayoutEditorWindowController.h"
#import "BarView.h"
#import "Pomodoro.h"
#import "PreviewData.h"

static const CGFloat kWinW = 600, kWinH = 420;

@implementation LayoutEditorWindowController {
    NSPopUpButton *_modePop;
    NSSlider      *_widthSlider;
    NSTextField   *_widthVal;
    NSImageView   *_preview;
    NSView        *_rowsHost;
    NSInteger      _mode;

    BarView       *_renderBar;     // offscreen, reused to render the preview image
    Pomodoro      *_pomo;

    NSMutableArray<NSNumber *>    *_types;       // TileType per row, in display order
    NSArray<NSDictionary *>       *_defaults;    // built-in specs for the current mode
    NSMutableArray<NSButton *>    *_showBtns;
    NSMutableArray<NSSlider *>    *_sizeSliders;
    NSMutableArray<NSSlider *>    *_prioSliders;
    NSMutableArray<NSTextField *> *_prioVals;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWinW, kWinH)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Customize Touch Bar Layout";
    w.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:w])) {
        _mode = BarModeSystem;
        _types = [NSMutableArray array];
        _showBtns = [NSMutableArray array]; _sizeSliders = [NSMutableArray array];
        _prioSliders = [NSMutableArray array]; _prioVals = [NSMutableArray array];
        _renderBar = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, 30)];
        _renderBar.animateModeSwitch = NO;
        _pomo = [Pomodoro new]; [_pomo toggle];
        _renderBar.pomodoro = _pomo; _renderBar.caffeinated = YES;
        _renderBar.uptime = 3 * 86400 + 4 * 3600 + 600;
        PBFeedSample(_renderBar, 60);   // one-time fill; data persists across refreshes
        [self build];
    }
    return self;
}

static NSTextField *lbl(NSString *s, NSRect f, CGFloat sz, BOOL secondary) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.frame = f; t.font = [NSFont systemFontOfSize:sz];
    if (secondary) t.textColor = [NSColor secondaryLabelColor];
    return t;
}

- (void)build {
    NSView *c = self.window.contentView;
    CGFloat top = kWinH;

    [c addSubview:lbl(@"Mode", NSMakeRect(20, top - 36, 44, 20), 12, YES)];
    _modePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(60, top - 40, 170, 26)];
    for (NSInteger m = 0; m < BarModeCount; m++) [_modePop addItemWithTitle:[BarView nameForMode:m]];
    _modePop.target = self; _modePop.action = @selector(modeChanged:);
    [c addSubview:_modePop];

    [c addSubview:lbl(@"Preview width", NSMakeRect(250, top - 36, 100, 20), 12, YES)];
    _widthSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(350, top - 39, 170, 22)];
    _widthSlider.minValue = 240; _widthSlider.maxValue = 1004; _widthSlider.doubleValue = 1004;
    _widthSlider.target = self; _widthSlider.action = @selector(widthChanged:);
    [c addSubview:_widthSlider];
    _widthVal = lbl(@"1004", NSMakeRect(524, top - 36, 56, 20), 11, YES);
    [c addSubview:_widthVal];

    // Live preview strip (rendered offscreen at true width, scaled to fit).
    NSView *frame = [[NSView alloc] initWithFrame:NSMakeRect(20, top - 92, kWinW - 40, 38)];
    frame.wantsLayer = YES; frame.layer.backgroundColor = [NSColor blackColor].CGColor;
    frame.layer.cornerRadius = 6;
    [c addSubview:frame];
    _preview = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 4, kWinW - 48, 30)];
    _preview.imageScaling = NSImageScaleProportionallyDown;
    _preview.imageAlignment = NSImageAlignLeft;
    [frame addSubview:_preview];

    [c addSubview:lbl(@"Drag a tile's size, toggle Show to hide it, or lower its priority so it drops first when space is tight.",
                      NSMakeRect(20, top - 116, kWinW - 40, 18), 10, YES)];

    // Column headers
    CGFloat hy = top - 138;
    [c addSubview:lbl(@"Tile",     NSMakeRect(20,  hy, 100, 16), 10, YES)];
    [c addSubview:lbl(@"Show",     NSMakeRect(128, hy, 56,  16), 10, YES)];
    [c addSubview:lbl(@"Size",     NSMakeRect(196, hy, 120, 16), 10, YES)];
    [c addSubview:lbl(@"Priority", NSMakeRect(360, hy, 120, 16), 10, YES)];

    _rowsHost = [[NSView alloc] initWithFrame:NSMakeRect(0, 56, kWinW, hy - 56)];
    [c addSubview:_rowsHost];

    NSButton *reset = [NSButton buttonWithTitle:@"Reset this mode" target:self action:@selector(resetMode:)];
    reset.frame = NSMakeRect(20, 16, 150, 30); reset.bezelStyle = NSBezelStyleRounded;
    [c addSubview:reset];
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(closeWin:)];
    done.frame = NSMakeRect(kWinW - 120, 16, 100, 30); done.bezelStyle = NSBezelStyleRounded;
    done.keyEquivalent = @"\r";
    [c addSubview:done];

    [self loadMode];
}

- (void)present {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self refreshPreview];
}

#pragma mark - persistence

- (NSString *)keyFor:(NSInteger)type { return [BarView overrideKeyForMode:_mode type:type]; }

- (void)writeRow:(NSInteger)i {
    NSInteger type = _types[i].integerValue;
    BOOL show = _showBtns[i].state == NSControlStateValueOn;
    NSDictionary *o = @{ @"hidden": @(!show),
                         @"w":      @(_sizeSliders[i].doubleValue),
                         @"prio":   @((int)lround(_prioSliders[i].doubleValue)) };
    [NSUserDefaults.standardUserDefaults setObject:o forKey:[self keyFor:type]];
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self refreshPreview];
}

#pragma mark - rows

- (void)loadMode {
    for (NSView *v in [_rowsHost.subviews copy]) [v removeFromSuperview];
    [_types removeAllObjects];
    [_showBtns removeAllObjects]; [_sizeSliders removeAllObjects];
    [_prioSliders removeAllObjects]; [_prioVals removeAllObjects];

    _defaults = [BarView defaultLayoutForMode:_mode];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    CGFloat rowH = 30, y = _rowsHost.bounds.size.height - rowH;

    for (NSInteger i = 0; i < (NSInteger)_defaults.count; i++) {
        NSDictionary *d = _defaults[i];
        NSInteger type = [d[@"type"] integerValue];
        [_types addObject:@(type)];
        NSDictionary *o = [ud dictionaryForKey:[self keyFor:type]];

        BOOL show   = o[@"hidden"] ? ![o[@"hidden"] boolValue] : YES;
        double wt   = o[@"w"]    ? [o[@"w"] doubleValue]   : [d[@"weight"] doubleValue];
        double prio = o[@"prio"] ? [o[@"prio"] doubleValue]: [d[@"prio"] doubleValue];

        [_rowsHost addSubview:lbl(d[@"name"], NSMakeRect(20, y + 6, 100, 18), 12, NO)];

        NSButton *show2 = [NSButton checkboxWithTitle:@"" target:self action:@selector(rowChanged:)];
        show2.frame = NSMakeRect(138, y + 5, 40, 20); show2.tag = i;
        show2.state = show ? NSControlStateValueOn : NSControlStateValueOff;
        [_rowsHost addSubview:show2]; [_showBtns addObject:show2];

        NSSlider *size = [[NSSlider alloc] initWithFrame:NSMakeRect(196, y + 5, 150, 20)];
        size.minValue = 0.3; size.maxValue = 3.0; size.doubleValue = wt; size.tag = i;
        size.target = self; size.action = @selector(rowChanged:);
        [_rowsHost addSubview:size]; [_sizeSliders addObject:size];

        NSSlider *pr = [[NSSlider alloc] initWithFrame:NSMakeRect(360, y + 5, 150, 20)];
        pr.minValue = 0; pr.maxValue = 100; pr.doubleValue = prio; pr.tag = i;
        pr.target = self; pr.action = @selector(rowChanged:);
        [_rowsHost addSubview:pr]; [_prioSliders addObject:pr];

        NSTextField *pv = lbl([NSString stringWithFormat:@"%d", (int)lround(prio)], NSMakeRect(516, y + 6, 36, 18), 11, YES);
        [_rowsHost addSubview:pv]; [_prioVals addObject:pv];

        y -= rowH;
    }
}

#pragma mark - preview

- (void)refreshPreview {
    CGFloat w = lround(_widthSlider.doubleValue);
    _renderBar.frame = NSMakeRect(0, 0, w, 30);
    [_renderBar setMode:_mode animated:NO];
    NSImage *img = [[NSImage alloc] initWithData:[_renderBar dataWithPDFInsideRect:_renderBar.bounds]];
    _preview.image = img;
}

#pragma mark - actions

- (void)modeChanged:(NSPopUpButton *)p { _mode = p.indexOfSelectedItem; [self loadMode]; [self refreshPreview]; }
- (void)widthChanged:(NSSlider *)s { _widthVal.stringValue = [NSString stringWithFormat:@"%d", (int)lround(s.doubleValue)]; [self refreshPreview]; }
- (void)rowChanged:(NSControl *)sender {
    NSInteger i = sender.tag;
    if (i >= 0 && i < (NSInteger)_prioVals.count)
        _prioVals[i].stringValue = [NSString stringWithFormat:@"%d", (int)lround(_prioSliders[i].doubleValue)];
    [self writeRow:i];
}

- (void)resetMode:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSNumber *t in _types) [ud removeObjectForKey:[self keyFor:t.integerValue]];
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
}

- (void)closeWin:(id)sender { [self close]; }

@end
