//
//  PBLoginItem.h — the "start at login" LaunchAgent, lifted out of AppDelegate.
//  Installs/removes ~/Library/LaunchAgents/com.fun.pulsebar.plist.
//
#import <Foundation/Foundation.h>

@interface PBLoginItem : NSObject
- (BOOL)isEnabled;            // is the LaunchAgent plist installed?
- (void)setEnabled:(BOOL)on;  // install + launchctl load, or unload + remove
@end
