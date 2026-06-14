//
//  ModifierMonitor.h — watches global ⌘/⌥ flag changes and reports a
//  *deliberate* hold (debounced) so the delegate can drive the bar. Keeps the
//  Accessibility-permission + NSEvent-monitor plumbing out of AppDelegate.
//
#import <AppKit/AppKit.h>

@protocol PBModifierMonitorDelegate <NSObject>
- (void)modifierMonitorEngageOption;      // overlay modifier held deliberately
- (void)modifierMonitorDisengageOption;   // overlay modifier released
- (void)modifierMonitorEngageControl;     // peek modifier held deliberately (momentary)
- (void)modifierMonitorDisengageControl;  // peek modifier released
@end

@interface PBModifierMonitor : NSObject
@property (nonatomic, weak) id<PBModifierMonitorDelegate> delegate;
// Which modifier key triggers each action. Set before calling -enable.
// 0 disables the action. When both masks are equal, peek takes priority.
// Default: peekMask=Control, overlayMask=Option.
@property (nonatomic) NSEventModifierFlags peekMask;
@property (nonatomic) NSEventModifierFlags overlayMask;
- (BOOL)enable;   // prompts for Accessibility, installs monitors; returns trusted?
- (void)disable;
@end
