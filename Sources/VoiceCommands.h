//
//  VoiceCommands.h — deterministic intent parser + the closed command
//  vocabulary for PulseBar's voice agent.
//
//  Turns a spoken/typed phrase into ONE structured intent drawn from a FIXED,
//  SAFE action set. This is the fast, offline, reliable path; an LLM is only a
//  fallback for phrasings this can't match, and it is constrained to the SAME
//  vocabulary (see +promptVocabulary / +isKnownAction).
//
//  Pure logic — Foundation only, NO side effects, NO I/O, NO launching.
//
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PBCmdCategory) {
    PBCatControls,
    PBCatBar,
    PBCatSystem,
    PBCatQuery,
    PBCatApp,
    PBCatReply
};

/// One parsed intent. `action` is always a vocabulary name (see +isKnownAction),
/// `args` carries its typed arguments, `confidence` is 0..1.
@interface PBIntent : NSObject
@property (nonatomic) PBCmdCategory category;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, copy) NSDictionary *args;
@property (nonatomic) double confidence;   // 0..1
@end

@interface PBVoiceCommands : NSObject

// Deterministic parse. appResolver maps a free-text app query to a canonical app
// name (or nil if unknown) — used for "open <app>". Returns nil if nothing matches confidently.
+ (PBIntent *)parse:(NSString *)text appResolver:(NSString *(^)(NSString *query))appResolver;

+ (NSString *)promptVocabulary;             // closed action list (names+arg shapes+examples) for the LLM system prompt
+ (NSArray<NSDictionary *> *)catalog;        // [{@"action",@"category"(NSNumber),@"desc",@"examples"(NSArray)}] for UI/help
+ (BOOL)isKnownAction:(NSString *)action;    // reject out-of-vocabulary LLM output

@end
