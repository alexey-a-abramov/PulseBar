//
//  PrivateAPI.h — declarations for the undocumented Touch Bar SPI.
//
//  These methods are implemented by AppKit / DFRFoundation at runtime; we only
//  declare them so the compiler knows their signatures. Every call site guards
//  with -respondsToSelector: (and the DFR C functions are resolved via dlsym),
//  so the app degrades gracefully on machines without a Touch Bar.
//
//  This is the same approach used by Pock, MTMR and BetterTouchTool. It relies
//  on private API and is therefore unsuitable for the Mac App Store — fine for
//  a personal / open-source tool.
//
#import <AppKit/AppKit.h>

// --- DFRFoundation C functions (loaded with dlsym at runtime) ---------------
typedef void (*DFRElementSetControlStripPresenceFn)(NSTouchBarItemIdentifier, BOOL);
typedef void (*DFRSystemModalShowsCloseBoxFn)(BOOL);

// --- NSTouchBarItem: add/remove an item to the always-visible Control Strip --
@interface NSTouchBarItem (PulseBarPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

// --- NSTouchBar: present a custom bar system-wide, regardless of focus -------
@interface NSTouchBar (PulseBarPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
@end
