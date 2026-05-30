//
//  CrashReporter.h — a modal crash dialog showing a copyable stack trace.
//  Used both for a fatal launch failure (caught NSException) and to surface a
//  crash from a previous run (PBTakePendingCrashReport) on the next launch.
//
#import <AppKit/AppKit.h>

@interface PBCrashReporter : NSObject
// Shows a modal window with `report` in a scrollable monospaced view plus
// Copy / Open Log buttons. allowContinue=YES adds "Continue" (the run proceeds);
// allowContinue=NO is fatal (only Quit) and terminates the app on dismissal.
+ (void)presentReport:(NSString *)report title:(NSString *)title allowContinue:(BOOL)allowContinue;
@end
