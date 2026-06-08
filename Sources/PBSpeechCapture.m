//
//  PBSpeechCapture.m
//
#import "PBSpeechCapture.h"
#import "Log.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

@implementation PBSpeechCapture {
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    NSString *_text;
}

- (void)fail:(NSString *)msg { PBLog(@"speech: %@", msg); if (self.onError) self.onError(msg); }

- (void)start {
    if (_recording) return;
    _text = @"";
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) { [self fail:@"Allow Speech Recognition in Privacy settings"]; return; }
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!g) { [self fail:@"Allow Microphone in Privacy settings"]; return; }
                    [self begin];
                });
            }];
        });
    }];
}

- (void)begin {
    if (_recording) return;
    _recognizer = [[SFSpeechRecognizer alloc] init];
    if (!_recognizer || !_recognizer.isAvailable) { [self fail:@"Speech recognizer unavailable"]; return; }
    _engine = [[AVAudioEngine alloc] init];
    _req = [[SFSpeechAudioBufferRecognitionRequest alloc] init]; _req.shouldReportPartialResults = YES;
    if (_recognizer.supportsOnDeviceRecognition) _req.requiresOnDeviceRecognition = YES;
    AVAudioInputNode *input = _engine.inputNode;
    SFSpeechAudioBufferRecognitionRequest *req = _req;
    [input installTapOnBus:0 bufferSize:1024 format:[input outputFormatForBus:0]
                     block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) { [req appendAudioPCMBuffer:buf]; }];
    [_engine prepare];
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) { [self fail:err.localizedDescription ?: @"audio failed"]; [self teardown]; return; }
    _recording = YES;
    __weak typeof(self) ws = self;
    _task = [_recognizer recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *result, NSError *e) {
        typeof(self) s = ws; if (!s) return;
        if (result) { s->_text = result.bestTranscription.formattedString;
            if (s.onPartial) s.onPartial(s->_text); }
    }];
}

- (void)stop:(void (^)(NSString *))done {
    NSString *t = [(_text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self teardown];
    if (done) done(t);
}

- (void)teardown {
    if (_engine) { [_engine stop]; [_engine.inputNode removeTapOnBus:0]; }
    [_req endAudio]; [_task cancel];
    _engine = nil; _req = nil; _task = nil; _recording = NO;
}

@end
