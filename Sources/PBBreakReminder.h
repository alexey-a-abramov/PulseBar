//
//  PBBreakReminder.h — the unmutable "take a break" nudge, lifted out of
//  AppDelegate. Watches the active working-session length and, past the
//  configured threshold (PBKeyBreakReminder, default 80 min), asks its host to
//  show a full-width banner — repeating every 15 min until the session resets.
//
#import <Foundation/Foundation.h>

@interface PBBreakReminder : NSObject
@property (nonatomic, copy) void (^onShow)(NSString *durationText);  // show the banner
@property (nonatomic, copy) void (^onHide)(void);                    // clear the banner

- (void)update:(double)sessionSeconds;   // call ~1 Hz
- (void)rearm;                            // re-evaluate against a changed threshold on the next update
- (void)acknowledge;                      // user pressed OK — dismiss; next nudge ~15 min later
@end
