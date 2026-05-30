//
//  LayoutEditorWindowController.m
//
#import "LayoutEditorWindowController.h"
#import "BarView.h"
#import "Pomodoro.h"
#import "PreviewData.h"

static const CGFloat kWinW = 772, kWinH = 452;

// Column x-origins (and widths), shared by the headers and the per-row controls
// so they always line up: Tile · Show · Size · Min · Priority · ▲▼.
static const CGFloat kColTile  = 20;
static const CGFloat kColShow  = 138;
static const CGFloat kColSize  = 186;   // slider, width kSliderW
static const CGFloat kColMin   = 320;   // slider, width kSliderW
static const CGFloat kColPrio  = 454;   // slider, width kSliderW
static const CGFloat kColPrioV = 590;   // numeric priority value
static const CGFloat kColUp    = 624;   // ▲
static const CGFloat kColDown  = 660;   // ▼
static const CGFloat kSliderW  = 120;
static const CGFloat kArrowW   = 28;

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
    NSMutableArray<NSSlider *>    *_minSliders;
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
        _minSliders = [NSMutableArray array];
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

    [c addSubview:lbl(@"Drag Size/Min to resize a tile, toggle Show to hide it, lower Priority so it drops first when space is tight, or use ▲/▼ to reorder.",
                      NSMakeRect(20, top - 116, kWinW - 40, 18), 10, YES)];

    // Column headers — aligned to the per-row control columns.
    CGFloat hy = top - 138;
    [c addSubview:lbl(@"Tile",     NSMakeRect(kColTile, hy, 100,      16), 10, YES)];
    [c addSubview:lbl(@"Show",     NSMakeRect(kColShow, hy, 40,       16), 10, YES)];
    [c addSubview:lbl(@"Size",     NSMakeRect(kColSize, hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Min",      NSMakeRect(kColMin,  hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Priority", NSMakeRect(kColPrio, hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Order",    NSMakeRect(kColUp,   hy, 64,       16), 10, YES)];

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
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    // Merge into any existing override so a field we don't touch here (notably
    // @"order", written by the ▲/▼ buttons) is preserved.
    NSMutableDictionary *o = [([ud dictionaryForKey:[self keyFor:type]] ?: @{}) mutableCopy];
    o[@"hidden"] = @(!show);
    o[@"w"]      = @(_sizeSliders[i].doubleValue);
    o[@"prio"]   = @((int)lround(_prioSliders[i].doubleValue));
    o[@"minW"]   = @(lround(_minSliders[i].doubleValue));
    [ud setObject:o forKey:[self keyFor:type]];
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self refreshPreview];
}

#pragma mark - rows

// Effective display order for a tile of `type` in the current mode: the saved
// @"order" override if present, else its natural index within _defaults.
- (NSInteger)orderForType:(NSInteger)type naturalIndex:(NSInteger)natural {
    NSDictionary *o = [NSUserDefaults.standardUserDefaults dictionaryForKey:[self keyFor:type]];
    if (o && o[@"order"]) return [o[@"order"] integerValue];
    return natural;
}

- (void)loadMode {
    for (NSView *v in [_rowsHost.subviews copy]) [v removeFromSuperview];
    [_types removeAllObjects];
    [_showBtns removeAllObjects]; [_sizeSliders removeAllObjects]; [_minSliders removeAllObjects];
    [_prioSliders removeAllObjects]; [_prioVals removeAllObjects];

    _defaults = [BarView defaultLayoutForMode:_mode];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    // Build the row order: indices into _defaults sorted by effective display
    // order (stable; ties keep natural order), mirroring the renderer's sort.
    NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:_defaults.count];
    for (NSInteger i = 0; i < (NSInteger)_defaults.count; i++) [idx addObject:@(i)];
    [idx sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSDictionary *da = _defaults[a.integerValue], *db = _defaults[b.integerValue];
        NSInteger oa = [self orderForType:[da[@"type"] integerValue] naturalIndex:a.integerValue];
        NSInteger ob = [self orderForType:[db[@"type"] integerValue] naturalIndex:b.integerValue];
        if (oa < ob) return NSOrderedAscending;
        if (oa > ob) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    CGFloat rowH = 30, y = _rowsHost.bounds.size.height - rowH;

    for (NSInteger row = 0; row < (NSInteger)idx.count; row++) {
        NSDictionary *d = _defaults[idx[row].integerValue];
        NSInteger type = [d[@"type"] integerValue];
        [_types addObject:@(type)];
        NSDictionary *o = [ud dictionaryForKey:[self keyFor:type]];

        BOOL show   = o[@"hidden"] ? ![o[@"hidden"] boolValue] : YES;
        double wt   = o[@"w"]    ? [o[@"w"] doubleValue]    : [d[@"weight"] doubleValue];
        double prio = o[@"prio"] ? [o[@"prio"] doubleValue] : [d[@"prio"] doubleValue];
        double minW = o[@"minW"] ? [o[@"minW"] doubleValue] : [d[@"minW"] doubleValue];

        [_rowsHost addSubview:lbl(d[@"name"], NSMakeRect(kColTile, y + 6, 110, 18), 12, NO)];

        NSButton *show2 = [NSButton checkboxWithTitle:@"" target:self action:@selector(rowChanged:)];
        show2.frame = NSMakeRect(kColShow, y + 5, 40, 20); show2.tag = row;
        show2.state = show ? NSControlStateValueOn : NSControlStateValueOff;
        [_rowsHost addSubview:show2]; [_showBtns addObject:show2];

        NSSlider *size = [[NSSlider alloc] initWithFrame:NSMakeRect(kColSize, y + 5, kSliderW, 20)];
        size.minValue = 0.3; size.maxValue = 3.0; size.doubleValue = wt; size.tag = row;
        size.target = self; size.action = @selector(rowChanged:);
        [_rowsHost addSubview:size]; [_sizeSliders addObject:size];

        NSSlider *mn = [[NSSlider alloc] initWithFrame:NSMakeRect(kColMin, y + 5, kSliderW, 20)];
        mn.minValue = 24; mn.maxValue = 160; mn.doubleValue = minW; mn.tag = row;
        mn.target = self; mn.action = @selector(rowChanged:);
        [_rowsHost addSubview:mn]; [_minSliders addObject:mn];

        NSSlider *pr = [[NSSlider alloc] initWithFrame:NSMakeRect(kColPrio, y + 5, kSliderW, 20)];
        pr.minValue = 0; pr.maxValue = 100; pr.doubleValue = prio; pr.tag = row;
        pr.target = self; pr.action = @selector(rowChanged:);
        [_rowsHost addSubview:pr]; [_prioSliders addObject:pr];

        NSTextField *pv = lbl([NSString stringWithFormat:@"%d", (int)lround(prio)], NSMakeRect(kColPrioV, y + 6, 30, 18), 11, YES);
        [_rowsHost addSubview:pv]; [_prioVals addObject:pv];

        NSButton *up = [NSButton buttonWithTitle:@"▲" target:self action:@selector(moveUp:)];
        up.frame = NSMakeRect(kColUp, y + 4, kArrowW, 22); up.tag = row;
        up.bezelStyle = NSBezelStyleRounded; up.enabled = (row > 0);
        [_rowsHost addSubview:up];

        NSButton *down = [NSButton buttonWithTitle:@"▼" target:self action:@selector(moveDown:)];
        down.frame = NSMakeRect(kColDown, y + 4, kArrowW, 22); down.tag = row;
        down.bezelStyle = NSBezelStyleRounded; down.enabled = (row < (NSInteger)idx.count - 1);
        [_rowsHost addSubview:down];

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

- (void)moveUp:(NSButton *)sender   { [self moveRow:sender.tag by:-1]; }
- (void)moveDown:(NSButton *)sender { [self moveRow:sender.tag by:+1]; }

// Move the tile at display row `i` one step (delta -1 = up/left, +1 = down/right),
// then persist a dense @"order" 0..n-1 to every tile in the mode (merged so
// weight/prio/hidden/minW survive), and rebuild the rows + preview.
- (void)moveRow:(NSInteger)i by:(NSInteger)delta {
    NSInteger j = i + delta;
    if (i < 0 || i >= (NSInteger)_types.count || j < 0 || j >= (NSInteger)_types.count) return;

    // Current visual order is the row order (_types); swap the two neighbours.
    NSMutableArray<NSNumber *> *order = [_types mutableCopy];
    NSNumber *tmp = order[i]; order[i] = order[j]; order[j] = tmp;

    // Write a dense order index to each tile's (merged) override dict.
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSInteger pos = 0; pos < (NSInteger)order.count; pos++) {
        NSInteger type = order[pos].integerValue;
        NSString *key = [self keyFor:type];
        NSMutableDictionary *o = [([ud dictionaryForKey:key] ?: @{}) mutableCopy];
        o[@"order"] = @(pos);
        [ud setObject:o forKey:key];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
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
