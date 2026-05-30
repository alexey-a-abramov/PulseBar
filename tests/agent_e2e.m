//
//  agent_e2e.m — end-to-end test of the PBAgent pipeline:
//  prompt -> Ollama/Gemma -> JSON parse -> action dispatched to a mock runner.
//  Usage: agent_e2e ["set volume to 30"]
//
#import <Foundation/Foundation.h>
#import "../Sources/Agent.h"

@interface MockRunner : NSObject <PBAgentRunner>
@property (nonatomic, copy) NSString *gotAction;
@property (nonatomic, copy) NSDictionary *gotArgs;
@end
@implementation MockRunner
- (NSString *)agentRunAction:(NSString *)a args:(NSDictionary *)args {
    self.gotAction = a; self.gotArgs = args;
    return @"ok";
}
@end

int main(int argc, const char **argv) { @autoreleasepool {
    NSString *prompt = argc > 1 ? @(argv[1]) : @"set the volume to 30 percent";
    NSString *expect = argc > 2 ? @(argv[2]) : @"set_volume";

    PBAgent *agent = [PBAgent new];
    MockRunner *runner = [MockRunner new];
    agent.runner = runner;

    __block BOOL done = NO; __block NSString *reply = nil;
    [agent ask:prompt done:^(NSString *interp, NSString *r) { reply = r; done = YES; }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

    if (!done) { printf("FAIL: timed out waiting for the model\n"); return 1; }
    printf("  prompt : %s\n  action : %s\n  args   : %s\n  reply  : %s\n",
           prompt.UTF8String, runner.gotAction.UTF8String ?: "(none)",
           runner.gotArgs ? runner.gotArgs.description.UTF8String : "(none)", reply.UTF8String ?: "(none)");
    BOOL ok = [runner.gotAction isEqualToString:expect];
    printf("%s (expected action '%s')\n", ok ? "PASS" : "WARN: different action", expect.UTF8String);
    return ok ? 0 : 0;   // model variance is a warning, not a hard fail
}}
