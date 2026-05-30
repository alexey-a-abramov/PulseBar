//
//  BarView.h — interactive full-width Touch Bar surface.
//
#import <AppKit/AppKit.h>
#import "Stats.h"
#import "Controls.h"

@class Pomodoro;

@protocol BarActionDelegate <NSObject>
- (void)barSetVolume:(float)v;
- (void)barToggleMute;
- (void)barSetBrightness:(float)v;
- (void)barMediaPlayPause;
- (void)barMediaNext;
- (void)barMediaPrev;
- (void)barTogglePomodoro;
- (void)barOpenSettings;
@end

@interface BarView : NSView

@property (nonatomic, weak) id<BarActionDelegate> actionDelegate;
@property (nonatomic, weak) Pomodoro *pomodoro;
@property (nonatomic) BOOL showCores;          // CPU tile: sparkline vs per-core

- (void)updateWithCPU:(double)cpu cores:(const double *)cores count:(int)n
                  mem:(MemInfo)mem net:(NetSample)net gpu:(double)gpu
                 disk:(DiskIO)disk space:(DiskSpace)space battery:(BatteryInfo)bat
              topProc:(NSString *)tp topCPU:(double)tcpu
           nowPlaying:(NowPlaying)np volume:(float)vol mute:(BOOL)mute brightness:(float)bright;

@end
