//
//  Agent.m
//
#import "Agent.h"
#import "Log.h"
#import "VoiceCommands.h"

static NSString *const kOllama = @"http://127.0.0.1:11434";

// The system prompt is generated from the single source of truth (the command
// registry) so the model's vocabulary can never drift from what we dispatch.
static NSString *systemPrompt(void) {
    return [NSString stringWithFormat:
        @"You are PulseBar, a Mac assistant that controls safe system settings and the PulseBar Touch Bar itself. "
        @"For EVERY user message reply with ONE JSON object and NOTHING else (no markdown, no code fences):\n"
        @"{\"action\":\"<name>\",\"args\":{...},\"say\":\"<short sentence>\"}\n\n%@\n\n"
        @"Use ONLY these exact action names. If asked for anything else — especially anything destructive "
        @"(quitting or deleting apps, sending messages, shutting down) — DO NOT invent an action; use reply and "
        @"politely decline. Keep \"say\" under 14 words.",
        [PBVoiceCommands promptVocabulary]];
}

@implementation PBAgent {
    NSMutableArray<NSDictionary *> *_history;
}

- (instancetype)init {
    if ((self = [super init])) { _history = [NSMutableArray array]; _model = @"gemma3:4b"; }
    return self;
}

- (void)resetSession { [_history removeAllObjects]; }

+ (void)status:(NSString *)model done:(void (^)(BOOL, BOOL))done {
    NSURL *u = [NSURL URLWithString:[kOllama stringByAppendingString:@"/api/tags"]];
    NSURLRequest *r = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        BOOL up = (e == nil && d != nil), ready = NO;
        if (up) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            for (NSDictionary *m in j[@"models"]) {
                NSString *n = m[@"name"] ?: @"";
                if ([n isEqualToString:model] || [n hasPrefix:[model stringByAppendingString:@":"]] ||
                    [[n componentsSeparatedByString:@":"].firstObject isEqualToString:[model componentsSeparatedByString:@":"].firstObject]) ready = YES;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(up, ready); });
    }] resume];
}

// Extract the first balanced {...} JSON object from arbitrary model text.
static NSDictionary *extractJSON(NSString *s) {
    NSInteger start = [s rangeOfString:@"{"].location;
    if (start == NSNotFound) return nil;
    NSInteger depth = 0;
    for (NSInteger i = start; i < (NSInteger)s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth == 0) {
            NSString *sub = [s substringWithRange:NSMakeRange(start, i - start + 1)];
            NSData *d = [sub dataUsingEncoding:NSUTF8StringEncoding];
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            return [j isKindOfClass:NSDictionary.class] ? j : nil;
        } }
    }
    return nil;
}

static NSString *cleanText(NSString *s) {   // strip code fences / stray JSON braces for display
    NSString *t = [s stringByReplacingOccurrencesOfString:@"```json" withString:@""];
    t = [[t stringByReplacingOccurrencesOfString:@"```" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length ? t : @"(no reply)";
}
static NSString *humanArgs(NSDictionary *args) {   // {"percent":25} -> " · percent 25"
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in args) { if ([k isEqualToString:@"say"]) continue; [parts addObject:[NSString stringWithFormat:@"%@ %@", k, args[k]]]; }
    return parts.count ? [@" · " stringByAppendingString:[parts componentsJoinedByString:@", "]] : @"";
}

- (void)ask:(NSString *)text done:(void (^)(NSString *, NSString *))done {
    [_history addObject:@{ @"role": @"user", @"content": text }];

    // Fast path: a confident deterministic match runs instantly and offline,
    // bypassing the model entirely. The model is only the fallback.
    PBIntent *intent = [PBVoiceCommands parse:text appResolver:self.appResolver];
    if (intent && intent.confidence >= 0.8) {
        NSString *res = self.runner ? [self.runner agentRunAction:intent.action args:intent.args] : nil;
        BOOL silent = (intent.category == PBCatQuery || intent.category == PBCatReply);
        NSString *interp = silent ? nil : [NSString stringWithFormat:@"⚙ %@%@", intent.action, humanArgs(intent.args)];
        NSString *reply = res.length ? res : @"Done.";
        [_history addObject:@{ @"role": @"assistant", @"content": reply }];
        PBLog(@"agent(fast): '%@' -> %@", text, interp ?: reply);
        PBLogConversation(text, @"(fast-path)", intent.action, reply);
        dispatch_async(dispatch_get_main_queue(), ^{ done(interp, reply); });
        return;
    }

    NSMutableArray *messages = [NSMutableArray arrayWithObject:@{ @"role": @"system", @"content": systemPrompt() }];
    [messages addObjectsFromArray:_history];
    NSDictionary *body = @{ @"model": self.model ?: @"gemma3:4b", @"messages": messages,
                            @"stream": @NO, @"options": @{ @"temperature": @0.2 } };

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kOllama stringByAppendingString:@"/api/chat"]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 60;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    __weak PBAgent *ws = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        PBAgent *self2 = ws; if (!self2) return;
        NSString *interp = nil, *reply = nil, *content = @"", *action = nil;
        if (err || !data) {
            reply = [NSString stringWithFormat:@"(agent offline: %@)", err.localizedDescription ?: @"no response"];
        } else {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            content = j[@"message"][@"content"] ?: @"";
            [self2->_history addObject:@{ @"role": @"assistant", @"content": content }];
            NSDictionary *act = extractJSON(content);
            action = act[@"action"];
            NSDictionary *args = [act[@"args"] isKindOfClass:NSDictionary.class] ? act[@"args"] : @{};
            NSString *say = act[@"say"]; if (!say.length) say = args[@"say"];   // reply puts it in args
            reply = say.length ? say : cleanText(content);                      // never show raw JSON
            BOOL actionable = action.length && ![action isEqualToString:@"reply"];
            if (actionable && ![PBVoiceCommands isKnownAction:action]) {
                // Model invented an action outside the vetted vocabulary — refuse safely.
                reply = say.length ? say : @"Sorry, I can't do that.";
                action = @"reply";
            } else if (actionable) {
                NSString *res = self2.runner ? [self2.runner agentRunAction:action args:args] : nil;
                interp = [NSString stringWithFormat:@"⚙ %@%@", action, humanArgs(args)];
                if (res.length) reply = res;
            }
        }
        PBLog(@"agent: '%@' -> %@", text, interp ?: reply);
        PBLogConversation(text, content, action, reply);   // save the turn for analysis
        dispatch_async(dispatch_get_main_queue(), ^{ done(interp, reply); });
    }] resume];
}

@end
