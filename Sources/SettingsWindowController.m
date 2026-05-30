//
//  SettingsWindowController.m
//
#import "SettingsWindowController.h"

@implementation SettingsWindowController {
    __weak id<SettingsDelegate> _delegate;
    NSButton   *_fullBar, *_login;
    NSStepper  *_workStep, *_breakStep;
    NSTextField *_workVal, *_breakVal;
}

- (instancetype)initWithDelegate:(id<SettingsDelegate>)delegate {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 300)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"PulseBar Settings";
    w.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:w])) {
        _delegate = delegate;
        [self build];
    }
    return self;
}

static NSTextField *label(NSString *s, NSRect f, CGFloat sz, BOOL bold) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.frame = f; t.font = bold ? [NSFont boldSystemFontOfSize:sz] : [NSFont systemFontOfSize:sz];
    return t;
}

- (void)build {
    NSView *c = self.window.contentView;
    CGFloat W = 380, top = 300;

    [c addSubview:label(@"⟂ PulseBar", NSMakeRect(20, top - 40, W - 40, 24), 17, YES)];
    NSTextField *sub = label(@"Live system monitor on the Touch Bar", NSMakeRect(20, top - 60, W - 40, 18), 11, NO);
    sub.textColor = [NSColor secondaryLabelColor];
    [c addSubview:sub];

    _fullBar = [NSButton checkboxWithTitle:@"Take over the entire Touch Bar (hide Control Strip)"
                                    target:self action:@selector(toggleFullBar:)];
    _fullBar.frame = NSMakeRect(20, top - 96, W - 40, 20);
    [c addSubview:_fullBar];
    NSTextField *fbHelp = label(@"Fills the whole bar & stays put across apps. You'll use PulseBar's\nown volume/brightness instead of the system Control Strip.",
                                NSMakeRect(40, top - 132, W - 60, 30), 10, NO);
    fbHelp.textColor = [NSColor secondaryLabelColor]; fbHelp.maximumNumberOfLines = 2;
    [c addSubview:fbHelp];

    _login = [NSButton checkboxWithTitle:@"Start PulseBar at login" target:self action:@selector(toggleLogin:)];
    _login.frame = NSMakeRect(20, top - 160, W - 40, 20);
    [c addSubview:_login];

    [c addSubview:label(@"Pomodoro", NSMakeRect(20, top - 196, 120, 18), 12, YES)];

    [c addSubview:label(@"Work", NSMakeRect(20, top - 222, 50, 18), 11, NO)];
    _workStep = [[NSStepper alloc] initWithFrame:NSMakeRect(110, top - 224, 20, 24)];
    _workStep.minValue = 1; _workStep.maxValue = 120; _workStep.increment = 1;
    _workStep.target = self; _workStep.action = @selector(changeWork:);
    [c addSubview:_workStep];
    _workVal = label(@"25 min", NSMakeRect(135, top - 222, 80, 18), 11, NO);
    [c addSubview:_workVal];

    [c addSubview:label(@"Break", NSMakeRect(20, top - 248, 50, 18), 11, NO)];
    _breakStep = [[NSStepper alloc] initWithFrame:NSMakeRect(110, top - 250, 20, 24)];
    _breakStep.minValue = 1; _breakStep.maxValue = 60; _breakStep.increment = 1;
    _breakStep.target = self; _breakStep.action = @selector(changeBreak:);
    [c addSubview:_breakStep];
    _breakVal = label(@"5 min", NSMakeRect(135, top - 248, 80, 18), 11, NO);
    [c addSubview:_breakVal];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit PulseBar" target:self action:@selector(doQuit:)];
    quit.frame = NSMakeRect(W - 140, 18, 120, 30);
    quit.bezelStyle = NSBezelStyleRounded;
    [c addSubview:quit];
}

- (void)present {
    [self syncFromDelegate];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)syncFromDelegate {
    _fullBar.state = [_delegate settingsFullBarEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _login.state   = [_delegate settingsLoginEnabled]   ? NSControlStateValueOn : NSControlStateValueOff;
    NSInteger wm = [_delegate settingsWorkMinutes], bm = [_delegate settingsBreakMinutes];
    _workStep.integerValue = wm; _breakStep.integerValue = bm;
    _workVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)wm];
    _breakVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)bm];
}

- (void)toggleFullBar:(NSButton *)b { [_delegate settingsSetFullBar:(b.state == NSControlStateValueOn)]; }
- (void)toggleLogin:(NSButton *)b   { [_delegate settingsSetLogin:(b.state == NSControlStateValueOn)];
                                       [self syncFromDelegate]; }
- (void)changeWork:(NSStepper *)s {
    _workVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)s.integerValue];
    [_delegate settingsSetWork:s.integerValue breakMin:_breakStep.integerValue];
}
- (void)changeBreak:(NSStepper *)s {
    _breakVal.stringValue = [NSString stringWithFormat:@"%ld min", (long)s.integerValue];
    [_delegate settingsSetWork:_workStep.integerValue breakMin:s.integerValue];
}
- (void)doQuit:(id)s { [_delegate settingsQuit]; }

@end
