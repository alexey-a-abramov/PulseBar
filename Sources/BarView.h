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
- (void)barDidChangeMode:(NSInteger)mode;
- (void)barSendFunctionKey:(NSInteger)n;   // n = 1..12
@end

@interface BarView : NSView

@property (nonatomic, weak) id<BarActionDelegate> actionDelegate;
@property (nonatomic, weak) Pomodoro *pomodoro;
@property (nonatomic) BOOL showCores;          // CPU tile: sparkline vs per-core
@property (nonatomic) BOOL caffeinated;        // caffeine toggle state
@property (nonatomic) BOOL animateModeSwitch;  // NO on the live Touch Bar (DFR), YES on desktop
@property (nonatomic) BOOL fnMode;             // when YES, show F1–F12 instead of the normal bar
@property (nonatomic) double uptime;           // seconds since boot (System mode)
@property (nonatomic, readonly) NSInteger mode;

- (void)setMode:(NSInteger)mode animated:(BOOL)animated;

- (void)updateWithCPU:(double)cpu cores:(const double *)cores count:(int)n
                  mem:(MemInfo)mem net:(NetSample)net gpu:(double)gpu
                 disk:(DiskIO)disk space:(DiskSpace)space battery:(BatteryInfo)bat
              topProc:(NSString *)tp topCPU:(double)tcpu
           nowPlaying:(NowPlaying)np volume:(float)vol mute:(BOOL)mute brightness:(float)bright;

@end
