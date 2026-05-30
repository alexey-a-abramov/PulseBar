//
//  VoiceCommands.m — see VoiceCommands.h.
//
//  Strategy: normalize the input, then try the vocabulary patterns in priority
//  order (most specific first). The FIRST confident match wins. Anything that
//  doesn't match — or that looks destructive — returns nil so the caller falls
//  back to the constrained LLM. We NEVER emit an action outside the vocabulary
//  and NEVER emit anything destructive.
//
#import "VoiceCommands.h"

#pragma mark - PBIntent

@implementation PBIntent
@end

#pragma mark - Vocabulary table

// Every action name, paired with its category. Single source of truth for
// +isKnownAction and the catalog. Keep in sync with the parser below.
static NSDictionary<NSString *, NSNumber *> *PBActionCategories(void) {
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            // Controls
            @"set_volume":        @(PBCatControls),
            @"adjust_volume":     @(PBCatControls),
            @"toggle_mute":       @(PBCatControls),
            @"set_brightness":    @(PBCatControls),
            @"adjust_brightness": @(PBCatControls),
            @"media":             @(PBCatControls),
            // Bar
            @"set_mode":           @(PBCatBar),
            @"toggle_pomodoro":    @(PBCatBar),
            @"toggle_caffeine":    @(PBCatBar),
            @"show_mirror":        @(PBCatBar),
            @"hide_mirror":        @(PBCatBar),
            @"open_settings":      @(PBCatBar),
            @"open_layout_editor": @(PBCatBar),
            @"set_tile":           @(PBCatBar),
            // System
            @"lock":           @(PBCatSystem),
            @"sleep_display":  @(PBCatSystem),
            @"dark_mode":      @(PBCatSystem),
            @"mission_control":@(PBCatSystem),
            @"do_not_disturb": @(PBCatSystem),
            // Query
            @"get_status": @(PBCatQuery),
            // App
            @"open_app": @(PBCatApp),
            // Misc
            @"web_search": @(PBCatReply),
            @"reply":      @(PBCatReply),
        };
    });
    return m;
}

#pragma mark - Normalization

// Lowercase, strip punctuation that doesn't carry meaning, collapse whitespace,
// trim, and remove a leading wake word / politeness filler.
static NSString *PBNormalize(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return @"";
    NSString *s = [raw lowercaseString];

    // Replace anything that's not a letter/number/space with a space. Keeping
    // only [a-z0-9 ] also folds "what's" -> "what s", which our patterns expect.
    NSMutableString *clean = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [clean appendFormat:@"%C", c];
        } else {
            [clean appendString:@" "];
        }
    }

    // Collapse runs of whitespace to single spaces and trim.
    NSArray *parts = [clean componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [kept addObject:p];
    s = [kept componentsJoinedByString:@" "];

    // Strip leading wake words / fillers, possibly several in a row.
    NSArray *prefixes = @[ @"hey pulsebar", @"hey pulse bar", @"ok pulsebar", @"okay pulsebar",
                           @"pulsebar", @"hey", @"please", @"could you please", @"could you",
                           @"can you please", @"can you", @"would you", @"i want to",
                           @"i d like to", @"i would like to", @"id like to", @"lets", @"let s" ];
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *pre in prefixes) {
            if ([s isEqualToString:pre]) { s = @""; changed = YES; break; }
            NSString *withSpace = [pre stringByAppendingString:@" "];
            if ([s hasPrefix:withSpace]) {
                s = [s substringFromIndex:withSpace.length];
                changed = YES;
                break;
            }
        }
    }
    return s;
}

#pragma mark - Number words

// Parse an integer 0..100 from either digits ("30") or words ("thirty",
// "twenty five", "one hundred"). Returns -1 if `s` is not a recognised number.
static NSInteger PBParseNumber(NSString *s) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0) return -1;

    // Pure digits.
    static NSCharacterSet *nonDigits = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet]; });
    if ([s rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
        NSInteger v = [s integerValue];
        return v;   // caller clamps
    }

    // Word forms.
    static NSDictionary *units = nil, *tens = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        units = @{ @"zero":@0, @"one":@1, @"two":@2, @"three":@3, @"four":@4,
                   @"five":@5, @"six":@6, @"seven":@7, @"eight":@8, @"nine":@9,
                   @"ten":@10, @"eleven":@11, @"twelve":@12, @"thirteen":@13,
                   @"fourteen":@14, @"fifteen":@15, @"sixteen":@16, @"seventeen":@17,
                   @"eighteen":@18, @"nineteen":@19 };
        tens  = @{ @"twenty":@20, @"thirty":@30, @"forty":@40, @"fifty":@50,
                   @"sixty":@60, @"seventy":@70, @"eighty":@80, @"ninety":@90 };
    });

    NSArray *words = [s componentsSeparatedByString:@" "];
    NSInteger total = 0;
    BOOL any = NO;
    for (NSString *w in words) {
        if (w.length == 0 || [w isEqualToString:@"and"]) continue;
        if ([w isEqualToString:@"hundred"]) {
            // "one hundred" / "a hundred" / bare "hundred".
            total = total == 0 ? 100 : total * 100;
            any = YES;
        } else if ([w isEqualToString:@"a"]) {
            continue;   // "a hundred"
        } else if (units[w]) {
            total += [units[w] integerValue];
            any = YES;
        } else if (tens[w]) {
            total += [tens[w] integerValue];
            any = YES;
        } else {
            return -1;   // an unknown token means this isn't a clean number phrase
        }
    }
    return any ? total : -1;
}

static NSInteger PBClampPercent(NSInteger v) {
    if (v < 0)   return 0;
    if (v > 100) return 100;
    return v;
}

#pragma mark - Small helpers

static BOOL PBContainsWord(NSString *s, NSString *word) {
    // Whole-word containment on a space-normalized string.
    if ([s isEqualToString:word]) return YES;
    if ([s hasPrefix:[word stringByAppendingString:@" "]]) return YES;
    if ([s hasSuffix:[@" " stringByAppendingString:word]]) return YES;
    NSString *mid = [NSString stringWithFormat:@" %@ ", word];
    return [s rangeOfString:mid].location != NSNotFound;
}

static BOOL PBContainsAny(NSString *s, NSArray<NSString *> *phrases) {
    for (NSString *p in phrases) {
        // Multi-word phrases use substring search; single words use word match.
        if ([p rangeOfString:@" "].location != NSNotFound) {
            if ([s rangeOfString:p].location != NSNotFound) return YES;
        } else if (PBContainsWord(s, p)) {
            return YES;
        }
    }
    return NO;
}

static PBIntent *PBMake(PBCmdCategory cat, NSString *action, NSDictionary *args, double conf) {
    PBIntent *i = [PBIntent new];
    i.category = cat;
    i.action = action;
    i.args = args ?: @{};
    i.confidence = conf;
    return i;
}

// Canonical tile token for a friendly word, or nil if not a tile.
static NSString *PBTileToken(NSString *w) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // canonical tokens (accepted as-is)
            @"cpu":@"cpu", @"mem":@"mem", @"gpu":@"gpu", @"net":@"net", @"disk":@"disk",
            @"uptime":@"uptime", @"batt":@"batt", @"media":@"media", @"vol":@"vol",
            @"mute":@"mute", @"bright":@"bright", @"pomo":@"pomo", @"caffeine":@"caffeine",
            @"sc_lock":@"sc_lock", @"sc_sleep":@"sc_sleep", @"sc_shot":@"sc_shot",
            @"sc_dark":@"sc_dark", @"sc_mission":@"sc_mission", @"sc_note":@"sc_note",
            @"sc_launch":@"sc_launch", @"sc_activity":@"sc_activity",
            // friendly aliases
            @"memory":@"mem", @"ram":@"mem", @"network":@"net", @"battery":@"batt",
            @"volume":@"vol", @"brightness":@"bright", @"storage":@"disk",
            @"pomodoro":@"pomo", @"graphics":@"gpu", @"music":@"media", @"player":@"media",
        };
    });
    return map[w];
}

// Canonical bar mode for a word/phrase, or nil.
static NSString *PBModeToken(NSString *w) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"system":@"system",
            @"media":@"media", @"music":@"media",
            @"productivity":@"productivity", @"focus":@"productivity",
            @"classic":@"classic",
            @"shortcuts":@"shortcuts", @"actions":@"shortcuts",
        };
    });
    return map[w];
}

// Strip a leading article/determiner from a captured tail ("the gpu" -> "gpu").
static NSString *PBStripLeadingArticle(NSString *s) {
    NSArray *arts = @[ @"the ", @"a ", @"an ", @"my ", @"this ", @"that ", @"current " ];
    for (NSString *a in arts) {
        if ([s hasPrefix:a]) return [s substringFromIndex:a.length];
    }
    return s;
}

#pragma mark - set_tile parsing

// Try to read a tile token out of a phrase that mentions "tile" or a known
// tile word. Returns the token or nil.
static NSString *PBFindTileToken(NSString *s) {
    for (NSString *w in [s componentsSeparatedByString:@" "]) {
        NSString *tok = PBTileToken(w);
        if (tok) return tok;
    }
    return nil;
}

#pragma mark - PBVoiceCommands

@implementation PBVoiceCommands

+ (BOOL)isKnownAction:(NSString *)action {
    if (![action isKindOfClass:NSString.class]) return NO;
    return PBActionCategories()[action] != nil;
}

+ (PBIntent *)parse:(NSString *)text appResolver:(NSString *(^)(NSString *))appResolver {
    NSString *s = PBNormalize(text);
    if (s.length == 0) return nil;

    // -------- Safety: refuse destructive / out-of-scope requests outright. ----
    // There is deliberately no quit/delete/shutdown action. If the phrase is
    // clearly asking for one, bail to nil so the agent declines rather than the
    // LLM trying to satisfy it.
    NSArray *destructive = @[ @"delete", @"erase", @"wipe", @"format", @"uninstall",
                              @"remove all", @"rm ", @"shut down", @"shutdown",
                              @"power off", @"turn off the computer", @"turn off the mac",
                              @"restart", @"reboot", @"log out", @"logout", @"sign out",
                              @"force quit", @"kill", @"empty the trash", @"empty trash" ];
    if (PBContainsAny(s, destructive)) return nil;
    // "quit" / "close" an app is also out of vocabulary (no such action).
    if (PBContainsWord(s, @"quit") || [s hasPrefix:@"close "]) return nil;

    // ======================================================================
    // CONTROLS
    // ======================================================================

    // --- Mute / unmute / silence ---
    if (PBContainsAny(s, @[ @"mute", @"unmute", @"silence", @"un mute" ])) {
        return PBMake(PBCatControls, @"toggle_mute", @{}, 0.95);
    }

    // --- Volume: explicit number ("volume 30", "set volume to 30", "volume thirty") ---
    {
        PBIntent *v = [self parseLevel:s
                                 nouns:@[ @"volume", @"sound", @"audio" ]
                                action:@"set_volume"];
        if (v) return v;
    }
    // --- Volume up/down (also bare "louder"/"quieter"/"turn it up") ---
    if (PBContainsAny(s, @[ @"volume up", @"louder", @"turn it up", @"turn up the volume",
                            @"turn the volume up", @"increase volume", @"raise the volume",
                            @"raise volume", @"crank it up", @"pump it up", @"more volume" ])) {
        return PBMake(PBCatControls, @"adjust_volume", @{ @"dir": @"up" }, 0.92);
    }
    if (PBContainsAny(s, @[ @"volume down", @"quieter", @"turn it down", @"turn down the volume",
                            @"turn the volume down", @"decrease volume", @"lower the volume",
                            @"lower volume", @"softer", @"less volume" ])) {
        return PBMake(PBCatControls, @"adjust_volume", @{ @"dir": @"down" }, 0.92);
    }

    // --- Brightness: explicit number ---
    {
        PBIntent *v = [self parseLevel:s
                                 nouns:@[ @"brightness" ]
                                action:@"set_brightness"];
        if (v) return v;
    }
    // --- Brightness up/down ---
    if (PBContainsAny(s, @[ @"brighter", @"brightness up", @"increase brightness",
                            @"raise brightness", @"turn up the brightness", @"more brightness",
                            @"brighten" ])) {
        return PBMake(PBCatControls, @"adjust_brightness", @{ @"dir": @"up" }, 0.92);
    }
    if (PBContainsAny(s, @[ @"dimmer", @"dim the screen", @"dim screen", @"brightness down",
                            @"decrease brightness", @"lower brightness", @"turn down the brightness",
                            @"less brightness", @"darker" ]) || PBContainsWord(s, @"dim")) {
        return PBMake(PBCatControls, @"adjust_brightness", @{ @"dir": @"down" }, 0.9);
    }

    // --- Media transport ---
    if (PBContainsAny(s, @[ @"next track", @"next song", @"skip track", @"skip song",
                            @"skip forward", @"play next" ]) ||
        PBContainsWord(s, @"next") || PBContainsWord(s, @"skip")) {
        return PBMake(PBCatControls, @"media", @{ @"cmd": @"next" }, 0.92);
    }
    if (PBContainsAny(s, @[ @"previous track", @"previous song", @"go back a track",
                            @"play previous", @"last track", @"last song" ]) ||
        PBContainsWord(s, @"previous") || PBContainsWord(s, @"prev")) {
        return PBMake(PBCatControls, @"media", @{ @"cmd": @"prev" }, 0.9);
    }
    if (PBContainsAny(s, @[ @"play pause", @"pause music", @"pause the music", @"resume music",
                            @"play music", @"play the music", @"play song", @"play some music",
                            @"start music", @"pause" ]) ||
        PBContainsWord(s, @"play") || PBContainsWord(s, @"pause") || PBContainsWord(s, @"resume")) {
        // "back" alone means previous track in a media context.
        return PBMake(PBCatControls, @"media", @{ @"cmd": @"playpause" }, 0.9);
    }
    if (PBContainsWord(s, @"back")) {
        return PBMake(PBCatControls, @"media", @{ @"cmd": @"prev" }, 0.7);
    }

    // ======================================================================
    // BAR
    // ======================================================================

    // --- Pomodoro / focus timer / break ---
    if (PBContainsAny(s, @[ @"pomodoro", @"start focus", @"focus timer", @"start a timer",
                            @"start the timer", @"take a break", @"start a break",
                            @"start focusing", @"focus session", @"stop the timer",
                            @"stop pomodoro" ])) {
        return PBMake(PBCatBar, @"toggle_pomodoro", @{}, 0.92);
    }

    // --- Caffeine / keep awake ---
    if (PBContainsAny(s, @[ @"caffeinate", @"keep awake", @"stay awake", @"keep it awake",
                            @"don t sleep", @"do not sleep", @"keep the screen on",
                            @"prevent sleep", @"keep my mac awake", @"caffeine" ])) {
        return PBMake(PBCatBar, @"toggle_caffeine", @{}, 0.92);
    }

    // --- Mirror ---
    if (PBContainsAny(s, @[ @"hide mirror", @"hide the mirror", @"close mirror",
                            @"close the mirror", @"hide camera", @"hide the camera" ])) {
        return PBMake(PBCatBar, @"hide_mirror", @{}, 0.92);
    }
    if (PBContainsAny(s, @[ @"show mirror", @"show the mirror", @"open mirror",
                            @"open the mirror", @"mirror me", @"show camera",
                            @"show the camera", @"selfie" ]) || PBContainsWord(s, @"mirror")) {
        return PBMake(PBCatBar, @"show_mirror", @{}, 0.9);
    }

    // --- Layout editor (check before plain settings) ---
    if (PBContainsAny(s, @[ @"layout editor", @"edit layout", @"edit the layout",
                            @"customize layout", @"customise layout", @"customize the layout",
                            @"customise the layout", @"edit the bar", @"customize the bar",
                            @"rearrange tiles", @"arrange tiles", @"configure tiles",
                            @"configure the bar" ])) {
        return PBMake(PBCatBar, @"open_layout_editor", @{}, 0.92);
    }

    // --- Settings / preferences ---
    if (PBContainsAny(s, @[ @"open settings", @"open the settings", @"settings",
                            @"preferences", @"open preferences", @"open prefs", @"prefs",
                            @"open the settings window" ])) {
        return PBMake(PBCatBar, @"open_settings", @{}, 0.9);
    }

    // --- set_tile (show/hide/resize a specific tile) ---
    {
        PBIntent *t = [self parseSetTile:s];
        if (t) return t;
    }

    // --- set_mode (… mode / switch to … / show shortcuts) ---
    {
        PBIntent *m = [self parseSetMode:s];
        if (m) return m;
    }

    // ======================================================================
    // SYSTEM
    // ======================================================================

    if (PBContainsAny(s, @[ @"lock screen", @"lock the screen", @"lock my mac",
                            @"lock the mac", @"lock my screen", @"lock my computer",
                            @"lock the computer" ]) || PBContainsWord(s, @"lock")) {
        return PBMake(PBCatSystem, @"lock", @{}, 0.95);
    }

    if (PBContainsAny(s, @[ @"sleep display", @"sleep the display", @"turn off the screen",
                            @"turn off screen", @"turn the screen off", @"screen off",
                            @"display off", @"sleep the screen", @"sleep screen",
                            @"put the display to sleep", @"blank the screen" ])) {
        return PBMake(PBCatSystem, @"sleep_display", @{}, 0.92);
    }

    if (PBContainsAny(s, @[ @"dark mode", @"toggle dark", @"light mode", @"toggle light",
                            @"toggle appearance", @"switch to dark", @"switch to light",
                            @"go dark", @"night mode" ])) {
        return PBMake(PBCatSystem, @"dark_mode", @{}, 0.92);
    }

    if (PBContainsAny(s, @[ @"mission control", @"show all windows", @"show my windows",
                            @"expose", @"spaces overview" ])) {
        return PBMake(PBCatSystem, @"mission_control", @{}, 0.92);
    }

    if (PBContainsAny(s, @[ @"do not disturb", @"do not disturbe", @"dnd", @"focus mode",
                            @"turn on focus", @"silence notifications", @"mute notifications",
                            @"quiet mode", @"don t disturb me", @"don t disturb" ])) {
        return PBMake(PBCatSystem, @"do_not_disturb", @{}, 0.92);
    }

    // ======================================================================
    // QUERY (get_status)
    // ======================================================================
    {
        PBIntent *q = [self parseQuery:s];
        if (q) return q;
    }

    // ======================================================================
    // MISC — web search
    // ======================================================================
    {
        PBIntent *w = [self parseWebSearch:s];
        if (w) return w;
    }

    // ======================================================================
    // APP — open/launch/switch to <X>  (kept last: broad verbs)
    // ======================================================================
    {
        PBIntent *a = [self parseOpenApp:s resolver:appResolver];
        if (a) return a;
    }

    // No confident match — let the caller fall back to the LLM.
    return nil;
}

#pragma mark - Sub-parsers

// "<noun> 30", "set <noun> to 30", "<noun> thirty", "set <noun> 30%",
// "make it 30" when a noun also appears. Returns set_volume/set_brightness or nil.
+ (PBIntent *)parseLevel:(NSString *)s nouns:(NSArray<NSString *> *)nouns action:(NSString *)action {
    BOOL hasNoun = NO;
    for (NSString *n in nouns) if (PBContainsWord(s, n)) { hasNoun = YES; break; }
    if (!hasNoun) return nil;

    // Find a number token (digit run or number word/phrase) anywhere in the text.
    // We scan tokens and also try multi-word number phrases like "twenty five".
    NSArray *toks = [s componentsSeparatedByString:@" "];

    // 1) Any pure-digit token.
    for (NSString *t in toks) {
        NSInteger n = PBParseNumber(t);
        if (n >= 0 && [t rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
            PBCmdCategory cat = [PBActionCategories()[action] integerValue];
            return PBMake(cat, action, @{ @"percent": @(PBClampPercent(n)) }, 0.95);
        }
    }

    // 2) A number expressed in words: take the longest trailing run of number words.
    //    e.g. "set volume to twenty five" -> "twenty five" -> 25.
    static NSSet *numWords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        numWords = [NSSet setWithArray:@[ @"zero",@"one",@"two",@"three",@"four",@"five",@"six",
            @"seven",@"eight",@"nine",@"ten",@"eleven",@"twelve",@"thirteen",@"fourteen",
            @"fifteen",@"sixteen",@"seventeen",@"eighteen",@"nineteen",@"twenty",@"thirty",
            @"forty",@"fifty",@"sixty",@"seventy",@"eighty",@"ninety",@"hundred",@"and",@"a" ]];
    });
    NSInteger best = -1;
    NSMutableArray *run = [NSMutableArray array];
    for (NSString *t in toks) {
        if ([numWords containsObject:t]) {
            [run addObject:t];
        } else if (run.count) {
            NSInteger n = PBParseNumber([run componentsJoinedByString:@" "]);
            if (n >= 0) best = n;   // last complete run wins
            [run removeAllObjects];
        }
    }
    if (run.count) {
        NSInteger n = PBParseNumber([run componentsJoinedByString:@" "]);
        if (n >= 0) best = n;
    }
    if (best >= 0) {
        PBCmdCategory cat = [PBActionCategories()[action] integerValue];
        return PBMake(cat, action, @{ @"percent": @(PBClampPercent(best)) }, 0.9);
    }
    return nil;
}

// "<mode> mode", "switch to <mode>", "show shortcuts", "go to focus".
+ (PBIntent *)parseSetMode:(NSString *)s {
    BOOL modeCue = PBContainsWord(s, @"mode") ||
                   PBContainsAny(s, @[ @"switch to", @"go to", @"change to", @"show " ]);

    // Find a mode keyword in the text.
    NSString *found = nil;
    for (NSString *w in [s componentsSeparatedByString:@" "]) {
        NSString *tok = PBModeToken(w);
        if (tok) { found = tok; break; }
    }
    if (!found) return nil;

    // Disambiguate "media"/"music"/"focus" so they don't fire without a cue:
    //  - "media mode" / "switch to media" -> set_mode media   (cue present)
    //  - bare "music" was already handled by media-transport above.
    // Require either an explicit "mode" word or a switch/show cue.
    if (!modeCue) return nil;

    return PBMake(PBCatBar, @"set_mode", @{ @"mode": found }, 0.92);
}

// "hide the gpu tile", "show battery tile", "make cpu bigger/smaller",
// "show/hide <tile>". Returns set_tile or nil.
+ (PBIntent *)parseSetTile:(NSString *)s {
    BOOL mentionsTile = PBContainsWord(s, @"tile") || PBContainsWord(s, @"tiles");
    BOOL show = PBContainsWord(s, @"show") || PBContainsWord(s, @"display") ||
                PBContainsWord(s, @"enable") || PBContainsWord(s, @"add") ||
                PBContainsWord(s, @"reveal");
    BOOL hide = PBContainsWord(s, @"hide") || PBContainsWord(s, @"remove") ||
                PBContainsWord(s, @"disable") || PBContainsWord(s, @"turn off the");
    BOOL bigger  = PBContainsAny(s, @[ @"bigger", @"larger", @"big", @"wider", @"make it large" ]);
    BOOL smaller = PBContainsAny(s, @[ @"smaller", @"small", @"narrower", @"tiny", @"shrink" ]);

    // Only treat as a tile command when there's a real tile cue: an explicit
    // "tile" word, or a resize verb, or a show/hide paired with a tile token.
    if (!(mentionsTile || bigger || smaller || ((show || hide)))) return nil;

    NSString *tok = PBFindTileToken(s);
    if (!tok) return nil;

    // Resize takes precedence when present.
    if (bigger || smaller) {
        return PBMake(PBCatBar, @"set_tile",
                      @{ @"tile": tok, @"size": bigger ? @"big" : @"small" }, 0.9);
    }
    if (show && !hide) {
        return PBMake(PBCatBar, @"set_tile", @{ @"tile": tok, @"show": @1 }, 0.92);
    }
    if (hide) {
        return PBMake(PBCatBar, @"set_tile", @{ @"tile": tok, @"show": @0 }, 0.92);
    }
    return nil;
}

// Status queries for battery/cpu/memory/disk/uptime/volume/brightness/now_playing.
+ (PBIntent *)parseQuery:(NSString *)s {
    // Must look like a question / status request, not a command.
    BOOL questionCue = PBContainsAny(s, @[ @"what s", @"whats", @"what is", @"what", @"how much",
                                           @"how many", @"how s", @"how is", @"hows", @"tell me",
                                           @"show me the", @"status", @"check", @"how much is",
                                           @"how long" ]);

    // now_playing — special phrasing.
    if (PBContainsAny(s, @[ @"what s playing", @"whats playing", @"what is playing",
                            @"what song", @"what s this song", @"now playing", @"what track",
                            @"current song", @"what music is" ])) {
        return PBMake(PBCatQuery, @"get_status", @{ @"what": @"now_playing" }, 0.92);
    }

    // Map a subject word to a get_status "what".
    NSString *what = nil;
    if (PBContainsWord(s, @"battery") || PBContainsWord(s, @"charge"))           what = @"battery";
    else if (PBContainsWord(s, @"cpu") || PBContainsWord(s, @"processor"))       what = @"cpu";
    else if (PBContainsWord(s, @"memory") || PBContainsWord(s, @"ram"))          what = @"memory";
    else if (PBContainsWord(s, @"disk") || PBContainsWord(s, @"storage") ||
             PBContainsWord(s, @"space"))                                        what = @"disk";
    else if (PBContainsWord(s, @"uptime"))                                       what = @"uptime";
    else if (PBContainsWord(s, @"volume"))                                       what = @"volume";
    else if (PBContainsWord(s, @"brightness"))                                   what = @"brightness";

    if (!what) return nil;

    // "uptime" alone is a clear query; otherwise require a question cue so we
    // don't hijack commands like "set volume" (already handled) — but those
    // earlier branches returned first, so by here a bare subject is a query.
    double conf = 0.9;
    if (!questionCue && ![what isEqualToString:@"uptime"]) {
        // Bare subject like "battery" / "memory" — treat as a status query but
        // with slightly lower confidence.
        conf = 0.75;
    }
    return PBMake(PBCatQuery, @"get_status", @{ @"what": what }, conf);
}

// "search [the web] for <Q>", "google <Q>", "look up <Q>", "search <Q>".
+ (PBIntent *)parseWebSearch:(NSString *)s {
    NSArray *triggers = @[ @"search the web for ", @"search the internet for ",
                           @"search online for ", @"search for ", @"google for ",
                           @"google ", @"look up ", @"web search for ", @"search " ];
    for (NSString *t in triggers) {
        if ([s hasPrefix:t]) {
            NSString *q = [[s substringFromIndex:t.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            q = PBStripLeadingArticle(q);
            if (q.length) {
                return PBMake(PBCatReply, @"web_search", @{ @"query": q }, 0.9);
            }
        }
    }
    return nil;
}

// "open <X>", "launch <X>", "start <X>", "switch to <X>", "go to <X>".
// Resolve X via appResolver. If it resolves -> high confidence with the
// resolved name. If not, still emit open_app with the raw query but lower
// the confidence.
+ (PBIntent *)parseOpenApp:(NSString *)s resolver:(NSString *(^)(NSString *))appResolver {
    NSArray *verbs = @[ @"open ", @"launch ", @"start ", @"switch to ", @"go to ",
                        @"bring up ", @"fire up ", @"run " ];
    NSString *query = nil;
    for (NSString *v in verbs) {
        if ([s hasPrefix:v]) {
            query = [s substringFromIndex:v.length];
            break;
        }
    }
    if (!query) return nil;

    query = PBStripLeadingArticle([query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    // Drop a trailing " app" ("open the safari app" -> "safari").
    if ([query hasSuffix:@" app"]) query = [query substringToIndex:query.length - 4];
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) return nil;

    NSString *resolved = appResolver ? appResolver(query) : nil;
    if (resolved.length) {
        return PBMake(PBCatApp, @"open_app", @{ @"name": resolved }, 0.93);
    }
    // Unresolved: still offer open_app with the raw text, but low confidence so
    // the caller can prefer the LLM if it wants.
    return PBMake(PBCatApp, @"open_app", @{ @"name": query }, 0.55);
}

#pragma mark - Vocabulary / catalog for callers

+ (NSString *)promptVocabulary {
    // Compact, exact spec to paste into an LLM system prompt. Mirrors the parser
    // vocabulary EXACTLY — names, arg shapes, and one example each.
    return
    @"You control PulseBar. Reply with ONE JSON object and NOTHING else:\n"
    @"{\"action\":\"<name>\",\"args\":{...},\"say\":\"<short sentence>\"}\n"
    @"Use ONLY these actions and the EXACT arg shapes. Never invent actions. "
    @"There is NO quit/close/delete/shutdown/restart — refuse those in \"say\" with action \"reply\".\n"
    @"\n"
    @"Controls:\n"
    @"  set_volume {\"percent\":0-100}            // \"set volume to 30\"\n"
    @"  adjust_volume {\"dir\":\"up\"|\"down\"}        // \"turn it up\"\n"
    @"  toggle_mute {}                           // \"mute\"\n"
    @"  set_brightness {\"percent\":0-100}        // \"brightness 70\"\n"
    @"  adjust_brightness {\"dir\":\"up\"|\"down\"}    // \"dimmer\"\n"
    @"  media {\"cmd\":\"playpause\"|\"next\"|\"prev\"} // \"next track\"\n"
    @"\n"
    @"Bar:\n"
    @"  set_mode {\"mode\":\"system\"|\"media\"|\"productivity\"|\"classic\"|\"shortcuts\"} // \"media mode\"\n"
    @"  toggle_pomodoro {}                       // \"start a pomodoro\"\n"
    @"  toggle_caffeine {}                       // \"keep awake\"\n"
    @"  show_mirror {}                           // \"show mirror\"\n"
    @"  hide_mirror {}                           // \"hide mirror\"\n"
    @"  open_settings {}                         // \"open settings\"\n"
    @"  open_layout_editor {}                    // \"edit layout\"\n"
    @"  set_tile {\"tile\":<token>,\"show\":0|1[,\"size\":\"big\"|\"small\"]} // \"hide the gpu tile\"\n"
    @"    tiles: cpu mem gpu net disk uptime batt media vol mute bright pomo caffeine\n"
    @"           sc_lock sc_sleep sc_shot sc_dark sc_mission sc_note sc_launch sc_activity\n"
    @"\n"
    @"System:\n"
    @"  lock {}                                  // \"lock the screen\"\n"
    @"  sleep_display {}                         // \"turn off the screen\"\n"
    @"  dark_mode {}                             // \"toggle dark mode\"\n"
    @"  mission_control {}                       // \"mission control\"\n"
    @"  do_not_disturb {}                        // \"do not disturb\"\n"
    @"\n"
    @"Query:\n"
    @"  get_status {\"what\":\"battery\"|\"cpu\"|\"memory\"|\"disk\"|\"uptime\"|\"volume\"|\"brightness\"|\"now_playing\"} // \"what's my battery\"\n"
    @"\n"
    @"App:\n"
    @"  open_app {\"name\":\"<app name>\"}          // \"open Safari\"\n"
    @"\n"
    @"Misc:\n"
    @"  web_search {\"query\":\"<text>\"}           // \"google touch bar apps\"\n"
    @"  reply {}                                 // chitchat/answer — put it in \"say\"\n";
}

+ (NSArray<NSDictionary *> *)catalog {
    // Machine-readable list for UI/help. category is an NSNumber (PBCmdCategory).
    #define CAT(c) @((NSInteger)(c))
    return @[
        @{ @"action": @"set_volume",        @"category": CAT(PBCatControls),
           @"desc": @"Set volume to a percentage (0–100).",
           @"examples": @[ @"set volume to 30", @"volume 30", @"volume thirty" ] },
        @{ @"action": @"adjust_volume",     @"category": CAT(PBCatControls),
           @"desc": @"Nudge volume up or down.",
           @"examples": @[ @"louder", @"turn it up", @"volume down" ] },
        @{ @"action": @"toggle_mute",       @"category": CAT(PBCatControls),
           @"desc": @"Toggle mute.",
           @"examples": @[ @"mute", @"unmute", @"silence" ] },
        @{ @"action": @"set_brightness",    @"category": CAT(PBCatControls),
           @"desc": @"Set screen brightness to a percentage (0–100).",
           @"examples": @[ @"brightness 70", @"set brightness to 50" ] },
        @{ @"action": @"adjust_brightness", @"category": CAT(PBCatControls),
           @"desc": @"Nudge brightness up or down.",
           @"examples": @[ @"brighter", @"dimmer" ] },
        @{ @"action": @"media",             @"category": CAT(PBCatControls),
           @"desc": @"Media transport: play/pause, next, previous.",
           @"examples": @[ @"play", @"pause", @"next", @"previous" ] },

        @{ @"action": @"set_mode",          @"category": CAT(PBCatBar),
           @"desc": @"Switch the bar mode.",
           @"examples": @[ @"media mode", @"switch to focus", @"show shortcuts" ] },
        @{ @"action": @"toggle_pomodoro",   @"category": CAT(PBCatBar),
           @"desc": @"Start/stop the pomodoro focus timer.",
           @"examples": @[ @"start a pomodoro", @"take a break" ] },
        @{ @"action": @"toggle_caffeine",   @"category": CAT(PBCatBar),
           @"desc": @"Keep the Mac awake (toggle caffeine).",
           @"examples": @[ @"caffeinate", @"keep awake", @"don't sleep" ] },
        @{ @"action": @"show_mirror",       @"category": CAT(PBCatBar),
           @"desc": @"Show the camera mirror.",
           @"examples": @[ @"show mirror" ] },
        @{ @"action": @"hide_mirror",       @"category": CAT(PBCatBar),
           @"desc": @"Hide the camera mirror.",
           @"examples": @[ @"hide mirror" ] },
        @{ @"action": @"open_settings",     @"category": CAT(PBCatBar),
           @"desc": @"Open PulseBar settings.",
           @"examples": @[ @"open settings", @"preferences" ] },
        @{ @"action": @"open_layout_editor",@"category": CAT(PBCatBar),
           @"desc": @"Open the bar layout editor.",
           @"examples": @[ @"edit layout", @"customize layout" ] },
        @{ @"action": @"set_tile",          @"category": CAT(PBCatBar),
           @"desc": @"Show, hide, or resize a tile.",
           @"examples": @[ @"hide the gpu tile", @"show the battery tile", @"make cpu bigger" ] },

        @{ @"action": @"lock",              @"category": CAT(PBCatSystem),
           @"desc": @"Lock the screen.",
           @"examples": @[ @"lock", @"lock the screen" ] },
        @{ @"action": @"sleep_display",     @"category": CAT(PBCatSystem),
           @"desc": @"Put the display to sleep.",
           @"examples": @[ @"sleep display", @"turn off the screen" ] },
        @{ @"action": @"dark_mode",         @"category": CAT(PBCatSystem),
           @"desc": @"Toggle dark mode.",
           @"examples": @[ @"dark mode", @"toggle dark" ] },
        @{ @"action": @"mission_control",   @"category": CAT(PBCatSystem),
           @"desc": @"Open Mission Control.",
           @"examples": @[ @"mission control" ] },
        @{ @"action": @"do_not_disturb",    @"category": CAT(PBCatSystem),
           @"desc": @"Toggle Do Not Disturb / Focus.",
           @"examples": @[ @"do not disturb", @"dnd", @"focus mode on" ] },

        @{ @"action": @"get_status",        @"category": CAT(PBCatQuery),
           @"desc": @"Report a system metric.",
           @"examples": @[ @"what's my battery", @"cpu usage", @"what's playing" ] },

        @{ @"action": @"open_app",          @"category": CAT(PBCatApp),
           @"desc": @"Open or switch to an app.",
           @"examples": @[ @"open Safari", @"launch Notes", @"switch to Mail" ] },

        @{ @"action": @"web_search",        @"category": CAT(PBCatReply),
           @"desc": @"Search the web for a query.",
           @"examples": @[ @"search the web for swift", @"google touch bar apps" ] },
        @{ @"action": @"reply",             @"category": CAT(PBCatReply),
           @"desc": @"Chitchat or answer — spoken text only, no side effect.",
           @"examples": @[ @"hello", @"thanks", @"what can you do" ] },
    ];
    #undef CAT
}

@end
