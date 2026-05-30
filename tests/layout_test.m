//
//  layout_test.m — assertions for the size-aware layout engine: which tiles
//  survive at a given content width, in what order, and how force-hide
//  overrides affect that. Links BarView (+ AppKit) but draws nothing.
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   : %s\n", msg); } \
    else      { printf("  FAIL : %s\n", msg); failures++; } \
} while (0)

static BOOL eq(NSArray<NSString *> *got, NSArray<NSString *> *want, const char *label) {
    BOOL ok = [got isEqualToArray:want];
    if (!ok) printf("         %s: got %s\n", label, [got componentsJoinedByString:@", "].UTF8String);
    return ok;
}

// Resolve a System tile's override key by display name (no hardcoded ordinals).
static NSString *systemKey(NSString *name) {
    for (NSDictionary *d in [BarView defaultLayoutForMode:BarModeSystem])
        if ([d[@"name"] isEqualToString:name])
            return [BarView overrideKeyForMode:BarModeSystem type:[d[@"type"] integerValue]];
    return nil;
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    printf("PulseBar — layout engine tests\n");
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    // Clean any stray overrides from earlier runs in this domain.
    for (NSString *n in @[@"CPU", @"Memory", @"GPU", @"Network", @"Disk I/O", @"Uptime", @"Battery"])
        [ud removeObjectForKey:systemKey(n)];

    NSArray *full = @[@"CPU", @"Memory", @"GPU", @"Network", @"Disk I/O", @"Uptime", @"Battery"];
    NSArray *wide = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(wide, full, "wide"), "System @700 shows all 7 tiles in order");

    // Tight widths drop lowest-priority first (Uptime, then GPU, Disk, Net, Batt).
    NSArray *w200 = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:200];
    CHECK(eq(w200, (@[@"CPU", @"Memory", @"Battery"]), "w200"), "System @200 keeps CPU/Memory/Battery");
    NSArray *w150 = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:150];
    CHECK(eq(w150, (@[@"CPU", @"Memory"]), "w150"), "System @150 keeps CPU/Memory");
    NSArray *w30 = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:30];
    CHECK(eq(w30, (@[@"CPU"]), "w30"), "System @30 keeps at least the top-priority tile");

    // Order is preserved as width shrinks (visible set is a subsequence of full).
    CHECK([full containsObject:w200.lastObject] && [full indexOfObject:@"Memory"] < [full indexOfObject:@"Battery"],
          "visible tiles keep their left→right order");

    // Shortcuts mode: all 8 at a wide content width.
    NSArray *sc = [BarView visibleTileNamesForMode:BarModeShortcuts contentWidth:700];
    CHECK(sc.count == 8, "Shortcuts @700 shows all 8 tiles");

    // Force-hide override removes a tile even when there's room for it.
    [ud setObject:@{@"hidden": @YES} forKey:systemKey(@"Uptime")];
    NSArray *hidden = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(![hidden containsObject:@"Uptime"], "force-hidden Uptime is absent at full width");
    CHECK(hidden.count == 6 && [hidden.firstObject isEqualToString:@"CPU"], "remaining 6 tiles still present in order");
    [ud removeObjectForKey:systemKey(@"Uptime")];   // cleanup

    NSArray *restored = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(restored, full, "restored"), "removing the override restores Uptime");

    // Reordering: an @"order" override moves the last System tile (Battery) to
    // the front. Merge into any existing dict so other fields would survive.
    NSString *battKey = systemKey(@"Battery");
    NSMutableDictionary *battOv = [([ud dictionaryForKey:battKey] ?: @{}) mutableCopy];
    battOv[@"order"] = @(-1);   // sorts ahead of every natural index (0..n-1)
    [ud setObject:battOv forKey:battKey];
    NSArray *reordered = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK([reordered.firstObject isEqualToString:@"Battery"] && reordered.count == full.count,
          "order override moves Battery to the front at full width");
    [ud removeObjectForKey:battKey];   // cleanup — keep the test idempotent

    NSArray *reset = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(reset, full, "reset"), "removing the order override restores natural order");

    printf("\n%s — %d failure(s)\n", failures ? "FAILED" : "ALL TESTS PASSED", failures);
    return failures ? 1 : 0;
}}
