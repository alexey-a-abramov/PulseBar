//
//  stats_test.m — unit tests for the system-metrics samplers.
//  Compiled against Sources/Stats.m; links Foundation + IOKit only (no AppKit),
//  so it runs anywhere, including headless.
//
#import <Foundation/Foundation.h>
#import "../Sources/Stats.h"
#import <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  ok   : %s\n", msg); } \
    else      { printf("  FAIL : %s\n", msg); failures++; } \
} while (0)

int main(void) {
    @autoreleasepool {
        printf("PulseBar — stats unit tests\n");

        // CPU: prime, wait, sample. Must be a real percentage.
        StatsCPUPercent();
        usleep(350 * 1000);
        double cpu = StatsCPUPercent();
        printf("  cpu = %.1f%%\n", cpu);
        CHECK(cpu >= 0.0 && cpu <= 100.0, "cpu in [0,100]");

        // Per-core: prime, wait, sample.
        double cores[128];
        StatsPerCore(cores, 128);
        usleep(250 * 1000);
        int n = StatsPerCore(cores, 128);
        printf("  cores = %d\n", n);
        CHECK(n > 0, "core count > 0");
        int coresOK = 1;
        for (int i = 0; i < n; i++) if (cores[i] < 0.0 || cores[i] > 100.0) coresOK = 0;
        CHECK(coresOK, "every core in [0,100]");

        // Memory.
        MemInfo m = StatsMemory();
        printf("  mem = %.2f / %.2f GB (%.1f%%)  pressure=%d\n",
               m.usedBytes / 1e9, m.totalBytes / 1e9, m.usedPct, m.pressure);
        CHECK(m.totalBytes > 0, "total memory > 0");
        CHECK(m.usedBytes > 0 && m.usedBytes <= m.totalBytes, "0 < used <= total");
        CHECK(m.usedPct > 0.0 && m.usedPct <= 100.0, "used%% in (0,100]");
        printf("  swap = %.2f / %.2f GB used\n", m.swapUsedBytes / 1e9, m.swapTotalBytes / 1e9);
        CHECK(m.swapUsedBytes <= m.swapTotalBytes, "swap used <= total");

        // Network: prime, wait, sample. Rates must be non-negative.
        StatsNetwork();
        usleep(300 * 1000);
        NetSample net = StatsNetwork();
        printf("  net = down %.0f B/s  up %.0f B/s\n", net.downBps, net.upBps);
        CHECK(net.downBps >= 0.0 && net.upBps >= 0.0, "net rates non-negative");

        // Battery (laptops only).
        BatteryInfo b = StatsBattery();
        printf("  battery: has=%d  %.0f%%  charging=%d  ttE=%dmin\n",
               b.hasBattery, b.percent, b.charging, b.timeToEmptyMin);
        if (b.hasBattery) {
            CHECK(b.percent >= 0.0 && b.percent <= 100.0, "battery %% in [0,100]");
        } else {
            printf("  (no battery present — desktop?)\n");
        }

        // GPU
        double gpu = StatsGPUPercent();
        printf("  gpu = %.0f%%\n", gpu);
        CHECK(gpu >= -1.0 && gpu <= 100.0, "gpu in [-1,100]");

        // Disk I/O
        StatsDiskIO(); usleep(300 * 1000); DiskIO dio = StatsDiskIO();
        printf("  disk io = R %.0f  W %.0f B/s\n", dio.readBps, dio.writeBps);
        CHECK(dio.readBps >= 0 && dio.writeBps >= 0, "disk io non-negative");

        // Disk space
        DiskSpace dsp = StatsDiskSpace();
        printf("  disk = %.0f free / %.0f GB total\n", dsp.freeBytes / 1e9, dsp.totalBytes / 1e9);
        CHECK(dsp.totalBytes > 0 && dsp.freeBytes <= dsp.totalBytes, "disk space sane");

        // Top process
        char proc[256]; double pcpu = 0; StatsTopProcess(proc, sizeof(proc), &pcpu);
        printf("  top process = '%s' (%.1f%%)\n", proc, pcpu);
        CHECK(pcpu >= 0, "top-process cpu non-negative");

        // Uptime
        double up = StatsUptimeSeconds();
        printf("  uptime = %.1f hours\n", up / 3600.0);
        CHECK(up > 0, "uptime > 0");

        printf("\n%s — %d failure%s\n",
               failures ? "TESTS FAILED" : "ALL TESTS PASSED",
               failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
