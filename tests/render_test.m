//
//  render_test.m — renders every BarView mode to /tmp/pulsebar_modes.png so the
//  layout/accordion can be inspected without a physical Touch Bar.
//
#import <AppKit/AppKit.h>
#import "../Sources/BarView.h"
#import "../Sources/PBClock.h"
#import "../Sources/Pomodoro.h"
#import "../Sources/PreviewData.h"

static NSImage *renderMode(BarView *v, NSInteger mode) {
    [v setMode:mode animated:NO];
    NSData *pdf = [v dataWithPDFInsideRect:v.bounds];
    return [[NSImage alloc] initWithData:pdf];
}

static void writeGrid(BarView *v, CGFloat W, CGFloat H, CGFloat S, NSString *path) {
    int rows = (int)BarModeCount, gap = 8;
    int rowPix = (int)(H * S), pw = (int)(W * S), ph = rows * rowPix + (rows - 1) * gap;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pw pixelsHigh:ph
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, pw, ph));
    for (int m = 0; m < rows; m++) {
        NSImage *img = renderMode(v, m);
        CGFloat y = ph - (m + 1) * rowPix - m * gap;
        [img drawInRect:NSMakeRect(0, y, pw, rowPix) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    printf("wrote %s (%dx%d)\n", path.UTF8String, pw, ph);
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    PBClockSetFrozenNow([NSDate dateWithTimeIntervalSince1970:1718283600]);   // freeze world clocks for a stable Glance row

    CGFloat W = 1004, H = 30, S = 2.6;
    BarView *v = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    Pomodoro *pomo = [Pomodoro new]; [pomo toggle]; v.pomodoro = pomo;
    v.caffeinated = YES;
    v.uptime = 3 * 86400 + 4 * 3600 + 600;
    v.thermal = (PBThermalSample){ .hasTemp = 1, .cpuTempC = 54, .cpuTempMaxC = 57, .hasFan = 1, .fanRPM = 1200, .fanMaxRPM = 7200 };
    v.safeAreaLeftInset = 0; v.safeAreaRightInset = 110;   // default fit: clears the collapsed Control Strip

    PBFeedSample(v, 70);

    v.density = PBDensityFull;
    writeGrid(v, W, H, S, @"/tmp/pulsebar_modes.png");      // full layout
    v.density = PBDensityCompact;
    writeGrid(v, W, H, S, @"/tmp/pulsebar_compact.png");    // compact: icon-only pill + actions
    v.density = PBDensityFull;

    // Auto density at a tight width: must render compact (icon-only pill) on its
    // own — availFull ≈ 256 < System's ~372 required.
    {
        BarView *tight = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, 640, H)];
        tight.pomodoro = pomo; tight.caffeinated = YES; tight.uptime = v.uptime;
        tight.thermal = v.thermal;
        tight.safeAreaLeftInset = 0; tight.safeAreaRightInset = 110;
        tight.density = PBDensityAuto;
        PBFeedSample(tight, 70);
        writeGrid(tight, 640, H, S, @"/tmp/pulsebar_auto_tight.png");
    }

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

    // Break-reminder banner (unmutable session-length nudge)
    v.appOverlay = NO; [v setMode:BarModeProductivity animated:NO];
    v.breakReminderText = @"1h 26m"; v.breakReminder = YES;
    NSImage *br = [[NSImage alloc] initWithData:[v dataWithPDFInsideRect:v.bounds]];
    NSBitmapImageRep *brr = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:fw pixelsHigh:fh
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *brgc = [NSGraphicsContext graphicsContextWithBitmapImageRep:brr];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:brgc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, fw, fh));
    [br drawInRect:NSMakeRect(0, 0, fw, fh) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    [[brr representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/pulsebar_break.png" atomically:YES];
    printf("wrote /tmp/pulsebar_break.png\n");

    // Arrange mode (long-press the active pill → drag tiles to reorder)
    v.breakReminder = NO; v.density = PBDensityFull; [v setMode:BarModeSystem animated:NO];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [v performSelector:@selector(enterArrange)];
    #pragma clang diagnostic pop
    NSImage *ar = [[NSImage alloc] initWithData:[v dataWithPDFInsideRect:v.bounds]];
    NSBitmapImageRep *arr = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:fw pixelsHigh:fh
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *argc = [NSGraphicsContext graphicsContextWithBitmapImageRep:arr];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:argc];
    [[NSColor blackColor] setFill]; NSRectFill(NSMakeRect(0, 0, fw, fh));
    [ar drawInRect:NSMakeRect(0, 0, fw, fh) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    [[arr representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/pulsebar_arrange.png" atomically:YES];
    printf("wrote /tmp/pulsebar_arrange.png\n");
    return 0;
}}
