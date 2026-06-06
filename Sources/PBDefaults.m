//
//  PBDefaults.m
//
#import "PBDefaults.h"

NSString * const PBKeyFullBar     = @"fullBar";
NSString * const PBKeyMirror      = @"mirror";
NSString * const PBKeyModifiers   = @"modifiers";
NSString * const PBKeyMode        = @"mode";
NSString * const PBKeyWork        = @"work";
NSString * const PBKeyBreak       = @"break";
NSString * const PBKeyShowTopProc = @"showTopProc";
NSString * const PBKeyMediaApp    = @"mediaApp";
NSString * const PBKeyAdaptive    = @"adaptiveLength";
NSString * const PBKeyBreakReminder = @"breakReminderMinutes";
NSString * const PBKeySafeLeft    = @"safeAreaLeft";
NSString * const PBKeySafeRight   = @"safeAreaRight";
NSString * const PBKeyCompact     = @"compactLayout";

const NSInteger PBDefaultWorkMinutes          = 25;
const NSInteger PBDefaultBreakMinutes         = 5;
const NSInteger PBDefaultBreakReminderMinutes = 80;
const NSInteger PBDefaultSafeLeft             = 0;
const NSInteger PBDefaultSafeRight            = 110;

NSInteger PBDefaultsInteger(NSString *key, NSInteger fallback) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    return [ud objectForKey:key] ? [ud integerForKey:key] : fallback;
}
BOOL PBDefaultsBool(NSString *key, BOOL fallback) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    return [ud objectForKey:key] ? [ud boolForKey:key] : fallback;
}
NSString * const PBKeyTBBackup    = @"tbBackup";
NSString * const PBKeyLayoutSchemaVersion = @"layoutSchemaVersion";
