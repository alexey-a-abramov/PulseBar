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
}

// Debounced (~0.3s) so quick ⌘-/⌥-shortcuts don't trigger; only a deliberate hold does.
- (void)flagsChanged:(NSEventModifierFlags)flags {
    BOOL cmdNow = (flags & NSEventModifierFlagCommand) != 0, cmdWas = (_prev & NSEventModifierFlagCommand) != 0;
    BOOL optNow = (flags & NSEventModifierFlagOption)  != 0, optWas = (_prev & NSEventModifierFlagOption)  != 0;
    _prev = flags;
    if (optNow && !optWas) [self performSelector:@selector(fireOption) withObject:nil afterDelay:0.30];
    if (!optNow && optWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireOption) object:nil]; [self.delegate modifierMonitorDisengageOption]; }
    if (cmdNow && !cmdWas) [self performSelector:@selector(fireCommand) withObject:nil afterDelay:0.30];
    if (!cmdNow && cmdWas) [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireCommand) object:nil];
}

- (void)fireOption  { [self.delegate modifierMonitorEngageOption]; }
- (void)fireCommand { [self.delegate modifierMonitorEngageCommand]; }

@end
