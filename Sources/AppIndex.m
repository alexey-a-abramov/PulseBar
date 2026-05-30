//
//  AppIndex.m
//
#import "AppIndex.h"

@implementation PBAppEntry
@end

#pragma mark - Scoring

// Score tiers. Higher is a better match. They are spaced far enough apart that
// a stronger tier always beats a weaker one regardless of the small per-tier
// bonuses we add for tie-breaking.
static const double kScoreExact       = 1000.0;  // whole name == query
static const double kScoreWordPrefix  =  800.0;  // some word starts with the query
static const double kScoreNamePrefix  =  700.0;  // name starts with the query
static const double kScoreAllTokens   =  600.0;  // every query token prefixes a word
static const double kScoreInitials    =  500.0;  // query == leading initials of words
static const double kScoreSubsequence =  400.0;  // query chars appear in order
static const double kScoreSubstring   =  300.0;  // query is a plain substring

// Below this, treat it as "no reasonable match".
static const double kScoreThreshold   =  250.0;

// Lowercase + trim, collapsing internal whitespace runs to single spaces.
static NSString *PBNormalize(NSString *s) {
    if (s.length == 0) return @"";
    NSString *lower = [s lowercaseString];
    NSArray<NSString *> *parts =
        [lower componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [kept addObject:p];
    return [kept componentsJoinedByString:@" "];
}

// Split a normalized string into word tokens. Treats whitespace as the only
// separator (the name has already been lowercased/collapsed).
static NSArray<NSString *> *PBTokens(NSString *normalized) {
    if (normalized.length == 0) return @[];
    return [normalized componentsSeparatedByString:@" "];
}

// Is `needle` an in-order subsequence of `hay`? (e.g. "vsc" in "visualstudiocode")
static BOOL PBIsSubsequence(NSString *needle, NSString *hay) {
    NSUInteger ni = 0, nlen = needle.length, hlen = hay.length;
    if (nlen == 0) return YES;
    if (nlen > hlen) return NO;
    for (NSUInteger hi = 0; hi < hlen && ni < nlen; hi++) {
        if ([needle characterAtIndex:ni] == [hay characterAtIndex:hi]) ni++;
    }
    return ni == nlen;
}

// Leading initials of each word, e.g. "Visual Studio Code" -> "vsc".
static NSString *PBInitials(NSArray<NSString *> *words) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *w in words) {
        if (w.length) [out appendFormat:@"%C", [w characterAtIndex:0]];
    }
    return out;
}

// Core scorer. `q` and `name` are already normalized (lowercased/trimmed).
// Returns 0 if nothing matches at all.
static double PBScore(NSString *q, NSString *name) {
    if (q.length == 0 || name.length == 0) return 0.0;

    NSArray<NSString *> *nameWords = PBTokens(name);
    NSArray<NSString *> *qTokens   = PBTokens(q);

    // A compact, space-free form of each side for subsequence/initials tests.
    NSString *nameCompact = [name stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSString *qCompact    = [q stringByReplacingOccurrencesOfString:@" " withString:@""];

    // 1) Exact whole-name match.
    if ([name isEqualToString:q]) return kScoreExact;

    // 2) Some word begins with the (single-token) query. We weight mostly by
    //    how much of the WHOLE name the query covers — so a query that is a
    //    bigger share of a short name ("chrome" in "Google Chrome", 1/2 words)
    //    beats the same word buried in a longer name ("Chrome Remote Desktop",
    //    1/3 words). An exact full-word hit and a first-word hit are smaller
    //    tie-breakers on top.
    if (qTokens.count == 1) {
        double best = 0.0;
        for (NSUInteger i = 0; i < nameWords.count; i++) {
            NSString *w = nameWords[i];
            if (w.length >= q.length && [w hasPrefix:q]) {
                double nameCover = (double)q.length / (double)nameCompact.length;  // 0..1
                double posBonus  = (i == 0) ? 4.0 : 0.0;
                double fullWord  = [w isEqualToString:q] ? 3.0 : 0.0;
                double s = kScoreWordPrefix + nameCover * 120.0 + posBonus + fullWord;
                if (s > best) best = s;
            }
        }
        if (best > 0.0) return best;
    }

    // 3) Whole name starts with the query string (handles multi-word queries
    //    like "system sett" -> "System Settings").
    if ([name hasPrefix:q]) {
        double cover = (double)q.length / (double)name.length;
        return kScoreNamePrefix + cover * 30.0;
    }

    // 4) Multi-word query where every token prefixes a distinct word, in order
    //    where possible (e.g. "vis stu cod" -> "Visual Studio Code").
    if (qTokens.count >= 2) {
        NSUInteger searchFrom = 0;
        BOOL allMatched = YES;
        NSUInteger matchedWords = 0;
        for (NSString *t in qTokens) {
            if (t.length == 0) continue;
            BOOL found = NO;
            for (NSUInteger j = searchFrom; j < nameWords.count; j++) {
                if ([nameWords[j] hasPrefix:t]) { searchFrom = j + 1; found = YES; matchedWords++; break; }
            }
            if (!found) { allMatched = NO; break; }
        }
        if (allMatched) {
            // Reward covering more of the name's words (tighter match).
            double cover = nameWords.count ? (double)matchedWords / (double)nameWords.count : 0.0;
            return kScoreAllTokens + cover * 40.0;
        }
    }

    // 5) Initials match: query equals (a prefix of) the words' initials.
    //    "vsc" -> V·S·C(ode). Require >= 2 words so single-word apps don't
    //    spuriously match their own first letters.
    if (nameWords.count >= 2) {
        NSString *initials = PBInitials(nameWords);
        if (qCompact.length >= 2 && [initials hasPrefix:qCompact]) {
            double cover = (double)qCompact.length / (double)initials.length;  // 0..1
            return kScoreInitials + cover * 30.0;
        }
    }

    // 6) Subsequence of the compacted name (chars in order). "actmon" ->
    //    "activitymonitor", "vsc" -> "visualstudiocode".
    if (PBIsSubsequence(qCompact, nameCompact)) {
        // Denser matches (query length close to name length) score higher.
        double density = (double)qCompact.length / (double)nameCompact.length;  // 0..1
        return kScoreSubsequence + density * 60.0;
    }

    // 7) Plain substring anywhere in the name.
    if ([name rangeOfString:q].location != NSNotFound) {
        double cover = (double)q.length / (double)name.length;
        return kScoreSubstring + cover * 40.0;
    }

    return 0.0;
}

#pragma mark - PBAppIndex

@implementation PBAppIndex {
    NSArray<PBAppEntry *> *_apps;   // nil until first scan
}

+ (instancetype)shared {
    static PBAppIndex *gShared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gShared = [[PBAppIndex alloc] init]; });
    return gShared;
}

// The directories we scan. For "container" folders that hold many apps we also
// descend exactly one level so e.g. /Applications/Utilities/* is found.
- (NSArray<NSString *> *)scanRoots {
    NSString *home = NSHomeDirectory();
    return @[
        @"/Applications",
        @"/Applications/Utilities",
        @"/System/Applications",
        @"/System/Applications/Utilities",
        [home stringByAppendingPathComponent:@"Applications"],
    ];
}

// Display name + bundleID for an .app bundle, reading Contents/Info.plist.
- (PBAppEntry *)entryForBundleAtPath:(NSString *)path {
    NSString *filename = [[path lastPathComponent] stringByDeletingPathExtension];

    NSString *displayName = nil;
    NSString *bundleID = nil;

    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle) {
        bundleID = [bundle bundleIdentifier];
        NSDictionary *info = [bundle infoDictionary];
        displayName = info[@"CFBundleDisplayName"];
        if (displayName.length == 0) displayName = info[@"CFBundleName"];
    }

    // Fall back to reading the plist directly if NSBundle gave us nothing.
    if (displayName.length == 0 || bundleID.length == 0) {
        NSString *plistPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (info) {
            if (displayName.length == 0) displayName = info[@"CFBundleDisplayName"];
            if (displayName.length == 0) displayName = info[@"CFBundleName"];
            if (bundleID.length == 0)    bundleID    = info[@"CFBundleIdentifier"];
        }
    }

    if (displayName.length == 0) displayName = filename;

    PBAppEntry *e = [[PBAppEntry alloc] init];
    e.name = displayName;
    e.path = path;
    e.bundleID = (bundleID.length ? bundleID : nil);
    return e;
}

- (void)refresh {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<PBAppEntry *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    for (NSString *root in [self scanRoots]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;

        NSError *err = nil;
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:&err];
        if (!entries) continue;

        for (NSString *child in entries) {
            NSString *full = [root stringByAppendingPathComponent:child];

            if ([[child pathExtension] isEqualToString:@"app"]) {
                if (![seenPaths containsObject:full]) {
                    [seenPaths addObject:full];
                    [found addObject:[self entryForBundleAtPath:full]];
                }
                continue;
            }

            // One level into a non-.app subfolder (e.g. a vendor folder under
            // /Applications) so nested apps are still indexed.
            BOOL childIsDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&childIsDir] && childIsDir) {
                NSArray<NSString *> *sub = [fm contentsOfDirectoryAtPath:full error:NULL];
                for (NSString *grandchild in sub) {
                    if (![[grandchild pathExtension] isEqualToString:@"app"]) continue;
                    NSString *gfull = [full stringByAppendingPathComponent:grandchild];
                    if (![seenPaths containsObject:gfull]) {
                        [seenPaths addObject:gfull];
                        [found addObject:[self entryForBundleAtPath:gfull]];
                    }
                }
            }
        }
    }

    @synchronized (self) { _apps = [found copy]; }
}

- (NSArray<PBAppEntry *> *)allApps {
    @synchronized (self) {
        if (_apps == nil) {
            // Drop the lock while scanning, then re-check.
        } else {
            return _apps;
        }
    }
    [self refresh];
    @synchronized (self) { return _apps ?: @[]; }
}

- (NSArray<PBAppEntry *> *)matchesFor:(NSString *)query limit:(NSInteger)limit {
    NSString *q = PBNormalize(query);
    if (q.length == 0) return @[];

    NSArray<PBAppEntry *> *apps = [self allApps];

    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    for (PBAppEntry *e in apps) {
        double s = PBScore(q, PBNormalize(e.name));
        if (s >= kScoreThreshold) {
            [scored addObject:@{ @"e": e, @"s": @(s) }];
        }
    }

    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double sa = [a[@"s"] doubleValue], sb = [b[@"s"] doubleValue];
        if (sa > sb) return NSOrderedAscending;   // higher score first
        if (sa < sb) return NSOrderedDescending;
        // Tie-break: shorter display name first (the more "exact" feel), then
        // alphabetical for stability.
        PBAppEntry *ea = a[@"e"], *eb = b[@"e"];
        if (ea.name.length != eb.name.length) return ea.name.length < eb.name.length ? NSOrderedAscending : NSOrderedDescending;
        return [ea.name caseInsensitiveCompare:eb.name];
    }];

    NSMutableArray<PBAppEntry *> *out = [NSMutableArray array];
    for (NSDictionary *d in scored) {
        if (limit > 0 && (NSInteger)out.count >= limit) break;
        [out addObject:d[@"e"]];
    }
    return out;
}

- (PBAppEntry *)bestMatchFor:(NSString *)query {
    return [self matchesFor:query limit:1].firstObject;
}

@end
