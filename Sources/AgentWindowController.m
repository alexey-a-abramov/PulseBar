//
//  AgentWindowController.m — compact, polished chat window for the agent.
//
#import "AgentWindowController.h"
#import "Log.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

// --------------------------------------------------------------------------
// Gradient "orb" (matches the Touch Bar agent button)
// --------------------------------------------------------------------------
@interface OrbView : NSView @end
@implementation OrbView
- (void)drawRect:(NSRect)r {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    NSGradient *g = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.38 green:0.42 blue:0.99 alpha:1],
        [NSColor colorWithSRGBRed:0.78 green:0.36 blue:0.98 alpha:1],
        [NSColor colorWithSRGBRed:0.99 green:0.38 blue:0.62 alpha:1]]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:b] angle:45];
    NSImage *s = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:nil];
    s = [s imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold]];
    if (@available(macOS 12.0, *)) s = [s imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor whiteColor]]];
    NSSize sz = s.size;
    [s drawInRect:NSMakeRect(NSMidX(b) - sz.width / 2, NSMidY(b) - sz.height / 2, sz.width, sz.height)];
}
@end

// --------------------------------------------------------------------------
// Bubble chat transcript (custom-drawn rounded bubbles)
// --------------------------------------------------------------------------
@interface BubbleView : NSView
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *msgs;   // role,text,color,align
- (void)addRole:(NSString *)role text:(NSString *)text color:(NSColor *)color align:(NSTextAlignment)align;
- (void)removeAll;
- (CGFloat)layoutInto:(NSMutableArray *)rects width:(CGFloat)W;       // returns total height
@end

@implementation BubbleView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)f { if ((self = [super initWithFrame:f])) _msgs = [NSMutableArray array]; return self; }

- (NSFont *)bodyFont { return [NSFont systemFontOfSize:13]; }

- (CGFloat)layoutInto:(NSMutableArray *)rects width:(CGFloat)W {
    CGFloat pad = 9, maxBubble = W * 0.74, y = 12;
    for (NSDictionary *m in _msgs) {
        NSTextAlignment al = [m[@"align"] integerValue];
        NSRect tr = [m[@"text"] boundingRectWithSize:NSMakeSize(maxBubble - pad * 2, 9999)
                                              options:NSStringDrawingUsesLineFragmentOrigin
                                           attributes:@{ NSFontAttributeName: self.bodyFont }];
        CGFloat bw = ceil(tr.size.width) + pad * 2, bh = ceil(tr.size.height) + pad * 1.4 + 13;  // +13 for role label
        if (bw > maxBubble) bw = maxBubble;
        CGFloat x = (al == NSTextAlignmentRight) ? (W - bw - 12) : 12;
        if (al == NSTextAlignmentCenter) x = (W - bw) / 2;
        if (rects) [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, bw, bh)]];
        y += bh + 8;
    }
    return y + 4;
}

- (void)removeAll {
    [_msgs removeAllObjects];
    NSRect f = self.frame; f.size.height = NSHeight(self.superview.bounds); self.frame = f;
    [self setNeedsDisplay:YES];
}

- (void)addRole:(NSString *)role text:(NSString *)text color:(NSColor *)color align:(NSTextAlignment)align {
    [_msgs addObject:@{ @"role": role, @"text": text ?: @"", @"color": color, @"align": @(align) }];
    CGFloat h = [self layoutInto:nil width:NSWidth(self.bounds)];
    NSRect f = self.frame; f.size.height = MAX(h, NSHeight(self.superview.bounds)); self.frame = f;
    [self setNeedsDisplay:YES];
    [self scrollPoint:NSMakePoint(0, NSMaxY(self.bounds))];
}

- (void)drawRect:(NSRect)dirty {
  @try {
    NSMutableArray *rects = [NSMutableArray array];
    [self layoutInto:rects width:NSWidth(self.bounds)];
    for (NSUInteger i = 0; i < _msgs.count && i < rects.count; i++) {
        NSDictionary *m = _msgs[i]; NSRect r = [rects[i] rectValue];
        NSColor *col = m[@"color"]; NSTextAlignment al = [m[@"align"] integerValue];
        BOOL right = (al == NSTextAlignmentRight);
        // bubble
        NSColor *bg = right ? [[self acc] colorWithAlphaComponent:0.22]
                            : (al == NSTextAlignmentCenter ? [NSColor colorWithCalibratedWhite:1 alpha:0.05]
                                                           : [NSColor colorWithCalibratedWhite:1 alpha:0.09]);
        [bg setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:11 yRadius:11] fill];
        // role label
        [m[@"role"] drawAtPoint:NSMakePoint(r.origin.x + 10, r.origin.y + 5)
                 withAttributes:@{ NSFontAttributeName:[NSFont boldSystemFontOfSize:9], NSForegroundColorAttributeName:col }];
        // body
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = (al == NSTextAlignmentCenter) ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        [m[@"text"] drawInRect:NSMakeRect(r.origin.x + 9, r.origin.y + 17, r.size.width - 18, r.size.height - 20)
                withAttributes:@{ NSFontAttributeName:self.bodyFont, NSForegroundColorAttributeName:[NSColor labelColor], NSParagraphStyleAttributeName:ps }];
    }
  } @catch (NSException *e) { PBLog(@"BubbleView drawRect exception: %@ — %@", e.name, e.reason); }
}
- (NSColor *)acc { return [NSColor colorWithSRGBRed:0.36 green:0.55 blue:0.98 alpha:1]; }
@end

// --------------------------------------------------------------------------
@interface AgentWindowController () <NSTextFieldDelegate, NSWindowDelegate>
@end

static NSString *kAgentGreeting = @"Hey! Tell me what to do — “mute”, “brightness 80”, “play music” — or ask a question. Tap 🎙 to talk.";

@implementation AgentWindowController {
    PBAgent     *_agent;
    BubbleView  *_bubbles;
    NSScrollView *_scroll;
    NSTextField *_input;
    NSTextField *_status;
    NSButton    *_send, *_mic;
    BOOL         _busy;
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_req;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    BOOL          _listening;
}

- (instancetype)initWithAgent:(PBAgent *)agent {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 460)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"PulseBar Agent";
    w.titleVisibility = NSWindowTitleHidden;
    w.titlebarAppearsTransparent = YES;
    w.releasedWhenClosed = NO;
    w.level = NSFloatingWindowLevel;
    w.minSize = NSMakeSize(360, 320);
    w.backgroundColor = [NSColor colorWithCalibratedWhite:0.11 alpha:1.0];
    if ((self = [super initWithWindow:w])) { _agent = agent; w.delegate = self; [self build]; }
    return self;
}

- (void)build {
    NSView *c = self.window.contentView;
    CGFloat W = 440, H = 460;

    // header
    OrbView *orb = [[OrbView alloc] initWithFrame:NSMakeRect(16, H - 40, 26, 26)];
    orb.autoresizingMask = NSViewMinYMargin; [c addSubview:orb];
    NSTextField *title = [NSTextField labelWithString:@"PulseBar"];
    title.frame = NSMakeRect(50, H - 34, 200, 20); title.font = [NSFont boldSystemFontOfSize:15];
    title.autoresizingMask = NSViewMinYMargin; [c addSubview:title];
    _status = [NSTextField labelWithString:@"checking…"];
    _status.frame = NSMakeRect(50, H - 50, W - 60, 14); _status.font = [NSFont systemFontOfSize:10];
    _status.textColor = [NSColor secondaryLabelColor]; _status.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable; [c addSubview:_status];

    // transcript
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 86, W - 16, H - 86 - 58)];
    _scroll.hasVerticalScroller = YES; _scroll.borderType = NSNoBorder; _scroll.drawsBackground = NO;
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _bubbles = [[BubbleView alloc] initWithFrame:_scroll.contentView.bounds];
    _bubbles.autoresizingMask = NSViewWidthSizable;
    _scroll.documentView = _bubbles;
    [c addSubview:_scroll];

    // quick-suggestion chips
    NSArray *chips = @[@"what's my battery", @"focus mode", @"volume 30", @"open Safari"];
    CGFloat cx = 10;
    for (NSString *chip in chips) {
        NSButton *b = [NSButton buttonWithTitle:chip target:self action:@selector(chipTapped:)];
        b.bezelStyle = NSBezelStyleRounded; b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:10]; [b sizeToFit];
        NSRect bf = b.frame; bf.origin = NSMakePoint(cx, 54); bf.size.height = 20; b.frame = bf;
        b.autoresizingMask = NSViewMaxYMargin; [c addSubview:b];
        cx += bf.size.width + 6;
    }

    // input row
    _input = [[NSTextField alloc] initWithFrame:NSMakeRect(14, 12, W - 14 - 78, 30)];
    _input.placeholderString = @"Ask or command…  (or tap 🎙)";
    _input.delegate = self; _input.bezelStyle = NSTextFieldRoundedBezel; _input.font = [NSFont systemFontOfSize:13];
    _input.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin; [c addSubview:_input];

    _mic = [self iconButton:@"mic.fill" action:@selector(toggleMic:) frame:NSMakeRect(W - 72, 11, 30, 30)];
    [c addSubview:_mic];
    _send = [self iconButton:@"paperplane.fill" action:@selector(send:) frame:NSMakeRect(W - 38, 11, 30, 30)];
    _send.keyEquivalent = @"\r"; [c addSubview:_send];

    [_bubbles addRole:@"PULSEBAR" text:kAgentGreeting color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
}

- (NSButton *)iconButton:(NSString *)symbol action:(SEL)action frame:(NSRect)f {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [NSImage new] target:self action:action];
    b.frame = f; b.bezelStyle = NSBezelStyleRegularSquare; b.bordered = NO;
    b.contentTintColor = [NSColor controlAccentColor];
    b.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    return b;
}

- (void)present {
    [self refreshStatus];
    [NSApp activateIgnoringOtherApps:YES];
    if (!self.window.isVisible) [self.window center];   // don't yank a window the user moved / re-presented
    [self showWindow:nil]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:_input];
}

- (void)clearTranscript {
    [_bubbles removeAll];
    [_bubbles addRole:@"PULSEBAR" text:kAgentGreeting color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
}

- (void)showTurnUser:(NSString *)user action:(NSString *)interp reply:(NSString *)reply {
    [self present];
    if (user.length)  [_bubbles addRole:@"YOU" text:user color:[NSColor systemBlueColor] align:NSTextAlignmentRight];
    if (interp.length)[_bubbles addRole:@"ACTION" text:interp color:[NSColor systemTealColor] align:NSTextAlignmentCenter];
    [_bubbles addRole:@"PULSEBAR" text:reply ?: @"(no reply)" color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
}

- (void)windowWillClose:(NSNotification *)n {
    if (_listening) [self stopListening];
    if (self.onWindowClosed) self.onWindowClosed();
}

- (BOOL)listening { return _listening; }
- (void)presentAndListen { [self present]; [self startListening]; }
- (void)stopAndSend {
    [self stopListening];
    if ([_input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) [self send:nil];
}

- (void)refreshStatus {
    [PBAgent status:_agent.model done:^(BOOL up, BOOL ready) {
        if (!up)         { self->_status.stringValue = @"⚠︎ Ollama not running"; self->_status.textColor = [NSColor systemOrangeColor]; }
        else if (!ready) { self->_status.stringValue = @"⬇︎ Gemma 3 4B downloading…"; self->_status.textColor = [NSColor systemOrangeColor]; }
        else             { self->_status.stringValue = @"● Gemma 3 4B · on-device"; self->_status.textColor = [NSColor systemGreenColor]; }
    }];
}

- (void)chipTapped:(NSButton *)b { _input.stringValue = b.title; [self send:nil]; }

- (void)send:(id)sender {
    NSString *text = [_input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || _busy) return;
    _input.stringValue = @"";
    [_bubbles addRole:@"YOU" text:text color:[NSColor systemBlueColor] align:NSTextAlignmentRight];
    _busy = YES; _send.enabled = NO; _status.stringValue = @"…thinking";
    [_agent ask:text done:^(NSString *interp, NSString *reply) {
        if (interp.length) [self->_bubbles addRole:@"ACTION" text:interp color:[NSColor systemTealColor] align:NSTextAlignmentCenter];
        [self->_bubbles addRole:@"PULSEBAR" text:reply ?: @"(no reply)" color:[NSColor systemPurpleColor] align:NSTextAlignmentLeft];
        self->_busy = NO; self->_send.enabled = YES;
        [self refreshStatus];
        if (self->_onTurnComplete) self->_onTurnComplete(interp.length > 0);   // actionRan → coordinator may auto-close
    }];
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if ([n.userInfo[@"NSTextMovement"] integerValue] == NSReturnTextMovement) [self send:nil];
}

#pragma mark - voice

- (void)toggleMic:(id)s {
    if (_listening) { [self stopListening]; if (_input.stringValue.length) [self send:nil]; }
    else            { [self startListening]; }
}
- (void)startListening {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) { self->_status.stringValue = @"⚠︎ Allow Speech Recognition in Privacy settings"; return; }
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!g) { self->_status.stringValue = @"⚠︎ Allow Microphone in Privacy settings"; return; }
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
    _req = [[SFSpeechAudioBufferRecognitionRequest alloc] init]; _req.shouldReportPartialResults = YES;
    if (_recognizer.supportsOnDeviceRecognition) _req.requiresOnDeviceRecognition = YES;
    AVAudioInputNode *input = _engine.inputNode;
    SFSpeechAudioBufferRecognitionRequest *req = _req;
    [input installTapOnBus:0 bufferSize:1024 format:[input outputFormatForBus:0] block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) { [req appendAudioPCMBuffer:buf]; }];
    [_engine prepare];
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) { _status.stringValue = [NSString stringWithFormat:@"⚠︎ audio: %@", err.localizedDescription]; [self stopListening]; return; }
    _listening = YES; _mic.contentTintColor = [NSColor systemRedColor];
    _mic.image = [NSImage imageWithSystemSymbolName:@"stop.circle.fill" accessibilityDescription:nil];
    _status.stringValue = @"🎙 Listening… (tap 🎙 to send)"; _status.textColor = [NSColor systemRedColor];
    __weak typeof(self) wself = self;
    _task = [_recognizer recognitionTaskWithRequest:_req resultHandler:^(SFSpeechRecognitionResult *result, NSError *e) {
        typeof(self) sself = wself; if (!sself) return;   // window torn down mid-listen → bail (no retain cycle)
        if (result) { sself->_input.stringValue = result.bestTranscription.formattedString;
            if (result.isFinal) { NSString *t = sself->_input.stringValue; [sself stopListening]; if (t.length) [sself send:nil]; } }
        if (e) [sself stopListening];
    }];
}
- (void)stopListening {
    if (_engine) { [_engine stop]; [_engine.inputNode removeTapOnBus:0]; }
    [_req endAudio]; [_task cancel]; _engine = nil; _req = nil; _task = nil; _listening = NO;
    _mic.contentTintColor = [NSColor controlAccentColor];
    _mic.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
    [self refreshStatus];
}

@end
