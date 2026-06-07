//
//  Agent.h — local LLM agent (Gemma via Ollama) with a lightweight JSON
//  tool-calling protocol that maps natural language to Mac actions.
//
#import <Foundation/Foundation.h>

// AppDelegate implements this to actually perform actions.
@protocol PBAgentRunner <NSObject>
- (NSString *)agentRunAction:(NSString *)action args:(NSDictionary *)args;  // returns a short result/confirmation
@end

@interface PBAgent : NSObject
@property (nonatomic, weak) id<PBAgentRunner> runner;
@property (nonatomic, copy) NSString *model;        // e.g. "gemma3:4b"
@property (nonatomic, copy) NSString *(^appResolver)(NSString *query);  // free text → canonical app name (for "open X")

// Ask the agent. `interpretation` is the parsed action (nil for plain replies),
// `reply` is the text to show the user. Always called on the main thread.
- (void)ask:(NSString *)text done:(void (^)(NSString *interpretation, NSString *reply))done;

// Forget the conversation history (start a fresh dialogue). The system prompt is
// rebuilt per call, so the next ask: begins clean.
- (void)resetSession;

// Check Ollama is up and the model is pulled.
+ (void)status:(NSString *)model done:(void (^)(BOOL serverUp, BOOL modelReady))done;
@end
