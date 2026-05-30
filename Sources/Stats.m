//
//  Stats.m — system metrics sampling implementation.
//
#import "Stats.h"

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <string.h>
#include <time.h>

#include <sys/mount.h>
#include <stdio.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

static double monotonicSeconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------------------
// CPU (aggregate)
// ---------------------------------------------------------------------------
double StatsCPUPercent(void) {
    static int primed = 0;
    static uint64_t pUser = 0, pSys = 0, pIdle = 0, pNice = 0;

    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                        (host_info_t)&info, &count) != KERN_SUCCESS) {
        return 0.0;
    }
    uint64_t user = info.cpu_ticks[CPU_STATE_USER];
    uint64_t sys  = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t idle = info.cpu_ticks[CPU_STATE_IDLE];
    uint64_t nice = info.cpu_ticks[CPU_STATE_NICE];

    double pct = 0.0;
    if (primed) {
        uint64_t busy  = (user - pUser) + (sys - pSys) + (nice - pNice);
        uint64_t total = busy + (idle - pIdle);
        pct = total ? (100.0 * (double)busy / (double)total) : 0.0;
    }
    pUser = user; pSys = sys; pIdle = idle; pNice = nice; primed = 1;
    if (pct < 0) pct = 0; if (pct > 100) pct = 100;
    return pct;
}

// ---------------------------------------------------------------------------
// CPU (per-core)
// ---------------------------------------------------------------------------
int StatsPerCore(double *out, int maxN) {
    static int primed = 0;
    static processor_info_array_t prevInfo = NULL;
    static mach_msg_type_number_t prevCount = 0;
    static natural_t prevCPUs = 0;

    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                            &cpuCount, &info, &infoCount) != KERN_SUCCESS) {
        return 0;
    }

    int n = (int)cpuCount;
    if (n > maxN) n = maxN;
    for (int i = 0; i < n; i++) {
        double pct = 0.0;
        unsigned base = (unsigned)i * CPU_STATE_MAX;
        uint64_t user = info[base + CPU_STATE_USER];
        uint64_t sys  = info[base + CPU_STATE_SYSTEM];
        uint64_t idle = info[base + CPU_STATE_IDLE];
        uint64_t nice = info[base + CPU_STATE_NICE];
        if (primed && prevInfo && (natural_t)i < prevCPUs) {
            uint64_t pu = prevInfo[base + CPU_STATE_USER];
            uint64_t ps = prevInfo[base + CPU_STATE_SYSTEM];
            uint64_t pi = prevInfo[base + CPU_STATE_IDLE];
            uint64_t pn = prevInfo[base + CPU_STATE_NICE];
            uint64_t busy  = (user - pu) + (sys - ps) + (nice - pn);
            uint64_t total = busy + (idle - pi);
            pct = total ? (100.0 * (double)busy / (double)total) : 0.0;
        }
        if (pct < 0) pct = 0; if (pct > 100) pct = 100;
        out[i] = pct;
    }

    if (prevInfo) {
        vm_deallocate(mach_task_self(), (vm_address_t)prevInfo,
                      (vm_size_t)prevCount * sizeof(integer_t));
    }
    prevInfo = info; prevCount = infoCount; prevCPUs = cpuCount; primed = 1;
    return n;
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------
MemInfo StatsMemory(void) {
    MemInfo m = (MemInfo){0, 0, 0.0, 0};

    int64_t total = 0; size_t len = sizeof(total);
    sysctlbyname("hw.memsize", &total, &len, NULL, 0);
    m.totalBytes = (uint64_t)total;

    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        uint64_t active     = (uint64_t)vm.active_count          * pageSize;
        uint64_t wired      = (uint64_t)vm.wire_count            * pageSize;
        uint64_t compressed = (uint64_t)vm.compressor_page_count * pageSize;
        uint64_t used = active + wired + compressed;
        m.usedBytes = used;
        m.usedPct = m.totalBytes ? (100.0 * (double)used / (double)m.totalBytes) : 0.0;
    }

    int level = 0; size_t ls = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &ls, NULL, 0) != 0) {
        level = 1;
    }
    m.pressure = level;

    struct xsw_usage sw; size_t sws = sizeof(sw);
    if (sysctlbyname("vm.swapusage", &sw, &sws, NULL, 0) == 0) {
        m.swapUsedBytes  = sw.xsu_used;
        m.swapTotalBytes = sw.xsu_total;
    }
    return m;
}

// ---------------------------------------------------------------------------
// Network throughput
// ---------------------------------------------------------------------------
NetSample StatsNetwork(void) {
    static int primed = 0;
    static uint64_t pIn = 0, pOut = 0;
    static double pT = 0.0;

    uint64_t totIn = 0, totOut = 0;
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data) continue;
            if (strncmp(p->ifa_name, "lo", 2) == 0) continue;        // skip loopback
            struct if_data *d = (struct if_data *)p->ifa_data;
            totIn  += d->ifi_ibytes;
            totOut += d->ifi_obytes;
        }
        freeifaddrs(ifap);
    }

    double now = monotonicSeconds();
    NetSample s = (NetSample){0.0, 0.0};
    if (primed && now > pT) {
        double dt = now - pT;
        // guard against counter wrap / iface reset
        s.downBps = (totIn  >= pIn)  ? (double)(totIn  - pIn)  / dt : 0.0;
        s.upBps   = (totOut >= pOut) ? (double)(totOut - pOut) / dt : 0.0;
    }
    pIn = totIn; pOut = totOut; pT = now; primed = 1;
    return s;
}

// ---------------------------------------------------------------------------
// Battery
// ---------------------------------------------------------------------------
BatteryInfo StatsBattery(void) {
    BatteryInfo b = (BatteryInfo){0, 0.0, 0, -1};

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return b;
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
            if (!ps) continue;

            CFNumberRef cap = (CFNumberRef)CFDictionaryGetValue(ps, CFSTR(kIOPSCurrentCapacityKey));
            CFNumberRef max = (CFNumberRef)CFDictionaryGetValue(ps, CFSTR(kIOPSMaxCapacityKey));
            if (cap && max) {
                int c = 0, mx = 100;
                CFNumberGetValue(cap, kCFNumberIntType, &c);
                CFNumberGetValue(max, kCFNumberIntType, &mx);
                b.hasBattery = 1;
                b.percent = mx ? (100.0 * (double)c / (double)mx) : 0.0;
            }
            CFStringRef state = (CFStringRef)CFDictionaryGetValue(ps, CFSTR(kIOPSPowerSourceStateKey));
            if (state) {
                b.charging = (CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) ? 1 : 0;
            }
            CFNumberRef tte = (CFNumberRef)CFDictionaryGetValue(ps, CFSTR(kIOPSTimeToEmptyKey));
            if (tte) {
                int t = -1;
                CFNumberGetValue(tte, kCFNumberIntType, &t);
                b.timeToEmptyMin = t;
            }
            break;  // first real power source is enough
        }
        CFRelease(list);
    }
    CFRelease(blob);
    return b;
}

// ---------------------------------------------------------------------------
// GPU utilisation (IOAccelerator PerformanceStatistics → "Device Utilization %")
// ---------------------------------------------------------------------------
double StatsGPUPercent(void) {
    double pct = -1.0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS)
        return pct;
    io_object_t obj;
    while ((obj = IOIteratorNext(it))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFDictionaryRef perf = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (perf) {
                CFNumberRef n = CFDictionaryGetValue(perf, CFSTR("Device Utilization %"));
                if (!n) n = CFDictionaryGetValue(perf, CFSTR("Renderer Utilization %"));
                if (n) { long v = 0; CFNumberGetValue(n, kCFNumberLongType, &v); pct = (double)v; }
            }
            CFRelease(props);
        }
        IOObjectRelease(obj);
        if (pct >= 0) break;
    }
    IOObjectRelease(it);
    return pct;
}

// ---------------------------------------------------------------------------
// Disk I/O (sum of all block storage drivers; rate since previous call)
// ---------------------------------------------------------------------------
DiskIO StatsDiskIO(void) {
    static int primed = 0;
    static uint64_t pR = 0, pW = 0; static double pT = 0.0;

    uint64_t totR = 0, totW = 0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS) {
        io_object_t obj;
        while ((obj = IOIteratorNext(it))) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFDictionaryRef st = CFDictionaryGetValue(props, CFSTR("Statistics"));
                if (st) {
                    CFNumberRef r = CFDictionaryGetValue(st, CFSTR("Bytes (Read)"));
                    CFNumberRef w = CFDictionaryGetValue(st, CFSTR("Bytes (Write)"));
                    long long v = 0;
                    if (r) { CFNumberGetValue(r, kCFNumberLongLongType, &v); totR += (uint64_t)v; }
                    if (w) { CFNumberGetValue(w, kCFNumberLongLongType, &v); totW += (uint64_t)v; }
                }
                CFRelease(props);
            }
            IOObjectRelease(obj);
        }
        IOObjectRelease(it);
    }

    double now = monotonicSeconds();
    DiskIO d = (DiskIO){0.0, 0.0};
    if (primed && now > pT) {
        double dt = now - pT;
        d.readBps  = (totR >= pR) ? (double)(totR - pR) / dt : 0.0;
        d.writeBps = (totW >= pW) ? (double)(totW - pW) / dt : 0.0;
    }
    pR = totR; pW = totW; pT = now; primed = 1;
    return d;
}

// ---------------------------------------------------------------------------
// Disk space for the boot volume
// ---------------------------------------------------------------------------
DiskSpace StatsDiskSpace(void) {
    DiskSpace d = (DiskSpace){0, 0};
    struct statfs s;
    if (statfs("/", &s) == 0) {
        d.freeBytes  = (uint64_t)s.f_bavail * s.f_bsize;
        d.totalBytes = (uint64_t)s.f_blocks * s.f_bsize;
    }
    return d;
}

// ---------------------------------------------------------------------------
// Busiest process (shells out to `ps`, sorted by CPU)
// ---------------------------------------------------------------------------
void StatsTopProcess(char *nameOut, int nameLen, double *cpuOut) {
    if (nameOut && nameLen) nameOut[0] = '\0';
    if (cpuOut) *cpuOut = 0.0;
    FILE *p = popen("ps -Aceo pcpu=,comm= -r 2>/dev/null | head -1", "r");
    if (!p) return;
    char line[512];
    if (fgets(line, sizeof(line), p)) {
        double cpu = 0.0; char name[256] = {0};
        if (sscanf(line, " %lf %255[^\n]", &cpu, name) >= 1) {  // pcpu then comm
            if (cpuOut) *cpuOut = cpu;
            if (nameOut && nameLen) {
                // basename only
                char *slash = strrchr(name, '/');
                const char *base = slash ? slash + 1 : name;
                strncpy(nameOut, base, nameLen - 1);
                nameOut[nameLen - 1] = '\0';
            }
        }
    }
    pclose(p);
}

// ---------------------------------------------------------------------------
// Uptime
// ---------------------------------------------------------------------------
double StatsUptimeSeconds(void) {
    struct timeval bt; size_t sz = sizeof(bt);
    if (sysctlbyname("kern.boottime", &bt, &sz, NULL, 0) != 0) return 0;
    double now = (double)time(NULL);
    double up = now - (double)bt.tv_sec;
    return up < 0 ? 0 : up;
}
