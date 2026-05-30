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
extern NSString * const PBKeyTBBackup;     // NSString — saved Touch Bar PresentationModeGlobal
extern NSString * const PBKeyLayoutSchemaVersion; // NSInteger — version of the persisted per-tile override schema
