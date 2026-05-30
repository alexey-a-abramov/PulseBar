//
//  SettingsWindowController.h — the desktop settings window opened from the
//  gear button on the Touch Bar.
//
#import <AppKit/AppKit.h>

@protocol SettingsDelegate <NSObject>
- (BOOL)settingsFullBarEnabled;
- (void)settingsSetFullBar:(BOOL)on;
- (BOOL)settingsLoginEnabled;
- (void)settingsSetLogin:(BOOL)on;
- (NSInteger)settingsWorkMinutes;
- (NSInteger)settingsBreakMinutes;
- (void)settingsSetWork:(NSInteger)w breakMin:(NSInteger)b;
- (BOOL)settingsTopProcEnabled;
- (void)settingsSetTopProc:(BOOL)on;
- (void)settingsQuit;
@end

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithDelegate:(id<SettingsDelegate>)delegate;
- (void)present;
@end
