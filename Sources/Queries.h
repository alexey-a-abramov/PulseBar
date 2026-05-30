//
//  Queries.h — read-only "status answers" for PulseBar's voice agent.
//
//  Given a status key, returns a short, natural spoken sentence describing the
//  current system state. READ-ONLY: this module never mutates anything.
//
#import <Foundation/Foundation.h>

@interface PBQueries : NSObject
// `what` ∈ {"battery","cpu","memory","disk","uptime","volume","brightness","now_playing"}.
// Returns a short spoken sentence (e.g. "Battery is 76% and charging."), or nil if `what` is unknown.
+ (NSString *)answer:(NSString *)what;
@end
