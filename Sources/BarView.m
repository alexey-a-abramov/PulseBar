//
//  BarView.m — multi-mode interactive Touch Bar with an animated accordion.
//  Left: mode tabs (the active one expands — the "accordion"). Middle: the
//  active mode's content (cross-fades on switch). Right: battery, clock, gear.
//  Flipped coordinates (origin top-left).
//
#import "BarView.h"
#import "Pomodoro.h"

typedef NS_ENUM(NSInteger, TileType) {
    TCPU, TMEM, TGPU, TNET, TDISK,
    TMEDIA, TVOL, TBRIGHT, TPOMO,
    TCAFFEINE, TSC_LOCK, TSC_SLEEP, TSC_SHOT, TSC_DARK, TSC_MISSION, TSC_NOTE,
    TBATT, TCLOCK, TSETTINGS, TTAB
};
typedef struct { TileType type; NSRect rect; NSInteger arg; } Tile;

static NSString *fmtRate(double bps) {
    const char *u[] = {"B", "K", "M", "G"};
    int i = 0; double v = bps;
    while (v >= 1024.0 && i < 3) { v /= 1024.0; i++; }
    return (i == 0) ? [NSString stringWithFormat:@"%.0f%s", v, u[i]]
                    : [NSString stringWithFormat:@"%.1f%s", v, u[i]];
}
static double toGB(uint64_t b) { return (double)b / (1024.0 * 1024.0 * 1024.0); }

static NSString *modeIcon(NSInteger m) {
    switch (m) {
        case BarModeSystem:       return @"cpu";
        case BarModeMedia:        return @"play.fill";
        case BarModeProductivity: return @"timer";
        case BarModeClassic:      return @"slider.horizontal.3";
        case BarModeShortcuts:    return @"bolt.fill";
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
    }
    return @"";
}
static int tilesForMode(NSInteger m, TileType *out, CGFloat *w) {
    int n = 0;
    #define ADD(t, wt) do { out[n] = (t); w[n++] = (wt); } while (0)
    switch (m) {
        case BarModeSystem:       ADD(TCPU,1.6); ADD(TMEM,1.05); ADD(TGPU,0.7); ADD(TNET,1.0); ADD(TDISK,1.0); break;
        case BarModeMedia:        ADD(TMEDIA,2.4); ADD(TVOL,1.2); break;
        case BarModeProductivity: ADD(TPOMO,1.5); ADD(TCAFFEINE,0.9); ADD(TSC_NOTE,0.9); ADD(TSC_LOCK,0.9); break;
        case BarModeClassic:      ADD(TBRIGHT,1.3); ADD(TVOL,1.3); ADD(TMEDIA,1.8); break;
        case BarModeShortcuts:    ADD(TSC_LOCK,1); ADD(TSC_SLEEP,1); ADD(TSC_SHOT,1); ADD(TSC_DARK,1); ADD(TSC_MISSION,1); ADD(TCAFFEINE,1); break;
    }
    #undef ADD
    return n;
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
    float       _vol, _bright;
    BOOL        _mute;
    double      _netMax, _diskMax;
    NSMutableArray<NSNumber *> *_cpuHist, *_netHist, *_gpuHist;

    NSInteger   _mode, _prevMode;
    double      _anim;            // 1 = settled
    CGFloat     _tabW[BarModeCount];
    NSTimer    *_animTimer;

    Tile        _tiles[40];
    int         _nTiles;
    TileType    _activeSlider;
    BOOL        _sliding;
    CGFloat     _downX;          // for swipe detection
}

- (BOOL)isFlipped { return YES; }
- (NSInteger)mode { return _mode; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _cpuHist = [NSMutableArray array]; _netHist = [NSMutableArray array]; _gpuHist = [NSMutableArray array];
        _netMax = 65536.0; _diskMax = 1048576.0;
        _topProc = @""; _npTitle = @""; _npArtist = @"";
        _activeSlider = -1; _mode = BarModeSystem; _prevMode = BarModeSystem; _anim = 1.0;
        for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i];
    }
    return self;
}

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

- (CGFloat)tabTarget:(NSInteger)m { return (m == _mode) ? 86 : 30; }

- (void)setMode:(NSInteger)mode animated:(BOOL)animated {
    if (mode < 0 || mode >= BarModeCount || mode == _mode) return;
    _prevMode = _mode; _mode = mode;
    if (animated) { _anim = 0; [self startAnim]; }
    else { _anim = 1; for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i]; [self setNeedsDisplay:YES]; }
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
    [s drawAtPoint:p withAttributes:@{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c }]; }
- (void)t:(NSString *)s rx:(CGFloat)rx y:(CGFloat)y sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    NSDictionary *a = @{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c };
    [s drawAtPoint:NSMakePoint(rx - [s sizeWithAttributes:a].width, y) withAttributes:a]; }
- (void)tc:(NSString *)s cx:(CGFloat)cx y:(CGFloat)y sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    NSDictionary *a = @{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c };
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
    NSDictionary *a = @{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c };
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
    [self symbol:sym in:NSMakeRect(r.origin.x, 3, r.size.width, 15) pt:13 color:active ? c : [NSColor colorWithCalibratedWhite:0.92 alpha:1]];
    [self tc:lab cx:NSMidX(r) y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
}

- (void)divider:(CGFloat)x { [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill]; NSRectFill(NSMakeRect(x - 0.5, 6, 1, self.bounds.size.height - 12)); }

#pragma mark - tiles

- (void)drawTile:(Tile)tile {
    NSRect r = tile.rect;
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
            [self label:@"MEM" in:r];
            if (_mem.swapUsedBytes > 0) [self t:[NSString stringWithFormat:@"swap %.1fG", toGB(_mem.swapUsedBytes)]
                                            at:NSMakePoint(r.origin.x + 34, 3) sz:6.5 w:NSFontWeightBold c:[NSColor colorWithSRGBRed:1 green:0.60 blue:0.20 alpha:1]];
            [self t:[NSString stringWithFormat:@"%.0f%%", _mem.usedPct] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self load:_mem.usedPct]];
            CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 17, bh = 8;
            [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:4 yRadius:4] fill];
            CGFloat fw = bw * MAX(0, MIN(1, _mem.usedPct / 100.0));
            if (fw > 1) { [[[self load:_mem.usedPct] colorWithAlphaComponent:0.85] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:4 yRadius:4] fill]; }
            [self t:[NSString stringWithFormat:@"%.1f/%.0fG", toGB(_mem.usedBytes), toGB(_mem.totalBytes)] at:NSMakePoint(bx + 3, by - 0.5) sz:7 w:NSFontWeightMedium c:[NSColor colorWithCalibratedWhite:0.96 alpha:0.95]];
            break; }
        case TGPU: {
            [self label:@"GPU" in:r]; double g = _gpu < 0 ? 0 : _gpu;
            [self t:[NSString stringWithFormat:@"%.0f%%", g] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self gpuC]];
            [self spark:_gpuHist rect:NSMakeRect(r.origin.x + 6, 13, r.size.width - 12, 15) color:[self gpuC] max:100];
            break; }
        case TNET: {
            [self label:@"NET" in:r];
            [self t:[NSString stringWithFormat:@"↓%@", fmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self cyan]];
            [self t:[NSString stringWithFormat:@"↑%@", fmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
            CGFloat sx = r.origin.x + r.size.width * 0.52;
            [self spark:_netHist rect:NSMakeRect(sx, 13, NSMaxX(r) - 6 - sx, 15) color:[self cyan] max:_netMax];
            break; }
        case TDISK: {
            [self label:@"DISK" in:r];
            if (_space.totalBytes) [self t:[NSString stringWithFormat:@"%.0fG", toGB(_space.freeBytes)] rx:NSMaxX(r) - 6 y:1 sz:11 w:NSFontWeightBold c:[NSColor colorWithSRGBRed:0.45 green:0.80 blue:0.92 alpha:1]];
            [self t:[NSString stringWithFormat:@"R %@", fmtRate(_disk.readBps)]  at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self accent]];
            [self t:[NSString stringWithFormat:@"W %@", fmtRate(_disk.writeBps)] at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
            [self t:@"free" rx:NSMaxX(r) - 6 y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
            break; }
        case TMEDIA: {
            CGFloat by = 4, bs = 22, gap = 2, x0 = r.origin.x + 4;
            [self symbol:@"backward.fill"                       in:NSMakeRect(x0, by, bs, bs) pt:11 color:[NSColor whiteColor]];
            [self symbol:_npPlaying ? @"pause.fill" : @"play.fill" in:NSMakeRect(x0 + bs + gap, by, bs, bs) pt:12 color:[self accent]];
            [self symbol:@"forward.fill"                        in:NSMakeRect(x0 + 2 * (bs + gap), by, bs, bs) pt:11 color:[NSColor whiteColor]];
            CGFloat tx = x0 + 3 * (bs + gap) + 4, tw = NSMaxX(r) - tx - 4;
            if (tw > 24) {
                if (_npHasInfo && _npTitle.length) { [self clip:_npTitle at:NSMakePoint(tx, 8) sz:9 w:NSFontWeightSemibold c:[NSColor whiteColor] maxW:tw];
                    [self clip:_npArtist at:NSMakePoint(tx, 19) sz:7.5 w:NSFontWeightMedium c:[self dim] maxW:tw]; }
                else [self t:@"— nothing playing —" at:NSMakePoint(tx, 12) sz:7.5 w:NSFontWeightMedium c:[self dim]];
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
            NSString *lab = p ? [p label] : @"POMODORO", *clock = p ? [p clockText] : @"25:00";
            BOOL work = p && (p.state == PomoWork), running = p && (p.state == PomoWork || p.state == PomoBreak);
            NSColor *col = running ? (work ? [NSColor colorWithSRGBRed:1 green:0.42 blue:0.30 alpha:1] : [self green]) : [self dim];
            [self label:lab in:r];
            [self symbol:running ? @"pause.circle.fill" : @"play.circle.fill" in:NSMakeRect(r.origin.x + 4, 12, 16, 16) pt:13 color:col];
            [self t:clock at:NSMakePoint(r.origin.x + 22, 13) sz:13 w:NSFontWeightBold c:col];
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
        case TBATT: {
            [self label:@"BATT" in:r];
            [self t:[NSString stringWithFormat:@"%.0f%%", _battery.percent] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self batt:_battery.percent chg:_battery.charging]];
            CGFloat bw = 22, bh = 11, bx = r.origin.x + 8, by = 15;
            [[NSColor colorWithCalibratedWhite:0.7 alpha:1] setStroke];
            NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:2.5 yRadius:2.5]; body.lineWidth = 1; [body stroke];
            [[NSColor colorWithCalibratedWhite:0.7 alpha:1] setFill]; NSRectFill(NSMakeRect(bx + bw + 0.5, by + bh / 2 - 2, 1.6, 4));
            [[self batt:_battery.percent chg:_battery.charging] setFill]; NSRectFill(NSMakeRect(bx + 1.5, by + 1.5, (bw - 3) * MAX(0, MIN(1, _battery.percent / 100.0)), bh - 3));
            if (_battery.charging) [self symbol:@"bolt.fill" in:NSMakeRect(bx, by, bw, bh) pt:8 color:[NSColor whiteColor]];
            break; }
        case TCLOCK: {
            static NSDateFormatter *tf = nil, *df = nil;
            if (!tf) { tf = [NSDateFormatter new]; tf.dateFormat = @"HH:mm:ss"; df = [NSDateFormatter new]; df.dateFormat = @"EEE d MMM"; }
            NSDate *now = [NSDate date];
            [self t:[df stringFromDate:now] rx:NSMaxX(r) - 6 y:2 sz:7.5 w:NSFontWeightMedium c:[self dim]];
            [self t:[tf stringFromDate:now] rx:NSMaxX(r) - 6 y:11 sz:14 w:NSFontWeightBold c:[NSColor whiteColor]];
            break; }
        case TSETTINGS: [self symbol:@"gearshape.fill" in:r pt:15 color:[NSColor colorWithCalibratedWhite:0.85 alpha:1]]; break;
        case TTAB: break;
    }
}

#pragma mark - layout

- (void)push:(TileType)type rect:(NSRect)r arg:(NSInteger)arg { if (_nTiles < 40) _tiles[_nTiles++] = (Tile){type, r, arg}; }

- (void)modeContent:(NSInteger)mode in:(NSRect)area draw:(BOOL)draw record:(BOOL)record {
    TileType types[16]; CGFloat wts[16];
    int n = tilesForMode(mode, types, wts);
    CGFloat sum = 0; for (int i = 0; i < n; i++) sum += wts[i];
    CGFloat pad = 4, avail = area.size.width - pad * 2, x = area.origin.x + pad;
    for (int i = 0; i < n; i++) {
        CGFloat tw = avail * wts[i] / sum; NSRect r = NSMakeRect(x, 0, tw, area.size.height);
        if (draw) [self drawTile:(Tile){types[i], r, 0}];
        if (record) [self push:types[i] rect:r arg:0];
        x += tw; if (draw && i < n - 1) [self divider:x];
    }
}

- (void)drawTab:(NSInteger)m rect:(NSRect)r active:(BOOL)active {
    NSRect pill = NSInsetRect(r, 1, 3);
    if (active) {
        [[self accent] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 5, 0, 16, r.size.height) pt:12 color:[NSColor blackColor]];
        if (r.size.width > 34) [self t:modeLabel(m) at:NSMakePoint(r.origin.x + 23, r.size.height / 2 - 5) sz:8.5 w:NSFontWeightHeavy c:[NSColor blackColor]];
    } else {
        [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 3, 0, r.size.width - 6, r.size.height) pt:12 color:[NSColor colorWithCalibratedWhite:0.78 alpha:1]];
    }
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    [[NSColor colorWithCalibratedWhite:0.035 alpha:1] setFill]; NSRectFill(b);
    [[[self load:_cpu] colorWithAlphaComponent:0.10] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));
    _nTiles = 0;

    // right cluster: settings · clock · battery
    CGFloat rx = W - 4;
    NSRect rSet = NSMakeRect(rx - 24, 0, 24, H); rx -= 26; [self drawTile:(Tile){TSETTINGS, rSet, 0}]; [self push:TSETTINGS rect:rSet arg:0];
    NSRect rClk = NSMakeRect(rx - 86, 0, 86, H); rx -= 88; [self drawTile:(Tile){TCLOCK, rClk, 0}];  [self push:TCLOCK rect:rClk arg:0];
    if (_battery.hasBattery) { NSRect rB = NSMakeRect(rx - 54, 0, 54, H); rx -= 56; [self drawTile:(Tile){TBATT, rB, 0}]; [self push:TBATT rect:rB arg:0]; }
    CGFloat rightEdge = rx; [self divider:rightEdge];

    // left tabs (accordion)
    CGFloat tx = 4;
    for (NSInteger m = 0; m < BarModeCount; m++) {
        NSRect tr = NSMakeRect(tx, 0, _tabW[m], H);
        [self drawTab:m rect:tr active:(m == _mode)];
        [self push:TTAB rect:tr arg:m];
        tx += _tabW[m] + 2;
    }
    [self divider:tx + 2];

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
}

#pragma mark - hit testing

- (Tile *)tileAt:(NSPoint)p { for (int i = 0; i < _nTiles; i++) if (NSPointInRect(p, _tiles[i].rect)) return &_tiles[i]; return NULL; }
- (float)sliderValueFor:(Tile *)t at:(NSPoint)p {
    CGFloat iconW = 20, x0 = t->rect.origin.x + iconW + 2, w = t->rect.size.width - iconW - 6;
    return (float)MAX(0, MIN(1, (p.x - x0) / w));
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _downX = p.x; _activeSlider = -1; _sliding = NO;
    Tile *t = [self tileAt:p];
    if (!t) return;
    CGFloat iconW = 20;   // begin slider drags on press for responsiveness
    if (t->type == TBRIGHT) { _activeSlider = TBRIGHT; _sliding = YES; [self.actionDelegate barSetBrightness:[self sliderValueFor:t at:p]]; }
    else if (t->type == TVOL && p.x >= t->rect.origin.x + iconW) { _activeSlider = TVOL; _sliding = YES; [self.actionDelegate barSetVolume:[self sliderValueFor:t at:p]]; }
}

- (void)mouseDragged:(NSEvent *)e {
    if (!_sliding || _activeSlider < 0) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    for (int i = 0; i < _nTiles; i++) if (_tiles[i].type == _activeSlider) {
        float v = [self sliderValueFor:&_tiles[i] at:p];
        if (_activeSlider == TVOL) [self.actionDelegate barSetVolume:v]; else [self.actionDelegate barSetBrightness:v];
        break;
    }
}

- (void)mouseUp:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_sliding) { _sliding = NO; _activeSlider = -1; return; }
    CGFloat dx = p.x - _downX;
    if (fabs(dx) > 45) {   // horizontal swipe -> switch modes (wraps)
        NSInteger nm = dx < 0 ? (_mode + 1) % BarModeCount : (_mode + BarModeCount - 1) % BarModeCount;
        [self setMode:nm animated:YES]; [self.actionDelegate barDidChangeMode:nm];
        return;
    }
    Tile *t = [self tileAt:p]; if (t) [self fireTap:t at:p];   // it was a tap
}

- (void)fireTap:(Tile *)t at:(NSPoint)p {
    id<BarActionDelegate> d = self.actionDelegate;
    switch (t->type) {
        case TTAB:      [self setMode:t->arg animated:YES]; [d barDidChangeMode:t->arg]; break;
        case TCPU:      self.showCores = !self.showCores; [self setNeedsDisplay:YES]; break;
        case TSETTINGS: [d barOpenSettings]; break;
        case TPOMO:     [d barTogglePomodoro]; [self setNeedsDisplay:YES]; break;
        case TCAFFEINE: [d barToggleCaffeine]; break;
        case TSC_LOCK:    [d barRunShortcut:@"lock"]; break;
        case TSC_SLEEP:   [d barRunShortcut:@"displaysleep"]; break;
        case TSC_SHOT:    [d barRunShortcut:@"screenshot"]; break;
        case TSC_DARK:    [d barRunShortcut:@"darkmode"]; break;
        case TSC_MISSION: [d barRunShortcut:@"missioncontrol"]; break;
        case TSC_NOTE:    [d barRunShortcut:@"newnote"]; break;
        case TMEDIA: { CGFloat x0 = t->rect.origin.x + 4, bs = 22, gap = 2;
            if (p.x < x0 + bs) [d barMediaPrev]; else if (p.x < x0 + 2 * (bs + gap)) [d barMediaPlayPause]; else if (p.x < x0 + 3 * (bs + gap)) [d barMediaNext]; break; }
        case TVOL:    [d barToggleMute]; break;   // tap on the speaker icon = mute
        default: break;
    }
}

@end
