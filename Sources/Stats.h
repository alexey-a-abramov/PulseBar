//
//  Stats.h — system metrics sampling (no AppKit; unit-testable C/ObjC).
//
//  All "rate" samplers (CPU, per-core, network) keep internal previous-sample
//  state, so call them once to prime, then again after a short interval to get
//  a meaningful value.
//
#ifndef PULSEBAR_STATS_H
#define PULSEBAR_STATS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Overall CPU utilisation in percent [0..100]. First call returns 0 (priming).
double StatsCPUPercent(void);

/// Per-core utilisation. Fills `out` with up to `maxN` values in [0..100],
/// returns the number of logical cores written. First call returns priming values.
int StatsPerCore(double *out, int maxN);

typedef struct {
    uint64_t usedBytes;       // approx "memory used" (active + wired + compressed)
    uint64_t totalBytes;      // physical RAM
    double   usedPct;         // 0..100
    int      pressure;        // kern memory pressure level (1 normal, 2 warn, 4 critical)
    uint64_t swapUsedBytes;   // vm.swapusage
    uint64_t swapTotalBytes;
} MemInfo;
MemInfo StatsMemory(void);

typedef struct {
    double downBps;         // bytes/sec received  (since previous call)
    double upBps;           // bytes/sec sent      (since previous call)
} NetSample;
NetSample StatsNetwork(void);

typedef struct {
    int    hasBattery;
    double percent;         // 0..100
    int    charging;        // 1 if on AC / charging
    int    timeToEmptyMin;  // minutes, -1 if unknown
} BatteryInfo;
BatteryInfo StatsBattery(void);

/// GPU utilisation in percent [0..100], or -1 if unavailable.
double StatsGPUPercent(void);

typedef struct { double readBps, writeBps; } DiskIO;     // since previous call
DiskIO StatsDiskIO(void);

typedef struct { uint64_t freeBytes, totalBytes; } DiskSpace;
DiskSpace StatsDiskSpace(void);                          // for "/"

/// Name + CPU% of the busiest process (via `ps`). Safe to call ~every few sec.
void StatsTopProcess(char *nameOut, int nameLen, double *cpuOut);

#ifdef __cplusplus
}
#endif

#endif /* PULSEBAR_STATS_H */
