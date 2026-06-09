//
//  PBOllama.h — talks to the local Ollama server (127.0.0.1:11434): list the
//  installed models and download (pull) a new one with streamed progress. Pure
//  Foundation; the model manager UI uses this directly.
//
#import <Foundation/Foundation.h>

@interface PBOllama : NSObject

// Installed model tags (e.g. @"gemma4:12b"); serverUp == NO if Ollama isn't running. Main thread.
+ (void)listInstalled:(void (^)(NSArray<NSString *> *names, BOOL serverUp))done;

// Curated models for the download picker: @[ @{@"tag",@"name",@"size",@"note"} ].
+ (NSArray<NSDictionary *> *)curatedModels;

// Pull (download) a model, streaming progress (0..1 + status text) and a final
// done(ok, error). Hold the instance for the duration; call once. Main thread.
- (void)pull:(NSString *)tag
  onProgress:(void (^)(double fraction, NSString *status))progress
        done:(void (^)(BOOL ok, NSString *error))done;
- (void)cancel;
@end
