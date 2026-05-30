//
//  voicecommands_test.m — unit tests for the deterministic voice intent parser.
//  Compiled against Sources/VoiceCommands.m; links Foundation only, so it runs
//  anywhere (including headless). Style mirrors tests/stats_test.m.
//
#import <Foundation/Foundation.h>
#import "../Sources/VoiceCommands.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   : %s\n", msg); } \
    else      { printf("  FAIL : %s\n", msg); failures++; } \
} while (0)

// Convenience: parse with the stub resolver and return the intent.
static NSString *(^kResolver)(NSString *) = ^NSString *(NSString *q) {
    return q.length ? [q capitalizedString] : nil;
};

static PBIntent *P(NSString *text) {
    return [PBVoiceCommands parse:text appResolver:kResolver];
}

// Does intent i have action `act` and args[key] equal to `val` (string compare)?
static BOOL hasArg(PBIntent *i, NSString *key, id val) {
    if (!i) return NO;
    id got = i.args[key];
    if (!got) return NO;
    return [got isEqual:val];
}

int main(void) {
    @autoreleasepool {
        printf("PulseBar — voice command parser unit tests\n");

        // ---- Controls ----
        PBIntent *i;

        i = P(@"volume 30");
        CHECK(i && [i.action isEqualToString:@"set_volume"] && hasArg(i, @"percent", @30),
              "\"volume 30\" -> set_volume percent=30");

        i = P(@"set volume to thirty");
        CHECK(i && [i.action isEqualToString:@"set_volume"] && hasArg(i, @"percent", @30),
              "\"set volume to thirty\" -> set_volume percent=30 (number words)");

        i = P(@"turn it up");
        CHECK(i && [i.action isEqualToString:@"adjust_volume"] && hasArg(i, @"dir", @"up"),
              "\"turn it up\" -> adjust_volume dir=up");

        i = P(@"mute");
        CHECK(i && [i.action isEqualToString:@"toggle_mute"],
              "\"mute\" -> toggle_mute");

        i = P(@"play music");
        CHECK(i && [i.action isEqualToString:@"media"] && hasArg(i, @"cmd", @"playpause"),
              "\"play music\" -> media playpause");

        i = P(@"next");
        CHECK(i && [i.action isEqualToString:@"media"] && hasArg(i, @"cmd", @"next"),
              "\"next\" -> media next");

        i = P(@"brightness 70");
        CHECK(i && [i.action isEqualToString:@"set_brightness"] && hasArg(i, @"percent", @70),
              "\"brightness 70\" -> set_brightness percent=70");

        i = P(@"dimmer");
        CHECK(i && [i.action isEqualToString:@"adjust_brightness"] && hasArg(i, @"dir", @"down"),
              "\"dimmer\" -> adjust_brightness dir=down");

        // ---- Bar ----
        i = P(@"switch to media");
        CHECK(i && [i.action isEqualToString:@"set_mode"] && hasArg(i, @"mode", @"media"),
              "\"switch to media\" -> set_mode media");

        i = P(@"focus mode");
        CHECK(i && [i.action isEqualToString:@"set_mode"] && hasArg(i, @"mode", @"productivity"),
              "\"focus mode\" -> set_mode productivity");

        i = P(@"show shortcuts");
        CHECK(i && [i.action isEqualToString:@"set_mode"] && hasArg(i, @"mode", @"shortcuts"),
              "\"show shortcuts\" -> set_mode shortcuts");

        i = P(@"start a pomodoro");
        CHECK(i && [i.action isEqualToString:@"toggle_pomodoro"],
              "\"start a pomodoro\" -> toggle_pomodoro");

        i = P(@"keep awake");
        CHECK(i && [i.action isEqualToString:@"toggle_caffeine"],
              "\"keep awake\" -> toggle_caffeine");

        i = P(@"open settings");
        CHECK(i && [i.action isEqualToString:@"open_settings"],
              "\"open settings\" -> open_settings");

        i = P(@"edit layout");
        CHECK(i && [i.action isEqualToString:@"open_layout_editor"],
              "\"edit layout\" -> open_layout_editor");

        i = P(@"hide the gpu tile");
        CHECK(i && [i.action isEqualToString:@"set_tile"] && hasArg(i, @"tile", @"gpu") && hasArg(i, @"show", @0),
              "\"hide the gpu tile\" -> set_tile gpu show=0");

        i = P(@"show the battery tile");
        CHECK(i && [i.action isEqualToString:@"set_tile"] && hasArg(i, @"tile", @"batt") && hasArg(i, @"show", @1),
              "\"show the battery tile\" -> set_tile batt show=1");

        i = P(@"make cpu bigger");
        CHECK(i && [i.action isEqualToString:@"set_tile"] && hasArg(i, @"tile", @"cpu") && hasArg(i, @"size", @"big"),
              "\"make cpu bigger\" -> set_tile cpu size=big");

        i = P(@"show mirror");
        CHECK(i && [i.action isEqualToString:@"show_mirror"],
              "\"show mirror\" -> show_mirror");

        i = P(@"hide the mirror");
        CHECK(i && [i.action isEqualToString:@"hide_mirror"],
              "\"hide the mirror\" -> hide_mirror");

        // ---- System ----
        i = P(@"lock the screen");
        CHECK(i && [i.action isEqualToString:@"lock"],
              "\"lock the screen\" -> lock");

        i = P(@"turn off the screen");
        CHECK(i && [i.action isEqualToString:@"sleep_display"],
              "\"turn off the screen\" -> sleep_display");

        i = P(@"dark mode");
        CHECK(i && [i.action isEqualToString:@"dark_mode"],
              "\"dark mode\" -> dark_mode");

        i = P(@"mission control");
        CHECK(i && [i.action isEqualToString:@"mission_control"],
              "\"mission control\" -> mission_control");

        i = P(@"do not disturb");
        CHECK(i && [i.action isEqualToString:@"do_not_disturb"],
              "\"do not disturb\" -> do_not_disturb");

        // ---- Query ----
        i = P(@"what's my battery");
        CHECK(i && [i.action isEqualToString:@"get_status"] && hasArg(i, @"what", @"battery"),
              "\"what's my battery\" -> get_status battery");

        i = P(@"how much memory am i using");
        CHECK(i && [i.action isEqualToString:@"get_status"] && hasArg(i, @"what", @"memory"),
              "\"how much memory am i using\" -> get_status memory");

        i = P(@"what's playing");
        CHECK(i && [i.action isEqualToString:@"get_status"] && hasArg(i, @"what", @"now_playing"),
              "\"what's playing\" -> get_status now_playing");

        // ---- App ----
        i = P(@"open safari");
        CHECK(i && [i.action isEqualToString:@"open_app"] && hasArg(i, @"name", @"Safari"),
              "\"open safari\" -> open_app Safari (resolved)");
        CHECK(i && i.confidence >= 0.9,
              "\"open safari\" -> high confidence (resolved app)");

        // ---- Misc ----
        i = P(@"google touch bar apps");
        CHECK(i && [i.action isEqualToString:@"web_search"] && hasArg(i, @"query", @"touch bar apps"),
              "\"google touch bar apps\" -> web_search query=\"touch bar apps\"");

        // ---- Safety: destructive / unknown returns nil ----
        i = P(@"delete all my files");
        CHECK(i == nil, "\"delete all my files\" -> nil (destructive, no match)");

        i = P(@"quit safari");
        CHECK(i == nil, "\"quit safari\" -> nil (no quit action)");

        i = P(@"asldkfj qwerty zzz");
        CHECK(i == nil, "gibberish -> nil (falls back to LLM)");

        i = P(@"");
        CHECK(i == nil, "empty string -> nil");

        // ---- isKnownAction ----
        CHECK([PBVoiceCommands isKnownAction:@"set_volume"] == YES,
              "isKnownAction(\"set_volume\") == YES");
        CHECK([PBVoiceCommands isKnownAction:@"rm"] == NO,
              "isKnownAction(\"rm\") == NO");
        CHECK([PBVoiceCommands isKnownAction:@"shutdown"] == NO,
              "isKnownAction(\"shutdown\") == NO (out of vocabulary)");

        // ---- Catalog & prompt sanity ----
        NSArray *cat = [PBVoiceCommands catalog];
        CHECK(cat.count >= 20, "catalog has >= 20 actions");
        BOOL catShapeOK = YES;
        for (NSDictionary *e in cat) {
            if (![e[@"action"] isKindOfClass:NSString.class] ||
                ![e[@"category"] isKindOfClass:NSNumber.class] ||
                ![e[@"desc"] isKindOfClass:NSString.class] ||
                ![e[@"examples"] isKindOfClass:NSArray.class]) catShapeOK = NO;
            if (![PBVoiceCommands isKnownAction:e[@"action"]]) catShapeOK = NO;
        }
        CHECK(catShapeOK, "every catalog entry has correct shape & known action");

        NSString *prompt = [PBVoiceCommands promptVocabulary];
        CHECK(prompt.length > 200 &&
              [prompt rangeOfString:@"set_volume"].location != NSNotFound &&
              [prompt rangeOfString:@"get_status"].location != NSNotFound &&
              [prompt rangeOfString:@"open_app"].location != NSNotFound,
              "promptVocabulary lists the actions");

        printf("\n%s — %d failure%s\n",
               failures ? "TESTS FAILED" : "ALL TESTS PASSED",
               failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
