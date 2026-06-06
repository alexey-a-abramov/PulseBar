//
//  ModifierMonitor.m
//
#import "ModifierMonitor.h"
#import <ApplicationServices/ApplicationServices.h>

@implementation PBModifierMonitor {
    id _globalMon, _localMon;
    NSEventModifierFlags _prev;
}

- (BOOL)enable {
    if (!AXIsProcessTrusted())
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
    if (_globalMon) return AXIsProcessTrusted();
    __weak PBModifierMonitor *ws = self;
    _globalMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                                        handler:^(NSEvent *e) { [ws flagsChanged:e.modifierFlags]; }];
    _localMon  = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                                       handler:^NSEvent *(NSEvent *e) { [ws flagsChanged:e.modifierFlags]; return e; }];
    return AXIsProcessTrusted();
}

- (void)disable {
    if (_globalMon) { [NSEvent removeMonitor:_globalMon]; _globalMon = nil; }
    if (_localMon)  { [NSEvent removeMonitor:_localMon];  _localMon = nil; }
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.delegate modifierMonitorDisengageOption];
    [self.delegate modifierMonitorDisengageControl];
}

// Debounced (~0.3s) so quick ⌃-/⌥-shortcuts don't trigger; only a deliberate hold does.
// ⌃ (Control) is a *momentary* modifier: engage on hold, disengage on release.
- (void)flagsChanged:(NSEventModifierFlags)flags {
    BOOL ctlNow = (flags & NSEventModifierFlagControl) != 0, ctlWas = (_prev & NSEventModifierFlagControl) != 0;
    BOOL optNow = (flags & NSEventModifierFlagOption)  != 0, optWas = (_prev & NSEventModifierFlagOption)  != 0;
    _prev = flags;
    if (optNow && !optWas) [self performSelector:@selector(fireOption) withObject:nil afterDelay:0.30];
    if (!optNow && optWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireOption) object:nil]; [self.delegate modifierMonitorDisengageOption]; }
    if (ctlNow && !ctlWas) [self performSelector:@selector(fireControl) withObject:nil afterDelay:0.30];
    if (!ctlNow && ctlWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireControl) object:nil]; [self.delegate modifierMonitorDisengageControl]; }
}

- (void)fireOption  { [self.delegate modifierMonitorEngageOption]; }
- (void)fireControl { [self.delegate modifierMonitorEngageControl]; }

@end
