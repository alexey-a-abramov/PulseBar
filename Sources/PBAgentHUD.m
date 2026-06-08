//
//  PBAgentHUD.m
//
#import "PBAgentHUD.h"

static const CGFloat kHUDW = 440, kHUDH = 60;

@implementation PBAgentHUDView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    // capsule background
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1, 1) xRadius:16 yRadius:16];
    [[NSColor colorWithCalibratedWhite:0.10 alpha:0.96] setFill]; [bg fill];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.08] setStroke]; bg.lineWidth = 1; [bg stroke];

    // gradient orb
    NSRect orb = NSMakeRect(14, (kHUDH - 30) / 2, 30, 30);
    NSGradient *g = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.38 green:0.42 blue:0.99 alpha:1],
        [NSColor colorWithSRGBRed:0.78 green:0.36 blue:0.98 alpha:1],
        [NSColor colorWithSRGBRed:0.99 green:0.38 blue:0.62 alpha:1]]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:orb] angle:45];
    NSString *sym = (_mode == PBHUDListening) ? @"mic.fill" : (_mode == PBHUDThinking ? @"ellipsis" : @"sparkles");
    NSImage *si = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    si = [si imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold]];
    if (@available(macOS 12.0, *)) si = [si imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor whiteColor]]];
    [si drawInRect:NSMakeRect(NSMidX(orb) - si.size.width / 2, NSMidY(orb) - si.size.height / 2, si.size.width, si.size.height)];

    // recording dot
    if (_mode == PBHUDListening) {
        [[NSColor systemRedColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(orb.origin.x + 24, orb.origin.y + 1, 8, 8)] fill];
    }

    // state caption + text
    CGFloat tx = NSMaxX(orb) + 14, tw = kHUDW - tx - 16;
    NSString *cap = (_mode == PBHUDListening) ? @"LISTENING" : (_mode == PBHUDThinking ? @"THINKING" : @"PULSEBAR");
    NSColor *capColor = (_mode == PBHUDListening) ? [NSColor systemRedColor]
                      : (_mode == PBHUDThinking ? [NSColor systemOrangeColor] : [NSColor systemPurpleColor]);
    [cap drawAtPoint:NSMakePoint(tx, 11)
      withAttributes:@{ NSFontAttributeName:[NSFont boldSystemFontOfSize:9], NSForegroundColorAttributeName:capColor }];

    NSString *body = _text.length ? _text : (_mode == PBHUDListening ? @"…" : @"");
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSColor *bodyCol = (_mode == PBHUDResult) ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite:0.92 alpha:1];
    [body drawInRect:NSMakeRect(tx, 24, tw, 26)
      withAttributes:@{ NSFontAttributeName:[NSFont systemFontOfSize:15 weight:(_mode==PBHUDResult?NSFontWeightSemibold:NSFontWeightRegular)],
                        NSForegroundColorAttributeName:bodyCol, NSParagraphStyleAttributeName:ps }];
}

@end

@implementation PBAgentHUD {
    NSPanel        *_panel;
    PBAgentHUDView *_view;
}

- (void)build {
    if (_panel) return;
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kHUDW, kHUDH)
        styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
        backing:NSBackingStoreBuffered defer:NO];
    _panel.level = NSStatusWindowLevel;
    _panel.opaque = NO; _panel.backgroundColor = [NSColor clearColor];
    _panel.hasShadow = YES; _panel.hidesOnDeactivate = NO; _panel.ignoresMouseEvents = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _view = [[PBAgentHUDView alloc] initWithFrame:NSMakeRect(0, 0, kHUDW, kHUDH)];
    _panel.contentView = _view;
}

- (void)position {
    NSScreen *s = [NSScreen mainScreen]; NSRect vf = s.visibleFrame;
    [_panel setFrameOrigin:NSMakePoint(NSMidX(vf) - kHUDW / 2, vf.origin.y + 120)];   // bottom-centre, above the Dock
}

- (void)appear {
    [self build];
    if (!_panel.isVisible) { [self position]; _panel.alphaValue = 0; [_panel orderFrontRegardless]; }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismiss) object:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.16; self->_panel.animator.alphaValue = 1; } completionHandler:nil];
}

- (void)setMode:(PBHUDMode)m text:(NSString *)t { [self build]; _view.mode = m; _view.text = t; [_view setNeedsDisplay:YES]; }

- (void)showListening { [self setMode:PBHUDListening text:@""]; [self appear]; }
- (void)updatePartial:(NSString *)text { [self setMode:PBHUDListening text:text]; }
- (void)showThinking { [self setMode:PBHUDThinking text:@""]; [self appear]; }
- (void)showResult:(NSString *)text {
    [self setMode:PBHUDResult text:text]; [self appear];
    [self performSelector:@selector(dismiss) withObject:nil afterDelay:2.6];   // fade away after reading time
}
- (void)dismiss {
    if (!_panel.isVisible) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(dismiss) object:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) { c.duration = 0.22; self->_panel.animator.alphaValue = 0; }
        completionHandler:^{ if (self->_panel.alphaValue < 0.05) [self->_panel orderOut:nil]; }];
}

@end
