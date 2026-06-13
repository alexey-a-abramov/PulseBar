//
//  BarView.m — multi-mode interactive Touch Bar with an animated accordion.
//  Left: mode tabs (the active one expands — the "accordion"). Middle: the
//  active mode's content (cross-fades on switch). Right: battery, clock, gear.
//  Flipped coordinates (origin top-left).
//
#import "BarView.h"
#import "Pomodoro.h"
#import "PBDefaults.h"
#import "PBLayout.h"
#import "PBClock.h"
#import "AppIndex.h"
#import "Log.h"
#import "PBFormat.h"

NSString * const PBLayoutChangedNotification = @"PBLayoutChanged";

// Right-cluster geometry (drawn in drawRect:): the fixed-width controls pinned
// to the trailing edge — clock and agent orb — plus the gap between them and the
// trailing padding. (Settings now lives in the menu bar, not the cluster.)
static const CGFloat kClusterPad = 4;    // trailing padding before the cluster
static const CGFloat kAgentW     = 32;
static const CGFloat kClusterGap = 2;    // gap between adjacent cluster controls

// Accordion tab geometry — shared by tabTarget:, the drawRect tab loop and the
// Auto-density predicate, so the "space left for content" math can't drift from
// what is actually drawn.
static const CGFloat kTabActiveFull    = 86;   // active pill, icon + label
static const CGFloat kTabActiveCompact = 38;   // active pill, icon only
static const CGFloat kTabInactive      = 30;
static const CGFloat kTabGap           = 2;
static const CGFloat kChevW            = 20;   // collapse/expand chevron tab
// Auto only *exits* compact once this much width is back (asymmetric hysteresis
// so frame jitter near the threshold can't flip the density every frame).
static const CGFloat kDensityExitSlack = 24;

typedef struct { TileType type; NSRect rect; NSInteger arg; } Tile;

static NSString *modeIcon(NSInteger m) {
    switch (m) {
        case BarModeSystem:       return @"cpu";
        case BarModeMedia:        return @"play.fill";
        case BarModeProductivity: return @"timer";
        case BarModeClassic:      return @"apple.logo";
        case BarModeShortcuts:    return @"bolt.fill";
        case BarModeGlance:       return @"gauge.with.dots.needle.33percent";
    }
    return @"square";
}
static NSString *modeLabel(NSInteger m) {
    switch (m) {
        case BarModeSystem:       return @"SYSTEM";
        case BarModeMedia:        return @"MEDIA";
        case BarModeProductivity: return @"FOCUS";
        case BarModeClassic:      return @"CLASSIC";
        case BarModeShortcuts:    return @"ACTIONS";
        case BarModeGlance:       return @"GLANCE";
    }
    return @"";
}
// Soft pastel accent per mode — used to fill the active accordion chip.
static NSColor *modePastel(NSInteger m) {
    switch (m) {
        case BarModeSystem:       return [NSColor colorWithSRGBRed:0.66 green:0.83 blue:0.99 alpha:1];  // sky
        case BarModeMedia:        return [NSColor colorWithSRGBRed:0.99 green:0.74 blue:0.82 alpha:1];  // rose
        case BarModeProductivity: return [NSColor colorWithSRGBRed:0.99 green:0.85 blue:0.66 alpha:1];  // peach
        case BarModeClassic:      return [NSColor colorWithSRGBRed:0.70 green:0.92 blue:0.86 alpha:1];  // mint
        case BarModeShortcuts:    return [NSColor colorWithSRGBRed:0.82 green:0.77 blue:0.99 alpha:1];  // lavender
        case BarModeGlance:       return [NSColor colorWithSRGBRed:0.74 green:0.90 blue:0.78 alpha:1];  // sage
    }
    return [NSColor colorWithSRGBRed:0.66 green:0.83 blue:0.99 alpha:1];
}


// The real (colourful) app icon for a launcher query, cached so we don't hit
// the disk on every 1 Hz redraw. NSNull marks a miss (app not installed).
static NSImage *launcherIcon(const char *queryC) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *q = @(queryC);
    id hit = cache[q];
    if (hit) return (hit == [NSNull null]) ? nil : hit;
    PBAppEntry *e = [[PBAppIndex shared] bestMatchFor:q];
    NSImage *img = e.path ? [[NSWorkspace sharedWorkspace] iconForFile:e.path] : nil;
    cache[q] = img ?: (id)[NSNull null];
    return img;
}


// Lightweight, env-gated tracing (PULSEBAR_DEBUG=1) for diagnosing input.
static BOOL pbDebug(void) { static int v = -1; if (v < 0) v = getenv("PULSEBAR_DEBUG") ? 1 : 0; return v; }

// Cached, NEVER-nil monospaced font. +[NSFont monospacedSystemFontOfSize:weight:]
// can intermittently return nil under redraw pressure; inserting that nil into a
// text-attributes dictionary throws (and AppKit turns it into a fatal crash
// during the layer flush — the real cause of the signal-5 crashes). Caching also
// avoids recreating a font on every glyph draw.
static NSFont *monoFont(CGFloat sz, NSFontWeight w) {
    static NSMutableDictionary<NSString *, NSFont *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%.2f/%.3f", sz, w];
    NSFont *f = cache[key];
    if (f) return f;
    f = [NSFont monospacedSystemFontOfSize:sz weight:w] ?: [NSFont systemFontOfSize:sz] ?: [NSFont systemFontOfSize:12];
    if (f) cache[key] = f;
    return f;
}

@implementation BarView {
    double      _cpu, _gpu, _topCPU;
    double      _cores[128];
    int         _coreCount;
    MemInfo     _mem;
    NetSample   _net;
    DiskIO      _disk;
    DiskSpace   _space;
    BatteryInfo _battery;
    NSString   *_topProc, *_npTitle, *_npArtist;
    BOOL        _npPlaying, _npHasInfo;
    double      _npElapsed, _npDuration;
    float       _vol, _bright;
    BOOL        _mute;
    double      _netMax, _diskMax;
    NSMutableArray<NSNumber *> *_cpuHist, *_netHist, *_gpuHist;

    NSInteger   _mode, _prevMode;
    PBDensity   _density;                       // Auto / Full / Compact (user choice)
    BOOL        _effectiveCompact;              // what's actually rendered this frame
    BOOL        _peeking;                       // ⌃ momentary peek of the previous mode in progress
    NSInteger   _peekSavedMode, _peekSavedPrev; // mode/recent to restore when the peek ends
    double      _anim;            // 1 = settled
    CGFloat     _tabW[BarModeCount];
    NSRect      _tabToggleRect;   // chevron hit target (collapse/expand the tab strip)
    NSTimer    *_animTimer;

    NSInteger   _view[40];        // per-metric alternate-view index (tap to cycle); 0 = default
    Tile        _tiles[40];
    int         _nTiles;
    TileType    _activeSlider;
    BOOL        _sliding;
    BOOL        _swiped;         // a swipe already fired this gesture
    CGFloat     _downX;          // for swipe detection
    CGFloat     _swipeMaxX;      // mode-switch swipe only starts left of here (the tab zone)
    float       _mediaSeekFrac;  // pending media scrubber position (committed on release)
    NSTimeInterval _lastTouchT;  // suppress mouse synthesized right after a Touch Bar touch
    BOOL        _agentPressing;  // agent orb press in progress
    BOOL        _notePressing;   // Focus side-note tile held (recording)
    NSTimeInterval _pressDownT;  // when the orb press began (for hold detection)
    BOOL        _arranging;      // arrange mode: drag tiles left/right to reorder
    BOOL        _pendingPillTap; // active pill pressed — deciding tap vs long-press
    NSPoint     _pressPoint;     // where the active-pill press began (to cancel long-press on drift)
    NSInteger   _dragType;       // TileType being dragged in arrange mode (-1 = none)
    int         _dragArg;        // which instance (launcher index) is being dragged
    NSRect      _breakOKRect;    // OK button on the take-a-break banner (hit-tested while it shows)
}

- (BOOL)isFlipped { return YES; }
- (NSInteger)mode { return _mode; }
- (NSInteger)recentMode { return _prevMode; }
- (PBDensity)density { return _density; }
- (void)setDensity:(PBDensity)d {
    if (_density == d) return;
    _density = d;
    [self recomputeDensity];
    [self setNeedsDisplay:YES];
}
// Legacy shim (old callers/tests): reads the effective state; writing maps to a fixed density.
- (BOOL)compactLayout { return _effectiveCompact; }
- (void)setCompactLayout:(BOOL)c { self.density = c ? PBDensityCompact : PBDensityFull; }

// Pure Auto predicate. avail is computed from the FULL-density pill width
// unconditionally — the decision must not depend on its own output.
+ (BOOL)effectiveCompactForMode:(NSInteger)mode density:(PBDensity)density
                          width:(CGFloat)width left:(CGFloat)li right:(CGFloat)ri {
    if (density == PBDensityFull)    return NO;
    if (density == PBDensityCompact) return YES;
    CGFloat tabs = kTabActiveFull + (BarModeCount - 1) * kTabInactive + BarModeCount * kTabGap;
    CGFloat avail = width - MAX(0, li) - MAX(0, ri) - (kClusterPad + kAgentW + kClusterGap) - (4 + tabs + 4 + 4 + 8);
    return PBRequiredMinContentWidth(mode) > avail;
}

// Re-evaluate the rendered density (cheap; called per frame from drawRect).
// Hysteresis: in Auto, once compact, only return to full when there's clear
// surplus — so width jitter at the threshold can't flip-flop the layout.
- (void)recomputeDensity {
    BOOL want = [BarView effectiveCompactForMode:_mode density:_density
                                           width:self.bounds.size.width
                                            left:self.safeAreaLeftInset right:self.safeAreaRightInset];
    if (_density == PBDensityAuto && _effectiveCompact && !want) {
        BOOL stillTight = [BarView effectiveCompactForMode:_mode density:PBDensityAuto
                                                     width:self.bounds.size.width - kDensityExitSlack
                                                      left:self.safeAreaLeftInset right:self.safeAreaRightInset];
        if (stillTight) want = YES;   // not enough surplus yet — stay compact
    }
    if (want == _effectiveCompact) return;
    _effectiveCompact = want;
    for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i];   // active pill shrinks/grows
}

// How many alternate views each metric tile cycles through (tap to switch).
static int viewCount(TileType t) {
    switch (t) { case TCPU: case TMEM: case TGPU: case TNET: case TDISK: case TUPTIME: return 2; default: return 1; }
}
// CPU's view doubles as the legacy "show cores" toggle (used by the menu item).
- (BOOL)showCores { return _view[TCPU] != 0; }
- (void)setShowCores:(BOOL)v { _view[TCPU] = v ? 1 : 0; [self setNeedsDisplay:YES]; }
- (void)setTabsCollapsed:(BOOL)c { _tabsCollapsed = c; [self setNeedsDisplay:YES]; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _cpuHist = [NSMutableArray array]; _netHist = [NSMutableArray array]; _gpuHist = [NSMutableArray array];
        _netMax = 65536.0; _diskMax = 1048576.0;
        _topProc = @""; _npTitle = @""; _npArtist = @"";
        _activeSlider = -1; _dragType = -1; _mode = BarModeSystem; _prevMode = BarModeSystem; _anim = 1.0;
        for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i];
        _lastTouchT = -1; _animateModeSwitch = YES;
        self.allowedTouchTypes = NSTouchTypeMaskDirect;   // receive physical Touch Bar touches
        // Active-area awareness: if the system ever resizes the region it gives us
        // (e.g. when its chrome appears), re-render to the real bounds. drawRect:
        // already lays out against self.bounds, so this keeps us correct either way.
        self.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(activeAreaChanged)
                                                     name:NSViewFrameDidChangeNotification object:self];
    }
    return self;
}

- (void)activeAreaChanged { [self setNeedsDisplay:YES]; }
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)updateWithCPU:(double)cpu cores:(const double *)cores count:(int)n
                  mem:(MemInfo)mem net:(NetSample)net gpu:(double)gpu
                 disk:(DiskIO)disk space:(DiskSpace)space battery:(BatteryInfo)bat
              topProc:(NSString *)tp topCPU:(double)tcpu
           nowPlaying:(NowPlaying)np volume:(float)vol mute:(BOOL)mute brightness:(float)bright {
    _cpu = cpu; _coreCount = n > 128 ? 128 : n;
    for (int i = 0; i < _coreCount; i++) _cores[i] = cores[i];
    _mem = mem; _net = net; _gpu = gpu; _disk = disk; _space = space; _battery = bat;
    _topProc = tp ?: @""; _topCPU = tcpu;
    _npTitle = [NSString stringWithUTF8String:np.title] ?: @"";
    _npArtist = [NSString stringWithUTF8String:np.artist] ?: @"";
    _npPlaying = np.isPlaying; _npHasInfo = np.hasInfo;
    _npElapsed = np.elapsed; _npDuration = np.duration;
    _vol = vol; _mute = mute; _bright = bright;

    [_cpuHist addObject:@(cpu)]; [_gpuHist addObject:@(gpu < 0 ? 0 : gpu)]; [_netHist addObject:@(net.downBps + net.upBps)];
    const NSInteger cap = 160;
    while ((NSInteger)_cpuHist.count > cap) [_cpuHist removeObjectAtIndex:0];
    while ((NSInteger)_gpuHist.count > cap) [_gpuHist removeObjectAtIndex:0];
    while ((NSInteger)_netHist.count > cap) [_netHist removeObjectAtIndex:0];
    double mx = 65536.0; for (NSNumber *x in _netHist) if (x.doubleValue > mx) mx = x.doubleValue; _netMax = mx;
    double dcur = disk.readBps + disk.writeBps; _diskMax = MAX(MAX(_diskMax * 0.95, 1048576.0), dcur);

    [self setNeedsDisplay:YES];
}

#pragma mark - mode switching (accordion)

- (CGFloat)tabTarget:(NSInteger)m { return (m == _mode) ? (_effectiveCompact ? kTabActiveCompact : kTabActiveFull) : kTabInactive; }

- (void)setMode:(NSInteger)mode animated:(BOOL)animated {
    if (mode < 0 || mode >= BarModeCount || mode == _mode) return;
    _prevMode = _mode; _mode = mode;
    if (animated) { _anim = 0; [self startAnim]; }
    else { _anim = 1; for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i]; [self setNeedsDisplay:YES]; }
}

// Momentary "peek" — hold ⌃ to glance at the previous mode, release to snap back
// to where you were. Unlike a tap, this must NOT change recentMode, so a peek of
// the peek still returns home. setMode: rolls _prevMode forward, so we snapshot
// both and restore them verbatim on release.
- (void)beginPeekMode {
    if (_peeking || _prevMode == _mode) return;
    _peeking = YES;
    _peekSavedMode = _mode; _peekSavedPrev = _prevMode;
    [self setMode:_prevMode animated:_animateModeSwitch];
}
- (void)endPeekMode {
    if (!_peeking) return;
    _peeking = NO;
    [self setMode:_peekSavedMode animated:_animateModeSwitch];
    _prevMode = _peekSavedPrev;   // setMode: clobbered recentMode — restore the real one
}

- (void)startAnim {
    if (_animTimer) return;
    _animTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(animStep) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_animTimer forMode:NSRunLoopCommonModes];
}
- (void)animStep {
    BOOL moving = NO;
    for (NSInteger i = 0; i < BarModeCount; i++) {
        CGFloat t = [self tabTarget:i];
        _tabW[i] += (t - _tabW[i]) * 0.30;
        if (fabs(_tabW[i] - t) > 0.5) moving = YES; else _tabW[i] = t;
    }
    if (_anim < 1.0) { _anim += 0.10; if (_anim >= 1.0) _anim = 1.0; else moving = YES; }
    [self setNeedsDisplay:YES];
    if (!moving) { [_animTimer invalidate]; _animTimer = nil; }
}

#pragma mark - colours / text

- (NSColor *)load:(double)p { if (p < 50) return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1];
    if (p < 80) return [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.04 alpha:1];
    return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1]; }
- (NSColor *)batt:(double)p chg:(BOOL)c { if (c) return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1];
    if (p <= 20) return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1];
    if (p <= 40) return [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.04 alpha:1];
    return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1]; }
- (NSColor *)dim   { return [NSColor colorWithCalibratedWhite:0.55 alpha:1]; }
- (NSColor *)cyan  { return [NSColor colorWithSRGBRed:0.22 green:0.70 blue:0.96 alpha:1]; }
- (NSColor *)pink  { return [NSColor colorWithSRGBRed:1.00 green:0.32 blue:0.47 alpha:1]; }
- (NSColor *)gpuC  { return [NSColor colorWithSRGBRed:0.66 green:0.45 blue:0.98 alpha:1]; }
- (NSColor *)accent{ return [NSColor colorWithSRGBRed:0.36 green:0.78 blue:0.98 alpha:1]; }
- (NSColor *)green { return [NSColor colorWithSRGBRed:0.30 green:0.82 blue:0.45 alpha:1]; }

- (void)t:(NSString *)s at:(NSPoint)p sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    [s drawAtPoint:p withAttributes:@{ NSFontAttributeName:monoFont(sz, w), NSForegroundColorAttributeName:(c ?: NSColor.whiteColor) }]; }
- (void)t:(NSString *)s rx:(CGFloat)rx y:(CGFloat)y sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    NSDictionary *a = @{ NSFontAttributeName:monoFont(sz, w), NSForegroundColorAttributeName:(c ?: NSColor.whiteColor) };
    [s drawAtPoint:NSMakePoint(rx - [s sizeWithAttributes:a].width, y) withAttributes:a]; }
- (void)tc:(NSString *)s cx:(CGFloat)cx y:(CGFloat)y sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    NSDictionary *a = @{ NSFontAttributeName:monoFont(sz, w), NSForegroundColorAttributeName:(c ?: NSColor.whiteColor) };
    [s drawAtPoint:NSMakePoint(cx - [s sizeWithAttributes:a].width / 2, y) withAttributes:a]; }
- (void)label:(NSString *)s in:(NSRect)r { [self t:s at:NSMakePoint(r.origin.x + 6, 2) sz:7.5 w:NSFontWeightBold c:[self dim]]; }

- (void)symbol:(NSString *)name in:(NSRect)box pt:(CGFloat)pt color:(NSColor *)c {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) { [self tc:@"●" cx:NSMidX(box) y:box.origin.y + box.size.height / 2 - pt / 2 sz:pt w:NSFontWeightBold c:c]; return; }
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightSemibold];
    if (@available(macOS 12.0, *)) cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:c]];
    NSImage *ti = [img imageWithSymbolConfiguration:cfg];
    NSSize s = ti.size;
    NSRect r = NSMakeRect(box.origin.x + (box.size.width - s.width) / 2, box.origin.y + (box.size.height - s.height) / 2, s.width, s.height);
    [ti drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (void)clip:(NSString *)s at:(NSPoint)p sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c maxW:(CGFloat)maxW {
    NSDictionary *a = @{ NSFontAttributeName:monoFont(sz, w), NSForegroundColorAttributeName:(c ?: NSColor.whiteColor) };
    NSString *str = s;
    while ([str sizeWithAttributes:a].width > maxW && str.length > 1) str = [[str substringToIndex:str.length - 2] stringByAppendingString:@"…"];
    [str drawAtPoint:p withAttributes:a];
}

- (void)spark:(NSArray<NSNumber *> *)h rect:(NSRect)r color:(NSColor *)c max:(double)mx {
    if (h.count < 2) return; if (mx <= 0) mx = 1;
    NSBezierPath *p = [NSBezierPath bezierPath]; NSInteger n = h.count;
    for (NSInteger i = 0; i < n; i++) {
        double f = h[i].doubleValue / mx; if (f > 1) f = 1; if (f < 0) f = 0;
        CGFloat px = r.origin.x + r.size.width * ((CGFloat)i / (CGFloat)(n - 1)), py = r.origin.y + r.size.height * (1.0 - f);
        (i == 0) ? [p moveToPoint:NSMakePoint(px, py)] : [p lineToPoint:NSMakePoint(px, py)];
    }
    NSBezierPath *fill = [p copy];
    [fill lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))]; [fill lineToPoint:NSMakePoint(r.origin.x, NSMaxY(r))]; [fill closePath];
    [[c colorWithAlphaComponent:0.18] setFill]; [fill fill];
    [c setStroke]; p.lineWidth = 1.4; [p stroke];
}

- (void)slider:(NSRect)area value:(float)v color:(NSColor *)c label:(NSString *)lab {
    CGFloat y = area.origin.y + area.size.height / 2 - 1, x0 = area.origin.x, w = area.size.width;
    [[NSColor colorWithCalibratedWhite:1 alpha:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x0, y, w, 3) xRadius:1.5 yRadius:1.5] fill];
    CGFloat fw = w * MAX(0, MIN(1, v));
    [c setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x0, y, fw, 3) xRadius:1.5 yRadius:1.5] fill];
    [[NSColor whiteColor] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x0 + fw - 3, y - 2.5, 6, 8) xRadius:2 yRadius:2] fill];
    [self t:lab at:NSMakePoint(x0, area.origin.y + 1) sz:6.5 w:NSFontWeightBold c:[self dim]];
}

- (void)action:(NSString *)sym label:(NSString *)lab in:(NSRect)r active:(BOOL)active color:(NSColor *)c {
    if (active) { [[c colorWithAlphaComponent:0.18] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 3, 3) xRadius:5 yRadius:5] fill]; }
    if (_effectiveCompact) {   // icon-only — no caption (keeps the tile narrow & uncluttered)
        [self symbol:sym in:r pt:15 color:active ? c : [NSColor colorWithCalibratedWhite:0.92 alpha:1]];
        return;
    }
    [self symbol:sym in:NSMakeRect(r.origin.x, 3, r.size.width, 15) pt:13 color:active ? c : [NSColor colorWithCalibratedWhite:0.92 alpha:1]];
    [self tc:lab cx:NSMidX(r) y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
}

- (void)divider:(CGFloat)x { [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill]; NSRectFill(NSMakeRect(x - 0.5, 6, 1, self.bounds.size.height - 12)); }

#pragma mark - tiles

// The active-working-session chip — shared by the dedicated Focus tile and the
// uptime tile's tap-view (one drawing, no copy-paste drift).
- (void)drawSessionChip:(NSRect)r {
    [self label:@"SESSION" in:r];
    [self t:PBFmtUptime(self.sessionSeconds) at:NSMakePoint(r.origin.x + 6, 13) sz:13 w:NSFontWeightBold c:[self green]];
}

- (void)drawTile:(Tile)tile {
    NSRect r = tile.rect;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(r);   // a squeezed tile must never spill into its neighbours or the right cluster
    switch (tile.type) {
        case TCPU: {
            if (self.showCores && _coreCount > 0) {
                [self label:@"CORES" in:r];
                NSRect content = NSMakeRect(r.origin.x + 6, 13, r.size.width - 12, 15);
                CGFloat gap = 2, bw = (content.size.width - (_coreCount - 1) * gap) / _coreCount;
                for (int i = 0; i < _coreCount; i++) { CGFloat bh = MAX(1.5, content.size.height * (_cores[i] / 100.0));
                    [[self load:_cores[i]] setFill]; NSRectFill(NSMakeRect(content.origin.x + i * (bw + gap), NSMaxY(content) - bh, bw, bh)); }
            } else {
                [self label:@"CPU" in:r];
                [self spark:_cpuHist rect:NSMakeRect(r.origin.x + 6, 12, r.size.width - 12, 10) color:[self load:_cpu] max:100];
                if (_topProc.length) [self clip:[NSString stringWithFormat:@"▸ %@ %.0f%%", _topProc, _topCPU]
                                            at:NSMakePoint(r.origin.x + 6, 22) sz:6.5 w:NSFontWeightMedium c:[self dim] maxW:r.size.width - 12];
            }
            [self t:[NSString stringWithFormat:@"%.0f%%", _cpu] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self load:_cpu]];
            break; }
        case TMEM: {
            NSColor *orange = [NSColor colorWithSRGBRed:1 green:0.60 blue:0.20 alpha:1];
            [self label:@"MEM" in:r];
            [self t:[NSString stringWithFormat:@"%.0f%%", _mem.usedPct] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self load:_mem.usedPct]];
            if (_view[TMEM] == 0) {                         // usage: bar + used/total (+ swap hint)
                CGFloat swapX = r.origin.x + 34, swapMaxW = (NSMaxX(r) - 6 - 32) - swapX;
                NSString *swapStr = [NSString stringWithFormat:@"swap %.0fG", PBToGB(_mem.swapUsedBytes)];
                if (_mem.swapUsedBytes > 0 && [swapStr sizeWithAttributes:@{ NSFontAttributeName:monoFont(6.5, NSFontWeightBold) }].width <= swapMaxW)
                    [self t:swapStr at:NSMakePoint(swapX, 3) sz:6.5 w:NSFontWeightBold c:orange];
                CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 17, bh = 8;
                [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:4 yRadius:4] fill];
                CGFloat fw = bw * MAX(0, MIN(1, _mem.usedPct / 100.0));
                if (fw > 1) { [[[self load:_mem.usedPct] colorWithAlphaComponent:0.85] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:4 yRadius:4] fill]; }
                [self t:[NSString stringWithFormat:@"%.1f/%.0fG", PBToGB(_mem.usedBytes), PBToGB(_mem.totalBytes)] at:NSMakePoint(bx + 3, by - 0.5) sz:7 w:NSFontWeightMedium c:[NSColor colorWithCalibratedWhite:0.96 alpha:0.95]];
            } else {                                         // pressure + swap
                NSColor *pc = _mem.pressure >= 4 ? [self pink] : (_mem.pressure >= 2 ? orange : [self green]);
                NSString *pw = _mem.pressure >= 4 ? @"critical" : (_mem.pressure >= 2 ? @"warning" : @"normal");
                [pc setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(r.origin.x + 6, 13, 6, 6)] fill];
                [self t:pw at:NSMakePoint(r.origin.x + 15, 11) sz:8 w:NSFontWeightSemibold c:pc];
                [self t:[NSString stringWithFormat:@"swap %.1fG", PBToGB(_mem.swapUsedBytes)] at:NSMakePoint(r.origin.x + 6, 21) sz:7.5 w:NSFontWeightMedium c:orange];
            }
            break; }
        case TGPU: {
            [self label:@"GPU" in:r]; double g = _gpu < 0 ? 0 : _gpu;
            [self t:[NSString stringWithFormat:@"%.0f%%", g] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self gpuC]];
            if (_view[TGPU] == 0) {                          // dynamic: sparkline over time
                [self spark:_gpuHist rect:NSMakeRect(r.origin.x + 6, 13, r.size.width - 12, 15) color:[self gpuC] max:100];
            } else {                                         // fundamental: current load bar
                CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 18, bh = 7;
                [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:3 yRadius:3] fill];
                CGFloat fw = bw * MAX(0, MIN(1, g / 100.0));
                if (fw > 1) { [[[self gpuC] colorWithAlphaComponent:0.85] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:3 yRadius:3] fill]; }
            }
            break; }
        case TNET: {
            [self label:@"NET" in:r];
            if (_view[TNET] == 0) {                          // dynamic: rates + sparkline
                [self t:[NSString stringWithFormat:@"↓%@", PBFmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self cyan]];
                [self t:[NSString stringWithFormat:@"↑%@", PBFmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
                CGFloat sx = r.origin.x + r.size.width * 0.52;
                [self spark:_netHist rect:NSMakeRect(sx, 13, NSMaxX(r) - 6 - sx, 15) color:[self cyan] max:_netMax];
            } else {                                         // fundamental: larger rate readout
                [self t:[NSString stringWithFormat:@"↓ %@", PBFmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 11) sz:10 w:NSFontWeightSemibold c:[self cyan]];
                [self t:[NSString stringWithFormat:@"↑ %@", PBFmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:10 w:NSFontWeightSemibold c:[self pink]];
            }
            break; }
        case TDISK: {
            [self label:@"DISK" in:r];
            NSColor *dc = [NSColor colorWithSRGBRed:0.45 green:0.80 blue:0.92 alpha:1];
            if (_view[TDISK] == 0) {                         // dynamic: R/W rates + free
                if (_space.totalBytes) [self t:[NSString stringWithFormat:@"%.0fG", PBToGB(_space.freeBytes)] rx:NSMaxX(r) - 6 y:1 sz:11 w:NSFontWeightBold c:dc];
                [self t:[NSString stringWithFormat:@"R %@", PBFmtRate(_disk.readBps)]  at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self accent]];
                [self t:[NSString stringWithFormat:@"W %@", PBFmtRate(_disk.writeBps)] at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
                [self t:@"free" rx:NSMaxX(r) - 6 y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
            } else {                                         // fundamental: free/used space bar
                double frac = _space.totalBytes ? (double)(_space.totalBytes - _space.freeBytes) / _space.totalBytes : 0;
                [self t:[NSString stringWithFormat:@"%.0fG free", PBToGB(_space.freeBytes)] at:NSMakePoint(r.origin.x + 6, 11) sz:8.5 w:NSFontWeightSemibold c:dc];
                [self t:[NSString stringWithFormat:@"of %.0fG", PBToGB(_space.totalBytes)] rx:NSMaxX(r) - 6 y:12 sz:7 w:NSFontWeightMedium c:[self dim]];
                CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 21, bh = 6;
                [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:3 yRadius:3] fill];
                CGFloat fw = bw * MAX(0, MIN(1, frac));
                if (fw > 1) { [[dc colorWithAlphaComponent:0.8] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:3 yRadius:3] fill]; }
            }
            break; }
        case TMEDIA: {
            CGFloat by = 4, bs = 22, gap = 2, x0 = r.origin.x + 4;
            [self symbol:@"backward.fill"                       in:NSMakeRect(x0, by, bs, bs) pt:11 color:[NSColor whiteColor]];
            [self symbol:_npPlaying ? @"pause.fill" : @"play.fill" in:NSMakeRect(x0 + bs + gap, by, bs, bs) pt:12
                   color:_npPlaying ? [self accent] : [NSColor colorWithCalibratedWhite:0.55 alpha:1]];   // blue=playing, dim=paused
            [self symbol:@"forward.fill"                        in:NSMakeRect(x0 + 2 * (bs + gap), by, bs, bs) pt:11 color:[NSColor whiteColor]];
            CGFloat tx = x0 + 3 * (bs + gap) + 4, tw = NSMaxX(r) - tx - 4;
            if (tw > 24) {
                if (_npHasInfo && _npTitle.length) {
                    if (_npDuration > 1) {
                        [self clip:_npTitle at:NSMakePoint(tx, 3) sz:9 w:NSFontWeightSemibold c:[NSColor whiteColor] maxW:tw];
                        double frac = _npElapsed / _npDuration; if (frac < 0) frac = 0; if (frac > 1) frac = 1;
                        [self t:PBFmtClock(_npElapsed) at:NSMakePoint(tx, 18) sz:7 w:NSFontWeightMedium c:[self dim]];
                        [self t:PBFmtClock(_npDuration) rx:tx + tw y:18 sz:7 w:NSFontWeightMedium c:[self dim]];
                        CGFloat bx = tx + 26, bw = tw - 52;
                        if (bw > 8) {
                            [[NSColor colorWithCalibratedWhite:1 alpha:0.14] setFill];
                            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, 20, bw, 2.5) xRadius:1.2 yRadius:1.2] fill];
                            [[self accent] setFill];
                            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, 20, bw * frac, 2.5) xRadius:1.2 yRadius:1.2] fill];
                        }
                    } else {
                        [self clip:_npTitle at:NSMakePoint(tx, 8) sz:9 w:NSFontWeightSemibold c:[NSColor whiteColor] maxW:tw];
                        [self clip:_npArtist at:NSMakePoint(tx, 19) sz:7.5 w:NSFontWeightMedium c:[self dim] maxW:tw];
                    }
                } else [self t:@"— nothing playing —" at:NSMakePoint(tx, 12) sz:7.5 w:NSFontWeightMedium c:[self dim]];
            }
            break; }
        case TVOL: {
            CGFloat iconW = 20;
            NSString *sym = _mute ? @"speaker.slash.fill" : (_vol < 0.33 ? @"speaker.fill" : @"speaker.wave.2.fill");
            [self symbol:sym in:NSMakeRect(r.origin.x + 2, 4, iconW, 22) pt:11 color:_mute ? [self pink] : [NSColor whiteColor]];
            [self slider:NSMakeRect(r.origin.x + iconW + 2, 0, r.size.width - iconW - 6, r.size.height) value:_mute ? 0 : _vol color:[self accent] label:@"VOL"];
            break; }
        case TBRIGHT: {
            CGFloat iconW = 20;
            [self symbol:@"sun.max.fill" in:NSMakeRect(r.origin.x + 2, 4, iconW, 22) pt:12 color:[NSColor colorWithSRGBRed:1 green:0.8 blue:0.2 alpha:1]];
            [self slider:NSMakeRect(r.origin.x + iconW + 2, 0, r.size.width - iconW - 6, r.size.height) value:_bright < 0 ? 0 : _bright color:[NSColor colorWithSRGBRed:1 green:0.8 blue:0.3 alpha:1] label:@"BRIGHT"];
            break; }
        case TPOMO: {
            Pomodoro *p = self.pomodoro;
            BOOL idle = !p || p.state == PomoIdle;
            NSString *lab = p ? [p label] : @"POMODORO", *clock = p ? [p clockText] : @"25:00";
            BOOL work = p && (p.state == PomoWork), running = p && (p.state == PomoWork || p.state == PomoBreak);
            NSColor *col = running ? (work ? [NSColor colorWithSRGBRed:1 green:0.42 blue:0.30 alpha:1] : [self green]) : [self dim];
            [self label:idle ? (p.adaptiveLength ? @"FOCUS · auto" : @"FOCUS · set") : lab in:r];
            [self symbol:running ? @"pause.circle.fill" : @"play.circle.fill" in:NSMakeRect(r.origin.x + 4, 12, 16, 16) pt:13 color:running ? col : [self green]];
            [self t:clock at:NSMakePoint(r.origin.x + 22, 13) sz:13 w:NSFontWeightBold c:col];
            if (idle) [self t:@"▾" rx:NSMaxX(r) - 6 y:13 sz:10 w:NSFontWeightBold c:[self dim]];   // tap the time → adjust
            if (p && running) { CGFloat bx = r.origin.x + 6, bw = r.size.width - 12;
                [[col colorWithAlphaComponent:0.25] setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw, 1.5));
                [col setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw * [p progress], 1.5)); }
            break; }
        case TCAFFEINE:   [self action:@"cup.and.saucer.fill" label:self.caffeinated ? @"AWAKE" : @"CAFFEINE" in:r active:self.caffeinated color:[self green]]; break;
        case TSC_LOCK:    [self action:@"lock.fill"            label:@"LOCK"   in:r active:NO color:[self accent]]; break;
        case TSC_SLEEP:   [self action:@"moon.zzz.fill"        label:@"SLEEP"  in:r active:NO color:[self accent]]; break;
        case TSC_SHOT:    [self action:@"camera.fill"          label:@"SHOT"   in:r active:NO color:[self accent]]; break;
        case TSC_DARK:    [self action:@"circle.lefthalf.filled" label:@"DARK" in:r active:NO color:[self accent]]; break;
        case TSC_MISSION: [self action:@"macwindow"            label:@"SPACES" in:r active:NO color:[self accent]]; break;
        case TSC_NOTE:    [self action:@"note.text"            label:@"NOTE"   in:r active:NO color:[self accent]]; break;
        case TSC_LAUNCH:  [self action:@"square.grid.3x3.fill" label:@"APPS"   in:r active:NO color:[self accent]]; break;
        case TSC_ACTIVITY:[self action:@"waveform.path.ecg"    label:@"MONITOR" in:r active:NO color:[self accent]]; break;
        case TSC_REMIND:  [self action:@"checklist"            label:@"REMIND" in:r active:NO color:[self accent]]; break;
        case TMUTE:       [self action:_mute ? @"speaker.slash.fill" : @"speaker.wave.2.fill" label:_mute ? @"MUTED" : @"MUTE" in:r active:_mute color:[self pink]]; break;
        case TUPTIME: {
            // One chip, tap to switch between total uptime and the active session.
            if (_view[TUPTIME] == 0) {
                [self label:@"UPTIME" in:r];
                [self t:PBFmtUptime(self.uptime) at:NSMakePoint(r.origin.x + 6, 13) sz:13 w:NSFontWeightBold c:[self accent]];
            } else {
                [self drawSessionChip:r];
            }
            break; }
        case TSESSION:   // dedicated active-working-session chip (e.g. for Focus mode)
            [self drawSessionChip:r];
            break;
        case TNOTE: {   // hold to record a voice side-note (walkie-talkie)
            BOOL rec = self.noteRecording;
            [self action:rec ? @"waveform" : @"mic.fill" label:rec ? @"REC…" : @"NOTE" in:r active:rec color:[self pink]];
            break; }
        case TBATT: {
            // Single compact icon: battery glyph with the % inside; charging bolt to its left.
            CGFloat bw = 26, bh = 14, bx = NSMidX(r) - (bw + 2) / 2, by = (r.size.height - bh) / 2;
            NSColor *bc = [self batt:_battery.percent chg:_battery.charging];
            [[NSColor colorWithCalibratedWhite:0.78 alpha:1] setStroke];
            NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:3 yRadius:3]; shell.lineWidth = 1.2; [shell stroke];
            [[NSColor colorWithCalibratedWhite:0.78 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx + bw + 1, by + bh / 2 - 2.5, 2, 5) xRadius:1 yRadius:1] fill];
            CGFloat innerW = (bw - 3) * MAX(0, MIN(1, _battery.percent / 100.0));
            [[bc colorWithAlphaComponent:0.9] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx + 1.5, by + 1.5, innerW, bh - 3) xRadius:1.5 yRadius:1.5] fill];
            [self tc:[NSString stringWithFormat:@"%.0f", _battery.percent] cx:bx + bw / 2 y:by + bh / 2 - 4.5 sz:8 w:NSFontWeightHeavy c:[NSColor whiteColor]];
            if (_battery.charging) [self symbol:@"bolt.fill" in:NSMakeRect(bx - 9, by, 8, bh) pt:8 color:[self green]];
            break; }
        case TCLOCK: break;   // clock removed from the bar (menu bar shows the time)
        case TSETTINGS: [self symbol:@"gearshape.fill" in:r pt:15 color:[NSColor colorWithCalibratedWhite:0.85 alpha:1]]; break;
        case TAGENT: {
            CGFloat d = 21, cx = NSMidX(r), cy = r.size.height / 2;
            NSRect orb = NSMakeRect(cx - d / 2, cy - d / 2, d, d);
            NSGradient *g = [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithSRGBRed:0.38 green:0.42 blue:0.99 alpha:1],
                [NSColor colorWithSRGBRed:0.78 green:0.36 blue:0.98 alpha:1],
                [NSColor colorWithSRGBRed:0.99 green:0.38 blue:0.62 alpha:1]]];
            [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:orb] angle:45];
            [self symbol:@"sparkles" in:orb pt:11 color:[NSColor whiteColor]];
            break; }
        case TLAUNCH: {
            const Launcher *L = &gLaunchers[(tile.arg >= 0 && tile.arg < gLauncherCount) ? tile.arg : 0];
            NSImage *icon = launcherIcon(L->query);
            CGFloat d = 18, ix = NSMidX(r) - d / 2;
            if (icon) [icon drawInRect:NSMakeRect(ix, 4, d, d) fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            else [self symbol:@"app.dashed" in:NSMakeRect(r.origin.x, 4, r.size.width, d) pt:14 color:[self accent]];
            [self tc:@(L->label) cx:NSMidX(r) y:23 sz:6.5 w:NSFontWeightBold c:[self dim]];
            break; }
        case TWCLOCK: {   // world clock — DST-correct time for the city at `arg`
            int ci = (int)tile.arg;
            const PBCity *c = PBCityAt(ci);
            [self label:@(c->label) in:r];
            [self t:PBClockTimeForCity(ci) at:NSMakePoint(r.origin.x + 6, 12) sz:13 w:NSFontWeightBold c:[self accent]];
            NSString *tag = PBClockOffsetTag(ci);
            if (tag.length) [self t:tag rx:NSMaxX(r) - 4 y:3 sz:8 w:NSFontWeightSemibold c:[self dim]];
            int dd = PBClockDayDelta(ci);
            if (dd != 0) [self t:(dd > 0 ? @"+1d" : @"−1d") rx:NSMaxX(r) - 4 y:NSMaxY(r) - 10
                              sz:7.5 w:NSFontWeightBold c:(dd > 0 ? [self green] : [self pink])];
            break; }
        case TTEMP: {   // CPU temperature + fan, glanceable colour ramp
            PBThermalSample th = _thermal;
            [self label:@"TEMP" in:r];
            if (th.hasTemp) {
                // green < 65 · amber 65–85 · red > 85 (M-series throttles ~100°C)
                double t = th.cpuTempC;
                NSColor *tc = t < 65 ? [self green]
                            : (t < 85 ? [NSColor colorWithSRGBRed:1 green:0.72 blue:0.22 alpha:1]
                                      : [NSColor colorWithSRGBRed:1 green:0.36 blue:0.30 alpha:1]);
                [self symbol:@"thermometer.medium" in:NSMakeRect(r.origin.x + 2, 11, 14, 16) pt:12 color:tc];
                [self t:[NSString stringWithFormat:@"%.0f°", t] at:NSMakePoint(r.origin.x + 17, 12) sz:13 w:NSFontWeightBold c:tc];
            } else {
                [self t:@"—" at:NSMakePoint(r.origin.x + 6, 12) sz:13 w:NSFontWeightBold c:[self dim]];
            }
            if (th.hasFan) {
                NSString *fan = th.fanRPM < 1 ? @"idle" : [NSString stringWithFormat:@"%.0f", th.fanRPM];
                [self t:fan rx:NSMaxX(r) - 4 y:3 sz:8 w:NSFontWeightSemibold c:[self dim]];
                if (th.fanRPM >= 1 && th.fanMaxRPM > 0) {   // tiny fan-load underline
                    CGFloat bx = r.origin.x + 6, bw = r.size.width - 12;
                    double frac = MAX(0, MIN(1, th.fanRPM / th.fanMaxRPM));
                    [[[self dim] colorWithAlphaComponent:0.4] setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw, 1.5));
                    [[self accent] setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw * frac, 1.5));
                }
            }
            break; }
        case TFKEY: case TAPP_HIDE: case TAPP_QUIT: case TTAB: break;   // drawn inline by overlays
    }
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - layout

- (void)push:(TileType)type rect:(NSRect)r arg:(NSInteger)arg { if (_nTiles < 40) _tiles[_nTiles++] = (Tile){type, r, arg}; }

- (void)modeContent:(NSInteger)mode in:(NSRect)area draw:(BOOL)draw record:(BOOL)record {
    CGFloat pad = 4, avail = area.size.width - pad * 2;
    TileDef vis[16];
    int nvis = packVisible(mode, avail, vis);   // overrides + size-aware hiding
    if (nvis <= 0) return;

    // Give each visible tile its minW, then split the leftover by weight so
    // small tiles aren't starved and big ones still take the lion's share.
    CGFloat sumMin = 0, sumW = 0;
    for (int i = 0; i < nvis; i++) { sumMin += vis[i].minW; sumW += vis[i].weight; }
    if (sumW <= 0) sumW = 1;
    CGFloat extra = MAX(0, avail - sumMin), x = area.origin.x + pad;
    for (int i = 0; i < nvis; i++) {
        CGFloat tw = vis[i].minW + extra * vis[i].weight / sumW;
        if (vis[i].maxW > 0 && tw > vis[i].maxW) tw = vis[i].maxW;   // capped tiles stay compact (freed space → right margin)
        NSRect r = NSMakeRect(x, 0, tw, area.size.height);
        if (draw) [self drawTile:(Tile){vis[i].type, r, vis[i].arg}];
        if (record) [self push:vis[i].type rect:r arg:vis[i].arg];
        x += tw;
        if (draw && i < nvis - 1) [self divider:x];
    }
}

- (void)drawTab:(NSInteger)m rect:(NSRect)r active:(BOOL)active {
    NSRect pill = NSInsetRect(r, 1, 3);
    if (active) {
        NSColor *ink = [NSColor colorWithCalibratedWhite:0.12 alpha:1];   // dark text on the soft pastel
        [modePastel(m) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        if (_arranging) {   // arrange mode: pill turns into the drag affordance (tap to finish)
            [self symbol:@"arrow.left.arrow.right" in:r pt:13 color:ink];
            NSColor *ac = [NSColor colorWithSRGBRed:1.0 green:0.62 blue:0.20 alpha:1];
            NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6];
            ring.lineWidth = 1.5; [ac setStroke]; [ring stroke];
        } else if (_effectiveCompact) {   // compact: highlight + icon only, no text label
            [self symbol:modeIcon(m) in:r pt:13 color:ink];
        } else {
            [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 5, 0, 16, r.size.height) pt:12 color:ink];
            if (r.size.width > 34) [self t:modeLabel(m) at:NSMakePoint(r.origin.x + 23, r.size.height / 2 - 5) sz:8.5 w:NSFontWeightHeavy c:ink];
        }
    } else {
        [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 3, 0, r.size.width - 6, r.size.height) pt:12 color:[NSColor colorWithCalibratedWhite:0.78 alpha:1]];
    }
}

// The collapse/expand chevron that sits in the tab strip. › when collapsed
// (tap to reveal all modes), ‹ when expanded (tap to collapse to the active pill).
- (void)drawTabChevron:(NSRect)r collapsed:(BOOL)collapsed {
    NSRect pill = NSInsetRect(r, 1, 3);
    [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
    [self symbol:collapsed ? @"chevron.right" : @"chevron.left"
              in:r pt:11 color:[NSColor colorWithCalibratedWhite:0.7 alpha:1]];
}

- (void)drawFnKeys:(NSRect)b {
    CGFloat H = b.size.height, pad = 4, gap = 3;
    CGFloat li = MAX(0, self.safeAreaLeftInset), ri = MAX(0, self.safeAreaRightInset);
    CGFloat W = b.size.width - li - ri;   // keypad lives inside the safe area
    int n = 12;
    CGFloat bw = (W - pad * 2 - gap * (n - 1)) / n, x = li + pad;
    for (int i = 1; i <= n; i++) {
        NSRect r = NSMakeRect(x, 2, bw, H - 4);
        [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
        [self tc:[NSString stringWithFormat:@"F%d", i] cx:NSMidX(r) y:H / 2 - 7 sz:12 w:NSFontWeightSemibold c:[NSColor whiteColor]];
        [self push:TFKEY rect:r arg:i];
        x += bw + gap;
    }
}

- (void)drawPillButton:(NSRect)r label:(NSString *)lab color:(NSColor *)c {
    [[c colorWithAlphaComponent:0.20] setFill];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 4) xRadius:6 yRadius:6];
    [p fill]; [c setStroke]; p.lineWidth = 1; [p stroke];
    [self tc:lab cx:NSMidX(r) y:r.size.height / 2 - 6 sz:11 w:NSFontWeightSemibold c:c];
}

- (void)drawAppOverlay:(NSRect)b {
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat li = MAX(0, self.safeAreaLeftInset), ri = MAX(0, self.safeAreaRightInset);
    [[[self accent] colorWithAlphaComponent:0.12] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));
    if (self.appIcon) {
        NSRect ir = NSMakeRect(li + 12, (H - 24) / 2, 24, 24);
        [self.appIcon drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    [self t:(self.appName ?: @"App") at:NSMakePoint(li + 44, H / 2 - 9) sz:14 w:NSFontWeightBold c:[NSColor whiteColor]];
    [self t:@"⌥ app — quick actions" at:NSMakePoint(li + 44, H / 2 + 6) sz:8 w:NSFontWeightMedium c:[self dim]];
    CGFloat bw = 74, gap = 8;
    NSRect rh = NSMakeRect(W - ri - 6 - bw * 2 - gap, 0, bw, H);
    NSRect rq = NSMakeRect(W - ri - 6 - bw, 0, bw, H);
    [self drawPillButton:rh label:@"Hide" color:[self accent]];
    [self drawPillButton:rq label:@"Quit" color:[self pink]];
    [self push:TAPP_HIDE rect:rh arg:0];
    [self push:TAPP_QUIT rect:rq arg:0];
}

// A full-width "take a break" banner. Spans the whole bar so it can't be missed,
// shows how long the current focus session has run, and isn't dismissable from
// the bar (it auto-clears and re-appears every 15 min — see AppDelegate).
- (void)drawBreakReminder:(NSRect)b {
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat li = MAX(0, self.safeAreaLeftInset), ri = MAX(0, self.safeAreaRightInset);
    NSColor *amber  = [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.20 alpha:1];
    NSGradient *bg = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.20 green:0.12 blue:0.03 alpha:1],
        [NSColor colorWithSRGBRed:0.32 green:0.20 blue:0.05 alpha:1]]];
    [bg drawInRect:b angle:0];
    [[amber colorWithAlphaComponent:0.55] setFill]; NSRectFill(NSMakeRect(0, H - 2, W, 2));
    [[amber colorWithAlphaComponent:0.55] setFill]; NSRectFill(NSMakeRect(0, 0, W, 2));

    [self symbol:@"cup.and.saucer.fill" in:NSMakeRect(li + 14, (H - 22) / 2, 26, 22) pt:16 color:amber];

    // OK button (right) — the banner stays until you press it.
    CGFloat okW = 58, okH = 20;
    _breakOKRect = NSMakeRect(W - ri - 12 - okW, (H - okH) / 2, okW, okH);
    [amber setFill];
    [[NSBezierPath bezierPathWithRoundedRect:_breakOKRect xRadius:6 yRadius:6] fill];
    [self tc:@"OK" cx:NSMidX(_breakOKRect) y:NSMidY(_breakOKRect) - 6.5 sz:11 w:NSFontWeightHeavy c:[NSColor colorWithCalibratedWhite:0.12 alpha:1]];

    NSString *dur = self.breakReminderText.length ? self.breakReminderText : @"a while";
    [self t:@"Time for a break" at:NSMakePoint(li + 50, H / 2 - 10) sz:13 w:NSFontWeightHeavy c:[NSColor whiteColor]];
    [self clip:[NSString stringWithFormat:@"Focused for %@ — stand up, stretch, then press OK", dur]
            at:NSMakePoint(li + 50, H / 2 + 5) sz:8.5 w:NSFontWeightMedium c:[NSColor colorWithCalibratedWhite:0.85 alpha:1]
          maxW:_breakOKRect.origin.x - (li + 50) - 12];
}

// Arrange mode cues: a dashed amber frame around the reorderable content and a
// highlight on the tile currently being dragged.
- (void)drawArrangeCuesIn:(NSRect)content {
    NSColor *ac = [NSColor colorWithSRGBRed:1.0 green:0.62 blue:0.20 alpha:1];
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(content, 2, 3) xRadius:6 yRadius:6];
    frame.lineWidth = 1.5; CGFloat dash[2] = {4, 3}; [frame setLineDash:dash count:2 phase:0];
    [[ac colorWithAlphaComponent:0.85] setStroke]; [frame stroke];
    for (int i = 0; i < _nTiles; i++) {
        if (_tiles[i].type != _dragType || (int)_tiles[i].arg != _dragArg) continue;
        NSBezierPath *h = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(_tiles[i].rect, 2, 4) xRadius:5 yRadius:5];
        [[ac colorWithAlphaComponent:0.20] setFill]; [h fill];
        [ac setStroke]; h.lineWidth = 1.5; [h stroke];
    }
}

- (void)drawRect:(NSRect)dirty {
  @try {
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    [[NSColor colorWithCalibratedWhite:0.035 alpha:1] setFill]; NSRectFill(b);
    _nTiles = 0;
    if (self.appOverlay) { [self drawAppOverlay:b]; return; }   // ⌥ held -> app context
    if (self.fnMode)     { [self drawFnKeys:b];     return; }
    if (self.breakReminder) { [self drawBreakReminder:b]; return; }   // unmutable session-length nudge
    [[[self load:_cpu] colorWithAlphaComponent:0.10] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));

    // Re-evaluate Auto density first — the tab widths and tile rendering below
    // depend on the effective compactness for THIS frame.
    [self recomputeDensity];

    // Safe area: reserve the left/right insets for system chrome (close box, right
    // panel) so nothing important is ever covered and the layout doesn't shift as
    // that chrome comes and goes. Faint hairlines mark the boundaries.
    CGFloat li = MAX(0, self.safeAreaLeftInset), ri = MAX(0, self.safeAreaRightInset);
    if (li > 0) [self divider:li];
    if (ri > 0) [self divider:W - ri];

    // Right cluster: just the agent orb, kept inside the right safe inset. No clock
    // (the menu bar shows the time) and no settings gear (it's in the menu too).
    CGFloat rx = W - ri - kClusterPad;
    NSRect rAg = NSMakeRect(rx - kAgentW, 0, kAgentW, H); rx -= kAgentW + kClusterGap; [self drawTile:(Tile){TAGENT, rAg, 0}]; [self push:TAGENT rect:rAg arg:0];
    CGFloat rightEdge = rx; [self divider:rightEdge];

    // left tabs (accordion) — start after the left safe inset (the close box zone).
    // Collapsed: only the active pill + a › chevron to expand (reclaims the inactive
    // tabs' width for content). Expanded: every tab, exactly as before (no chevron —
    // collapse is triggered from the menu / Settings, so expanded costs no pixels).
    CGFloat tx = li + 4;
    _tabToggleRect = NSZeroRect;
    if (_tabsCollapsed) {
        NSRect tr = NSMakeRect(tx, 0, _tabW[_mode], H);
        [self drawTab:_mode rect:tr active:YES];
        [self push:TTAB rect:tr arg:_mode];
        tx += _tabW[_mode] + kTabGap;
        _tabToggleRect = NSMakeRect(tx, 0, kChevW, H);
        [self drawTabChevron:_tabToggleRect collapsed:YES];
        tx += kChevW + kTabGap;
    } else {
        for (NSInteger m = 0; m < BarModeCount; m++) {
            NSRect tr = NSMakeRect(tx, 0, _tabW[m], H);
            [self drawTab:m rect:tr active:(m == _mode)];
            [self push:TTAB rect:tr arg:m];
            tx += _tabW[m] + kTabGap;
        }
    }
    [self divider:tx + 2];
    _swipeMaxX = tx + 4;   // swipe-to-switch is only recognised left of here (the tab zone)

    // content area between tabs and right cluster
    NSRect content = NSMakeRect(tx + 4, 0, MAX(40, rightEdge - (tx + 4) - 4), H);
    if (_anim >= 1.0) {
        [self modeContent:_mode in:content draw:YES record:YES];
    } else {
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(content);
        CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(cg); CGContextSetAlpha(cg, 1.0 - _anim); [self modeContent:_prevMode in:content draw:YES record:NO]; CGContextRestoreGState(cg);
        CGContextSaveGState(cg); CGContextSetAlpha(cg, _anim);       [self modeContent:_mode     in:content draw:YES record:NO]; CGContextRestoreGState(cg);
        [NSGraphicsContext restoreGraphicsState];
        [self modeContent:_mode in:content draw:NO record:YES];   // hit rects for current mode
    }
    if (_arranging) [self drawArrangeCuesIn:content];   // dashed border + dragged-tile highlight
  } @catch (NSException *e) {
    // A drawing exception here would otherwise surface during the CATransaction
    // flush as a hard crash (signal 5). Log the reason and skip the frame.
    PBLog(@"drawRect exception (mode %ld): %@ — %@", (long)_mode, e.name, e.reason);
  }
}

#pragma mark - hit testing

- (Tile *)tileAt:(NSPoint)p { for (int i = 0; i < _nTiles; i++) if (NSPointInRect(p, _tiles[i].rect)) return &_tiles[i]; return NULL; }
- (float)sliderValueFor:(Tile *)t at:(NSPoint)p {
    CGFloat iconW = 20, x0 = t->rect.origin.x + iconW + 2, w = t->rect.size.width - iconW - 6;
    return (float)MAX(0, MIN(1, (p.x - x0) / w));
}

// Shared interaction core (used by both mouse and direct touch).
- (void)beginAt:(NSPoint)p {
    _downX = p.x; _activeSlider = -1; _sliding = NO; _swiped = NO; _agentPressing = NO; _notePressing = NO;
    _pendingPillTap = NO; _dragType = -1;
    if (self.breakReminder) {   // banner is modal-ish: only the OK button dismisses it
        if (NSPointInRect(p, _breakOKRect)) [self.actionDelegate barAcknowledgeBreak];
        return;
    }
    if (!_arranging && NSPointInRect(p, _tabToggleRect)) {   // chevron → collapse/expand the tab strip
        self.tabsCollapsed = !_tabsCollapsed;
        [self.actionDelegate barSetTabsCollapsed:_tabsCollapsed];
        return;
    }
    Tile *t = [self tileAt:p];
    if (pbDebug()) NSLog(@"[PB] beginAt (%.0f,%.0f) tile=%ld", p.x, p.y, t ? (long)t->type : -1);
    if (!t) return;

    // Arrange mode: tap a tab to finish/switch, otherwise pick up a content tile to drag-reorder.
    if (_arranging) {
        if (t->type == TTAB) {
            [self exitArrange];
            if (t->arg != _mode) { [self setMode:t->arg animated:self.animateModeSwitch]; [self.actionDelegate barDidChangeMode:t->arg]; }
            return;
        }
        if (t->type == TAGENT) { [self exitArrange]; [self.actionDelegate barOpenAgent]; return; }
        if ([self reorderable:t->type]) { _dragType = t->type; _dragArg = (int)t->arg; }   // begin drag (reorder in moveAt)
        return;
    }

    if (t->type == TAGENT) {   // agent orb -> push-to-talk (tap toggles, hold = walkie-talkie)
        _agentPressing = YES; _pressDownT = NSProcessInfo.processInfo.systemUptime;
        [self.actionDelegate barAgentDown]; return;
    }
    if (t->type == TNOTE) {    // side note -> hold to record, release to save (walkie-talkie)
        _notePressing = YES; [self.actionDelegate barNoteDown]; return;
    }
    // Active mode pill: defer — quick release jumps to the recent mode; a long hold enters arrange.
    if (t->type == TTAB && t->arg == _mode) {
        _pendingPillTap = YES; _pressPoint = p;
        [self performSelector:@selector(enterArrange) withObject:nil afterDelay:0.55];
        return;
    }
    CGFloat iconW = 20;
    if (t->type == TBRIGHT) { _activeSlider = TBRIGHT; _sliding = YES; [self.actionDelegate barSetBrightness:[self sliderValueFor:t at:p]]; }
    else if (t->type == TVOL && p.x >= t->rect.origin.x + iconW) { _activeSlider = TVOL; _sliding = YES; [self.actionDelegate barSetVolume:[self sliderValueFor:t at:p]]; }
    else if (t->type == TMEDIA && p.x >= t->rect.origin.x + 4 + 3 * (22 + 2)) {   // scrubber region → seek (drag, commit on release)
        _activeSlider = TMEDIA; _sliding = YES; _mediaSeekFrac = [self mediaSeekFracFor:t at:p];
    }
    else { [self fireTap:t at:p]; }   // fire on press — reliable
}

// Fraction along the now-playing scrubber for a point (matches the bar drawn in drawTile TMEDIA).
- (float)mediaSeekFracFor:(Tile *)t at:(NSPoint)p {
    CGFloat x0 = t->rect.origin.x + 4, bs = 22, gap = 2;
    CGFloat tx = x0 + 3 * (bs + gap) + 4, tw = NSMaxX(t->rect) - tx - 4;
    CGFloat bx = tx + 26, bw = tw - 52;
    return bw > 0 ? (float)MAX(0, MIN(1, (p.x - bx) / bw)) : 0;
}
- (void)moveAt:(NSPoint)p {
    if (_agentPressing || _notePressing) return;   // holding orb/note (walkie-talkie) — ignore drags/swipes
    if (_arranging) { if (_dragType >= 0) [self dragReorderTo:p]; return; }
    if (_pendingPillTap && fabs(p.x - _pressPoint.x) > 8) [self cancelLongPress];   // it's a swipe, not a hold
    if (_sliding && _activeSlider >= 0) {
        for (int i = 0; i < _nTiles; i++) if (_tiles[i].type == _activeSlider) {
            if (_activeSlider == TMEDIA) { _mediaSeekFrac = [self mediaSeekFracFor:&_tiles[i] at:p]; }   // commit on release
            else { float v = [self sliderValueFor:&_tiles[i] at:p];
                   if (_activeSlider == TVOL) [self.actionDelegate barSetVolume:v]; else [self.actionDelegate barSetBrightness:v]; }
            break;
        }
        return;
    }
    // Mode-switch swipe is only recognised when it STARTS in the left tab zone, so
    // dragging the song scrubber / sliders never flips the panel by accident.
    if (!_swiped && _downX <= _swipeMaxX && fabs(p.x - _downX) > 55) {   // horizontal swipe -> switch modes (wraps)
        _swiped = YES;
        NSInteger nm = (p.x - _downX) < 0 ? (_mode + 1) % BarModeCount : (_mode + BarModeCount - 1) % BarModeCount;
        [self setMode:nm animated:self.animateModeSwitch]; [self.actionDelegate barDidChangeMode:nm];
    }
}
- (void)endInteraction {
    if (_pendingPillTap) {   // active pill released before the long-press fired → it's a tap: jump to recent mode
        [self cancelLongPress];
        if (!_arranging && !_swiped) {
            NSInteger target = _prevMode;
            [self setMode:target animated:self.animateModeSwitch];
            [self.actionDelegate barDidChangeMode:target];
        }
    }
    _dragType = -1;   // drop (any reorder was persisted live during the drag)
    if (_agentPressing) {
        _agentPressing = NO;
        BOOL hold = (NSProcessInfo.processInfo.systemUptime - _pressDownT) >= 0.4;
        [self.actionDelegate barAgentUp:hold];
    }
    if (_notePressing) { _notePressing = NO; [self.actionDelegate barNoteUp]; }
    if (_sliding && _activeSlider == TMEDIA) [self.actionDelegate barMediaSeek:_mediaSeekFrac];   // commit the scrub
    _sliding = NO; _activeSlider = -1;
}

#pragma mark - arrange mode (long-press the active pill, then drag tiles to reorder)

- (void)enterArrange { _pendingPillTap = NO; if (_arranging) return; _arranging = YES; [self setNeedsDisplay:YES]; }
- (void)exitArrange { if (!_arranging) return; _arranging = NO; _dragType = -1; [self setNeedsDisplay:YES]; }
- (void)cancelLongPress {
    if (!_pendingPillTap) return;
    _pendingPillTap = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(enterArrange) object:nil];
}
// Tabs and the orb aren't content; everything else (including individual launchers) reorders.
- (BOOL)reorderable:(TileType)t { return !(t == TTAB || t == TAGENT); }

// Live reorder: move the dragged tile to the slot under the finger and persist a
// sequential @"order" for the whole row (the same override the layout editor uses).
// Tracks (type, arg) so the Actions launchers reorder individually.
- (void)dragReorderTo:(NSPoint)p {
    if (_dragType < 0) return;
    TileType types[40]; int args[40]; CGFloat cx[40]; int n = 0;
    for (int i = 0; i < _nTiles && n < 40; i++) {
        if (![self reorderable:_tiles[i].type]) continue;
        types[n] = _tiles[i].type; args[n] = (int)_tiles[i].arg; cx[n] = NSMidX(_tiles[i].rect); n++;
    }
    if (n < 2) return;
    for (int i = 1; i < n; i++) {   // sort left→right by centre x (defensive)
        TileType tt = types[i]; int ag = args[i]; CGFloat c = cx[i]; int j = i - 1;
        while (j >= 0 && cx[j] > c) { types[j+1] = types[j]; args[j+1] = args[j]; cx[j+1] = cx[j]; j--; }
        types[j+1] = tt; args[j+1] = ag; cx[j+1] = c;
    }
    int di = -1; for (int i = 0; i < n; i++) if (types[i] == _dragType && args[i] == _dragArg) { di = i; break; }
    if (di < 0) return;
    int target = 0; for (int i = 0; i < n; i++) { if (i == di) continue; if (cx[i] < p.x) target++; }
    if (target == di) return;   // no slot change
    TileType seqT[40]; int seqA[40]; int m = 0;
    for (int i = 0; i < n; i++) if (i != di) { seqT[m] = types[i]; seqA[m] = args[i]; m++; }
    for (int i = m; i > target; i--) { seqT[i] = seqT[i-1]; seqA[i] = seqA[i-1]; }
    seqT[target] = (TileType)_dragType; seqA[target] = _dragArg; m++;
    for (int i = 0; i < m; i++) setOrderOverride(_mode, seqT[i], seqA[i], i);
    [[NSNotificationCenter defaultCenter] postNotificationName:PBLayoutChangedNotification object:nil];
    [self setNeedsDisplay:YES];
}

// Mouse — used by the desktop Mirror window.
- (void)mouseDown:(NSEvent *)e    { if (e.timestamp - _lastTouchT < 0.5) return; if (pbDebug()) NSLog(@"[PB] mouseDown"); [self beginAt:[self convertPoint:e.locationInWindow fromView:nil]]; }
- (void)mouseDragged:(NSEvent *)e { if (e.timestamp - _lastTouchT < 0.5) return; [self moveAt:[self convertPoint:e.locationInWindow fromView:nil]]; }
- (void)mouseUp:(NSEvent *)e      { if (e.timestamp - _lastTouchT < 0.5) return; [self endInteraction]; }

// Direct touches — how the PHYSICAL Touch Bar delivers input (it does NOT send
// mouse events to a plain custom view). This is what makes the bar tappable.
- (void)touchesBeganWithEvent:(NSEvent *)e {
    _lastTouchT = e.timestamp;
    NSTouch *t = [[e touchesMatchingPhase:NSTouchPhaseBegan inView:self] anyObject];
    if (pbDebug()) NSLog(@"[PB] touchesBegan touch=%@", t ? @"YES" : @"nil");
    if (t) [self beginAt:[t locationInView:self]];
}
- (void)touchesMovedWithEvent:(NSEvent *)e {
    _lastTouchT = e.timestamp;
    NSTouch *t = [[e touchesMatchingPhase:NSTouchPhaseMoved inView:self] anyObject];
    if (t) [self moveAt:[t locationInView:self]];
}
- (void)touchesEndedWithEvent:(NSEvent *)e     { _lastTouchT = e.timestamp; [self endInteraction]; }
- (void)touchesCancelledWithEvent:(NSEvent *)e { _lastTouchT = e.timestamp; [self endInteraction]; }

- (void)fireTap:(Tile *)t at:(NSPoint)p {
    if (pbDebug()) NSLog(@"[PB] fireTap tile=%ld", (long)t->type);
    id<BarActionDelegate> d = self.actionDelegate;
    switch (t->type) {
        case TTAB: { NSInteger target = (t->arg == _mode) ? _prevMode : t->arg;   // tap the active pill -> jump to your last mode
                     [self setMode:target animated:self.animateModeSwitch]; [d barDidChangeMode:target]; break; }
        case TCPU: case TMEM: case TGPU: case TNET: case TDISK: case TUPTIME:   // tap a metric to cycle its view
            _view[t->type] = (_view[t->type] + 1) % viewCount(t->type); [self setNeedsDisplay:YES]; break;
        case TSETTINGS: [d barOpenSettings]; break;
        case TAGENT:    [d barOpenAgent]; break;
        case TLAUNCH: { const Launcher *L = &gLaunchers[(t->arg >= 0 && t->arg < gLauncherCount) ? t->arg : 0];
                        if (L->cmd) [d barRunTerminalCommand:@(L->cmd)]; else [d barLaunchApp:@(L->query)]; break; }
        case TFKEY:     [d barSendFunctionKey:t->arg]; break;
        case TAPP_HIDE: [d barAppAction:@"hide"]; break;
        case TAPP_QUIT: [d barAppAction:@"quit"]; break;
        case TPOMO: {   // stopped: tap the play icon to start, the time to adjust length; running: pause
            BOOL idle = (self.pomodoro.state == PomoIdle);
            if (idle && p.x >= t->rect.origin.x + 24) [d barCyclePomodoroLength];
            else [d barTogglePomodoro];
            [self setNeedsDisplay:YES]; break; }
        case TCAFFEINE: [d barToggleCaffeine]; break;
        case TSC_LOCK:    [d barRunShortcut:@"lock"]; break;
        case TSC_SLEEP:   [d barRunShortcut:@"displaysleep"]; break;
        case TSC_SHOT:    [d barRunShortcut:@"screenshot"]; break;
        case TSC_DARK:    [d barRunShortcut:@"darkmode"]; break;
        case TSC_MISSION: [d barRunShortcut:@"missioncontrol"]; break;
        case TSC_NOTE:    [d barRunShortcut:@"newnote"]; break;
        case TSC_LAUNCH:  [d barRunShortcut:@"launchpad"]; break;
        case TSC_ACTIVITY:[d barRunShortcut:@"activity"]; break;
        case TSC_REMIND:  [d barRunShortcut:@"newreminder"]; break;
        case TMUTE:       [d barToggleMute]; break;
        case TMEDIA: { CGFloat x0 = t->rect.origin.x + 4, bs = 22, gap = 2;
            if (p.x < x0 + bs) [d barMediaPrev];
            else if (p.x < x0 + 2 * (bs + gap)) [d barMediaPlayPause];
            else if (p.x < x0 + 3 * (bs + gap)) [d barMediaNext];
            else {
                // Track area: tapping on/after the progress bar seeks; else toggles play.
                CGFloat tx = x0 + 3 * (bs + gap) + 4, tw = NSMaxX(t->rect) - tx - 4;
                CGFloat bx = tx + 26, bw = tw - 52;   // must match the scrubber in drawTile TMEDIA
                if (_npDuration > 1 && bw > 8 && p.x >= bx)
                    [d barMediaSeek:(float)MAX(0, MIN(1, (p.x - bx) / bw))];
                else
                    [d barMediaPlayPause];
            }
            break; }
        case TVOL:    [d barToggleMute]; break;   // tap on the speaker icon = mute
        default: break;
    }
}

@end

#pragma mark - Layout editor support

@implementation BarView (Layout)

+ (NSString *)nameForMode:(NSInteger)mode {
    switch (mode) {
        case BarModeSystem:       return @"System";
        case BarModeMedia:        return @"Media";
        case BarModeProductivity: return @"Productivity";
        case BarModeClassic:      return @"Classic";
        case BarModeShortcuts:    return @"Shortcuts";
        case BarModeGlance:       return @"Glance";
        default:                  return @"Mode";
    }
}

+ (NSString *)overrideKeyForMode:(NSInteger)mode type:(NSInteger)type {
    return overrideKey(mode, (TileType)type);
}

+ (BOOL)setOverrideForMode:(NSInteger)mode tileToken:(NSString *)token
                      show:(NSNumber *)show size:(NSString *)size {
    TileType t = tileTypeForToken(token);
    if ((int)t < 0) return NO;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = overrideKey(mode, t);
    NSMutableDictionary *o = [([ud dictionaryForKey:key] ?: @{}) mutableCopy];
    if (show) o[@"hidden"] = @(!show.boolValue);
    if (size) {   // coarse voice sizing → relative weight
        NSString *s = size.lowercaseString;
        if ([s isEqualToString:@"big"] || [s isEqualToString:@"bigger"] || [s isEqualToString:@"large"]) o[@"w"] = @2.5;
        else if ([s isEqualToString:@"small"] || [s isEqualToString:@"smaller"]) o[@"w"] = @0.6;
    }
    [ud setObject:o forKey:key];
    return YES;
}

+ (NSArray<NSString *> *)visibleTileNamesForMode:(NSInteger)mode contentWidth:(CGFloat)width {
    TileDef vis[16];
    int n = packVisible(mode, width, vis);
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:n];
    for (int i = 0; i < n; i++) [names addObject:tileName(vis[i].type)];
    return names;
}

+ (void)ensureLayoutSchema { pb_ensureLayoutSchema(); }   // engine owns the schema version

+ (NSArray<NSDictionary *> *)defaultLayoutForMode:(NSInteger)mode {
    TileDef defs[16];
    int n = tilesForMode(mode, defs);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (int i = 0; i < n; i++) {
        if (defs[i].type == TLAUNCH) continue;   // launcher apps aren't individually size-editable
        [out addObject:@{ @"type":   @(defs[i].type),
                          @"name":   tileName(defs[i].type),
                          @"weight": @(defs[i].weight),
                          @"prio":   @(defs[i].prio),
                          @"minW":   @(defs[i].minW) }];
    }
    return out;
}

@end
