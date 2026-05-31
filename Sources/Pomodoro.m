//
//  Pomodoro.m
//
#import "Pomodoro.h"

@implementation Pomodoro {
    double    _remaining;     // seconds
    PomoState _resumeState;   // what to resume to after a pause
}

- (instancetype)init {
    if ((self = [super init])) {
        _workMinutes = 25;
        _breakMinutes = 5;
        _adaptiveLength = YES;
        _state = PomoIdle;
        _resumeState = PomoWork;
        _remaining = 0;
    }
    return self;
}

+ (NSInteger)adaptiveWorkMinutes:(double)sessionSeconds {
    NSInteger m = 25 + 5 * (NSInteger)(sessionSeconds / 1800.0);   // +5 min per 30 min of session
    return MAX(20, MIN(50, m));
}

- (void)cycleWorkLength {
    NSInteger presets[] = { 20, 25, 30, 45, 50 };
    int n = (int)(sizeof(presets) / sizeof(presets[0])), idx = 0;
    for (int i = 0; i < n; i++) if (presets[i] == _workMinutes) { idx = i; break; }
    _workMinutes = presets[(idx + 1) % n];
    _adaptiveLength = NO;   // manual choice sticks
}

- (NSInteger)remainingSeconds { return (NSInteger)ceil(_remaining); }
- (NSInteger)phaseSeconds {
    PomoState s = (_state == PomoPaused) ? _resumeState : _state;
    return (s == PomoBreak ? _breakMinutes : _workMinutes) * 60;
}

- (void)startPhase:(PomoState)phase {
    _state = phase;
    _remaining = (phase == PomoBreak ? _breakMinutes : _workMinutes) * 60.0;
}

- (void)toggle {
    switch (_state) {
        case PomoIdle:  [self startPhase:PomoWork]; break;
        case PomoWork:
        case PomoBreak: _resumeState = _state; _state = PomoPaused; break;
        case PomoPaused: _state = _resumeState; break;
    }
}

- (void)reset { _state = PomoIdle; _remaining = 0; _resumeState = PomoWork; }

- (void)tick:(double)dt {
    if (_state != PomoWork && _state != PomoBreak) return;
    _remaining -= dt;
    if (_remaining <= 0) {
        BOOL wasWork = (_state == PomoWork);
        if (self.onComplete) self.onComplete(wasWork);
        [self startPhase:wasWork ? PomoBreak : PomoWork];   // auto-advance
    }
}

- (double)progress {
    NSInteger total = [self phaseSeconds];
    if (total <= 0) return 0;
    return 1.0 - (_remaining / (double)total);
}

- (NSString *)label {
    switch (_state) {
        case PomoWork:   return @"WORK";
        case PomoBreak:  return @"BREAK";
        case PomoPaused: return (_resumeState == PomoBreak) ? @"BREAK·❚❚" : @"WORK·❚❚";
        default:         return @"POMODORO";
    }
}

- (NSString *)clockText {
    NSInteger r = self.remainingSeconds; if (r < 0) r = 0;
    if (_state == PomoIdle) r = _workMinutes * 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)(r / 60), (long)(r % 60)];
}

@end
