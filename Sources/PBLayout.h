//
//  PBLayout.h — PulseBar's AppKit-free tile model + size-aware packing engine.
//  Lifted out of BarView so the layout logic (which tiles a mode has, which fit
//  a given content width, and the persisted override keys) is a small,
//  independently testable module. Pure Foundation — no view / drawing state.
//
#import <Foundation/Foundation.h>

// Identity of every tile the bar can show. Order is NOT persisted (tokens are),
// so it's safe to reorder the enum — but keep tileToken() in sync.
typedef NS_ENUM(NSInteger, TileType) {
    TCPU, TMEM, TGPU, TNET, TDISK, TUPTIME,
    TMEDIA, TVOL, TMUTE, TBRIGHT, TPOMO,
    TCAFFEINE, TSC_LOCK, TSC_SLEEP, TSC_SHOT, TSC_DARK, TSC_MISSION, TSC_NOTE,
    TSC_LAUNCH, TSC_ACTIVITY, TSC_REMIND, TLAUNCH, TSESSION, TNOTE,
    TAGENT, TBATT, TCLOCK, TSETTINGS, TFKEY, TAPP_HIDE, TAPP_QUIT,
    TWCLOCK,        // world clock — instanced by city index (arg = gCities idx)
    TTEMP,          // CPU temperature + fan
    TTAB            // active-mode pill — keep LAST: tileTypeForToken iterates [0, TTAB]
};

// Layout spec for one tile in a mode's content area.
//   weight — share of leftover width once every visible tile has its minW.
//   prio   — higher survives longer; lowest-prio tiles hide first when the row
//            can't fit everyone's minW.
//   minW   — narrowest width at which the tile is still legible.
//   maxW   — cap on width (0 = uncapped); freed space becomes right margin.
//   arg    — opaque per-tile index (e.g. which launcher app); 0 for most tiles.
// Array order is the on-screen left→right order; prio is independent of it.
typedef struct { TileType type; CGFloat weight; int prio; CGFloat minW; CGFloat maxW; int arg; } TileDef;

// The Actions launcher palette (the table is shared with BarView's icon drawing).
typedef struct { const char *label; const char *query; const char *cmd; } Launcher;
extern const Launcher gLaunchers[];
extern const int gLauncherCount;

// Built-in tile list for `mode`, left→right; returns the count written to `out`
// (caller supplies TileDef[16]).
int tilesForMode(NSInteger mode, TileDef *out);
// Human-readable tile name (for the layout editor).
NSString *tileName(TileType t);
// Persisted per-tile override key, e.g. "PBTile.system.cpu".
NSString *overrideKey(NSInteger mode, TileType t);
// Reverse of the tile token (+ a few voice synonyms); (TileType)-1 if unknown.
TileType tileTypeForToken(NSString *token);
// Persist a tile instance's left→right display order (drag-to-arrange + editor).
void setOrderOverride(NSInteger mode, TileType t, int arg, NSInteger order);
// Tiles visible for `mode` at content width `avail`, after overrides + priority
// hiding, compacted left→right into `out` (TileDef[16]); returns the count.
int packVisible(NSInteger mode, CGFloat avail, TileDef *out);
// Stamp the persisted-override schema version on first run (idempotent).
void pb_ensureLayoutSchema(void);

// Invalidate the packVisible cache. Call after ANY change to the persisted
// layout (overrides, order, or the per-mode add/remove composition) — the bar
// observes PBLayoutChangedNotification and calls this.
void pb_bumpLayoutGen(void);

// Bar density. Auto = passive adaptation: render compact (icon-only pill +
// icon-only actions) when the content area can't fit the mode's full tile set —
// i.e. go denser BEFORE the priority system starts hiding tiles.
typedef NS_ENUM(NSInteger, PBDensity) { PBDensityAuto = 0, PBDensityFull = 1, PBDensityCompact = 2 };

// Width the mode needs to show EVERY tile at its full minW (overrides applied,
// no priority hiding). The Auto-density predicate compares this to the space left
// after the insets/tabs/cluster.
CGFloat PBRequiredMinContentWidth(NSInteger mode);
