//
//  BarView.h — interactive, multi-mode Touch Bar surface with an animated
//  accordion mode switcher.
//
#import <AppKit/AppKit.h>
#import "Stats.h"
#import "Controls.h"
#import "PBLayout.h"
#import "PBThermal.h"

@class Pomodoro;

// Mode order matches the accordion tabs on the left.
typedef NS_ENUM(NSInteger, BarMode) {
    BarModeSystem,
    BarModeMedia,
    BarModeProductivity,
    BarModeClassic,
    BarModeShortcuts,
    BarModeGlance,        // dashboard: key metrics + temp + world clocks (clocks' home)
    BarModeCount
};

@protocol BarActionDelegate <NSObject>
- (void)barSetVolume:(float)v;
- (void)barToggleMute;
- (void)barSetBrightness:(float)v;
- (void)barMediaPlayPause;
- (void)barMediaNext;
- (void)barMediaPrev;
- (void)barMediaSeek:(float)fraction;   // tap the progress bar to jump (0..1)
- (void)barTogglePomodoro;
- (void)barCyclePomodoroLength;   // tap the time area when stopped → adjust focus length
- (void)barToggleCaffeine;
- (void)barRunShortcut:(NSString *)action;
- (void)barLaunchApp:(NSString *)query;            // launcher tile — open an app (fuzzy-resolved)
- (void)barRunTerminalCommand:(NSString *)cmd;     // launcher tile — run a command in a terminal
- (void)barOpenSettings;
- (void)barOpenAgent;
- (void)barAgentDown;             // agent orb pressed — start/stop voice capture
- (void)barAgentUp:(BOOL)wasHold; // released (wasHold = walkie-talkie)
- (void)barNoteDown;              // Focus side-note tile pressed — start recording
- (void)barNoteUp;                // released — stop + save the side note
- (void)barAcknowledgeBreak;      // OK pressed on the take-a-break banner
- (void)barDidChangeMode:(NSInteger)mode;
- (void)barSetTabsCollapsed:(BOOL)collapsed;   // chevron on the tab strip toggled collapse
- (void)barSendFunctionKey:(NSInteger)n;   // n = 1..12 (legacy)
- (void)barAppAction:(NSString *)action;   // "hide" | "quit" the frontmost app
@end

@interface BarView : NSView

@property (nonatomic, weak) id<BarActionDelegate> actionDelegate;
@property (nonatomic, weak) Pomodoro *pomodoro;
@property (nonatomic) BOOL showCores;          // CPU tile: sparkline vs per-core
@property (nonatomic) BOOL caffeinated;        // caffeine toggle state
@property (nonatomic) BOOL animateModeSwitch;  // NO on the live Touch Bar (DFR), YES on desktop
// Density: Full / Compact, or Auto — render compact when the content area can't
// fit the mode's full tile set (denser BEFORE the priority system hides tiles).
@property (nonatomic) PBDensity density;
@property (nonatomic) BOOL compactLayout;      // legacy shim: getter = effective compact; setter maps to Full/Compact
@property (nonatomic) BOOL fnMode;             // (legacy) F1–F12 overlay — Fn is handled natively now
@property (nonatomic) BOOL appOverlay;         // ⌥ held: show the frontmost-app overlay
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, strong) NSImage  *appIcon;
@property (nonatomic) double uptime;           // seconds since boot (System mode)
@property (nonatomic) double sessionSeconds;   // length of the current active working session
@property (nonatomic) PBThermalSample thermal; // CPU temp + fan (TTEMP tile)
@property (nonatomic) BOOL   tabsCollapsed;     // collapse the tab strip to the active pill (+ a chevron to expand)
@property (nonatomic) BOOL   noteRecording;    // Focus side-note tile is capturing (turns red)
@property (nonatomic) BOOL   breakReminder;    // ⌃-unmutable "take a break" banner is showing
@property (nonatomic, copy)   NSString *breakReminderText;  // e.g. "1h 26m" — session length shown in the banner
// Safe-area insets: keep drawn content clear of system chrome that overlaps the
// bar — the close box (✕) on the live Touch Bar's left, the system panel on its
// right. Reserved whether or not the chrome is currently visible, so the layout
// never jumps. 0 on the desktop mirror (no chrome there). The bar still fills the
// whole panel; only the tiles/tabs/orb stay inside the safe area.
@property (nonatomic) CGFloat safeAreaLeftInset;
@property (nonatomic) CGFloat safeAreaRightInset;
@property (nonatomic, readonly) NSInteger mode;

- (void)setMode:(NSInteger)mode animated:(BOOL)animated;
- (NSInteger)recentMode;       // the previously-active mode

// The Auto-density predicate (pure; unit-tested). Computes the space left for
// content from the FULL-density tab widths — never from the current compact
// state — so the decision can't feed back into itself and oscillate.
+ (BOOL)effectiveCompactForMode:(NSInteger)mode density:(PBDensity)density
                          width:(CGFloat)width left:(CGFloat)li right:(CGFloat)ri;
- (void)beginPeekMode;         // ⌃ held: momentarily show the previous mode (recentMode is preserved)
- (void)endPeekMode;           // ⌃ released: restore the mode shown before the peek

- (void)updateWithCPU:(double)cpu cores:(const double *)cores count:(int)n
                  mem:(MemInfo)mem net:(NetSample)net gpu:(double)gpu
                 disk:(DiskIO)disk space:(DiskSpace)space battery:(BatteryInfo)bat
              topProc:(NSString *)tp topCPU:(double)tcpu
           nowPlaying:(NowPlaying)np volume:(float)vol mute:(BOOL)mute brightness:(float)bright;

@end

// Posted (on the default center) when the size editor saves a layout change.
extern NSString * const PBLayoutChangedNotification;

// Size/layout editor support: enumerate a mode's built-in tile specs.
@interface BarView (Layout)
+ (NSString *)nameForMode:(NSInteger)mode;
// Ordered specs for a mode. Each dict: @"type"(NSNumber TileType), @"name"(NSString),
// @"weight"(NSNumber), @"prio"(NSNumber), @"minW"(NSNumber).
+ (NSArray<NSDictionary *> *)defaultLayoutForMode:(NSInteger)mode;
// The NSUserDefaults key for a tile's size/priority/visibility override. The
// editor and the renderer MUST agree on this, so both go through here.
+ (NSString *)overrideKeyForMode:(NSInteger)mode type:(NSInteger)type;
// Voice/agent tile control: show/hide or coarsely resize a tile (by stable token
// or a friendly synonym) in `mode`. size is "big"/"small" (nil = unchanged).
// Returns NO if the token names no tile. Caller posts PBLayoutChangedNotification.
+ (BOOL)setOverrideForMode:(NSInteger)mode tileToken:(NSString *)token
                      show:(NSNumber *)show size:(NSString *)size;
// Names of the tiles visible for `mode` at the given content width (after
// overrides + priority hiding), left→right. The renderer uses the same packing.
+ (NSArray<NSString *> *)visibleTileNamesForMode:(NSInteger)mode contentWidth:(CGFloat)width;
// One-time: record the persisted-override schema version in NSUserDefaults if
// absent, so future schema changes have a version to migrate from.
+ (void)ensureLayoutSchema;
@end
