//
//  MirrorController.h — the desktop "mirror": a floating, clickable copy of the
//  Touch Bar in a panel. Owns the panel + its BarView and the show/hide
//  visibility persistence. Feed `.bar` exactly like the live bar.
//
#import <AppKit/AppKit.h>
#import "BarView.h"

@class Pomodoro;

@interface PBMirrorController : NSObject
@property (nonatomic, readonly) BarView *bar;     // the mirror's BarView — push the same updates here
@property (nonatomic, readonly) BOOL     visible;
- (instancetype)initWithActionDelegate:(id<BarActionDelegate>)delegate pomodoro:(Pomodoro *)pomo mode:(NSInteger)mode;
- (void)show;
- (void)hide;
- (void)toggle;
- (void)suspendPersistence;   // before app termination: don't persist "hidden" when the panel closes
@end
