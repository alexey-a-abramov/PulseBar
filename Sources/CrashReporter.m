//
//  CrashReporter.m
//
#import "CrashReporter.h"
#import "Log.h"

@implementation PBCrashReporter {
    NSWindow  *_win;
    NSString  *_report;
    NSButton  *_copyBtn;
}

+ (void)presentReport:(NSString *)report title:(NSString *)title allowContinue:(BOOL)allowContinue {
    if (!report.length) return;
    PBCrashReporter *r = [PBCrashReporter new];
    [r runWithReport:report title:title allowContinue:allowContinue];
}

- (void)runWithReport:(NSString *)report title:(NSString *)title allowContinue:(BOOL)allowContinue {
    [self buildWindowWithReport:report title:title allowContinue:allowContinue];
    [NSApp activateIgnoringOtherApps:YES];
    [_win center];
    [_win makeKeyAndOrderFront:nil];
    NSModalResponse resp = [NSApp runModalForWindow:_win];
    [_win orderOut:nil];
    if (resp != NSModalResponseContinue) [NSApp terminate:nil];   // Quit (or fatal dialog dismissed)
}

// Builds (but does not present) the dialog. Split out so it can be rendered in tests.
- (NSWindow *)buildWindowWithReport:(NSString *)report title:(NSString *)title allowContinue:(BOOL)allowContinue {
    _report = report;
    CGFloat W = 720, H = 480;
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                       styleMask:NSWindowStyleMaskTitled
                                         backing:NSBackingStoreBuffered defer:NO];
    _win.title = @"PulseBar";
    _win.level = NSModalPanelWindowLevel;
    NSView *c = _win.contentView;

    NSTextField *head = [NSTextField labelWithString:title ?: @"PulseBar ran into a problem"];
    head.font = [NSFont boldSystemFontOfSize:15];
    head.frame = NSMakeRect(20, H - 44, W - 40, 24);
    [c addSubview:head];

    NSTextField *sub = [NSTextField labelWithString:@"The details below were also saved to the log. Use “Copy details” to share them."];
    sub.font = [NSFont systemFontOfSize:11]; sub.textColor = [NSColor secondaryLabelColor];
    sub.frame = NSMakeRect(20, H - 64, W - 40, 16);
    [c addSubview:sub];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, W - 40, H - 64 - 60)];
    sv.hasVerticalScroller = YES; sv.hasHorizontalScroller = YES; sv.autohidesScrollers = YES;
    sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.editable = NO; tv.selectable = YES; tv.richText = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.textContainerInset = NSMakeSize(8, 8);
    tv.string = report;
    tv.horizontallyResizable = YES; tv.verticallyResizable = YES;
    tv.textContainer.widthTracksTextView = NO;
    tv.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);
    sv.documentView = tv;
    [c addSubview:sv];

    // Buttons (bottom): left = utilities, right = continue/quit.
    NSButton *openLog = [NSButton buttonWithTitle:@"Open Log" target:self action:@selector(openLog:)];
    openLog.frame = NSMakeRect(20, 16, 110, 30); openLog.bezelStyle = NSBezelStyleRounded;
    [c addSubview:openLog];
    _copyBtn = [NSButton buttonWithTitle:@"Copy details" target:self action:@selector(copyReport:)];
    _copyBtn.frame = NSMakeRect(136, 16, 130, 30); _copyBtn.bezelStyle = NSBezelStyleRounded;
    [c addSubview:_copyBtn];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:self action:@selector(quit:)];
    quit.frame = NSMakeRect(W - 130, 16, 110, 30); quit.bezelStyle = NSBezelStyleRounded;
    [c addSubview:quit];
    if (allowContinue) {
        NSButton *cont = [NSButton buttonWithTitle:@"Continue" target:self action:@selector(cont:)];
        cont.frame = NSMakeRect(W - 250, 16, 110, 30); cont.bezelStyle = NSBezelStyleRounded;
        cont.keyEquivalent = @"\r";
        [c addSubview:cont];
    } else {
        quit.keyEquivalent = @"\r";
    }
    return _win;
}

- (void)copyReport:(id)sender {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:_report forType:NSPasteboardTypeString];
    _copyBtn.title = @"Copied ✓";
}

- (void)openLog:(id)sender {
    [[NSWorkspace sharedWorkspace] selectFile:PBLogFile() inFileViewerRootedAtPath:PBLogDirectory()];
}

- (void)cont:(id)sender { [NSApp stopModalWithCode:NSModalResponseContinue]; }
- (void)quit:(id)sender { [NSApp stopModalWithCode:NSModalResponseStop]; }

@end
