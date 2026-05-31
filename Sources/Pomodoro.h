//
//  Pomodoro.h — a tiny work/break timer model.
//
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PomoState) {
    PomoIdle,
    PomoWork,
    PomoBreak,
    PomoPaused,
};

@interface Pomodoro : NSObject

@property (nonatomic) NSInteger workMinutes;    // default 25
@property (nonatomic) NSInteger breakMinutes;   // default 5
@property (nonatomic) BOOL adaptiveLength;      // YES → length auto-set from the working session
@property (nonatomic, readonly) PomoState state;
@property (nonatomic, readonly) NSInteger remainingSeconds;
@property (nonatomic, readonly) NSInteger phaseSeconds;      // length of current phase
@property (nonatomic, copy) void (^onComplete)(BOOL wasWork); // a phase just ended

- (void)toggle;            // idle→work · running→pause · paused→resume
- (void)reset;             // back to idle

// Adaptive focus length: rewards sustained focus. The suggested work block grows
// with the current uninterrupted working session (5 min per extra 30 min of
// session), clamped to [20, 50]. Applied automatically while idle unless the
// length was set manually. See README "Adaptive Pomodoro".
+ (NSInteger)adaptiveWorkMinutes:(double)sessionSeconds;
- (void)cycleWorkLength;   // manual override: cycle 20→25→30→45→50→20 (turns off adaptive)
- (void)tick:(double)dt;   // advance by dt seconds (call ~1 Hz)
- (double)progress;        // 0..1 of the current phase elapsed
- (NSString *)label;       // "WORK" / "BREAK" / "POMODORO"
- (NSString *)clockText;   // "mm:ss"

@end
