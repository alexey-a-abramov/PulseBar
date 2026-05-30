//
//  AppIndex.h — a reusable application-launcher index.
//
//  Scans the standard macOS application folders for ".app" bundles and
//  fuzzy-matches a (possibly spoken) query like "vs code", "chrome" or
//  "system settings" to the right installed app. Foundation-only, read-only:
//  it enumerates bundles and reads their Info.plist; it never launches or
//  writes anything.
//
#import <Foundation/Foundation.h>

/// One installed application.
@interface PBAppEntry : NSObject
@property (nonatomic, copy) NSString *name;      // display name, e.g. "Visual Studio Code"
@property (nonatomic, copy) NSString *path;      // "/Applications/Visual Studio Code.app"
@property (nonatomic, copy) NSString *bundleID;  // may be nil
@end

/// A shared, lazily-built index of installed applications.
@interface PBAppIndex : NSObject

+ (instancetype)shared;

- (void)refresh;                                       // (re)scan; safe to call repeatedly
- (NSArray<PBAppEntry *> *)allApps;                    // current snapshot (scans lazily on first use)
- (PBAppEntry *)bestMatchFor:(NSString *)query;        // highest-scoring app, or nil if nothing reasonable
- (NSArray<PBAppEntry *> *)matchesFor:(NSString *)query limit:(NSInteger)limit;  // ranked, best first

@end
