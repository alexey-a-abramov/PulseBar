//
//  BarView.m — interactive full-width system monitor + controls.
//  Flipped coordinates (origin top-left). Tiles are laid out in drawRect and
//  their frames cached for hit-testing in mouseDown/mouseDragged.
//
#import "BarView.h"
#import "Pomodoro.h"

typedef NS_ENUM(NSInteger, TileType) {
    TCPU, TMEM, TGPU, TNET, TDISK,
    TMEDIA, TVOL, TBRIGHT, TPOMO, TBATT, TCLOCK, TSETTINGS
};
typedef struct { TileType type; CGFloat weight; } TileDef;
typedef struct { TileType type; NSRect rect; } Tile;

static NSString *fmtRate(double bps) {
    const char *u[] = {"B", "K", "M", "G"};
    int i = 0; double v = bps;
    while (v >= 1024.0 && i < 3) { v /= 1024.0; i++; }
    return (i == 0) ? [NSString stringWithFormat:@"%.0f%s", v, u[i]]
                    : [NSString stringWithFormat:@"%.1f%s", v, u[i]];
}
static double toGB(uint64_t b) { return (double)b / (1024.0 * 1024.0 * 1024.0); }

@implementation BarView {
    double      _cpu, _gpu, _topCPU;
    double      _cores[128];
    int         _coreCount;
    MemInfo     _mem;
    NetSample   _net;
    DiskIO      _disk;
    DiskSpace   _space;
    BatteryInfo _battery;
    NSString   *_topProc;
    NSString   *_npTitle, *_npArtist;
    BOOL        _npPlaying, _npHasInfo;
    float       _vol, _bright;
    BOOL        _mute;
    double      _netMax, _diskMax;
    NSMutableArray<NSNumber *> *_cpuHist, *_netHist, *_gpuHist;

    Tile        _tiles[24];
    int         _nTiles;
    TileType    _activeSlider;     // -1 none
    BOOL        _sliding;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _cpuHist = [NSMutableArray array];
        _netHist = [NSMutableArray array];
        _gpuHist = [NSMutableArray array];
        _netMax = 65536.0; _diskMax = 1048576.0;
        _topProc = @""; _npTitle = @""; _npArtist = @"";
        _activeSlider = -1;
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

    [_cpuHist addObject:@(cpu)];
    [_gpuHist addObject:@(gpu < 0 ? 0 : gpu)];
    [_netHist addObject:@(net.downBps + net.upBps)];
    const NSInteger cap = 160;
    while ((NSInteger)_cpuHist.count > cap) [_cpuHist removeObjectAtIndex:0];
    while ((NSInteger)_gpuHist.count > cap) [_gpuHist removeObjectAtIndex:0];
    while ((NSInteger)_netHist.count > cap) [_netHist removeObjectAtIndex:0];
    double m = 65536.0; for (NSNumber *x in _netHist) if (x.doubleValue > m) m = x.doubleValue; _netMax = m;
    double dm = 1048576.0; double dcur = disk.readBps + disk.writeBps; if (dcur > dm) dm = dcur; _diskMax = MAX(_diskMax * 0.95, dm);

    [self setNeedsDisplay:YES];
}

#pragma mark - colours / text

- (NSColor *)load:(double)p {
    if (p < 50) return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1];
    if (p < 80) return [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.04 alpha:1];
    return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1];
}
- (NSColor *)batt:(double)p chg:(BOOL)c {
    if (c) return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1];
    if (p <= 20) return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1];
    if (p <= 40) return [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.04 alpha:1];
    return [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.38 alpha:1];
}
- (NSColor *)dim   { return [NSColor colorWithCalibratedWhite:0.55 alpha:1]; }
- (NSColor *)cyan  { return [NSColor colorWithSRGBRed:0.22 green:0.70 blue:0.96 alpha:1]; }
- (NSColor *)pink  { return [NSColor colorWithSRGBRed:1.00 green:0.32 blue:0.47 alpha:1]; }
- (NSColor *)gpuC  { return [NSColor colorWithSRGBRed:0.66 green:0.45 blue:0.98 alpha:1]; }
- (NSColor *)accent{ return [NSColor colorWithSRGBRed:0.36 green:0.78 blue:0.98 alpha:1]; }

- (void)t:(NSString *)s at:(NSPoint)p sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    [s drawAtPoint:p withAttributes:@{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w],
                                       NSForegroundColorAttributeName:c }];
}
- (void)t:(NSString *)s rx:(CGFloat)rx y:(CGFloat)y sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c {
    NSDictionary *a = @{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c };
    [s drawAtPoint:NSMakePoint(rx - [s sizeWithAttributes:a].width, y) withAttributes:a];
}
- (void)label:(NSString *)s in:(NSRect)r { [self t:s at:NSMakePoint(r.origin.x + 6, 2) sz:7.5 w:NSFontWeightBold c:[self dim]]; }

- (void)symbol:(NSString *)name in:(NSRect)box pt:(CGFloat)pt color:(NSColor *)c {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) { [self t:@"●" at:box.origin sz:pt w:NSFontWeightBold c:c]; return; }
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightSemibold];
    if (@available(macOS 12.0, *)) {
        cfg = [cfg configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:c]];
    }
    NSImage *ti = [img imageWithSymbolConfiguration:cfg];
    NSSize s = ti.size;
    NSRect r = NSMakeRect(box.origin.x + (box.size.width - s.width) / 2,
                          box.origin.y + (box.size.height - s.height) / 2, s.width, s.height);
    [ti drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (void)spark:(NSArray<NSNumber *> *)h rect:(NSRect)r color:(NSColor *)c max:(double)mx {
    if (h.count < 2) return; if (mx <= 0) mx = 1;
    NSBezierPath *p = [NSBezierPath bezierPath];
    NSInteger n = h.count;
    for (NSInteger i = 0; i < n; i++) {
        double f = h[i].doubleValue / mx; if (f > 1) f = 1; if (f < 0) f = 0;
        CGFloat px = r.origin.x + r.size.width * ((CGFloat)i / (CGFloat)(n - 1));
        CGFloat py = r.origin.y + r.size.height * (1.0 - f);
        (i == 0) ? [p moveToPoint:NSMakePoint(px, py)] : [p lineToPoint:NSMakePoint(px, py)];
    }
    NSBezierPath *fill = [p copy];
    [fill lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r))];
    [fill lineToPoint:NSMakePoint(r.origin.x, NSMaxY(r))];
    [fill closePath];
    [[c colorWithAlphaComponent:0.18] setFill]; [fill fill];
    [c setStroke]; p.lineWidth = 1.4; [p stroke];
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
                for (int i = 0; i < _coreCount; i++) {
                    CGFloat bh = MAX(1.5, content.size.height * (_cores[i] / 100.0));
                    [[self load:_cores[i]] setFill];
                    NSRectFill(NSMakeRect(content.origin.x + i * (bw + gap), NSMaxY(content) - bh, bw, bh));
                }
            } else {
                [self label:@"CPU" in:r];
                [self spark:_cpuHist rect:NSMakeRect(r.origin.x + 6, 12, r.size.width - 12, 10) color:[self load:_cpu] max:100];
                if (_topProc.length) {
                    NSString *tp = [NSString stringWithFormat:@"▸ %@ %.0f%%", _topProc, _topCPU];
                    [self clip:tp at:NSMakePoint(r.origin.x + 6, 22) sz:6.5 w:NSFontWeightMedium c:[self dim] maxW:r.size.width - 12];
                }
            }
            [self t:[NSString stringWithFormat:@"%.0f%%", _cpu] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self load:_cpu]];
            break;
        }
        case TMEM: {
            [self label:@"MEM" in:r];
            [self t:[NSString stringWithFormat:@"%.0f%%", _mem.usedPct] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self load:_mem.usedPct]];
            CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 17, bh = 8;
            [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:4 yRadius:4] fill];
            CGFloat fw = bw * MAX(0, MIN(1, _mem.usedPct / 100.0));
            if (fw > 1) { [[[self load:_mem.usedPct] colorWithAlphaComponent:0.85] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:4 yRadius:4] fill]; }
            [self t:[NSString stringWithFormat:@"%.1f/%.0fG", toGB(_mem.usedBytes), toGB(_mem.totalBytes)]
                   at:NSMakePoint(bx + 3, by - 0.5) sz:7 w:NSFontWeightMedium c:[NSColor colorWithCalibratedWhite:0.96 alpha:0.95]];
            break;
        }
        case TGPU: {
            [self label:@"GPU" in:r];
            double g = _gpu < 0 ? 0 : _gpu;
            [self t:[NSString stringWithFormat:@"%.0f%%", g] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self gpuC]];
            [self spark:_gpuHist rect:NSMakeRect(r.origin.x + 6, 13, r.size.width - 12, 15) color:[self gpuC] max:100];
            break;
        }
        case TNET: {
            [self label:@"NET" in:r];
            [self t:[NSString stringWithFormat:@"↓%@", fmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self cyan]];
            [self t:[NSString stringWithFormat:@"↑%@", fmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
            CGFloat sx = r.origin.x + r.size.width * 0.52;
            [self spark:_netHist rect:NSMakeRect(sx, 13, NSMaxX(r) - 6 - sx, 15) color:[self cyan] max:_netMax];
            break;
        }
        case TDISK: {
            [self label:@"DISK" in:r];
            if (_space.totalBytes) [self t:[NSString stringWithFormat:@"%.0fG", toGB(_space.freeBytes)]
                                       rx:NSMaxX(r) - 6 y:1 sz:11 w:NSFontWeightBold c:[NSColor colorWithSRGBRed:0.45 green:0.80 blue:0.92 alpha:1]];
            [self t:[NSString stringWithFormat:@"R %@", fmtRate(_disk.readBps)]  at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self accent]];
            [self t:[NSString stringWithFormat:@"W %@", fmtRate(_disk.writeBps)] at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
            [self t:@"free" rx:NSMaxX(r) - 6 y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
            break;
        }
        case TMEDIA: {
            // three transport buttons on the left, track text on the right
            CGFloat by = 4, bs = 22, gap = 2, x0 = r.origin.x + 4;
            [self symbol:@"backward.fill"          in:NSMakeRect(x0,            by, bs, bs) pt:11 color:[NSColor whiteColor]];
            [self symbol:_npPlaying ? @"pause.fill":@"play.fill" in:NSMakeRect(x0 + bs + gap,   by, bs, bs) pt:12 color:[self accent]];
            [self symbol:@"forward.fill"           in:NSMakeRect(x0 + 2*(bs+gap), by, bs, bs) pt:11 color:[NSColor whiteColor]];
            CGFloat tx = x0 + 3 * (bs + gap) + 4, tw = NSMaxX(r) - tx - 4;
            if (tw > 24) {
                if (_npHasInfo && _npTitle.length) {
                    [self clip:_npTitle at:NSMakePoint(tx, 8)  sz:9 w:NSFontWeightSemibold c:[NSColor whiteColor] maxW:tw];
                    [self clip:_npArtist at:NSMakePoint(tx, 19) sz:7.5 w:NSFontWeightMedium c:[self dim] maxW:tw];
                } else {
                    [self t:@"— nothing playing —" at:NSMakePoint(tx, 12) sz:7.5 w:NSFontWeightMedium c:[self dim]];
                }
            }
            break;
        }
        case TVOL: {
            CGFloat iconW = 20;
            NSString *sym = _mute ? @"speaker.slash.fill" : (_vol < 0.33 ? @"speaker.fill" : @"speaker.wave.2.fill");
            [self symbol:sym in:NSMakeRect(r.origin.x + 2, 4, iconW, 22) pt:11 color:_mute ? [self pink] : [NSColor whiteColor]];
            [self slider:NSMakeRect(r.origin.x + iconW + 2, 0, r.size.width - iconW - 6, r.size.height)
                    value:_mute ? 0 : _vol color:[self accent] label:@"VOL"];
            break;
        }
        case TBRIGHT: {
            CGFloat iconW = 20;
            [self symbol:@"sun.max.fill" in:NSMakeRect(r.origin.x + 2, 4, iconW, 22) pt:12 color:[NSColor colorWithSRGBRed:1 green:0.8 blue:0.2 alpha:1]];
            [self slider:NSMakeRect(r.origin.x + iconW + 2, 0, r.size.width - iconW - 6, r.size.height)
                    value:_bright < 0 ? 0 : _bright color:[NSColor colorWithSRGBRed:1 green:0.8 blue:0.3 alpha:1] label:@"BRIGHT"];
            break;
        }
        case TPOMO: {
            Pomodoro *p = self.pomodoro;
            NSString *lab = p ? [p label] : @"POMODORO";
            NSString *clock = p ? [p clockText] : @"25:00";
            BOOL work = p && (p.state == PomoWork);
            BOOL running = p && (p.state == PomoWork || p.state == PomoBreak);
            NSColor *col = running ? (work ? [NSColor colorWithSRGBRed:1 green:0.42 blue:0.30 alpha:1]
                                           : [NSColor colorWithSRGBRed:0.30 green:0.82 blue:0.45 alpha:1])
                                   : [self dim];
            [self label:lab in:r];
            [self symbol:running ? @"pause.circle.fill" : @"play.circle.fill"
                      in:NSMakeRect(r.origin.x + 4, 12, 16, 16) pt:13 color:col];
            [self t:clock at:NSMakePoint(r.origin.x + 22, 13) sz:13 w:NSFontWeightBold c:col];
            // progress bar
            if (p && running) {
                CGFloat bx = r.origin.x + 6, bw = r.size.width - 12;
                [[col colorWithAlphaComponent:0.25] setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw, 1.5));
                [col setFill]; NSRectFill(NSMakeRect(bx, NSMaxY(r) - 3, bw * [p progress], 1.5));
            }
            break;
        }
        case TBATT: {
            [self label:@"BATT" in:r];
            [self t:[NSString stringWithFormat:@"%.0f%%", _battery.percent] rx:NSMaxX(r) - 6 y:1 sz:12 w:NSFontWeightBold c:[self batt:_battery.percent chg:_battery.charging]];
            CGFloat bw = 22, bh = 11, bx = r.origin.x + 8, by = 15;
            [[NSColor colorWithCalibratedWhite:0.7 alpha:1] setStroke];
            NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:2.5 yRadius:2.5];
            body.lineWidth = 1; [body stroke];
            [[NSColor colorWithCalibratedWhite:0.7 alpha:1] setFill];
            NSRectFill(NSMakeRect(bx + bw + 0.5, by + bh / 2 - 2, 1.6, 4));
            [[self batt:_battery.percent chg:_battery.charging] setFill];
            NSRectFill(NSMakeRect(bx + 1.5, by + 1.5, (bw - 3) * MAX(0, MIN(1, _battery.percent / 100.0)), bh - 3));
            if (_battery.charging) [self symbol:@"bolt.fill" in:NSMakeRect(bx, by, bw, bh) pt:8 color:[NSColor whiteColor]];
            break;
        }
        case TCLOCK: {
            static NSDateFormatter *tf = nil, *df = nil;
            if (!tf) { tf = [NSDateFormatter new]; tf.dateFormat = @"HH:mm:ss"; df = [NSDateFormatter new]; df.dateFormat = @"EEE d MMM"; }
            NSDate *now = [NSDate date];
            [self t:[df stringFromDate:now] rx:NSMaxX(r) - 6 y:2 sz:7.5 w:NSFontWeightMedium c:[self dim]];
            [self t:[tf stringFromDate:now] rx:NSMaxX(r) - 6 y:11 sz:14 w:NSFontWeightBold c:[NSColor whiteColor]];
            break;
        }
        case TSETTINGS: {
            [self symbol:@"gearshape.fill" in:r pt:15 color:[NSColor colorWithCalibratedWhite:0.85 alpha:1]];
            break;
        }
    }
}

- (void)clip:(NSString *)s at:(NSPoint)p sz:(CGFloat)sz w:(NSFontWeight)w c:(NSColor *)c maxW:(CGFloat)maxW {
    NSDictionary *a = @{ NSFontAttributeName:[NSFont monospacedSystemFontOfSize:sz weight:w], NSForegroundColorAttributeName:c };
    NSString *str = s;
    while ([str sizeWithAttributes:a].width > maxW && str.length > 1)
        str = [[str substringToIndex:str.length - 2] stringByAppendingString:@"…"];
    [str drawAtPoint:p withAttributes:a];
}

- (void)slider:(NSRect)area value:(float)v color:(NSColor *)c label:(NSString *)lab {
    CGFloat y = area.origin.y + area.size.height / 2 - 1;
    CGFloat x0 = area.origin.x, w = area.size.width;
    [[NSColor colorWithCalibratedWhite:1 alpha:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x0, y, w, 3) xRadius:1.5 yRadius:1.5] fill];
    CGFloat fw = w * MAX(0, MIN(1, v));
    [c setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x0, y, fw, 3) xRadius:1.5 yRadius:1.5] fill];
    // knob
    [[NSColor whiteColor] setFill];
    NSRect knob = NSMakeRect(x0 + fw - 3, y - 2.5, 6, 8);
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:2 yRadius:2] fill];
    [self t:lab at:NSMakePoint(x0, area.origin.y + 1) sz:6.5 w:NSFontWeightBold c:[self dim]];
}

#pragma mark - layout

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    [[NSColor colorWithCalibratedWhite:0.035 alpha:1] setFill]; NSRectFill(b);
    [[[self load:_cpu] colorWithAlphaComponent:0.10] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));

    BOOL hasBat = _battery.hasBattery;
    TileDef defs[16]; int nd = 0;
    defs[nd++] = (TileDef){TCPU,    1.45};
    defs[nd++] = (TileDef){TMEM,    0.95};
    defs[nd++] = (TileDef){TGPU,    0.62};
    defs[nd++] = (TileDef){TNET,    1.00};
    defs[nd++] = (TileDef){TDISK,   0.95};
    defs[nd++] = (TileDef){TMEDIA,  1.55};
    defs[nd++] = (TileDef){TVOL,    0.95};
    defs[nd++] = (TileDef){TBRIGHT, 0.95};
    defs[nd++] = (TileDef){TPOMO,   1.05};
    if (hasBat) defs[nd++] = (TileDef){TBATT, 0.62};
    defs[nd++] = (TileDef){TCLOCK,  0.95};
    defs[nd++] = (TileDef){TSETTINGS, 0.40};

    CGFloat sum = 0; for (int i = 0; i < nd; i++) sum += defs[i].weight;
    CGFloat pad = 5, avail = W - pad * 2, x = pad;
    _nTiles = 0;
    for (int i = 0; i < nd; i++) {
        CGFloat tw = avail * defs[i].weight / sum;
        NSRect r = NSMakeRect(x, 0, tw, H);
        _tiles[_nTiles++] = (Tile){defs[i].type, r};
        [self drawTile:(Tile){defs[i].type, r}];
        x += tw;
        if (i < nd - 1) [self divider:x];
    }
}

#pragma mark - hit testing

- (Tile *)tileAt:(NSPoint)p {
    for (int i = 0; i < _nTiles; i++) if (NSPointInRect(p, _tiles[i].rect)) return &_tiles[i];
    return NULL;
}

- (float)sliderValueFor:(Tile *)t at:(NSPoint)p {
    CGFloat iconW = 20, x0 = t->rect.origin.x + iconW + 2, w = t->rect.size.width - iconW - 6;
    return (float)MAX(0, MIN(1, (p.x - x0) / w));
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    Tile *t = [self tileAt:p];
    _activeSlider = -1; _sliding = NO;
    if (!t) return;
    id<BarActionDelegate> d = self.actionDelegate;
    switch (t->type) {
        case TCPU:   self.showCores = !self.showCores; [self setNeedsDisplay:YES]; break;
        case TSETTINGS: [d barOpenSettings]; break;
        case TPOMO:  [d barTogglePomodoro]; [self setNeedsDisplay:YES]; break;
        case TMEDIA: {
            CGFloat x0 = t->rect.origin.x + 4, bs = 22, gap = 2;
            if (p.x < x0 + bs) [d barMediaPrev];
            else if (p.x < x0 + 2 * (bs + gap)) [d barMediaPlayPause];
            else if (p.x < x0 + 3 * (bs + gap)) [d barMediaNext];
            break;
        }
        case TVOL: {
            CGFloat iconW = 20;
            if (p.x < t->rect.origin.x + iconW) { [d barToggleMute]; }
            else { _activeSlider = TVOL; _sliding = YES; [d barSetVolume:[self sliderValueFor:t at:p]]; }
            break;
        }
        case TBRIGHT: { _activeSlider = TBRIGHT; _sliding = YES; [d barSetBrightness:[self sliderValueFor:t at:p]]; break; }
        default: break;
    }
}

- (void)mouseDragged:(NSEvent *)e {
    if (!_sliding || _activeSlider < 0) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    for (int i = 0; i < _nTiles; i++) {
        if (_tiles[i].type == _activeSlider) {
            float v = [self sliderValueFor:&_tiles[i] at:p];
            if (_activeSlider == TVOL) [self.actionDelegate barSetVolume:v];
            else                       [self.actionDelegate barSetBrightness:v];
            break;
        }
    }
}

- (void)mouseUp:(NSEvent *)e { _sliding = NO; _activeSlider = -1; }

@end
