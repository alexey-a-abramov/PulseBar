//
//  VoiceNotes.m
//
#import "VoiceNotes.h"
#import "Log.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

@implementation PBVoiceNotes {
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    NSString *_text;
}

+ (NSString *)notesFile { return [PBLogDirectory() stringByAppendingPathComponent:@"notes.jsonl"]; }

- (void)setRecording:(BOOL)r { _recording = r; if (self.onStateChange) self.onStateChange(r); }

- (void)start {
    if (_recording) return;
    _text = @"";
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) { PBLog(@"side note: speech not authorized"); return; }
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!g) { PBLog(@"side note: mic not authorized"); return; }
                    [self beginCapture];
                });
            }];
        });
    }];
}

- (void)beginCapture {
    if (_recording) return;
    _recognizer = [[SFSpeechRecognizer alloc] init];
    if (!_recognizer || !_recognizer.isAvailable) { PBLog(@"side note: recognizer unavailable"); return; }
    _engine = [[AVAudioEngine alloc] init];
    _req = [[SFSpeechAudioBufferRecognitionRequest alloc] init]; _req.shouldReportPartialResults = YES;
    if (_recognizer.supportsOnDeviceRecognition) _req.requiresOnDeviceRecognition = YES;
    AVAudioInputNode *input = _engine.inputNode;
    SFSpeechAudioBufferRecognitionRequest *req = _req;
    [input installTapOnBus:0 bufferSize:1024 format:[input outputFormatForBus:0]
                     block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) { [req appendAudioPCMBuffer:buf]; }];
    [_engine prepare];
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) { PBLog(@"side note: audio failed: %@", err.localizedDescription); return; }
    [self setRecording:YES];
    __weak typeof(self) wself = self;
    _task = [_recognizer recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *result, NSError *e) {
        typeof(self) sself = wself; if (!sself) return;
        if (result) sself->_text = result.bestTranscription.formattedString;
    }];
}

- (void)stopAndSave {
    if (!_recording) { [self teardown]; return; }
    if (_engine) { [_engine stop]; [_engine.inputNode removeTapOnBus:0]; }
    [_req endAudio];
    NSString *txt = [(_text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self teardown];
    if (txt.length) {
        NSDictionary *note = @{ @"ts": @([[NSDate date] timeIntervalSince1970]), @"text": txt };
        NSData *d = [NSJSONSerialization dataWithJSONObject:note options:0 error:nil];
        NSString *path = [PBVoiceNotes notesFile];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh && d) { [fh seekToEndOfFile]; [fh writeData:d]; [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        PBLog(@"side note saved (%ld total): %@", (long)[PBVoiceNotes count], txt);
    } else {
        PBLog(@"side note: nothing captured");
    }
}

- (void)teardown {
    [_task cancel]; _task = nil; _req = nil; _engine = nil; _text = @"";
    if (_recording) [self setRecording:NO];
}

+ (NSInteger)count {
    NSString *s = [NSString stringWithContentsOfFile:[self notesFile] encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return 0;
    NSInteger n = 0;
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) if (line.length) n++;
    return n;
}

+ (NSString *)exportCSV {
    NSString *s = [NSString stringWithContentsOfFile:[self notesFile] encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return nil;
    static NSDateFormatter *df; if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss"; }
    NSMutableString *csv = [NSMutableString stringWithString:@"timestamp,note\n"];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) continue;
        NSString *when = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[j[@"ts"] doubleValue]]];
        NSString *text = [j[@"text"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];   // CSV-escape quotes
        [csv appendFormat:@"%@,\"%@\"\n", when, text ?: @""];
    }
    NSString *path = [PBLogDirectory() stringByAppendingPathComponent:@"notes.csv"];
    return [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] ? path : nil;
}

@end
