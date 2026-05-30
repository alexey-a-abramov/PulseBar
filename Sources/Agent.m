//
//  Agent.m
//
#import "Agent.h"
#import "Log.h"

static NSString *const kOllama = @"http://127.0.0.1:11434";

static NSString *const kSystemPrompt =
@"You are PulseBar, a Mac assistant that controls the system. For EVERY user message reply with ONE JSON object and NOTHING else (no markdown, no code fences):\n"
@"{\"action\":\"<name>\",\"args\":{...},\"say\":\"<short sentence>\"}\n"
@"Allowed actions and the EXACT arg shape:\n"
@"  set_volume {\"percent\":30}\n"
@"  set_brightness {\"percent\":70}\n"
@"  open_app {\"name\":\"Safari\"}\n"
@"  media {\"cmd\":\"playpause\"}   (cmd is playpause, next, or prev)\n"
@"  lock {}\n  sleep_display {}\n  dark_mode {}\n  mission_control {}\n"
@"  run_shortcut {\"name\":\"X\"}\n"
@"  reply {}   (for questions/chitchat — put the answer in \"say\")\n"
@"Use these EXACT action names. Keep \"say\" under 14 words.";

@implementation PBAgent {
    NSMutableArray<NSDictionary *> *_history;
}

- (instancetype)init {
    if ((self = [super init])) { _history = [NSMutableArray array]; _model = @"gemma3:4b"; }
    return self;
}

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

- (void)ask:(NSString *)text done:(void (^)(NSString *, NSString *))done {
    [_history addObject:@{ @"role": @"user", @"content": text }];

    NSMutableArray *messages = [NSMutableArray arrayWithObject:@{ @"role": @"system", @"content": kSystemPrompt }];
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
        NSString *interp = nil, *reply = nil;
        if (err || !data) {
            reply = [NSString stringWithFormat:@"(agent offline: %@)", err.localizedDescription ?: @"no response"];
        } else {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *content = j[@"message"][@"content"] ?: @"";
            [self2->_history addObject:@{ @"role": @"assistant", @"content": content }];
            NSDictionary *act = extractJSON(content);
            NSString *action = act[@"action"];
            NSDictionary *args = [act[@"args"] isKindOfClass:NSDictionary.class] ? act[@"args"] : @{};
            NSString *say = act[@"say"];
            if (!say.length && [act[@"args"] isKindOfClass:NSDictionary.class]) say = act[@"args"][@"say"];   // reply puts it in args
            reply = say.length ? say : (content.length ? content : @"(no reply)");
            if (action.length && ![action isEqualToString:@"reply"]) {
                NSString *res = self2.runner ? [self2.runner agentRunAction:action args:args] : nil;
                interp = [NSString stringWithFormat:@"⚙ %@ %@", action, args.count ? args : @""];
                if (res.length) reply = res;
            }
            PBLog(@"agent: '%@' -> %@", text, interp ?: reply);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(interp, reply); });
    }] resume];
}

@end
