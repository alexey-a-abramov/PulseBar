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
- (BOOL)settingsTabsCollapsed;            // collapse the mode-tab strip to the active pill
- (void)settingsSetTabsCollapsed:(BOOL)collapsed;
// Layout profile quick-switch (0 Default · 1 Minimum · 2 Custom). Setting Default/
// Minimum applies that profile's density+tabs+safe-area bundle; Custom is read-only
// (reported when the knobs have been hand-tuned away from either preset).
- (NSInteger)settingsLayoutProfile;
- (void)settingsSetLayoutProfile:(NSInteger)profile;
// Diagnostics actions (moved out of the status menu).
- (void)settingsReattachTouchBar;         // re-claim the bar (evict Control Strip)
- (void)settingsOpenLog;
// Per-app auto-mode switch
- (BOOL)settingsAutoModeEnabled;
- (void)settingsSetAutoModeEnabled:(BOOL)on;
- (NSArray<NSDictionary *> *)settingsAutoModeRules;        // [{bundleID,name,mode}]
- (void)settingsSetAutoModeRules:(NSArray<NSDictionary *> *)rules;
// Agent
- (NSString *)settingsAgentModel;
- (void)settingsSetAgentModel:(NSString *)tag;
- (NSInteger)settingsAgentTimeoutMinutes;
- (void)settingsSetAgentTimeoutMinutes:(NSInteger)minutes;
- (void)settingsEditLayout;
- (void)settingsQuit;
// Shortcut modifier assignments (0=⌃ Control · 1=⌥ Option · 2=⌘ Command · 3=Off)
- (NSInteger)settingsShortcutPeekMod;
- (void)settingsSetShortcutPeekMod:(NSInteger)mod;
- (NSInteger)settingsShortcutOverlayMod;
- (void)settingsSetShortcutOverlayMod:(NSInteger)mod;
@end

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithDelegate:(id<SettingsDelegate>)delegate;
- (void)present;
- (void)presentTab:(NSString *)identifier;   // general · layout · shortcuts · modes · focus · agent · diagnostics · notes
- (void)syncIfVisible;                        // re-pull values if the window is on-screen (external change)
@end
