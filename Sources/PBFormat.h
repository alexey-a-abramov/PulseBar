//
//  PBFormat.h — small pure value-formatting helpers (no view state). Lifted out
//  of BarView so the formatting is independently testable and reusable.
//
#import <Foundation/Foundation.h>

NSString *PBFmtRate(double bps);     // bytes/sec → "12K" / "1.4M" (1 decimal ≥ K)
double    PBToGB(uint64_t bytes);    // bytes → gibibytes
NSString *PBFmtClock(double sec);    // seconds → "m:ss"
NSString *PBFmtUptime(double sec);   // seconds → "3d 4h" / "4h 10m" / "42m"
