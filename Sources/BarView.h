//
//  BarView.h — interactive, multi-mode Touch Bar surface with an animated
//  accordion mode switcher.
//
#import <AppKit/AppKit.h>
#import "Stats.h"
#import "Controls.h"

@class Pomodoro;

// Mode order matches the accordion tabs on the left.
typedef NS_ENUM(NSInteger, BarMode) {
    BarModeSystem,
    BarModeMedia,
    BarModeProductivity,
    BarModeClassic,
    BarModeShortcuts,
    BarModeCount
};

@protocol BarActionDelegate <NSObject>
- (void)barSetVolume:(float)v;
- (void)barToggleMute;
- (void)barSetBrightness:(float)v;
- (void)barMediaPlayPause;
- (void)barMediaNext;
- (void)barMediaPrev;
- (void)barTogglePomodoro;
- (void)barToggleCaffeine;
- (void)barRunShortcut:(NSString *)action;
- (void)barOpenSettings;
- (void)barOpenAgent;
- (void)barAgentDown;             // agent orb pressed — start/stop voice capture
- (void)barAgentUp:(BOOL)wasHold; // released (wasHold = walkie-talkie)
- (void)barDidChangeMode:(NSInteger)mode;
- (void)barSendFunctionKey:(NSInteger)n;   // n = 1..12 (legacy)
- (void)barAppAction:(NSString *)action;   // "hide" | "quit" the frontmost app
@end

@interface BarView : NSView

@property (nonatomic, weak) id<BarActionDelegate> actionDelegate;
@property (nonatomic, weak) Pomodoro *pomodoro;
@property (nonatomic) BOOL showCores;          // CPU tile: sparkline vs per-core
@property (nonatomic) BOOL caffeinated;        // caffeine toggle state
@property (nonatomic) BOOL animateModeSwitch;  // NO on the live Touch Bar (DFR), YES on desktop
@property (nonatomic) BOOL fnMode;             // (legacy) F1–F12 overlay — Fn is handled natively now
@property (nonatomic) BOOL appOverlay;         // ⌥ held: show the frontmost-app overlay
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, strong) NSImage  *appIcon;
@property (nonatomic) double uptime;           // seconds since boot (System mode)
@property (nonatomic, readonly) NSInteger mode;

- (void)setMode:(NSInteger)mode animated:(BOOL)animated;
- (NSInteger)recentMode;       // the previously-active mode

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
// Names of the tiles visible for `mode` at the given content width (after
// overrides + priority hiding), left→right. The renderer uses the same packing.
+ (NSArray<NSString *> *)visibleTileNamesForMode:(NSInteger)mode contentWidth:(CGFloat)width;
// One-time: record the persisted-override schema version in NSUserDefaults if
// absent, so future schema changes have a version to migrate from.
+ (void)ensureLayoutSchema;
@end
