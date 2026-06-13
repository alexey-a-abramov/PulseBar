//
//  PBThermal.m — CPU temperature (IOHIDEventSystemClient) + fan (AppleSMC).
//  See PBThermal.h. Both backends were probed on the build machine
//  (MacBookPro17,1, M1): 57 temperature services with real °C, fan 0 at
//  ~1200 rpm. Everything degrades to hasTemp/hasFan = 0 where the SPI is absent.
//
#import "PBThermal.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#pragma mark - IOHIDEventSystemClient (temperature)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matches);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define HID_TEMP_FIELD (kIOHIDEventTypeTemperature << 16)

// CPU-sensor name tiers, most-specific first. We pick the first tier that
// matches any sensor and average just those, so a representative "CPU temp"
// comes from the core-cluster die sensors rather than the battery or ANE.
static BOOL nameMatchesTier(NSString *n, int tier) {
    switch (tier) {
        case 0: return [n containsString:@"tdie"];               // PMU/PMU2 tdie* — die temps
        case 1: return [n containsString:@"ACC MTR"];            // pACC/eACC core clusters
        case 2: return [n containsString:@"SOC MTR"] || [n containsString:@"SOC Die"];
        case 3: return [n.lowercaseString containsString:@"cpu"];
        default: return YES;                                     // anything valid
    }
}

// Cached client + the indices of the chosen-tier CPU sensors within its
// services array, resolved once.
static IOHIDEventSystemClientRef gHID;
static CFArrayRef gServices;
static NSArray<NSNumber *> *gCPUIdx;

static void thermalInit(void) {
    int page = 0xff00 /* kHIDPage_AppleVendor */, usage = 5 /* temperature sensor */;
    CFNumberRef p = CFNumberCreate(0, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(0, kCFNumberIntType, &usage);
    const void *k[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *v[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(0, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u);

    gHID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gHID) { CFRelease(match); return; }
    IOHIDEventSystemClientSetMatching(gHID, match);
    CFRelease(match);
    gServices = IOHIDEventSystemClientCopyServices(gHID);
    if (!gServices) return;

    long n = CFArrayGetCount(gServices);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:n];
    for (long i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        CFStringRef nm = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        [names addObject:(nm ? (__bridge_transfer NSString *)nm : @"")];
    }
    // Choose the most-specific tier that any sensor satisfies.
    for (int tier = 0; tier <= 4 && gCPUIdx.count == 0; tier++) {
        NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
        for (long i = 0; i < n; i++)
            if (nameMatchesTier(names[i], tier)) [idx addObject:@(i)];
        if (idx.count) gCPUIdx = idx;
    }
}

static BOOL readTemp(double *avgOut, double *maxOut) {
    static dispatch_once_t once; dispatch_once(&once, ^{ thermalInit(); });
    if (!gServices || gCPUIdx.count == 0) return NO;
    double sum = 0, mx = -1000; int cnt = 0;
    for (NSNumber *ix in gCPUIdx) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, ix.longValue);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        double t = IOHIDEventGetFloatValue(ev, HID_TEMP_FIELD);
        CFRelease(ev);
        if (t > -40 && t < 150) { sum += t; if (t > mx) mx = t; cnt++; }
    }
    if (!cnt) return NO;
    *avgOut = sum / cnt; *maxOut = mx; return YES;
}

#pragma mark - AppleSMC (fan)

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key; SMCVers vers; SMCPLimit pLimit; SMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; char bytes[32];
} SMCParam;
enum { kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t gSMC;
static BOOL gSMCReady, gSMCTried;

static UInt32 fourcc(const char *s) {
    return ((UInt32)(UInt8)s[0] << 24) | ((UInt32)(UInt8)s[1] << 16) | ((UInt32)(UInt8)s[2] << 8) | (UInt32)(UInt8)s[3];
}

static void smcInit(void) {
    gSMCTried = YES;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return;
    if (IOServiceOpen(svc, mach_task_self(), 0, &gSMC) == KERN_SUCCESS) gSMCReady = YES;
    IOObjectRelease(svc);
}

// Read an SMC key as a double, decoding the common numeric types. Returns NO if
// the key is absent or the call fails.
static BOOL smcRead(const char *key, double *out) {
    if (!gSMCReady) return NO;
    SMCParam in = {0}, info = {0};
    in.key = fourcc(key); in.data8 = kSMCGetKeyInfo;
    size_t sz = sizeof(SMCParam);
    if (IOConnectCallStructMethod(gSMC, 2, &in, sizeof in, &info, &sz) != KERN_SUCCESS) return NO;
    UInt32 type = info.keyInfo.dataType, size = info.keyInfo.dataSize;

    SMCParam rd = {0}, o = {0};
    rd.key = fourcc(key); rd.keyInfo.dataSize = size; rd.data8 = kSMCReadKey;
    sz = sizeof(SMCParam);
    if (IOConnectCallStructMethod(gSMC, 2, &rd, sizeof rd, &o, &sz) != KERN_SUCCESS) return NO;

    const UInt8 *b = (const UInt8 *)o.bytes;
    if (type == fourcc("flt ")) { float f; memcpy(&f, b, 4); *out = f; return YES; }
    if (type == fourcc("fpe2")) { *out = (double)((b[0] << 8) | b[1]) / 4.0; return YES; }   // Intel fans
    if (type == fourcc("ui8 ") || size == 1) { *out = b[0]; return YES; }
    if (type == fourcc("ui16") || size == 2) { *out = (b[0] << 8) | b[1]; return YES; }
    if (type == fourcc("ui32") || size == 4) { *out = (UInt32)((b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3]); return YES; }
    return NO;
}

static BOOL readFan(double *rpmOut, double *maxOut) {
    if (!gSMCTried) smcInit();
    if (!gSMCReady) return NO;
    double rpm = 0, mx = 0;
    if (!smcRead("F0Ac", &rpm)) return NO;          // primary fan actual rpm
    smcRead("F0Mx", &mx);
    if (rpm < 0 || rpm > 100000) return NO;
    *rpmOut = rpm; *maxOut = (mx > 0 && mx < 100000) ? mx : 0;
    return YES;
}

#pragma mark - public

PBThermalSample PBThermalRead(void) {
    PBThermalSample s = (PBThermalSample){0};
    double avg = 0, mx = 0;
    if (readTemp(&avg, &mx)) { s.hasTemp = 1; s.cpuTempC = avg; s.cpuTempMaxC = mx; }
    double rpm = 0, fmx = 0;
    if (readFan(&rpm, &fmx)) { s.hasFan = 1; s.fanRPM = rpm; s.fanMaxRPM = fmx; }
    return s;
}
