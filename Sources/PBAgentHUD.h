//
//  PBAgentHUD.h — a small floating, fading "heads-up" panel for the walkie-talkie
//  agent: shows the live transcript while you hold the orb, a thinking state, and
//  short results that fade away. Long/complex results go to the chat window instead.
//
#import <AppKit/AppKit.h>

// The drawable content (exposed so it can be render-verified offscreen).
typedef NS_ENUM(NSInteger, PBHUDMode) { PBHUDListening, PBHUDThinking, PBHUDResult };

@interface PBAgentHUDView : NSView
@property (nonatomic) PBHUDMode mode;
@property (nonatomic, copy) NSString *text;
@end

@interface PBAgentHUD : NSObject
- (void)showListening;
- (void)updatePartial:(NSString *)text;   // live transcript
- (void)showThinking;
- (void)showResult:(NSString *)text;      // shows then auto-fades
- (void)dismiss;                          // fade out now
@end
