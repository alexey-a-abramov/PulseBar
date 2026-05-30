//
//  render_test.m — renders every BarView mode to /tmp/pulsebar_modes.png so the
//  layout/accordion can be inspected without a physical Touch Bar.
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/Pomodoro.h"
#import "../Sources/PreviewData.h"

static NSImage *renderMode(BarView *v, NSInteger mode) {
    [v setMode:mode animated:NO];
    NSData *pdf = [v dataWithPDFInsideRect:v.bounds];
    return [[NSImage alloc] initWithData:pdf];
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];

    CGFloat W = 1004, H = 30, S = 2.6;
    BarView *v = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    Pomodoro *pomo = [Pomodoro new]; [pomo toggle]; v.pomodoro = pomo;
    v.caffeinated = YES;
    v.uptime = 3 * 86400 + 4 * 3600 + 600;

    PBFeedSample(v, 70);

    int rows = (int)BarModeCount, gap = 8;
    int rowPix = (int)(H * S), pw = (int)(W * S), ph = rows * rowPix + (rows - 1) * gap;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pw pixelsHigh:ph
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, pw, ph));
    for (int m = 0; m < rows; m++) {
        NSImage *img = renderMode(v, m);
        CGFloat y = ph - (m + 1) * rowPix - m * gap;     // top-to-bottom
        [img drawInRect:NSMakeRect(0, y, pw, rowPix) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/pulsebar_modes.png" atomically:YES];
    printf("wrote /tmp/pulsebar_modes.png (%dx%d, %d modes)\n", pw, ph, rows);

    // App overlay (⌥ held)
    [v setMode:BarModeSystem animated:NO]; v.appName = @"Telegram"; v.appOverlay = YES;
    NSImage *fn = [[NSImage alloc] initWithData:[v dataWithPDFInsideRect:v.bounds]];
    int fw = (int)(W * S), fh = (int)(H * S);
    NSBitmapImageRep *fr = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:fw pixelsHigh:fh
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *fgc = [NSGraphicsContext graphicsContextWithBitmapImageRep:fr];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:fgc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, fw, fh));
    [fn drawInRect:NSMakeRect(0, 0, fw, fh) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    [[fr representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/pulsebar_fn.png" atomically:YES];
    printf("wrote /tmp/pulsebar_fn.png\n");
    return 0;
}}
