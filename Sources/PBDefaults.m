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
NSString * const PBKeyDensity     = @"density";
NSString * const PBKeyTabsCollapsed = @"tabsCollapsed";
NSString * const PBKeyCustomLaunchers = @"customLaunchers";
NSString * const PBKeyAgentSessionTimeout = @"agentSessionTimeoutMin";
NSString * const PBKeyAgentModel  = @"agentModel";

const NSInteger PBDefaultWorkMinutes          = 25;
const NSInteger PBDefaultBreakMinutes         = 5;
const NSInteger PBDefaultBreakReminderMinutes = 80;
const NSInteger PBDefaultSafeLeft             = 0;
const NSInteger PBDefaultSafeRight            = 110;
const NSInteger PBDefaultAgentSessionTimeoutMin = 5;

NSInteger PBDefaultsInteger(NSString *key, NSInteger fallback) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    return [ud objectForKey:key] ? [ud integerForKey:key] : fallback;
}
BOOL PBDefaultsBool(NSString *key, BOOL fallback) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    return [ud objectForKey:key] ? [ud boolForKey:key] : fallback;
}
NSString *PBDefaultsString(NSString *key, NSString *fallback) {
    NSString *s = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return s.length ? s : fallback;
}
NSString * const PBKeyTBBackup    = @"tbBackup";
NSString * const PBKeyLayoutSchemaVersion = @"layoutSchemaVersion";
