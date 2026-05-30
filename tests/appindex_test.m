//
//  appindex_test.m — unit tests for the application-launcher index.
//  Compiled against Sources/AppIndex.m; reads the live filesystem (the standard
//  macOS application folders), so it runs anywhere a Mac has its system apps.
//
#import <Foundation/Foundation.h>
#import "../Sources/AppIndex.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   : %s\n", msg); } \
    else      { printf("  FAIL : %s\n", msg); failures++; } \
} while (0)

// Run a query and print what came back, returning the best-match entry.
static PBAppEntry *probe(PBAppIndex *idx, NSString *q) {
    PBAppEntry *e = [idx bestMatchFor:q];
    printf("  query %-18s -> %s\n",
           [[NSString stringWithFormat:@"'%@'", q] UTF8String],
           e ? [[NSString stringWithFormat:@"%@  (%@)", e.name, e.path] UTF8String] : "(nil)");
    return e;
}

int main(void) {
    @autoreleasepool {
        printf("PulseBar — app-index unit tests\n");

        PBAppIndex *idx = [PBAppIndex shared];

        // Lazy scan on first use.
        NSArray<PBAppEntry *> *apps = [idx allApps];
        printf("  indexed %lu apps\n", (unsigned long)apps.count);
        CHECK(apps.count > 0, "allApps.count > 0");

        // Calculator is guaranteed on every macOS install.
        PBAppEntry *calc = probe(idx, @"calculator");
        CHECK(calc != nil && [calc.name.lowercaseString containsString:@"calculator"],
              "'calculator' -> Calculator");
        CHECK(calc != nil && [calc.path containsString:@"Calculator.app"],
              "'calculator' resolves to a Calculator.app bundle");

        // System Settings (macOS 13+) or System Preferences (older). Either way
        // the resolved name should contain "System".
        PBAppEntry *sys = probe(idx, @"system settings");
        CHECK(sys != nil && [sys.name containsString:@"System"],
              "'system settings' -> something named 'System...'");

        // Subsequence / fuzzy matches -> Activity Monitor.
        PBAppEntry *am1 = probe(idx, @"activity");
        CHECK(am1 != nil && [am1.name.lowercaseString containsString:@"activity monitor"],
              "'activity' -> Activity Monitor");
        PBAppEntry *am2 = probe(idx, @"actmon");
        CHECK(am2 != nil && [am2.name.lowercaseString containsString:@"activity monitor"],
              "subsequence 'actmon' -> Activity Monitor");

        // matchesFor returns a ranked, bounded list with the obvious app first.
        NSArray<PBAppEntry *> *top = [idx matchesFor:@"calc" limit:5];
        printf("  matchesFor 'calc' limit 5 -> %lu result(s)\n", (unsigned long)top.count);
        CHECK(top.count > 0 && top.count <= 5, "matchesFor respects limit");
        CHECK(top.count > 0 && [top.firstObject.name.lowercaseString containsString:@"calculator"],
              "matchesFor 'calc' ranks Calculator first");

        // Gibberish must score below threshold -> nil.
        PBAppEntry *junk = probe(idx, @"zxqzq");
        CHECK(junk == nil, "gibberish 'zxqzq' -> nil");
        PBAppEntry *junk2 = probe(idx, @"qqzzxxjjkk");
        CHECK(junk2 == nil, "gibberish 'qqzzxxjjkk' -> nil");

        // Empty / whitespace query -> nil (no crash).
        CHECK([idx bestMatchFor:@""] == nil, "empty query -> nil");
        CHECK([idx bestMatchFor:@"   "] == nil, "whitespace query -> nil");

        // refresh is idempotent and keeps a non-empty index.
        [idx refresh];
        CHECK([idx allApps].count > 0, "index still populated after refresh");

        printf("\n%s — %d failure%s\n",
               failures ? "TESTS FAILED" : "ALL TESTS PASSED",
               failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
