//
//  voice_e2e.m — end-to-end test of the voice command pipeline WITHOUT any UI:
//  spoken phrases → PBAgent.ask → PBVoiceCommands fast-path → dispatch. Every
//  phrase here resolves deterministically (no Ollama needed). A recording
//  runner captures the dispatched action+args; read-only get_status queries are
//  answered for real via PBQueries (so you see live data); nothing else mutates
//  the system. Prints a transcript and asserts each phrase routes correctly.
//
#import <AppKit/AppKit.h>
#import "../Sources/Agent.h"
#import "../Sources/AppIndex.h"
#import "../Sources/VoiceCommands.h"
#import "../Sources/Queries.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("   ok   : %s\n", msg); } \
    else      { printf("   FAIL : %s\n", msg); failures++; } \
} while (0)

@interface VoiceRec : NSObject <PBAgentRunner>
@property (nonatomic, copy) NSString *act;
@property (nonatomic, copy) NSDictionary *args;
@property (nonatomic, copy) NSString *reply;
@end
@implementation VoiceRec
- (NSString *)agentRunAction:(NSString *)a args:(NSDictionary *)args {
    self.act = a; self.args = args;
    if ([a isEqualToString:@"get_status"]) return [PBQueries answer:args[@"what"]] ?: @"(no data)";
    return [NSString stringWithFormat:@"(emulated %@)", a];   // controls/bar/system/app: recorded, not executed
}
@end

static void say(PBAgent *ag, VoiceRec *rec, NSString *phrase) {
    rec.act = nil; rec.args = nil; rec.reply = nil;
    __block BOOL done = NO;
    [ag ask:phrase done:^(NSString *interp, NSString *reply) { rec.reply = reply; done = YES; }];
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && dl.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("🎙  \"%s\"\n     → %s %s\n     reply: %s\n",
           phrase.UTF8String, rec.act.UTF8String ?: "(none)",
           rec.args.count ? rec.args.description.UTF8String : "{}",
           rec.reply.UTF8String ?: "(none)");
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    printf("PulseBar — voice command end-to-end (emulated, no UI)\n\n");

    VoiceRec *rec = [VoiceRec new];
    PBAgent *ag = [PBAgent new];
    ag.runner = rec;
    ag.appResolver = ^NSString *(NSString *q) { return [[PBAppIndex shared] bestMatchFor:q].name; };

    printf("── Controls ──────────────────────────────\n");
    say(ag, rec, @"volume 30");            CHECK([rec.act isEqualToString:@"set_volume"] && [rec.args[@"percent"] intValue] == 30, "volume 30");
    say(ag, rec, @"turn it up");           CHECK([rec.act isEqualToString:@"adjust_volume"] && [rec.args[@"dir"] isEqualToString:@"up"], "turn it up");
    say(ag, rec, @"mute");                 CHECK([rec.act isEqualToString:@"toggle_mute"], "mute");
    say(ag, rec, @"set brightness to 60"); CHECK([rec.act isEqualToString:@"set_brightness"] && [rec.args[@"percent"] intValue] == 60, "brightness 60");
    say(ag, rec, @"play music");           CHECK([rec.act isEqualToString:@"media"] && [rec.args[@"cmd"] isEqualToString:@"playpause"], "play music");
    say(ag, rec, @"next track");           CHECK([rec.act isEqualToString:@"media"] && [rec.args[@"cmd"] isEqualToString:@"next"], "next track");

    printf("\n── Bar self-management ───────────────────\n");
    say(ag, rec, @"focus mode");           CHECK([rec.act isEqualToString:@"set_mode"] && [rec.args[@"mode"] isEqualToString:@"productivity"], "focus mode");
    say(ag, rec, @"switch to media");      CHECK([rec.act isEqualToString:@"set_mode"] && [rec.args[@"mode"] isEqualToString:@"media"], "switch to media");
    say(ag, rec, @"start a pomodoro");     CHECK([rec.act isEqualToString:@"toggle_pomodoro"], "start a pomodoro");
    say(ag, rec, @"keep awake");           CHECK([rec.act isEqualToString:@"toggle_caffeine"], "keep awake");
    say(ag, rec, @"hide the gpu tile");    CHECK([rec.act isEqualToString:@"set_tile"] && [rec.args[@"tile"] isEqualToString:@"gpu"], "hide gpu tile");
    say(ag, rec, @"show the desktop mirror"); CHECK([rec.act isEqualToString:@"show_mirror"], "show mirror");
    say(ag, rec, @"open the layout editor"); CHECK([rec.act isEqualToString:@"open_layout_editor"], "open layout editor");

    printf("\n── System (safe / reversible) ────────────\n");
    say(ag, rec, @"lock the screen");      CHECK([rec.act isEqualToString:@"lock"], "lock screen");
    say(ag, rec, @"toggle dark mode");     CHECK([rec.act isEqualToString:@"dark_mode"], "dark mode");
    say(ag, rec, @"open mission control"); CHECK([rec.act isEqualToString:@"mission_control"], "mission control");

    printf("\n── Query (read-only, real answers) ───────\n");
    say(ag, rec, @"what's my battery");    CHECK([rec.act isEqualToString:@"get_status"] && [rec.args[@"what"] isEqualToString:@"battery"], "battery query");
    say(ag, rec, @"how much memory am I using"); CHECK([rec.act isEqualToString:@"get_status"] && [rec.args[@"what"] isEqualToString:@"memory"], "memory query");

    printf("\n── App launcher (fuzzy index) ────────────\n");
    say(ag, rec, @"open calculator");      CHECK([rec.act isEqualToString:@"open_app"] && [rec.args[@"name"] length] > 0, "open calculator (resolved)");
    say(ag, rec, @"launch activity monitor"); CHECK([rec.act isEqualToString:@"open_app"] && [rec.args[@"name"] length] > 0, "launch activity monitor (resolved)");

    printf("\n── Safety (no destructive action exists) ─\n");
    PBIntent *bad = [PBVoiceCommands parse:@"delete all my files" appResolver:nil];
    CHECK(bad == nil, "‘delete all my files’ does not parse to any action");
    PBIntent *bad2 = [PBVoiceCommands parse:@"quit Safari and empty the trash" appResolver:nil];
    CHECK(bad2 == nil, "‘quit Safari and empty the trash’ does not parse to any action");

    printf("\n%s — %d failure(s)\n", failures ? "FAILED" : "ALL TESTS PASSED", failures);
    return failures ? 1 : 0;
}}
