//
//  width_test.m — renders one mode at decreasing widths so the size-aware
//  priority hiding can be inspected. Output: /tmp/pulsebar_widths.png
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/Pomodoro.h"

int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSInteger mode = (argc > 1) ? atoi(argv[1]) : BarModeSystem;

    CGFloat widths[] = {1004, 760, 560, 420, 320, 240};
    int nw = sizeof(widths) / sizeof(widths[0]);
    CGFloat H = 30, S = 2.6; int gap = 10;

    BarView *v = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 1004, H)];
    Pomodoro *pomo = [Pomodoro new]; [pomo toggle]; v.pomodoro = pomo;
    v.caffeinated = YES; v.uptime = 3 * 86400 + 4 * 3600 + 600;
    double cores[8] = {12, 80, 33, 5, 60, 20, 95, 40};
    MemInfo mem = { (uint64_t)(13.7 * 1e9), (uint64_t)(17.18 * 1e9), 80.0, 2, (uint64_t)(21.8 * 1e9), (uint64_t)(22.5 * 1e9) };
    DiskIO disk = { 5.0 * 1024 * 1024, 800.0 * 1024 };
    DiskSpace sp = { (uint64_t)(120.0 * 1e9), (uint64_t)(494.0 * 1e9) };
    BatteryInfo bat = { 1, 76, 1, 0 };
    NowPlaying np; memset(&np, 0, sizeof(np)); strcpy(np.title, "Midnight City"); strcpy(np.artist, "M83");
    np.isPlaying = 1; np.hasInfo = 1; np.elapsed = 72; np.duration = 244;
    for (int i = 0; i < 70; i++) {
        double cpu = 45 + 30 * sin(i * 0.30), gpu = 35 + 25 * sin(i * 0.20 + 1);
        NetSample n2 = { (0.6 + 0.5 * sin(i * 0.25)) * 2e6, (0.3 + 0.2 * sin(i * 0.30)) * 5e5 };
        [v updateWithCPU:cpu cores:cores count:8 mem:mem net:n2 gpu:gpu disk:disk space:sp battery:bat
                 topProc:@"WindowServer" topCPU:18.3 nowPlaying:np volume:0.62 mute:NO brightness:0.63];
    }
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
