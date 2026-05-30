//
//  render_test.m — renders BarView with sample data to a PNG so the layout can
//  be inspected without a physical Touch Bar.  Output: /tmp/pulsebar_bar.png
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/Pomodoro.h"

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];   // initialise AppKit (fonts / SF Symbols)

    CGFloat W = 1004, H = 30, S = 3;     // render at 3x for legibility
    BarView *v = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    Pomodoro *pomo = [Pomodoro new]; [pomo toggle]; v.pomodoro = pomo;

    double cores[8] = {12, 80, 33, 5, 60, 20, 95, 40};
    MemInfo mem = { (uint64_t)(13.7 * 1e9), (uint64_t)(17.18 * 1e9), 80.0, 2 };
    DiskIO disk = { 5.0 * 1024 * 1024, 800.0 * 1024 };
    DiskSpace sp = { (uint64_t)(120.0 * 1e9), (uint64_t)(494.0 * 1e9) };
    BatteryInfo bat = { 1, 76, 1, 0 };
    NowPlaying np; memset(&np, 0, sizeof(np));
    strcpy(np.title, "Midnight City"); strcpy(np.artist, "M83"); np.isPlaying = 1; np.hasInfo = 1;

    for (int i = 0; i < 70; i++) {
        double cpu = 45 + 30 * sin(i * 0.30);
        double gpu = 35 + 25 * sin(i * 0.20 + 1);
        NetSample n2 = { (0.6 + 0.5 * sin(i * 0.25)) * 2e6, (0.3 + 0.2 * sin(i * 0.30)) * 5e5 };
        [v updateWithCPU:cpu cores:cores count:8 mem:mem net:n2 gpu:gpu disk:disk space:sp
                 battery:bat topProc:@"WindowServer" topCPU:18.3
              nowPlaying:np volume:0.62 mute:NO brightness:0.63];
    }

    NSData *pdf = [v dataWithPDFInsideRect:v.bounds];
    NSImage *img = [[NSImage alloc] initWithData:pdf];
    int pw = (int)(W * S), ph = (int)(H * S);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pw pixelsHigh:ph bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, pw, ph));
    [img drawInRect:NSMakeRect(0, 0, pw, ph) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:@"/tmp/pulsebar_bar.png" atomically:YES];
    printf("wrote /tmp/pulsebar_bar.png (%dx%d)\n", pw, ph);
    return 0;
}}
