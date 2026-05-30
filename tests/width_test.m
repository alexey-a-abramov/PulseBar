//
//  width_test.m — renders one mode at decreasing widths so the size-aware
//  priority hiding can be inspected. Output: /tmp/pulsebar_widths.png
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/Pomodoro.h"
#import "../Sources/PreviewData.h"

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSInteger mode = (argc > 1) ? atoi(argv[1]) : BarModeSystem;

    CGFloat widths[] = {1004, 760, 560, 420, 320, 240};
    int nw = sizeof(widths) / sizeof(widths[0]);
    CGFloat H = 30, S = 2.6; int gap = 10;

    BarView *v = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, H)];
    Pomodoro *pomo = [Pomodoro new]; [pomo toggle]; v.pomodoro = pomo;
    v.caffeinated = YES; v.uptime = 3 * 86400 + 4 * 3600 + 600;
    PBFeedSample(v, 70);
    [v setMode:mode animated:NO];

    int rowPix = (int)(H * S), pw = (int)(1004 * S), ph = nw * rowPix + (nw - 1) * gap;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pw pixelsHigh:ph
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [[NSColor colorWithCalibratedWhite:0.15 alpha:1] setFill]; NSRectFill(NSMakeRect(0, 0, pw, ph));
    for (int i = 0; i < nw; i++) {
        [v setFrame:NSMakeRect(0, 0, widths[i], H)];
        NSImage *img = [[NSImage alloc] initWithData:[v dataWithPDFInsideRect:v.bounds]];
        CGFloat y = ph - (i + 1) * rowPix - i * gap;
        [img drawInRect:NSMakeRect(0, y, (int)(widths[i] * S), rowPix) fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver fraction:1];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/pulsebar_widths.png" atomically:YES];
    printf("wrote /tmp/pulsebar_widths.png — mode %ld at %d widths\n", (long)mode, nw);
    return 0;
}}
