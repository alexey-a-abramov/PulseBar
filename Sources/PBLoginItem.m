//
//  PBLoginItem.m
//
#import "PBLoginItem.h"
#import "PBProcess.h"

static NSString *AgentPlistPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.fun.pulsebar.plist"];
}

@implementation PBLoginItem

- (BOOL)isEnabled { return [[NSFileManager defaultManager] fileExistsAtPath:AgentPlistPath()]; }

- (void)setEnabled:(BOOL)on {
    NSString *p = AgentPlistPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSDictionary *plist = @{ @"Label": @"com.fun.pulsebar",
                                 @"ProgramArguments": @[exe],
                                 @"RunAtLoad": @YES,
                                 @"KeepAlive": @NO };
        [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [plist writeToFile:p atomically:YES];
        PBRunCapture(@"/bin/launchctl", @[@"load", @"-w", p]);
    } else {
        PBRunCapture(@"/bin/launchctl", @[@"unload", @"-w", p]);
        [fm removeItemAtPath:p error:nil];
    }
}

@end
