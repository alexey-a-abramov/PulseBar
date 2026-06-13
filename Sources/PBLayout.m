//
//  PBLayout.m — tile model + size-aware packing engine (see PBLayout.h).
//
#import "PBLayout.h"
#import "BarView.h"       // BarMode constants
#import "PBDefaults.h"

const Launcher gLaunchers[] = {
    { "ARC",      "Arc",       NULL },
    { "TERMIUS",  "Termius 2", NULL },
    { "ZED",      "Zed",       NULL },     // resolves "Zed Preview"
    { "CLAUDE",   "Claude",    NULL },
    { "CODE",     "Claude",    "claude" }, // Claude Code: run `claude` in a terminal
    { "DYNALIST", "Dynalist",  NULL },
};
const int gLauncherCount = (int)(sizeof(gLaunchers) / sizeof(gLaunchers[0]));

int tilesForMode(NSInteger m, TileDef *out) {
    int n = 0;
    #define ADD(t, wt, pr, mn)       do { out[n++] = (TileDef){(t), (wt), (pr), (mn), 0, 0}; } while (0)
    #define ADDM(t, wt, pr, mn, mx)  do { out[n++] = (TileDef){(t), (wt), (pr), (mn), (mx), 0}; } while (0)
    #define ADDL(ix, wt, pr, mn)     do { out[n++] = (TileDef){TLAUNCH, (wt), (pr), (mn), 0, (ix)}; } while (0)
    switch (m) {
        case BarModeSystem:   // capped widths → compact chips + a safe right margin (never cut at the battery)
            ADDM(TCPU,    1.6, 100, 64, 120);  ADDM(TMEM,   1.05, 90, 56, 112);  ADDM(TGPU,   0.7, 45, 44, 78);
            ADDM(TNET,    1.0,  70, 60, 100);  ADDM(TDISK,  1.0,  60, 56, 104);  ADDM(TUPTIME,0.7, 30, 52, 72);
            ADDM(TBATT,   0.3,  80, 40, 46);
            break;
        case BarModeMedia:
            ADD(TMEDIA,  3.0, 100, 140); ADD(TVOL,   1.2,  80, 90);
            break;
        case BarModeProductivity:
            ADDM(TPOMO,   1.5, 100, 80, 150);  ADDM(TSESSION, 0.9, 92, 60, 84);  ADDM(TNOTE, 0.8, 85, 48, 58);
            ADDM(TCAFFEINE,0.85, 80, 52, 64);  ADDM(TSC_REMIND,0.8, 50, 46, 56);  ADDM(TSC_LOCK, 0.8, 70, 46, 56);
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
    #undef ADDM
    #undef ADDL
    return n;
}

// Human-readable tile name for the layout editor.
NSString *tileName(TileType t) {
    switch (t) {
        case TCPU: return @"CPU";          case TMEM: return @"Memory";       case TGPU: return @"GPU";
        case TNET: return @"Network";      case TDISK: return @"Disk I/O";    case TUPTIME: return @"Uptime";
        case TBATT: return @"Battery";     case TMEDIA: return @"Now Playing";case TVOL: return @"Volume";
        case TMUTE: return @"Mute";        case TBRIGHT: return @"Brightness";case TPOMO: return @"Pomodoro";
        case TCAFFEINE: return @"Caffeine";case TSC_NOTE: return @"New Note"; case TSC_REMIND: return @"Reminder";
        case TSC_LOCK: return @"Lock";     case TSC_SLEEP: return @"Sleep";   case TSC_SHOT: return @"Screenshot";
        case TSC_DARK: return @"Dark Mode";case TSC_MISSION: return @"Mission Control";
        case TSC_LAUNCH: return @"Launchpad"; case TSC_ACTIVITY: return @"Activity";
        case TLAUNCH: return @"App"; case TSESSION: return @"Session"; case TNOTE: return @"Side Note";
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
        case TSC_REMIND: return @"sc_remind"; case TLAUNCH: return @"launch"; case TSESSION: return @"sess"; case TNOTE: return @"note";
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
NSString *overrideKey(NSInteger mode, TileType t) {
    return [NSString stringWithFormat:@"PBTile.%@.%@", modeToken(mode), tileToken(t)];
}
// Some tile types can appear MULTIPLE times in a mode (launchers; soon world
// clocks) — they're disambiguated by `arg`, so their override/order keys get a
// per-instance ".<arg>" suffix and they don't share one size-override dict. Every
// other type is single-instance per mode. Add new instanced types here, in ONE place.
static BOOL pb_isInstanced(TileType t) { return t == TLAUNCH; }

// Order key for a tile *instance*: instanced types get a ".<arg>" suffix so each
// instance orders individually; single-instance types keep the plain override key.
static NSString *orderKeyForType(NSInteger mode, TileType t, int arg) {
    return pb_isInstanced(t) ? [overrideKey(mode, t) stringByAppendingFormat:@".%d", arg]
                             : overrideKey(mode, t);
}
// Persist a tile instance's left→right display order (drag-to-arrange + editor).
void setOrderOverride(NSInteger mode, TileType t, int arg, NSInteger order) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *key = orderKeyForType(mode, t, arg);
    NSMutableDictionary *o = [([ud dictionaryForKey:key] ?: @{}) mutableCopy];
    o[@"order"] = @(order);
    [ud setObject:o forKey:key];
    pb_bumpLayoutGen();   // drag-to-arrange writes order without posting the notification
}

// ---- per-mode composition (user add/remove of widgets) --------------------
// PBCompose.<modeTok> = { "removed": [<instanceKey>…], "added": [{token,arg,weight,
// prio,minW,maxW}…] }. Absent ⇒ the mode is exactly its built-in tilesForMode().
static NSString *composeKey(NSInteger mode) { return [@"PBCompose." stringByAppendingString:modeToken(mode)]; }
// Stable per-instance identity for removal matching (token, or token.arg if instanced).
static NSString *instanceKey(TileType t, int arg) {
    NSString *tok = tileToken(t);
    return pb_isInstanced(t) ? [tok stringByAppendingFormat:@".%d", arg] : tok;
}
// The mode's effective tile list: built-in seed, minus `removed`, plus `added`.
static int composedTilesForMode(NSInteger mode, TileDef *out) {
    TileDef seed[16];
    int n = tilesForMode(mode, seed);
    NSDictionary *comp = [NSUserDefaults.standardUserDefaults dictionaryForKey:composeKey(mode)];
    if (![comp isKindOfClass:NSDictionary.class]) { for (int i = 0; i < n; i++) out[i] = seed[i]; return n; }
    NSArray *removed = [comp[@"removed"] isKindOfClass:NSArray.class] ? comp[@"removed"] : nil;
    NSArray *added   = [comp[@"added"]   isKindOfClass:NSArray.class] ? comp[@"added"]   : nil;
    int m = 0;
    for (int i = 0; i < n && m < 16; i++) {
        if (removed && [removed containsObject:instanceKey(seed[i].type, seed[i].arg)]) continue;
        out[m++] = seed[i];
    }
    for (NSDictionary *a in added) {
        if (m >= 16) break;
        if (![a isKindOfClass:NSDictionary.class]) continue;
        TileType t = tileTypeForToken(a[@"token"]);
        if ((int)t < 0) continue;
        TileDef d;
        d.type   = t;
        d.arg    = [a[@"arg"] intValue];
        d.weight = a[@"weight"] ? [a[@"weight"] doubleValue] : 0.8;
        d.prio   = a[@"prio"]   ? [a[@"prio"] intValue]      : 50;
        d.minW   = a[@"minW"]   ? [a[@"minW"] doubleValue]   : 48;
        d.maxW   = a[@"maxW"]   ? [a[@"maxW"] doubleValue]   : 0;
        out[m++] = d;
    }
    return m;
}

// Reverse of tileToken(), plus a few friendly synonyms for voice control.
// Returns -1 if the token names no tile.
TileType tileTypeForToken(NSString *tok) {
    NSString *t = tok.lowercaseString;
    NSDictionary<NSString *, NSNumber *> *synonyms = @{
        @"memory": @(TMEM), @"ram": @(TMEM), @"network": @(TNET), @"battery": @(TBATT),
        @"volume": @(TVOL), @"brightness": @(TBRIGHT), @"pomodoro": @(TPOMO),
    };
    if (synonyms[t]) return (TileType)synonyms[t].intValue;
    for (int i = 0; i <= TTAB; i++) if ([tileToken((TileType)i) isEqualToString:t]) return (TileType)i;
    return (TileType)-1;
}

// Current version of the persisted layout schema. v2: compact BOOL → density.
// v3: reserves the PBCompose.<mode> namespace (per-mode add/remove); no rewrite.
static const NSInteger kLayoutSchemaVersion = 3;

void pb_ensureLayoutSchema(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger stored = [ud integerForKey:PBKeyLayoutSchemaVersion];   // 0 when unset
    if (stored >= kLayoutSchemaVersion) return;
    // v1 → v2: carry an explicit compact choice over; people who never touched
    // the checkbox land on Auto. Object-presence check so a deliberate prior
    // OFF maps to Full, not Auto. PBKeyCompact is never written again.
    if (stored < 2 && [ud objectForKey:PBKeyDensity] == nil && [ud objectForKey:PBKeyCompact] != nil)
        [ud setInteger:([ud boolForKey:PBKeyCompact] ? PBDensityCompact : PBDensityFull) forKey:PBKeyDensity];
    [ud setInteger:kLayoutSchemaVersion forKey:PBKeyLayoutSchemaVersion];
}

// Overlay persisted size-editor overrides on the built-in defaults, dropping
// any tile the user force-hid. Compacts in place; updates *pn.
static void applyTileOverrides(NSInteger mode, TileDef *defs, int *pn) {
    // Stamp the schema version once, on the first override read of the session.
    static dispatch_once_t schemaOnce;
    dispatch_once(&schemaOnce, ^{ pb_ensureLayoutSchema(); });

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    int n = *pn, out = 0;
    for (int i = 0; i < n; i++) {
        // Instanced tiles (launchers, clocks) share one type token, so per-tile
        // size overrides don't apply to them individually — keep them as-is.
        if (!pb_isInstanced(defs[i].type)) {
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
    int n = composedTilesForMode(mode, defs);
    for (int i = 0; i < n; i++) if (defs[i].type == t) return i;
    return 1 << 20;
}

// A tile instance's effective display order: its persisted @"order" override if
// present, else its natural index. For launchers the natural order is the launcher
// index (arg), and the override is keyed per-instance so they reorder individually.
static NSInteger effectiveOrderForDef(NSInteger mode, TileDef d) {
    NSDictionary *o = [NSUserDefaults.standardUserDefaults dictionaryForKey:orderKeyForType(mode, d.type, d.arg)];
    if (o && o[@"order"]) return [o[@"order"] integerValue];
    return pb_isInstanced(d.type) ? d.arg : naturalIndexForType(mode, d.type);
}

CGFloat PBRequiredMinContentWidth(NSInteger mode) {
    TileDef defs[16];
    int n = composedTilesForMode(mode, defs);
    applyTileOverrides(mode, defs, &n);
    CGFloat sum = 0;
    for (int i = 0; i < n; i++) sum += defs[i].minW;
    return sum;
}

// ---- packVisible cache -----------------------------------------------------
// packVisible is a pure function of (mode, avail, the persisted layout). It runs
// every draw — and several times per frame (draw pass, hit-test record pass) — and
// each call does O(n²) NSUserDefaults reads (overrides + per-comparison order +
// the composition dict). Memoize on EXACT (mode, avail, gen): every call in a
// frame shares one avail → all but the first hit; steady-state frames reuse last
// second's entry. gen bumps on any layout write, so the memo is never stale.
static uint64_t gLayoutGen = 1;
void pb_bumpLayoutGen(void) { gLayoutGen++; }

typedef struct { BOOL valid; NSInteger mode; CGFloat avail; uint64_t gen; int count; TileDef out[16]; } PackCache;
static int packCompute(NSInteger mode, CGFloat avail, TileDef *out);

int packVisible(NSInteger mode, CGFloat avail, TileDef *out) {
    static PackCache cache[12]; static int next = 0;
    for (int i = 0; i < 12; i++)
        if (cache[i].valid && cache[i].gen == gLayoutGen && cache[i].mode == mode && cache[i].avail == avail) {
            memcpy(out, cache[i].out, sizeof(TileDef) * cache[i].count);
            return cache[i].count;
        }
    int m = packCompute(mode, avail, out);
    PackCache *e = &cache[next++ % 12];
    e->valid = YES; e->mode = mode; e->avail = avail; e->gen = gLayoutGen; e->count = m;
    memcpy(e->out, out, sizeof(TileDef) * m);
    return m;
}

// Compute which tiles are visible for `mode` at content width `avail`, after
// composition + overrides + priority-based hiding, compacted left→right into
// `out`. Returns the visible count.
static int packCompute(NSInteger mode, CGFloat avail, TileDef *out) {
    TileDef defs[16];
    int n = composedTilesForMode(mode, defs);
    applyTileOverrides(mode, defs, &n);
    if (n <= 0) return 0;

    // Reorder by effective display order before any hiding, so the editor's
    // ▲/▼ arrangement drives the on-screen left→right order. Stable insertion
    // sort over the small array; ties keep the natural (pre-sort) order.
    for (int i = 1; i < n; i++) {
        TileDef key = defs[i];
        NSInteger ko = effectiveOrderForDef(mode, key);
        int j = i - 1;
        while (j >= 0 && effectiveOrderForDef(mode, defs[j]) > ko) { defs[j + 1] = defs[j]; j--; }
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
