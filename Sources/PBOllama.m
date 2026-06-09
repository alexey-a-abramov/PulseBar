//
//  PBOllama.m
//
#import "PBOllama.h"
#import "Log.h"

static NSString *const kBase = @"http://127.0.0.1:11434";

@interface PBOllama () <NSURLSessionDataDelegate>
@end

@implementation PBOllama {
    NSURLSession         *_session;
    NSURLSessionDataTask *_task;
    NSMutableData        *_buf;
    void (^_progress)(double, NSString *);
    void (^_done)(BOOL, NSString *);
    double                _lastFrac;
    BOOL                  _finished;
}

+ (void)listInstalled:(void (^)(NSArray<NSString *> *, BOOL))done {
    NSURL *u = [NSURL URLWithString:[kBase stringByAppendingString:@"/api/tags"]];
    NSURLRequest *r = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSMutableArray *names = [NSMutableArray array]; BOOL up = (e == nil && d != nil);
        if (up) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            for (NSDictionary *m in j[@"models"]) { NSString *n = m[@"name"]; if (n.length) [names addObject:n]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(names, up); });
    }] resume];
}

+ (NSArray<NSDictionary *> *)curatedModels {
    return @[
        @{ @"tag": @"gemma4:12b", @"name": @"Gemma 4 · 12B", @"size": @"7.6 GB", @"note": @"recommended" },
        @{ @"tag": @"gemma4:e4b", @"name": @"Gemma 4 · E4B", @"size": @"9.6 GB", @"note": @"larger" },
        @{ @"tag": @"gemma4:e2b", @"name": @"Gemma 4 · E2B", @"size": @"7.2 GB", @"note": @"edge" },
        @{ @"tag": @"gemma4:26b", @"name": @"Gemma 4 · 26B", @"size": @"18 GB",  @"note": @"big" },
        @{ @"tag": @"gemma3:4b",  @"name": @"Gemma 3 · 4B",  @"size": @"3.3 GB", @"note": @"small & fast" },
        @{ @"tag": @"gemma3:12b", @"name": @"Gemma 3 · 12B", @"size": @"8.1 GB", @"note": @"" },
    ];
}

- (void)pull:(NSString *)tag onProgress:(void (^)(double, NSString *))progress done:(void (^)(BOOL, NSString *))done {
    _progress = [progress copy]; _done = [done copy];
    _buf = [NSMutableData data]; _lastFrac = 0; _finished = NO;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kBase stringByAppendingString:@"/api/pull"]]];
    req.HTTPMethod = @"POST"; [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"name": tag, @"stream": @YES } options:0 error:nil];
    req.timeoutInterval = 3600;
    _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                             delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    _task = [_session dataTaskWithRequest:req]; [_task resume];
}

// Stream is newline-delimited JSON: {"status":"...","total":N,"completed":M} … {"status":"success"}.
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    [_buf appendData:data];
    NSData *nl = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (1) {
        NSRange r = [_buf rangeOfData:nl options:0 range:NSMakeRange(0, _buf.length)];
        if (r.location == NSNotFound) break;
        NSData *line = [_buf subdataWithRange:NSMakeRange(0, r.location)];
        [_buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
        if (!line.length) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) continue;
        if (j[@"error"]) { [self finish:NO error:j[@"error"]]; return; }
        NSString *status = j[@"status"] ?: @"";
        double total = [j[@"total"] doubleValue], completed = [j[@"completed"] doubleValue];
        double frac = total > 0 ? completed / total : _lastFrac;
        if (frac > _lastFrac) _lastFrac = frac;
        if (_progress) _progress(_lastFrac, status);
        if ([status isEqualToString:@"success"]) { [self finish:YES error:nil]; return; }
    }
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (!_finished) [self finish:(error == nil) error:error.localizedDescription];
}

- (void)finish:(BOOL)ok error:(NSString *)err {
    if (_finished) return; _finished = YES;
    void (^d)(BOOL, NSString *) = _done; _done = nil; _progress = nil;
    [_session finishTasksAndInvalidate]; _task = nil; _session = nil;
    PBLog(@"ollama pull %@%@", ok ? @"complete" : @"failed", err.length ? [@": " stringByAppendingString:err] : @"");
    if (d) d(ok, err);
}
- (void)cancel {
    if (_finished) return; _finished = YES;
    _progress = nil; _done = nil;
    [_task cancel]; [_session invalidateAndCancel]; _task = nil; _session = nil;
}

@end
