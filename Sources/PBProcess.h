//
//  PBProcess.h — one place for the NSTask wrappers that were copy-pasted across
//  TouchBarPresenter, Controls and AppDelegate.
//
#import <Foundation/Foundation.h>

// Run a tool to completion and return its trimmed stdout (nil if it can't launch).
// BLOCKING — don't call on the main thread for slow tools.
NSString *PBRunCapture(NSString *path, NSArray<NSString *> *args);

// Fire-and-forget launch; ignores output and launch failures.
void PBLaunchDetached(NSString *path, NSArray<NSString *> *args);
