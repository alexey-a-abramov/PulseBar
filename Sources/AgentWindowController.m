//
//  AgentWindowController.m
//
#import "AgentWindowController.h"

@interface AgentWindowController () <NSTextFieldDelegate>
@end

@implementation AgentWindowController {
    PBAgent     *_agent;
    NSTextView  *_transcript;
    NSTextField *_input;
    NSTextField *_status;
    NSButton    *_send;
    BOOL         _busy;
}

- (instancetype)initWithAgent:(PBAgent *)agent {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 540)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"PulseBar Agent";
    w.releasedWhenClosed = NO;
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

    _input = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 12, W - 24 - 76, 28)];
    _input.placeholderString = @"Ask or command… (e.g. “set volume to 30”, “open Safari”)";
    _input.delegate = self;
    _input.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [c addSubview:_input];

    _send = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
    _send.frame = NSMakeRect(W - 12 - 70, 11, 70, 30);
    _send.bezelStyle = NSBezelStyleRounded; _send.keyEquivalent = @"\r";
    _send.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [c addSubview:_send];

    [self appendRole:@"PulseBar" text:@"Hi! Tell me what to do — e.g. “mute”, “brightness 80”, “play music”, or ask a question." color:[NSColor systemPurpleColor]];
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

- (void)appendRole:(NSString *)who text:(NSString *)text color:(NSColor *)color {
    NSTextStorage *ts = _transcript.textStorage;
    [ts beginEditing];
    NSDictionary *nameAttr = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:12], NSForegroundColorAttributeName: color };
    NSDictionary *bodyAttr = @{ NSFontAttributeName: [NSFont systemFontOfSize:12.5], NSForegroundColorAttributeName: [NSColor labelColor] };
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", who] attributes:nameAttr]];
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n\n", text] attributes:bodyAttr]];
    [ts endEditing];
    [_transcript scrollRangeToVisible:NSMakeRange(ts.length, 0)];
}

- (void)send:(id)sender {
    NSString *text = [_input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || _busy) return;
    _input.stringValue = @"";
    [self appendRole:@"You" text:text color:[NSColor systemBlueColor]];
    _busy = YES; _send.enabled = NO; _status.stringValue = @"…thinking";
    [_agent ask:text done:^(NSString *interp, NSString *reply) {
        if (interp.length) [self appendRole:@"Action" text:interp color:[NSColor systemTealColor]];
        [self appendRole:@"PulseBar" text:reply ?: @"(no reply)" color:[NSColor systemPurpleColor]];
        self->_busy = NO; self->_send.enabled = YES;
        [self refreshStatus];
    }];
}

// Enter in the text field sends.
- (void)controlTextDidEndEditing:(NSNotification *)n {
    NSNumber *reason = n.userInfo[@"NSTextMovement"];
    if (reason.integerValue == NSReturnTextMovement) [self send:nil];
}

@end
