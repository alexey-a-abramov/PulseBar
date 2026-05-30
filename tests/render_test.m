//
//  render_test.m — renders every BarView mode to /tmp/pulsebar_modes.png so the
//  layout/accordion can be inspected without a physical Touch Bar.
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/Pomodoro.h"

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

    // Fn overlay (F1–F12)
    [v setMode:BarModeSystem animated:NO]; v.fnMode = YES;
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
