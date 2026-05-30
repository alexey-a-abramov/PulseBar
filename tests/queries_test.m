//
//  queries_test.m — unit tests for the read-only status-answers module.
//  Compiled against Sources/Queries.m (+ Stats.m + Controls.m); links
//  Foundation, IOKit, CoreAudio, CoreGraphics, AppKit, ApplicationServices.
//
#import <Foundation/Foundation.h>
#import "../Sources/Queries.h"
#import <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   : %s\n", msg); } \
    else      { printf("  FAIL : %s\n", msg); failures++; } \
} while (0)

// True if `s` is a non-empty NSString.
static BOOL nonEmpty(NSString *s) {
    return [s isKindOfClass:[NSString class]] && s.length > 0;
}

// True if `s` contains at least one decimal digit.
static BOOL hasDigit(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSRange r = [s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
    return r.location != NSNotFound;
}

int main(void) {
    @autoreleasepool {
        printf("PulseBar — queries unit tests\n");

        NSString *battery    = [PBQueries answer:@"battery"];
        NSString *cpu        = [PBQueries answer:@"cpu"];      // primes + usleeps internally
        NSString *memory     = [PBQueries answer:@"memory"];
        NSString *disk       = [PBQueries answer:@"disk"];
        NSString *uptime     = [PBQueries answer:@"uptime"];
        NSString *volume     = [PBQueries answer:@"volume"];
        NSString *brightness = [PBQueries answer:@"brightness"];
        NSString *nowPlaying = [PBQueries answer:@"now_playing"];
        NSString *bogus      = [PBQueries answer:@"bogus"];

        // Human-readable: print every answer.
        printf("\n  battery     -> %s\n", battery.UTF8String);
        printf("  cpu         -> %s\n", cpu.UTF8String);
        printf("  memory      -> %s\n", memory.UTF8String);
        printf("  disk        -> %s\n", disk.UTF8String);
        printf("  uptime      -> %s\n", uptime.UTF8String);
        printf("  volume      -> %s\n", volume.UTF8String);
        printf("  brightness  -> %s\n", brightness.UTF8String);
        printf("  now_playing -> %s\n", nowPlaying.UTF8String);
        printf("  bogus       -> %s\n\n", bogus ? bogus.UTF8String : "(nil)");

        // Each known key returns a non-empty string.
        CHECK(nonEmpty(battery),    "battery returns a non-empty string");
        CHECK(nonEmpty(cpu),        "cpu returns a non-empty string");
        CHECK(nonEmpty(memory),     "memory returns a non-empty string");
        CHECK(nonEmpty(disk),       "disk returns a non-empty string");
        CHECK(nonEmpty(uptime),     "uptime returns a non-empty string");
        CHECK(nonEmpty(volume),     "volume returns a non-empty string");
        CHECK(nonEmpty(brightness), "brightness returns a non-empty string");

        // Unknown key returns nil.
        CHECK(bogus == nil, "bogus returns nil");

        // These answers must report a number, so they should contain a digit.
        CHECK(hasDigit(battery), "battery answer contains a digit");
        CHECK(hasDigit(cpu),     "cpu answer contains a digit");
        // Volume may be "Muted." with no digit; only require a digit when not muted.
        if ([volume isEqualToString:@"Muted."]) {
            printf("  note : volume is muted; skipping digit check\n");
        } else {
            CHECK(hasDigit(volume), "volume answer contains a digit");
        }

        printf("\n%s — %d failure%s\n",
               failures ? "TESTS FAILED" : "ALL TESTS PASSED",
               failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
