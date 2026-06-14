//
//  ModifierMonitor.m
//
#import "ModifierMonitor.h"
#import <ApplicationServices/ApplicationServices.h>

@implementation PBModifierMonitor {
    id _globalMon, _localMon;
    NSEventModifierFlags _prev;
}

- (instancetype)init {
    if ((self = [super init])) {
        _peekMask    = NSEventModifierFlagControl;
        _overlayMask = NSEventModifierFlagOption;
    }
    return self;
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

// Debounced (~0.3s) so quick modifier-shortcuts don't trigger; only a deliberate hold does.
// Peek is momentary: engage on hold, disengage on release.
// When both masks are equal, peek takes priority (overlay is suppressed).
- (void)flagsChanged:(NSEventModifierFlags)flags {
    NSEventModifierFlags pm = _peekMask, om = _overlayMask;
    BOOL sameKey = (pm && om && pm == om);

    BOOL ctlNow = pm ? ((flags & pm) != 0) : NO, ctlWas = pm ? ((_prev & pm) != 0) : NO;
    BOOL optNow = (om && !sameKey) ? ((flags & om) != 0) : NO;
    BOOL optWas = (om && !sameKey) ? ((_prev & om) != 0) : NO;
    _prev = flags;

    if (optNow && !optWas) [self performSelector:@selector(fireOption)  withObject:nil afterDelay:0.30];
    if (!optNow && optWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireOption)  object:nil]; [self.delegate modifierMonitorDisengageOption]; }
    if (ctlNow && !ctlWas) [self performSelector:@selector(fireControl) withObject:nil afterDelay:0.30];
    if (!ctlNow && ctlWas) { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireControl) object:nil]; [self.delegate modifierMonitorDisengageControl]; }
}

- (void)fireOption  { [self.delegate modifierMonitorEngageOption]; }
- (void)fireControl { [self.delegate modifierMonitorEngageControl]; }

@end
