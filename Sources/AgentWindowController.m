//
//  AgentWindowController.m
//
#import "AgentWindowController.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

@interface AgentWindowController () <NSTextFieldDelegate>
@end

@implementation AgentWindowController {
    PBAgent     *_agent;
    NSTextView  *_transcript;
    NSTextField *_input;
    NSTextField *_status;
    NSButton    *_send;
    NSButton    *_mic;
    BOOL         _busy;
    // voice
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    BOOL          _listening;
}

- (instancetype)initWithAgent:(PBAgent *)agent {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 540)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"PulseBar Agent";
    w.releasedWhenClosed = NO;
    w.level = NSFloatingWindowLevel;   // accessory app: keep it above other windows
    w.minSize = NSMakeSize(380, 360);
    if ((self = [super initWithWindow:w])) { _agent = agent; [self build]; }
    return self;
}

- (void)build {
    NSView *c = self.window.contentView;
    CGFloat W = 480, H = 540;

    _status = [NSTextField labelWithString:@"Gemma 3 4B — checking…"];
    _status.frame = NSMakeRect(16, H - 30, W - 32, 18);
    _status.font = [NSFont systemFontOfSize:11];
    _status.textColor = [NSColor secondaryLabelColor];
    _status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [c addSubview:_status];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 54, W - 24, H - 54 - 36)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSNoBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.drawsBackground = NO;
    _transcript = [[NSTextView alloc] initWithFrame:scroll.bounds];
    _transcript.editable = NO; _transcript.drawsBackground = NO;
    _transcript.textContainerInset = NSMakeSize(6, 8);
    _transcript.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = _transcript;
    [c addSubview:scroll];

    _input = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 12, W - 24 - 76 - 36, 28)];
    _input.placeholderString = @"Ask or command… (or tap 🎙 to speak)";
    _input.delegate = self;
    _input.bezelStyle = NSTextFieldRoundedBezel;
    _input.font = [NSFont systemFontOfSize:13];
    _input.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [c addSubview:_input];

    _mic = [NSButton buttonWithTitle:@"🎙" target:self action:@selector(toggleMic:)];
    _mic.frame = NSMakeRect(W - 12 - 70 - 36, 11, 32, 30);
    _mic.bezelStyle = NSBezelStyleRounded;
    _mic.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [c addSubview:_mic];

    _send = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
    _send.frame = NSMakeRect(W - 12 - 70, 11, 70, 30);
    _send.bezelStyle = NSBezelStyleRounded; _send.keyEquivalent = @"\r";
    _send.bezelColor = [NSColor systemBlueColor];
    _send.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [c addSubview:_send];

    [self appendRole:@"PulseBar" text:@"Hi! Tell me what to do — e.g. “mute”, “brightness 80”, “play music”, or ask a question." color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
}

- (void)present {
    [self refreshStatus];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_input];
}

- (void)refreshStatus {
    [PBAgent status:_agent.model done:^(BOOL up, BOOL ready) {
        if (!up)        { self->_status.stringValue = @"⚠︎ Ollama not running — start it to use the agent"; self->_status.textColor = [NSColor systemOrangeColor]; }
        else if (!ready){ self->_status.stringValue = @"⬇︎ Gemma 3 4B is still downloading…"; self->_status.textColor = [NSColor systemOrangeColor]; }
        else            { self->_status.stringValue = @"● Gemma 3 4B — ready (local, on-device)"; self->_status.textColor = [NSColor systemGreenColor]; }
    }];
}

- (void)appendRole:(NSString *)who text:(NSString *)text color:(NSColor *)color align:(NSTextAlignment)align {
    NSTextStorage *ts = _transcript.textStorage;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = align; ps.lineSpacing = 2; ps.paragraphSpacingBefore = 5; ps.paragraphSpacing = 11;
    if (align == NSTextAlignmentRight) ps.headIndent = 90; else ps.tailIndent = -90;   // gutter on the far side → chat feel
    [ts beginEditing];
    NSDictionary *nameAttr = @{ NSFontAttributeName:[NSFont boldSystemFontOfSize:10.5], NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:ps };
    NSDictionary *bodyAttr = @{ NSFontAttributeName:[NSFont systemFontOfSize:13], NSForegroundColorAttributeName:[NSColor labelColor], NSParagraphStyleAttributeName:ps };
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", who.uppercaseString] attributes:nameAttr]];
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", text] attributes:bodyAttr]];
    [ts endEditing];
    [_transcript scrollRangeToVisible:NSMakeRange(ts.length, 0)];
}

- (void)send:(id)sender {
    NSString *text = [_input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || _busy) return;
    _input.stringValue = @"";
    [self appendRole:@"You" text:text color:[NSColor systemBlueColor] align:NSTextAlignmentRight];
    _busy = YES; _send.enabled = NO; _status.stringValue = @"…thinking";
    [_agent ask:text done:^(NSString *interp, NSString *reply) {
        if (interp.length) [self appendRole:@"Action" text:interp color:[NSColor systemTealColor] align:NSTextAlignmentLeft];
        [self appendRole:@"PulseBar" text:reply ?: @"(no reply)" color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
        self->_busy = NO; self->_send.enabled = YES;
        [self refreshStatus];
    }];
}

// Enter in the text field sends.
- (void)controlTextDidEndEditing:(NSNotification *)n {
    NSNumber *reason = n.userInfo[@"NSTextMovement"];
    if (reason.integerValue == NSReturnTextMovement) [self send:nil];
}

#pragma mark - voice (on-device speech → text → agent)

- (void)toggleMic:(id)s {
    if (_listening) { [self stopListening]; if (_input.stringValue.length) [self send:nil]; }
    else            { [self startListening]; }
}

- (void)startListening {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                self->_status.stringValue = @"⚠︎ Allow Speech Recognition in System Settings → Privacy"; return;
            }
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { self->_status.stringValue = @"⚠︎ Allow Microphone in System Settings → Privacy"; return; }
                    [self beginCapture];
                });
            }];
        });
    }];
}

- (void)beginCapture {
    _recognizer = [[SFSpeechRecognizer alloc] init];
    if (!_recognizer || !_recognizer.isAvailable) { _status.stringValue = @"⚠︎ Speech recognizer unavailable"; return; }
    _engine = [[AVAudioEngine alloc] init];
    _req = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    _req.shouldReportPartialResults = YES;
    if (_recognizer.supportsOnDeviceRecognition) _req.requiresOnDeviceRecognition = YES;   // private, offline

    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    SFSpeechAudioBufferRecognitionRequest *req = _req;   // capture the request, not self
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [req appendAudioPCMBuffer:buf];
    }];
    [_engine prepare];
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) { _status.stringValue = [NSString stringWithFormat:@"⚠︎ audio: %@", err.localizedDescription]; [self stopListening]; return; }

    _listening = YES; _mic.title = @"◉"; _input.stringValue = @"";
    _status.stringValue = @"🎙 Listening… (tap 🎙 again to send)";
    _task = [_recognizer recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (result) {
            self->_input.stringValue = result.bestTranscription.formattedString;
            if (result.isFinal) { NSString *t = self->_input.stringValue; [self stopListening]; if (t.length) [self send:nil]; }
        }
        if (error) [self stopListening];
    }];
}

- (void)stopListening {
    if (_engine) { [_engine stop]; [_engine.inputNode removeTapOnBus:0]; }
    [_req endAudio]; [_task cancel];
    _engine = nil; _req = nil; _task = nil; _listening = NO;
    _mic.title = @"🎙";
    if ([_status.stringValue hasPrefix:@"🎙"]) [self refreshStatus];
}

@end
