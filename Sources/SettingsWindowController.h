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
- (NSString *)settingsMediaApp;
- (void)settingsSetMediaApp:(NSString *)app;
- (BOOL)settingsMirrorVisible;
- (void)settingsSetMirror:(BOOL)on;
- (BOOL)settingsModifiersEnabled;
- (void)settingsSetModifiers:(BOOL)on;
- (BOOL)settingsAdaptiveLength;
- (void)settingsSetAdaptive:(BOOL)on;
- (NSInteger)settingsBreakReminderMinutes;
- (void)settingsSetBreakReminderMinutes:(NSInteger)minutes;
// Live "fit" adjustment — px reserved/squeezed at each edge so system chrome
// (the ✕ and the Control Strip) never covers a tile or the agent orb. Setters
// apply immediately to the live bar and the desktop mirror (real-time preview).
- (CGFloat)settingsSafeLeft;
- (void)settingsSetSafeLeft:(CGFloat)px;
- (CGFloat)settingsSafeRight;
- (void)settingsSetSafeRight:(CGFloat)px;
- (NSInteger)settingsDensity;             // PBDensity: 0 Auto · 1 Full · 2 Compact
- (void)settingsSetDensity:(NSInteger)d;
// Agent
- (NSString *)settingsAgentModel;
- (void)settingsSetAgentModel:(NSString *)tag;
- (NSInteger)settingsAgentTimeoutMinutes;
- (void)settingsSetAgentTimeoutMinutes:(NSInteger)minutes;
- (void)settingsEditLayout;
- (void)settingsQuit;
@end

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithDelegate:(id<SettingsDelegate>)delegate;
- (void)present;
- (void)presentTab:(NSString *)identifier;   // "general" | "focus" | "notes"
@end
