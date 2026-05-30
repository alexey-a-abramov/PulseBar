//
//  PreviewData.m
//
#import "PreviewData.h"
#import "Stats.h"
#import <string.h>
#import <math.h>

void PBFeedSample(BarView *v, int frames) {
    double cores[8] = {12, 80, 33, 5, 60, 20, 95, 40};
    MemInfo mem = { (uint64_t)(13.7 * 1e9), (uint64_t)(17.18 * 1e9), 80.0, 2, (uint64_t)(21.8 * 1e9), (uint64_t)(22.5 * 1e9) };
    DiskIO disk = { 5.0 * 1024 * 1024, 800.0 * 1024 };
    DiskSpace sp = { (uint64_t)(120.0 * 1e9), (uint64_t)(494.0 * 1e9) };
    BatteryInfo bat = { 1, 76, 1, 0 };
    NowPlaying np; memset(&np, 0, sizeof(np));
    strncpy(np.title,  "Midnight City", sizeof(np.title)  - 1);
    strncpy(np.artist, "M83",           sizeof(np.artist) - 1);
    np.isPlaying = 1; np.hasInfo = 1; np.elapsed = 72; np.duration = 244;

    if (frames < 1) frames = 1;
    for (int i = 0; i < frames; i++) {
        double cpu = 45 + 30 * sin(i * 0.30), gpu = 35 + 25 * sin(i * 0.20 + 1);
        NetSample n2 = { (0.6 + 0.5 * sin(i * 0.25)) * 2e6, (0.3 + 0.2 * sin(i * 0.30)) * 5e5 };
        [v updateWithCPU:cpu cores:cores count:8 mem:mem net:n2 gpu:gpu disk:disk space:sp battery:bat
                 topProc:@"WindowServer" topCPU:18.3 nowPlaying:np volume:0.62 mute:NO brightness:0.63];
    }
}
