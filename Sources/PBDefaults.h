//
//  PBDefaults.h — single source of truth for NSUserDefaults keys.
//  Stringly-typed keys scattered across files silently break persistence on a
//  typo; keep every key name here.
//
#import <Foundation/Foundation.h>

extern NSString * const PBKeyFullBar;      // BOOL  — take over the whole bar (hide Control Strip)
extern NSString * const PBKeyMirror;       // BOOL  — desktop mirror window visible
extern NSString * const PBKeyModifiers;    // BOOL  — ⌘ recent / ⌥ app-overlay shortcuts enabled
extern NSString * const PBKeyMode;         // NSInteger — last active BarMode
extern NSString * const PBKeyWork;         // NSInteger — Pomodoro work minutes
extern NSString * const PBKeyBreak;        // NSInteger — Pomodoro break minutes
extern NSString * const PBKeyShowTopProc;  // BOOL  — sample/show the top CPU process
extern NSString * const PBKeyMediaApp;     // NSString — play/pause target app (e.g. Spotify)
extern NSString * const PBKeyAdaptive;     // BOOL  — Pomodoro focus length auto-grows with the session
extern NSString * const PBKeyBreakReminder;// NSInteger — minutes of unbroken session before the take-a-break banner (default 80)
extern NSString * const PBKeySafeLeft;     // NSInteger — px reserved on the live bar's left for the close box (default 0)
extern NSString * const PBKeySafeRight;    // NSInteger — px reserved on the live bar's right for the Control Strip (default 110)
extern NSString * const PBKeyCompact;      // BOOL  — legacy compact toggle (v1 schema; migrated to PBKeyDensity, never written now)
extern NSString * const PBKeyDensity;      // NSInteger PBDensity — 0 Auto (adapt to space) · 1 Full · 2 Compact
extern NSString * const PBKeyTabsCollapsed; // BOOL — collapse the mode-tab strip to the active pill (default NO)
extern NSString * const PBKeyCustomLaunchers; // NSArray of {label,query} — user-added app launchers beyond the curated set
extern NSString * const PBKeyAutoModeEnabled; // BOOL — auto-switch the bar's mode when the frontmost app changes (default NO)
extern NSString * const PBKeyAutoModeRules;   // NSArray of {bundleID,name,mode} — per-app → mode rules
extern NSString * const PBKeyAgentSessionTimeout; // NSInteger minutes — start a fresh agent dialogue after this much inactivity (0 = never)
extern NSString * const PBKeyAgentModel;   // NSString — active Ollama model tag (e.g. "gemma4:12b"); default "gemma3:4b"
extern NSString * const PBKeyShortcutPeekMod;    // NSInteger — 0 ⌃ Control · 1 ⌥ Option · 2 ⌘ Command · 3 Off (default 0)
extern NSString * const PBKeyShortcutOverlayMod; // NSInteger — 0 ⌃ Control · 1 ⌥ Option · 2 ⌘ Command · 3 Off (default 1)
extern NSString * const PBKeyLayoutProfile;      // NSInteger PBLayoutProfile — 0 Default · 1 Minimum · 2 Custom (default Default on first run)

// Default values — kept here so they aren't re-typed as literals across the app.
extern const NSInteger PBDefaultWorkMinutes;          // 25
extern const NSInteger PBDefaultBreakMinutes;         // 5
extern const NSInteger PBDefaultBreakReminderMinutes; // 80
extern const NSInteger PBDefaultSafeLeft;             // 0
extern const NSInteger PBDefaultSafeRight;            // 110
extern const NSInteger PBDefaultAgentSessionTimeoutMin; // 5 (0 = never reset the dialogue)
extern const NSInteger PBCloseBoxReserve;             // 64 — px the Touch Bar ✕ close box occupies on the left; reserved by every layout profile

// Read a defaults value, returning `fallback` when the key has never been set.
NSInteger PBDefaultsInteger(NSString *key, NSInteger fallback);
BOOL      PBDefaultsBool(NSString *key, BOOL fallback);
NSString *PBDefaultsString(NSString *key, NSString *fallback);   // fallback when unset/empty
extern NSString * const PBKeyTBBackup;     // NSString — saved Touch Bar PresentationModeGlobal
extern NSString * const PBKeyLayoutSchemaVersion; // NSInteger — version of the persisted per-tile override schema
