//
//  VoiceNotes.h — hands-free "side note" capture for Focus mode. Hold the note
//  tile, talk (walkie-talkie), release; the transcript is stored locally and you
//  keep working — no chat, no agent. Notes are appended to notes.jsonl and can
//  be exported as a CSV table.
//
#import <Foundation/Foundation.h>

@interface PBVoiceNotes : NSObject
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, copy) void (^onStateChange)(BOOL recording);   // UI feedback (tile turns red)

- (void)start;          // begin capture (requests Mic/Speech the first time)
- (void)stopAndSave;    // stop capture; append the transcript if non-empty

+ (NSString *)notesFile;          // ~/Library/Logs/PulseBar/notes.jsonl
+ (NSInteger)count;               // number of stored notes
+ (NSString *)exportCSV;          // write notes.csv (timestamp,note) from the jsonl; returns its path (or nil)
@end
