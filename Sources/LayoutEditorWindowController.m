//
//  LayoutEditorWindowController.m — per-mode tile editor: size / priority /
//  order, plus add & remove (driving the PBCompose composition layer).
//
#import "LayoutEditorWindowController.h"
#import "BarView.h"
#import "PBClock.h"      // gCities (world-clock palette)
#import "Pomodoro.h"
#import "PreviewData.h"

static const CGFloat kWinW = 812, kWinH = 452;

// Flipped document view so editor rows lay out top→down and the scroll view
// opens at the first row.
@interface PBFlippedView : NSView @end
@implementation PBFlippedView - (BOOL)isFlipped { return YES; } @end

// Column x-origins (and widths), shared by the headers and the per-row controls
// so they always line up: Tile · Show · Size · Min · Priority · ▲▼ · ✕.
static const CGFloat kColTile  = 20;
static const CGFloat kColShow  = 150;
static const CGFloat kColSize  = 196;   // slider, width kSliderW
static const CGFloat kColMin   = 326;   // slider, width kSliderW
static const CGFloat kColPrio  = 456;   // slider, width kSliderW
static const CGFloat kColPrioV = 588;   // numeric priority value
static const CGFloat kColUp    = 620;   // ▲
static const CGFloat kColDown  = 652;   // ▼
static const CGFloat kColDel   = 700;   // ✕ remove
static const CGFloat kSliderW  = 118;
static const CGFloat kArrowW   = 26;

// Simple (non-instanced) tile types the user can add to any mode.
static const TileType kAddable[] = {
    TCPU, TMEM, TGPU, TNET, TDISK, TTEMP, TUPTIME, TSESSION, TBATT,
    TVOL, TBRIGHT, TMUTE, TMEDIA, TPOMO, TCAFFEINE, TNOTE,
    TSC_LOCK, TSC_SLEEP, TSC_SHOT, TSC_DARK, TSC_MISSION, TSC_NOTE,
    TSC_LAUNCH, TSC_ACTIVITY, TSC_REMIND,
};
static const int kAddableCount = (int)(sizeof(kAddable) / sizeof(kAddable[0]));

@implementation LayoutEditorWindowController {
    NSPopUpButton *_modePop;
    NSButton      *_addBtn;
    NSSlider      *_widthSlider;
    NSTextField   *_widthVal;
    NSImageView   *_preview;
    NSView        *_rowsHost;
    NSInteger      _mode;

    BarView       *_renderBar;     // offscreen, reused to render the preview image
    Pomodoro      *_pomo;

    NSArray<NSDictionary *>       *_rows;        // composed rows for the current mode
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
        _showBtns = [NSMutableArray array]; _sizeSliders = [NSMutableArray array];
        _minSliders = [NSMutableArray array];
        _prioSliders = [NSMutableArray array]; _prioVals = [NSMutableArray array];
        _renderBar = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, 30)];
        _renderBar.animateModeSwitch = NO;
        _pomo = [Pomodoro new]; [_pomo toggle];
        _renderBar.pomodoro = _pomo; _renderBar.caffeinated = YES;
        _renderBar.uptime = 3 * 86400 + 4 * 3600 + 600;
        _renderBar.thermal = (PBThermalSample){ .hasTemp = 1, .cpuTempC = 54, .cpuTempMaxC = 57, .hasFan = 1, .fanRPM = 1200, .fanMaxRPM = 7200 };
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

    [c addSubview:lbl(@"Drag Size/Min to resize, toggle Show to hide, lower Priority so a tile drops first when space is tight, ▲/▼ to reorder, ✕ to remove. Add tiles (incl. world clocks & apps) below.",
                      NSMakeRect(20, top - 116, kWinW - 40, 18), 10, YES)];

    // Column headers — aligned to the per-row control columns.
    CGFloat hy = top - 138;
    [c addSubview:lbl(@"Tile",     NSMakeRect(kColTile, hy, 120,      16), 10, YES)];
    [c addSubview:lbl(@"Show",     NSMakeRect(kColShow, hy, 40,       16), 10, YES)];
    [c addSubview:lbl(@"Size",     NSMakeRect(kColSize, hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Min",      NSMakeRect(kColMin,  hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Priority", NSMakeRect(kColPrio, hy, kSliderW, 16), 10, YES)];
    [c addSubview:lbl(@"Order",    NSMakeRect(kColUp,   hy, 64,       16), 10, YES)];
    [c addSubview:lbl(@"Remove",   NSMakeRect(kColDel,  hy, 60,       16), 10, YES)];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 56, kWinW - 16, hy - 56 - 6)];
    scroll.hasVerticalScroller = YES; scroll.drawsBackground = NO;
    scroll.autohidesScrollers = YES; scroll.borderType = NSNoBorder;
    _rowsHost = [[PBFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kWinW - 16, hy - 56 - 6)];
    scroll.documentView = _rowsHost;
    [c addSubview:scroll];

    NSButton *reset = [NSButton buttonWithTitle:@"Reset this mode" target:self action:@selector(resetMode:)];
    reset.frame = NSMakeRect(20, 16, 150, 30); reset.bezelStyle = NSBezelStyleRounded;
    [c addSubview:reset];

    _addBtn = [NSButton buttonWithTitle:@"  Add tile…  ▾" target:self action:@selector(showAddMenu:)];
    _addBtn.frame = NSMakeRect(180, 16, 160, 30); _addBtn.bezelStyle = NSBezelStyleRounded;
    [c addSubview:_addBtn];

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

#pragma mark - display names

// Enriched row name: instanced tiles get their instance detail appended.
- (NSString *)displayNameForType:(TileType)t arg:(int)arg base:(NSString *)base {
    if (t == TWCLOCK) return [NSString stringWithFormat:@"%@ · %s", base, PBCityAt(arg)->name];
    if (t == TLAUNCH) return [NSString stringWithFormat:@"%@ · %@", base, pb_launcherLabel(arg)];
    return base;
}

#pragma mark - rows

- (void)loadMode {
    for (NSView *v in [_rowsHost.subviews copy]) [v removeFromSuperview];
    [_showBtns removeAllObjects]; [_sizeSliders removeAllObjects]; [_minSliders removeAllObjects];
    [_prioSliders removeAllObjects]; [_prioVals removeAllObjects];

    _rows = pb_composedRowsForMode(_mode);

    // Grow the (flipped) document view to fit every row; the scroll view clips.
    CGFloat rowH = 30;
    CGFloat clipH = _rowsHost.superview ? _rowsHost.superview.bounds.size.height : _rowsHost.bounds.size.height;
    CGFloat docH = MAX(clipH, _rows.count * rowH);
    _rowsHost.frame = NSMakeRect(0, 0, _rowsHost.frame.size.width, docH);
    CGFloat y = 0;

    for (NSInteger row = 0; row < (NSInteger)_rows.count; row++) {
        NSDictionary *d = _rows[row];
        TileType type = (TileType)[d[@"type"] integerValue];
        int      arg  = [d[@"arg"] intValue];
        BOOL     inst = [d[@"instanced"] boolValue];
        BOOL     show = ![d[@"hidden"] boolValue];
        double   wt   = [d[@"weight"] doubleValue];
        double   prio = [d[@"prio"] doubleValue];
        double   minW = [d[@"minW"] doubleValue];

        NSString *nm = [self displayNameForType:type arg:arg base:d[@"name"]];
        NSTextField *nameLbl = lbl(nm, NSMakeRect(kColTile, y + 6, 130, 18), 12, NO);
        if ([d[@"added"] boolValue]) nameLbl.textColor = [NSColor systemTealColor];   // user-added accent
        [_rowsHost addSubview:nameLbl];

        // Sliders/toggle only make sense for single-instance tiles (instanced
        // ones — clocks, launchers — are managed purely by add/remove + order).
        if (!inst) {
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
        } else {
            // Keep the parallel arrays aligned with the row index.
            [_showBtns addObject:(NSButton *)NSNull.null];
            [_sizeSliders addObject:(NSSlider *)NSNull.null];
            [_minSliders addObject:(NSSlider *)NSNull.null];
            [_prioSliders addObject:(NSSlider *)NSNull.null];
            [_prioVals addObject:(NSTextField *)NSNull.null];
            [_rowsHost addSubview:lbl(@"clock / app — add or remove", NSMakeRect(kColShow, y + 6, kColUp - kColShow - 8, 18), 10, YES)];
        }

        NSButton *up = [NSButton buttonWithTitle:@"▲" target:self action:@selector(moveUp:)];
        up.frame = NSMakeRect(kColUp, y + 4, kArrowW, 22); up.tag = row;
        up.bezelStyle = NSBezelStyleRounded; up.enabled = (row > 0);
        [_rowsHost addSubview:up];

        NSButton *down = [NSButton buttonWithTitle:@"▼" target:self action:@selector(moveDown:)];
        down.frame = NSMakeRect(kColDown, y + 4, kArrowW, 22); down.tag = row;
        down.bezelStyle = NSBezelStyleRounded; down.enabled = (row < (NSInteger)_rows.count - 1);
        [_rowsHost addSubview:down];

        NSButton *del = [NSButton buttonWithTitle:@"✕" target:self action:@selector(removeRow:)];
        del.frame = NSMakeRect(kColDel, y + 4, kArrowW, 22); del.tag = row;
        del.bezelStyle = NSBezelStyleRounded;
        [_rowsHost addSubview:del];

        y += rowH;
    }
}

- (void)showAddMenu:(NSButton *)sender {
    NSMenu *menu = [self buildAddMenu];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height + 2) inView:sender];
}

// Build the "Add tile…" menu for the current mode: World Clock cities, App
// launchers, and any simple tile not already present.
- (NSMenu *)buildAddMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    // Which single-instance types are already in the mode?
    NSMutableSet<NSNumber *> *present = [NSMutableSet set];
    for (NSDictionary *d in _rows)
        if (![d[@"instanced"] boolValue]) [present addObject:d[@"type"]];

    // World Clock → cities.
    NSMenuItem *clockItem = [[NSMenuItem alloc] initWithTitle:@"World Clock" action:NULL keyEquivalent:@""];
    NSMenu *clockMenu = [[NSMenu alloc] init];
    for (int i = 0; i < gCityCount; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%s  (%s)", gCities[i].name, gCities[i].label]
                                                    action:@selector(addClock:) keyEquivalent:@""];
        it.target = self; it.representedObject = @(i);
        [clockMenu addItem:it];
    }
    clockItem.submenu = clockMenu;
    [menu addItem:clockItem];

    // App Launcher → curated + previously-added apps, then pick any other app.
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"App Launcher" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    for (int i = 0; i < pb_launcherCount(); i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:pb_launcherLabel(i)
                                                    action:@selector(addLauncher:) keyEquivalent:@""];
        it.target = self; it.representedObject = @(i);
        [appMenu addItem:it];
    }
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *other = [[NSMenuItem alloc] initWithTitle:@"Other app…" action:@selector(addCustomApp:) keyEquivalent:@""];
    other.target = self; [appMenu addItem:other];
    appItem.submenu = appMenu;
    [menu addItem:appItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Other tiles → simple types not already present.
    for (int i = 0; i < kAddableCount; i++) {
        if ([present containsObject:@(kAddable[i])]) continue;
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:tileName(kAddable[i])
                                                    action:@selector(addSimple:) keyEquivalent:@""];
        it.target = self; it.representedObject = @(kAddable[i]);
        [menu addItem:it];
    }

    return menu;
}

#pragma mark - persistence

- (void)writeRow:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_rows.count) return;
    NSDictionary *d = _rows[i];
    if ([d[@"instanced"] boolValue]) return;   // no per-tile size overrides for instanced tiles
    TileType type = (TileType)[d[@"type"] integerValue];
    BOOL show = _showBtns[i].state == NSControlStateValueOn;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = [BarView overrideKeyForMode:_mode type:type];
    // Merge into any existing override so @"order" (written by ▲/▼) survives.
    NSMutableDictionary *o = [([ud dictionaryForKey:key] ?: @{}) mutableCopy];
    o[@"hidden"] = @(!show);
    o[@"w"]      = @(_sizeSliders[i].doubleValue);
    o[@"prio"]   = @((int)lround(_prioSliders[i].doubleValue));
    o[@"minW"]   = @(lround(_minSliders[i].doubleValue));
    [ud setObject:o forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self refreshPreview];
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
    if (i >= 0 && i < (NSInteger)_prioVals.count && ![_prioVals[i] isEqual:NSNull.null])
        _prioVals[i].stringValue = [NSString stringWithFormat:@"%d", (int)lround(_prioSliders[i].doubleValue)];
    [self writeRow:i];
}

- (void)moveUp:(NSButton *)sender   { [self moveRow:sender.tag by:-1]; }
- (void)moveDown:(NSButton *)sender { [self moveRow:sender.tag by:+1]; }

// Move the tile at display row `i` one step (delta -1 = up/left, +1 = down/right),
// then persist a dense 0..n-1 order to every row via the engine's instance-aware
// setOrderOverride, and rebuild rows + preview.
- (void)moveRow:(NSInteger)i by:(NSInteger)delta {
    NSInteger j = i + delta;
    if (i < 0 || i >= (NSInteger)_rows.count || j < 0 || j >= (NSInteger)_rows.count) return;

    NSMutableArray<NSDictionary *> *order = [_rows mutableCopy];
    NSDictionary *tmp = order[i]; order[i] = order[j]; order[j] = tmp;

    for (NSInteger pos = 0; pos < (NSInteger)order.count; pos++) {
        TileType t = (TileType)[order[pos][@"type"] integerValue];
        int arg = [order[pos][@"arg"] intValue];
        setOrderOverride(_mode, t, arg, pos);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
}

- (void)removeRow:(NSButton *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)_rows.count) return;
    TileType t = (TileType)[_rows[i][@"type"] integerValue];
    int arg = [_rows[i][@"arg"] intValue];
    pb_composeRemove(_mode, t, arg);
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
}

- (void)addClock:(NSMenuItem *)it    { [self addType:TWCLOCK arg:[it.representedObject intValue]]; }
- (void)addLauncher:(NSMenuItem *)it { [self addType:TLAUNCH arg:[it.representedObject intValue]]; }
- (void)addSimple:(NSMenuItem *)it   { [self addType:(TileType)[it.representedObject integerValue] arg:0]; }

// Pick any installed .app and register it as a custom launcher, then add it.
- (void)addCustomApp:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
    p.allowedFileTypes = @[@"app"];
    p.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    p.prompt = @"Add"; p.message = @"Choose an app to add as a launcher tile";
    if ([p runModal] != NSModalResponseOK || !p.URL) return;
    NSString *name = p.URL.lastPathComponent.stringByDeletingPathExtension;
    NSString *label = name.uppercaseString;
    if (label.length > 10) label = [label substringToIndex:10];
    int arg = pb_addCustomLauncher(label, name);
    [self addType:TLAUNCH arg:arg];
}

- (void)addType:(TileType)t arg:(int)arg {
    pb_composeAdd(_mode, t, arg);
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
}

- (void)resetMode:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    // Clear per-tile size/order overrides for every row, then drop composition.
    for (NSDictionary *d in _rows) {
        TileType t = (TileType)[d[@"type"] integerValue];
        [ud removeObjectForKey:[BarView overrideKeyForMode:_mode type:t]];
    }
    pb_composeReset(_mode);
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self loadMode];
    [self refreshPreview];
}

- (void)closeWin:(id)sender { [self close]; }

@end
