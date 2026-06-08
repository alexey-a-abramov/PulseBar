//
//  PBBreakReminder.m
//
#import "PBBreakReminder.h"
#import "PBDefaults.h"
#import "Log.h"

static const double kRepeatSeconds = 15 * 60.0;   // re-nudge cadence after you acknowledge

// Compact "1h 26m" / "44m" duration for the break banner.
static NSString *PBHumanDuration(double sec) {
    int s = sec < 0 ? 0 : (int)sec, h = s / 3600, m = (s % 3600) / 60;
    return h > 0 ? [NSString stringWithFormat:@"%dh %dm", h, m] : [NSString stringWithFormat:@"%dm", m];
}

@implementation PBBreakReminder {
    double _nextBreakAt;   // session-seconds at which the next banner fires
    double _lastSession;   // most recent session length (for re-arming on acknowledge)
    BOOL   _showing;       // banner is up and waiting for an explicit OK
}

- (void)rearm { _nextBreakAt = 0; }

- (void)update:(double)session {
    if (getenv("PULSEBAR_SELFQUIT")) return;
    _lastSession = session;
    NSInteger thrMin = PBDefaultsInteger(PBKeyBreakReminder, PBDefaultBreakReminderMinutes);
    double thr = (thrMin > 0 ? thrMin : PBDefaultBreakReminderMinutes) * 60.0;
    if (session < thr) {                         // session reset (you took a break) → clear the banner
        _nextBreakAt = thr;
        if (_showing) { _showing = NO; if (self.onHide) self.onHide(); }
        return;
    }
    if (_showing) return;                        // permanent until acknowledged — never auto-hide / re-fire
    if (_nextBreakAt < thr) _nextBreakAt = thr;
    if (session + 0.5 >= _nextBreakAt) [self fire:session];
}

- (void)fire:(double)session {
    _showing = YES;
    NSString *txt = PBHumanDuration(session);
    if (self.onShow) self.onShow(txt);
    PBLog(@"break reminder shown (session %@) — waiting for OK", txt);
}

// User pressed OK. Dismiss and don't nudge again for ~15 min.
- (void)acknowledge {
    if (!_showing) return;
    _showing = NO;
    if (self.onHide) self.onHide();
    _nextBreakAt = _lastSession + kRepeatSeconds;
    PBLog(@"break reminder acknowledged; next nudge in %ld min", (long)(kRepeatSeconds / 60));
}

@end
