//
//  ModifierMonitor.h — watches global ⌘/⌥ flag changes and reports a
//  *deliberate* hold (debounced) so the delegate can drive the bar. Keeps the
//  Accessibility-permission + NSEvent-monitor plumbing out of AppDelegate.
//
#import <AppKit/AppKit.h>

@protocol PBModifierMonitorDelegate <NSObject>
- (void)modifierMonitorEngageOption;     // ⌥ held deliberately
- (void)modifierMonitorDisengageOption;  // ⌥ released
- (void)modifierMonitorEngageCommand;    // ⌘ held deliberately
@end

@interface PBModifierMonitor : NSObject
@property (nonatomic, weak) id<PBModifierMonitorDelegate> delegate;
- (BOOL)enable;   // prompts for Accessibility, installs monitors; returns trusted?
- (void)disable;
@end
