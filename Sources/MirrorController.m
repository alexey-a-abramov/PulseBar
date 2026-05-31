//
//  MirrorController.m
//
#import "MirrorController.h"
#import "PBDefaults.h"
#import "Pomodoro.h"

@interface PBMirrorController () <NSWindowDelegate>
@end

@implementation PBMirrorController {
    NSPanel *_panel;
    BarView *_bar;
    BOOL     _persist;
}
@synthesize bar = _bar;

- (instancetype)initWithActionDelegate:(id<BarActionDelegate>)delegate pomodoro:(Pomodoro *)pomo mode:(NSInteger)mode {
    if ((self = [super init])) {
        _persist = YES;
        CGFloat barW = 1004;   // match the live Touch Bar app-area width
        CGFloat maxW = [NSScreen mainScreen].visibleFrame.size.width - 80;
        CGFloat scale = MIN(1.5, maxW / barW); if (scale < 0.9) scale = 0.9;
        CGFloat w = barW * scale, h = 30 * scale;
        NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel)
            backing:NSBackingStoreBuffered defer:NO];
        p.title = @"PulseBar — Touch Bar Mirror";
        p.level = NSFloatingWindowLevel; p.hidesOnDeactivate = NO; p.releasedWhenClosed = NO;
        p.movableByWindowBackground = YES; p.delegate = self;
        p.becomesKeyOnlyIfNeeded = YES;   // clicking it must NOT steal key focus / dismiss the system-modal Touch Bar

        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        _bar = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        _bar.actionDelegate = delegate;
        _bar.pomodoro = pomo;
        _bar.animateModeSwitch = YES;
        [_bar setMode:mode animated:NO];
        [container addSubview:_bar];
        _bar.bounds = NSMakeRect(0, 0, barW, 30);   // bounds < frame → scales the drawing up
        p.contentView = container;
        _panel = p;
    }
    return self;
}

- (BOOL)visible { return _panel.isVisible; }

- (void)show {
    NSRect sf = [NSScreen mainScreen].visibleFrame, wf = _panel.frame;
    [_panel setFrameOrigin:NSMakePoint(sf.origin.x + (sf.size.width - wf.size.width) / 2, sf.origin.y + 36)];
    [_panel orderFront:nil];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:PBKeyMirror];
}
- (void)hide { [_panel orderOut:nil]; [NSUserDefaults.standardUserDefaults setBool:NO forKey:PBKeyMirror]; }
- (void)toggle { _panel.isVisible ? [self hide] : [self show]; }
- (void)suspendPersistence { _persist = NO; }

- (void)windowWillClose:(NSNotification *)n {
    if (!_persist) return;   // app quitting → leave "visible" persisted so the mirror reopens next launch
    if (n.object == _panel) [NSUserDefaults.standardUserDefaults setBool:NO forKey:PBKeyMirror];
}

@end
