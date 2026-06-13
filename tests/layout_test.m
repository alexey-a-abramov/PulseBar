//
//  layout_test.m — assertions for the size-aware layout engine: which tiles
//  survive at a given content width, in what order, and how force-hide
//  overrides affect that. Links BarView (+ AppKit) but draws nothing.
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/PBDefaults.h"

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
    // (Direct defaults writes bypass PBLayoutChangedNotification, so the test
    // bumps the layout gen by hand to invalidate the packVisible memo — the app
    // does this automatically via -layoutChanged: / setOrderOverride.)
    [ud setObject:@{@"hidden": @YES} forKey:systemKey(@"Uptime")];
    pb_bumpLayoutGen();
    NSArray *hidden = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(![hidden containsObject:@"Uptime"], "force-hidden Uptime is absent at full width");
    CHECK(hidden.count == 6 && [hidden.firstObject isEqualToString:@"CPU"], "remaining 6 tiles still present in order");
    [ud removeObjectForKey:systemKey(@"Uptime")];   // cleanup
    pb_bumpLayoutGen();

    NSArray *restored = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(restored, full, "restored"), "removing the override restores Uptime");

    // Reordering: an @"order" override moves the last System tile (Battery) to
    // the front. Merge into any existing dict so other fields would survive.
    NSString *battKey = systemKey(@"Battery");
    NSMutableDictionary *battOv = [([ud dictionaryForKey:battKey] ?: @{}) mutableCopy];
    battOv[@"order"] = @(-1);   // sorts ahead of every natural index (0..n-1)
    [ud setObject:battOv forKey:battKey];
    pb_bumpLayoutGen();
    NSArray *reordered = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK([reordered.firstObject isEqualToString:@"Battery"] && reordered.count == full.count,
          "order override moves Battery to the front at full width");
    [ud removeObjectForKey:battKey];   // cleanup — keep the test idempotent
    pb_bumpLayoutGen();

    NSArray *reset = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(reset, full, "reset"), "removing the order override restores natural order");

    // ---- Composition: per-mode add / remove (PBCompose.<mode>) -------------
    // Build the compose key + a couple of tile tokens by stripping the trailing
    // component off the override keys, so the test stays free of hardcoded tokens.
    NSString *composeSystem = [@"PBCompose." stringByAppendingString:
        [systemKey(@"CPU") componentsSeparatedByString:@"."][1]];
    NSString *uptimeTok = [systemKey(@"Uptime") componentsSeparatedByString:@"."].lastObject;
    NSString *volTok = nil;
    for (NSDictionary *d in [BarView defaultLayoutForMode:BarModeClassic])
        if ([d[@"name"] isEqualToString:@"Volume"])
            volTok = [[BarView overrideKeyForMode:BarModeClassic type:[d[@"type"] integerValue]]
                      componentsSeparatedByString:@"."].lastObject;

    // Remove: drop Uptime from System via composition (not a per-tile hidden).
    [ud setObject:@{@"removed": @[uptimeTok]} forKey:composeSystem];
    pb_bumpLayoutGen();
    NSArray *composedRm = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(![composedRm containsObject:@"Uptime"] && composedRm.count == 6,
          "compose: removed Uptime is gone, 6 remain");

    // Add: append Volume (a tile System doesn't ship) via composition.
    [ud setObject:@{@"added": @[@{@"token": volTok, @"arg": @0, @"prio": @90, @"minW": @40}]}
           forKey:composeSystem];
    pb_bumpLayoutGen();
    NSArray *composedAdd = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK([composedAdd containsObject:@"Volume"] && composedAdd.count == full.count + 1,
          "compose: added Volume appears, count is full+1");

    [ud removeObjectForKey:composeSystem];   // cleanup
    pb_bumpLayoutGen();
    NSArray *composedReset = [BarView visibleTileNamesForMode:BarModeSystem contentWidth:700];
    CHECK(eq(composedReset, full, "composeReset"), "removing the composition restores the default set");

    // ---- Auto-density predicate (pure; no overrides set at this point) ----
    BOOL anyCompactAtDefault = NO;
    for (NSInteger m = 0; m < BarModeCount; m++)
        anyCompactAtDefault |= [BarView effectiveCompactForMode:m density:PBDensityAuto width:1004 left:0 right:110];
    CHECK(!anyCompactAtDefault, "Auto stays full for every mode at the default fit (1004 / 0 / 110)");
    CHECK([BarView effectiveCompactForMode:BarModeSystem density:PBDensityAuto width:640 left:0 right:110],
          "Auto goes compact for System at a tight width (640 / 0 / 110)");
    CHECK(![BarView effectiveCompactForMode:BarModeSystem density:PBDensityFull width:360 left:0 right:110],
          "Full never goes compact, even at 360");
    CHECK([BarView effectiveCompactForMode:BarModeSystem density:PBDensityCompact width:1004 left:0 right:0],
          "Compact is always compact, even with maximum space");
    BOOL a1 = [BarView effectiveCompactForMode:BarModeSystem density:PBDensityAuto width:640 left:0 right:110];
    BOOL a2 = [BarView effectiveCompactForMode:BarModeSystem density:PBDensityAuto width:640 left:0 right:110];
    CHECK(a1 == a2, "predicate is deterministic (same inputs, same answer)");

    // ---- v1→v2 schema migration: legacy compact bool → density ----
    void (^resetSchema)(void) = ^{ [ud removeObjectForKey:PBKeyDensity]; [ud removeObjectForKey:PBKeyLayoutSchemaVersion]; };
    resetSchema(); [ud setBool:YES forKey:PBKeyCompact]; [BarView ensureLayoutSchema];
    CHECK([ud integerForKey:PBKeyDensity] == PBDensityCompact, "migration: compact=YES → density Compact");
    resetSchema(); [ud setBool:NO forKey:PBKeyCompact]; [BarView ensureLayoutSchema];
    CHECK([ud integerForKey:PBKeyDensity] == PBDensityFull, "migration: explicit compact=NO → density Full");
    resetSchema(); [ud removeObjectForKey:PBKeyCompact]; [BarView ensureLayoutSchema];
    CHECK([ud objectForKey:PBKeyDensity] == nil, "migration: untouched compact → density unset (reads as Auto)");
    [ud removeObjectForKey:PBKeyCompact];   // cleanup

    printf("\n%s — %d failure(s)\n", failures ? "FAILED" : "ALL TESTS PASSED", failures);
    return failures ? 1 : 0;
}}
