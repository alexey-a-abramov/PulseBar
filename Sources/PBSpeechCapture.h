//
//  PBSpeechCapture.h — small reusable push-to-talk wrapper around
//  SFSpeechRecognizer + AVAudioEngine. Start on press, stop on release and get
//  the final transcript back. On-device when supported; no UI of its own.
//
#import <Foundation/Foundation.h>

@interface PBSpeechCapture : NSObject
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, copy) void (^onPartial)(NSString *text);   // live transcript (main thread)
@property (nonatomic, copy) void (^onError)(NSString *message);  // perms / audio failure (main thread)

- (void)start;                                  // request perms (first time) + begin
- (void)stop:(void (^)(NSString *finalText))done;  // stop + deliver the best transcript (trimmed; "" if none)
@end
