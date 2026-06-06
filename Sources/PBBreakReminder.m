//
//  PBBreakReminder.m
//
#import "PBBreakReminder.h"
#import "PBDefaults.h"
#import "Log.h"

static const double kRepeatSeconds = 15 * 60.0;   // re-nudge cadence once past the threshold
static const double kBannerSeconds = 12.0;         // how long the banner stays up

// Compact "1h 26m" / "44m" duration for the break banner.
static NSString *PBHumanDuration(double sec) {
    int s = sec < 0 ? 0 : (int)sec, h = s / 3600, m = (s % 3600) / 60;
    return h > 0 ? [NSString stringWithFormat:@"%dh %dm", h, m] : [NSString stringWithFormat:@"%dm", m];
}

@implementation PBBreakReminder {
    double _nextBreakAt;   // session-seconds at which the next banner fires
}

- (void)rearm { _nextBreakAt = 0; }

- (void)update:(double)session {
    if (getenv("PULSEBAR_SELFQUIT")) return;
    NSInteger thrMin = PBDefaultsInteger(PBKeyBreakReminder, PBDefaultBreakReminderMinutes);
    double thr = (thrMin > 0 ? thrMin : PBDefaultBreakReminderMinutes) * 60.0;
    if (session < thr) { _nextBreakAt = thr; return; }      // below threshold → arm for the first crossing
    if (_nextBreakAt < thr) _nextBreakAt = thr;
    if (session + 0.5 >= _nextBreakAt) {
        _nextBreakAt = session + kRepeatSeconds;
        [self fire:session];
    }
}

- (void)fire:(double)session {
    NSString *txt = PBHumanDuration(session);
    if (self.onShow) self.onShow(txt);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hide) object:nil];
    [self performSelector:@selector(hide) withObject:nil afterDelay:kBannerSeconds];
    PBLog(@"break reminder shown (session %@)", txt);
}

- (void)hide { if (self.onHide) self.onHide(); }

@end
