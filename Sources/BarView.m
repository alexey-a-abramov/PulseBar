//
//  BarView.m — multi-mode interactive Touch Bar with an animated accordion.
//  Left: mode tabs (the active one expands — the "accordion"). Middle: the
//  active mode's content (cross-fades on switch). Right: battery, clock, gear.
//  Flipped coordinates (origin top-left).
//
#import "BarView.h"
#import "Pomodoro.h"
#import "PBDefaults.h"
#import "AppIndex.h"
#import "Log.h"

NSString * const PBLayoutChangedNotification = @"PBLayoutChanged";

// Right-cluster geometry (drawn in drawRect:): the fixed-width controls pinned
// to the trailing edge — clock and agent orb — plus the gap between them and the
// trailing padding. (Settings now lives in the menu bar, not the cluster.)
static const CGFloat kClusterPad = 4;    // trailing padding before the cluster
static const CGFloat kAgentW     = 32;
static const CGFloat kClusterGap = 2;    // gap between adjacent cluster controls

// NOTE: persisted layout overrides are keyed by tileToken()/modeToken(), not by
// these ordinals, so reordering is safe — but keep tileToken() in sync.
typedef NS_ENUM(NSInteger, TileType) {
    TCPU, TMEM, TGPU, TNET, TDISK, TUPTIME,
    TMEDIA, TVOL, TMUTE, TBRIGHT, TPOMO,
    TCAFFEINE, TSC_LOCK, TSC_SLEEP, TSC_SHOT, TSC_DARK, TSC_MISSION, TSC_NOTE,
    TSC_LAUNCH, TSC_ACTIVITY, TSC_REMIND, TLAUNCH,
    TAGENT, TBATT, TCLOCK, TSETTINGS, TFKEY, TAPP_HIDE, TAPP_QUIT, TTAB
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
static NSString *fmtClock(double sec) { int s = sec < 0 ? 0 : (int)sec; return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60]; }
static NSString *fmtUptime(double sec) {
    int s = (int)sec, d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    if (d > 0) return [NSString stringWithFormat:@"%dd %dh", d, h];
    if (h > 0) return [NSString stringWithFormat:@"%dh %dm", h, m];
    return [NSString stringWithFormat:@"%dm", m];
}

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
// Soft pastel accent per mode — used to fill the active accordion chip.
static NSColor *modePastel(NSInteger m) {
    switch (m) {
        case BarModeSystem:       return [NSColor colorWithSRGBRed:0.66 green:0.83 blue:0.99 alpha:1];  // sky
        case BarModeMedia:        return [NSColor colorWithSRGBRed:0.99 green:0.74 blue:0.82 alpha:1];  // rose
        case BarModeProductivity: return [NSColor colorWithSRGBRed:0.99 green:0.85 blue:0.66 alpha:1];  // peach
        case BarModeClassic:      return [NSColor colorWithSRGBRed:0.70 green:0.92 blue:0.86 alpha:1];  // mint
        case BarModeShortcuts:    return [NSColor colorWithSRGBRed:0.82 green:0.77 blue:0.99 alpha:1];  // lavender
    }
    return [NSColor colorWithSRGBRed:0.66 green:0.83 blue:0.99 alpha:1];
}
// Layout spec for one tile in a mode's content area.
//   weight — share of leftover width once every visible tile has its minW.
//   prio   — higher survives longer; lowest-prio tiles are hidden first when
//            the content area can't fit everyone's minW.
//   minW   — narrowest width at which the tile is still legible.
//   arg    — opaque per-tile index (e.g. which launcher app); 0 for most tiles.
// Array order is the on-screen left→right order; prio is independent of it.
typedef struct { TileType type; CGFloat weight; int prio; CGFloat minW; int arg; } TileDef;

// The Actions mode is a colourful app-launcher palette. Each entry shows the
// real app icon (via PBAppIndex + NSWorkspace) and launches it on tap. `cmd`
// (non-NULL) runs in a terminal instead of opening an app (e.g. Claude Code).
typedef struct { const char *label; const char *query; const char *cmd; } Launcher;
static const Launcher gLaunchers[] = {
    { "ARC",      "Arc",       NULL },
    { "TERMIUS",  "Termius 2", NULL },
    { "ZED",      "Zed",       NULL },     // resolves "Zed Preview"
    { "CLAUDE",   "Claude",    NULL },
    { "CODE",     "Claude",    "claude" }, // Claude Code: run `claude` in a terminal
    { "DYNALIST", "Dynalist",  NULL },
};
static const int gLauncherCount = (int)(sizeof(gLaunchers) / sizeof(gLaunchers[0]));

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

static int tilesForMode(NSInteger m, TileDef *out) {
    int n = 0;
    #define ADD(t, wt, pr, mn)  do { out[n++] = (TileDef){(t), (wt), (pr), (mn), 0}; } while (0)
    #define ADDL(ix, wt, pr, mn) do { out[n++] = (TileDef){TLAUNCH, (wt), (pr), (mn), (ix)}; } while (0)
    switch (m) {
        case BarModeSystem:
            ADD(TCPU,    1.6, 100, 64);  ADD(TMEM,   1.05, 90, 56);  ADD(TGPU,   0.7, 45, 44);
            ADD(TNET,    1.0,  70, 60);  ADD(TDISK,  1.0,  60, 56);  ADD(TUPTIME,0.7, 30, 58);
            ADD(TBATT,   0.3,  80, 40);   // compact battery icon — don't stretch
            break;
        case BarModeMedia:
            ADD(TMEDIA,  3.0, 100, 140); ADD(TVOL,   1.2,  80, 90);
            break;
        case BarModeProductivity:
            ADD(TPOMO,   1.5, 100, 80);  ADD(TCAFFEINE, 0.85, 80, 52);
            ADD(TSC_NOTE,0.8,  60, 46);  ADD(TSC_REMIND,0.8,  50, 46);  ADD(TSC_LOCK, 0.8, 70, 46);
            break;
        case BarModeClassic:
            ADD(TBRIGHT, 1.3,  90, 90);  ADD(TVOL,   1.3, 100, 90);
            ADD(TMUTE,   0.7,  70, 40);  ADD(TMEDIA, 1.8,  80, 120);
            break;
        case BarModeShortcuts:   // app-launcher palette: dense, left-packed (weight 0 = no stretch)
            for (int i = 0; i < gLauncherCount; i++) ADDL(i, 0, 90 - i, 42);   // ~icon + ~1.3·icon pitch
            ADD(TSC_SHOT, 0, 40, 42); ADD(TSC_LOCK, 0, 35, 42);
            break;
    }
    #undef ADD
    #undef ADDL
    return n;
}

// Human-readable tile name for the layout editor.
static NSString *tileName(TileType t) {
    switch (t) {
        case TCPU: return @"CPU";          case TMEM: return @"Memory";       case TGPU: return @"GPU";
        case TNET: return @"Network";      case TDISK: return @"Disk I/O";    case TUPTIME: return @"Uptime";
        case TBATT: return @"Battery";     case TMEDIA: return @"Now Playing";case TVOL: return @"Volume";
        case TMUTE: return @"Mute";        case TBRIGHT: return @"Brightness";case TPOMO: return @"Pomodoro";
        case TCAFFEINE: return @"Caffeine";case TSC_NOTE: return @"New Note"; case TSC_REMIND: return @"Reminder";
        case TSC_LOCK: return @"Lock";     case TSC_SLEEP: return @"Sleep";   case TSC_SHOT: return @"Screenshot";
        case TSC_DARK: return @"Dark Mode";case TSC_MISSION: return @"Mission Control";
        case TSC_LAUNCH: return @"Launchpad"; case TSC_ACTIVITY: return @"Activity";
        case TLAUNCH: return @"App";
        default: return @"—";
    }
}

// Stable string tokens for the persisted override keys. These are written to
// disk, so they MUST stay frozen even if the TileType / BarMode enums are
// reordered or extended — do not rename existing tokens.
static NSString *tileToken(TileType t) {
    switch (t) {
        case TCPU: return @"cpu";          case TMEM: return @"mem";        case TGPU: return @"gpu";
        case TNET: return @"net";          case TDISK: return @"disk";      case TUPTIME: return @"uptime";
        case TBATT: return @"batt";        case TMEDIA: return @"media";    case TVOL: return @"vol";
        case TMUTE: return @"mute";        case TBRIGHT: return @"bright";  case TPOMO: return @"pomo";
        case TCAFFEINE: return @"caffeine";case TSC_LOCK: return @"sc_lock";case TSC_SLEEP: return @"sc_sleep";
        case TSC_SHOT: return @"sc_shot";  case TSC_DARK: return @"sc_dark";case TSC_MISSION: return @"sc_mission";
        case TSC_NOTE: return @"sc_note";  case TSC_LAUNCH: return @"sc_launch"; case TSC_ACTIVITY: return @"sc_activity";
        case TSC_REMIND: return @"sc_remind"; case TLAUNCH: return @"launch";
        default: return [NSString stringWithFormat:@"t%d", (int)t];
    }
}
static NSString *modeToken(NSInteger m) {
    switch (m) {
        case BarModeSystem: return @"system";  case BarModeMedia: return @"media";
        case BarModeProductivity: return @"productivity"; case BarModeClassic: return @"classic";
        case BarModeShortcuts: return @"shortcuts";
        default: return [NSString stringWithFormat:@"m%ld", (long)m];
    }
}
// Per-tile override key, e.g. "PBTile.system.cpu" — stable across enum changes.
static NSString *overrideKey(NSInteger mode, TileType t) {
    return [NSString stringWithFormat:@"PBTile.%@.%@", modeToken(mode), tileToken(t)];
}
// Reverse of tileToken(), plus a few friendly synonyms for voice control.
// Returns -1 if the token names no tile.
static TileType tileTypeForToken(NSString *tok) {
    NSString *t = tok.lowercaseString;
    NSDictionary<NSString *, NSNumber *> *synonyms = @{
        @"memory": @(TMEM), @"ram": @(TMEM), @"network": @(TNET), @"battery": @(TBATT),
        @"volume": @(TVOL), @"brightness": @(TBRIGHT), @"pomodoro": @(TPOMO),
    };
    if (synonyms[t]) return (TileType)synonyms[t].intValue;
    for (int i = 0; i <= TTAB; i++) if ([tileToken((TileType)i) isEqualToString:t]) return (TileType)i;
    return (TileType)-1;
}

// Current version of the persisted per-tile override schema (the {hidden, w,
// prio, order, minW} dicts under overrideKey()). Bump when the on-disk shape
// changes so a future +ensureLayoutSchema can migrate old dicts.
static const NSInteger kLayoutSchemaVersion = 1;

// Overlay persisted size-editor overrides on the built-in defaults, dropping
// any tile the user force-hid. Compacts in place; updates *pn.
static void applyTileOverrides(NSInteger mode, TileDef *defs, int *pn) {
    // Stamp the schema version once, on the first override read of the session.
    static dispatch_once_t schemaOnce;
    dispatch_once(&schemaOnce, ^{ [BarView ensureLayoutSchema]; });

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    int n = *pn, out = 0;
    for (int i = 0; i < n; i++) {
        // Launcher tiles share one type token, so per-tile size overrides don't
        // apply to them individually — keep them as-is.
        if (defs[i].type != TLAUNCH) {
            NSDictionary *o = [ud dictionaryForKey:overrideKey(mode, defs[i].type)];
            if (o) {
                if ([o[@"hidden"] boolValue]) continue;                   // force-hidden → drop
                if (o[@"w"])    defs[i].weight = MAX(0.2, [o[@"w"] doubleValue]);
                if (o[@"prio"]) defs[i].prio   = [o[@"prio"] intValue];
                if (o[@"minW"]) defs[i].minW   = MAX(24, MIN(200, [o[@"minW"] doubleValue]));
            }
        }
        defs[out++] = defs[i];
    }
    *pn = out;
}

// A tile's natural left→right index in a mode (its position in tilesForMode),
// or a large sentinel if it doesn't belong to the mode. Used as the default
// display order when a tile has no explicit @"order" override.
static int naturalIndexForType(NSInteger mode, TileType t) {
    TileDef defs[16];
    int n = tilesForMode(mode, defs);
    for (int i = 0; i < n; i++) if (defs[i].type == t) return i;
    return 1 << 20;
}

// A tile's effective display order: its persisted @"order" override if present,
// else its natural index from tilesForMode. Lower sorts further left.
static NSInteger effectiveOrder(NSInteger mode, TileType t) {
    NSDictionary *o = [NSUserDefaults.standardUserDefaults dictionaryForKey:overrideKey(mode, t)];
    if (o && o[@"order"]) return [o[@"order"] integerValue];
    return naturalIndexForType(mode, t);
}

// Compute which tiles are visible for `mode` at content width `avail`, after
// overrides + priority-based hiding, compacted left→right into `out`. Returns
// the visible count. Shared by the renderer and the layout unit test.
static int packVisible(NSInteger mode, CGFloat avail, TileDef *out) {
    TileDef defs[16];
    int n = tilesForMode(mode, defs);
    applyTileOverrides(mode, defs, &n);
    if (n <= 0) return 0;

    // Reorder by effective display order before any hiding, so the editor's
    // ▲/▼ arrangement drives the on-screen left→right order. Stable insertion
    // sort over the small array; ties keep the natural (pre-sort) order.
    for (int i = 1; i < n; i++) {
        TileDef key = defs[i];
        NSInteger ko = effectiveOrder(mode, key.type);
        int j = i - 1;
        while (j >= 0 && effectiveOrder(mode, defs[j].type) > ko) { defs[j + 1] = defs[j]; j--; }
        defs[j + 1] = key;
    }

    // Hide the lowest-priority tiles until everyone left fits at their minW;
    // at least one tile always survives.
    BOOL vis[16]; int nvis = n; CGFloat needed = 0;
    for (int i = 0; i < n; i++) { vis[i] = YES; needed += defs[i].minW; }
    while (needed > avail && nvis > 1) {
        int worst = -1;
        for (int i = 0; i < n; i++) if (vis[i] && (worst < 0 || defs[i].prio < defs[worst].prio)) worst = i;
        if (worst < 0) break;
        vis[worst] = NO; nvis--; needed -= defs[worst].minW;
    }
    int m = 0;
    for (int i = 0; i < n; i++) if (vis[i]) out[m++] = defs[i];
    return m;
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
    double      _anim;            // 1 = settled
    CGFloat     _tabW[BarModeCount];
    NSTimer    *_animTimer;

    NSInteger   _view[40];        // per-metric alternate-view index (tap to cycle); 0 = default
    Tile        _tiles[40];
    int         _nTiles;
    TileType    _activeSlider;
    BOOL        _sliding;
    BOOL        _swiped;         // a swipe already fired this gesture
    CGFloat     _downX;          // for swipe detection
    NSTimeInterval _lastTouchT;  // suppress mouse synthesized right after a Touch Bar touch
    BOOL        _agentPressing;  // agent orb press in progress
    NSTimeInterval _pressDownT;  // when the orb press began (for hold detection)
}

- (BOOL)isFlipped { return YES; }
- (NSInteger)mode { return _mode; }
- (NSInteger)recentMode { return _prevMode; }

// How many alternate views each metric tile cycles through (tap to switch).
static int viewCount(TileType t) {
    switch (t) { case TCPU: case TMEM: case TGPU: case TNET: case TDISK: return 2; default: return 1; }
}
// CPU's view doubles as the legacy "show cores" toggle (used by the menu item).
- (BOOL)showCores { return _view[TCPU] != 0; }
- (void)setShowCores:(BOOL)v { _view[TCPU] = v ? 1 : 0; [self setNeedsDisplay:YES]; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _cpuHist = [NSMutableArray array]; _netHist = [NSMutableArray array]; _gpuHist = [NSMutableArray array];
        _netMax = 65536.0; _diskMax = 1048576.0;
        _topProc = @""; _npTitle = @""; _npArtist = @"";
        _activeSlider = -1; _mode = BarModeSystem; _prevMode = BarModeSystem; _anim = 1.0;
        for (NSInteger i = 0; i < BarModeCount; i++) _tabW[i] = [self tabTarget:i];
        _lastTouchT = -1; _animateModeSwitch = YES;
        self.allowedTouchTypes = NSTouchTypeMaskDirect;   // receive physical Touch Bar touches
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
    [self symbol:sym in:NSMakeRect(r.origin.x, 3, r.size.width, 15) pt:13 color:active ? c : [NSColor colorWithCalibratedWhite:0.92 alpha:1]];
    [self tc:lab cx:NSMidX(r) y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
}

- (void)divider:(CGFloat)x { [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill]; NSRectFill(NSMakeRect(x - 0.5, 6, 1, self.bounds.size.height - 12)); }

#pragma mark - tiles

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
                NSString *swapStr = [NSString stringWithFormat:@"swap %.0fG", toGB(_mem.swapUsedBytes)];
                if (_mem.swapUsedBytes > 0 && [swapStr sizeWithAttributes:@{ NSFontAttributeName:monoFont(6.5, NSFontWeightBold) }].width <= swapMaxW)
                    [self t:swapStr at:NSMakePoint(swapX, 3) sz:6.5 w:NSFontWeightBold c:orange];
                CGFloat bx = r.origin.x + 6, bw = r.size.width - 12, by = 17, bh = 8;
                [[NSColor colorWithCalibratedWhite:1 alpha:0.10] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, bw, bh) xRadius:4 yRadius:4] fill];
                CGFloat fw = bw * MAX(0, MIN(1, _mem.usedPct / 100.0));
                if (fw > 1) { [[[self load:_mem.usedPct] colorWithAlphaComponent:0.85] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(bx, by, fw, bh) xRadius:4 yRadius:4] fill]; }
                [self t:[NSString stringWithFormat:@"%.1f/%.0fG", toGB(_mem.usedBytes), toGB(_mem.totalBytes)] at:NSMakePoint(bx + 3, by - 0.5) sz:7 w:NSFontWeightMedium c:[NSColor colorWithCalibratedWhite:0.96 alpha:0.95]];
            } else {                                         // pressure + swap
                NSColor *pc = _mem.pressure >= 4 ? [self pink] : (_mem.pressure >= 2 ? orange : [self green]);
                NSString *pw = _mem.pressure >= 4 ? @"critical" : (_mem.pressure >= 2 ? @"warning" : @"normal");
                [pc setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(r.origin.x + 6, 13, 6, 6)] fill];
                [self t:pw at:NSMakePoint(r.origin.x + 15, 11) sz:8 w:NSFontWeightSemibold c:pc];
                [self t:[NSString stringWithFormat:@"swap %.1fG", toGB(_mem.swapUsedBytes)] at:NSMakePoint(r.origin.x + 6, 21) sz:7.5 w:NSFontWeightMedium c:orange];
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
                [self t:[NSString stringWithFormat:@"↓%@", fmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self cyan]];
                [self t:[NSString stringWithFormat:@"↑%@", fmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
                CGFloat sx = r.origin.x + r.size.width * 0.52;
                [self spark:_netHist rect:NSMakeRect(sx, 13, NSMaxX(r) - 6 - sx, 15) color:[self cyan] max:_netMax];
            } else {                                         // fundamental: larger rate readout
                [self t:[NSString stringWithFormat:@"↓ %@", fmtRate(_net.downBps)] at:NSMakePoint(r.origin.x + 6, 11) sz:10 w:NSFontWeightSemibold c:[self cyan]];
                [self t:[NSString stringWithFormat:@"↑ %@", fmtRate(_net.upBps)]   at:NSMakePoint(r.origin.x + 6, 21) sz:10 w:NSFontWeightSemibold c:[self pink]];
            }
            break; }
        case TDISK: {
            [self label:@"DISK" in:r];
            NSColor *dc = [NSColor colorWithSRGBRed:0.45 green:0.80 blue:0.92 alpha:1];
            if (_view[TDISK] == 0) {                         // dynamic: R/W rates + free
                if (_space.totalBytes) [self t:[NSString stringWithFormat:@"%.0fG", toGB(_space.freeBytes)] rx:NSMaxX(r) - 6 y:1 sz:11 w:NSFontWeightBold c:dc];
                [self t:[NSString stringWithFormat:@"R %@", fmtRate(_disk.readBps)]  at:NSMakePoint(r.origin.x + 6, 12) sz:8 w:NSFontWeightSemibold c:[self accent]];
                [self t:[NSString stringWithFormat:@"W %@", fmtRate(_disk.writeBps)] at:NSMakePoint(r.origin.x + 6, 21) sz:8 w:NSFontWeightSemibold c:[self pink]];
                [self t:@"free" rx:NSMaxX(r) - 6 y:21 sz:6.5 w:NSFontWeightBold c:[self dim]];
            } else {                                         // fundamental: free/used space bar
                double frac = _space.totalBytes ? (double)(_space.totalBytes - _space.freeBytes) / _space.totalBytes : 0;
                [self t:[NSString stringWithFormat:@"%.0fG free", toGB(_space.freeBytes)] at:NSMakePoint(r.origin.x + 6, 11) sz:8.5 w:NSFontWeightSemibold c:dc];
                [self t:[NSString stringWithFormat:@"of %.0fG", toGB(_space.totalBytes)] rx:NSMaxX(r) - 6 y:12 sz:7 w:NSFontWeightMedium c:[self dim]];
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
                        [self t:fmtClock(_npElapsed) at:NSMakePoint(tx, 18) sz:7 w:NSFontWeightMedium c:[self dim]];
                        [self t:fmtClock(_npDuration) rx:tx + tw y:18 sz:7 w:NSFontWeightMedium c:[self dim]];
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
        case TSC_LAUNCH:  [self action:@"square.grid.3x3.fill" label:@"APPS"   in:r active:NO color:[self accent]]; break;
        case TSC_ACTIVITY:[self action:@"waveform.path.ecg"    label:@"MONITOR" in:r active:NO color:[self accent]]; break;
        case TSC_REMIND:  [self action:@"checklist"            label:@"REMIND" in:r active:NO color:[self accent]]; break;
        case TMUTE:       [self action:_mute ? @"speaker.slash.fill" : @"speaker.wave.2.fill" label:_mute ? @"MUTED" : @"MUTE" in:r active:_mute color:[self pink]]; break;
        case TUPTIME: {
            // Uptime + the current active working session (resets after a long idle gap).
            [self t:[NSString stringWithFormat:@"up %@",  fmtUptime(self.uptime)]         at:NSMakePoint(r.origin.x + 6, 4)  sz:9 w:NSFontWeightSemibold c:[self accent]];
            [self t:[NSString stringWithFormat:@"ses %@", fmtUptime(self.sessionSeconds)] at:NSMakePoint(r.origin.x + 6, 17) sz:9 w:NSFontWeightSemibold c:[self green]];
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
        [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 5, 0, 16, r.size.height) pt:12 color:ink];
        if (r.size.width > 34) [self t:modeLabel(m) at:NSMakePoint(r.origin.x + 23, r.size.height / 2 - 5) sz:8.5 w:NSFontWeightHeavy c:ink];
    } else {
        [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        [self symbol:modeIcon(m) in:NSMakeRect(r.origin.x + 3, 0, r.size.width - 6, r.size.height) pt:12 color:[NSColor colorWithCalibratedWhite:0.78 alpha:1]];
    }
}

- (void)drawFnKeys:(NSRect)b {
    CGFloat W = b.size.width, H = b.size.height, pad = 4, gap = 3;
    int n = 12;
    CGFloat bw = (W - pad * 2 - gap * (n - 1)) / n, x = pad;
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
    [[[self accent] colorWithAlphaComponent:0.12] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));
    if (self.appIcon) {
        NSRect ir = NSMakeRect(12, (H - 24) / 2, 24, 24);
        [self.appIcon drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    [self t:(self.appName ?: @"App") at:NSMakePoint(44, H / 2 - 9) sz:14 w:NSFontWeightBold c:[NSColor whiteColor]];
    [self t:@"⌥ app — quick actions" at:NSMakePoint(44, H / 2 + 6) sz:8 w:NSFontWeightMedium c:[self dim]];
    CGFloat bw = 74, gap = 8;
    NSRect rh = NSMakeRect(W - 6 - bw * 2 - gap, 0, bw, H);
    NSRect rq = NSMakeRect(W - 6 - bw, 0, bw, H);
    [self drawPillButton:rh label:@"Hide" color:[self accent]];
    [self drawPillButton:rq label:@"Quit" color:[self pink]];
    [self push:TAPP_HIDE rect:rh arg:0];
    [self push:TAPP_QUIT rect:rq arg:0];
}

- (void)drawRect:(NSRect)dirty {
  @try {
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    [[NSColor colorWithCalibratedWhite:0.035 alpha:1] setFill]; NSRectFill(b);
    _nTiles = 0;
    if (self.appOverlay) { [self drawAppOverlay:b]; return; }   // ⌥ held -> app context
    if (self.fnMode)     { [self drawFnKeys:b];     return; }
    [[[self load:_cpu] colorWithAlphaComponent:0.10] setFill]; NSRectFill(NSMakeRect(0, H - 1.5, W, 1.5));

    // Right cluster: just the agent orb, pinned to the trailing edge. No clock
    // (the menu bar shows the time) and no settings gear (it's in the menu too).
    CGFloat rx = W - kClusterPad;
    NSRect rAg = NSMakeRect(rx - kAgentW, 0, kAgentW, H); rx -= kAgentW + kClusterGap; [self drawTile:(Tile){TAGENT, rAg, 0}]; [self push:TAGENT rect:rAg arg:0];
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
    _downX = p.x; _activeSlider = -1; _sliding = NO; _swiped = NO; _agentPressing = NO;
    Tile *t = [self tileAt:p];
    if (pbDebug()) NSLog(@"[PB] beginAt (%.0f,%.0f) tile=%ld", p.x, p.y, t ? (long)t->type : -1);
    if (!t) return;
    if (t->type == TAGENT) {   // agent orb -> push-to-talk (tap toggles, hold = walkie-talkie)
        _agentPressing = YES; _pressDownT = NSProcessInfo.processInfo.systemUptime;
        [self.actionDelegate barAgentDown]; return;
    }
    CGFloat iconW = 20;
    if (t->type == TBRIGHT) { _activeSlider = TBRIGHT; _sliding = YES; [self.actionDelegate barSetBrightness:[self sliderValueFor:t at:p]]; }
    else if (t->type == TVOL && p.x >= t->rect.origin.x + iconW) { _activeSlider = TVOL; _sliding = YES; [self.actionDelegate barSetVolume:[self sliderValueFor:t at:p]]; }
    else { [self fireTap:t at:p]; }   // fire on press — reliable
}
- (void)moveAt:(NSPoint)p {
    if (_agentPressing) return;   // holding the orb (walkie-talkie) — ignore drags/swipes
    if (_sliding && _activeSlider >= 0) {
        for (int i = 0; i < _nTiles; i++) if (_tiles[i].type == _activeSlider) {
            float v = [self sliderValueFor:&_tiles[i] at:p];
            if (_activeSlider == TVOL) [self.actionDelegate barSetVolume:v]; else [self.actionDelegate barSetBrightness:v];
            break;
        }
        return;
    }
    if (!_swiped && fabs(p.x - _downX) > 55) {   // horizontal swipe -> switch modes (wraps)
        _swiped = YES;
        NSInteger nm = (p.x - _downX) < 0 ? (_mode + 1) % BarModeCount : (_mode + BarModeCount - 1) % BarModeCount;
        [self setMode:nm animated:self.animateModeSwitch]; [self.actionDelegate barDidChangeMode:nm];
    }
}
- (void)endInteraction {
    if (_agentPressing) {
        _agentPressing = NO;
        BOOL hold = (NSProcessInfo.processInfo.systemUptime - _pressDownT) >= 0.4;
        [self.actionDelegate barAgentUp:hold];
    }
    _sliding = NO; _activeSlider = -1;
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
        case TCPU: case TMEM: case TGPU: case TNET: case TDISK:   // tap a metric to cycle its view
            _view[t->type] = (_view[t->type] + 1) % viewCount(t->type); [self setNeedsDisplay:YES]; break;
        case TSETTINGS: [d barOpenSettings]; break;
        case TAGENT:    [d barOpenAgent]; break;
        case TLAUNCH: { const Launcher *L = &gLaunchers[(t->arg >= 0 && t->arg < gLauncherCount) ? t->arg : 0];
                        if (L->cmd) [d barRunTerminalCommand:@(L->cmd)]; else [d barLaunchApp:@(L->query)]; break; }
        case TFKEY:     [d barSendFunctionKey:t->arg]; break;
        case TAPP_HIDE: [d barAppAction:@"hide"]; break;
        case TAPP_QUIT: [d barAppAction:@"quit"]; break;
        case TPOMO:     [d barTogglePomodoro]; [self setNeedsDisplay:YES]; break;
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

+ (void)ensureLayoutSchema {
    // Per-tile override dicts (see overrideKey()) are versioned so future shape
    // changes can be migrated. First run with no version recorded: stamp the
    // current one. (No migrations exist yet at v1, so this is behaviour-neutral.)
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud objectForKey:PBKeyLayoutSchemaVersion] == nil)
        [ud setInteger:kLayoutSchemaVersion forKey:PBKeyLayoutSchemaVersion];
}

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
