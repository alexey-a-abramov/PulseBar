//
//  Controls.m
//
#import "Controls.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

// ===========================================================================
//  Volume / mute  (CoreAudio — public API)
// ===========================================================================
static AudioDeviceID defaultOutput(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    AudioDeviceID dev = 0; UInt32 sz = sizeof(dev);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &dev);
    return dev;
}

float CtlGetVolume(void) {
    AudioDeviceID d = defaultOutput(); if (!d) return 0;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyVolumeScalar,
                                     kAudioDevicePropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    Float32 v = 0; UInt32 sz = sizeof(v);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v) != noErr) {
        Float32 v1 = 0, v2 = 0;
        a.mElement = 1; sz = sizeof(v1); AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v1);
        a.mElement = 2; sz = sizeof(v2); AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &v2);
        v = (v1 + v2) / 2.0f;
    }
    return v;
}

void CtlSetVolume(float v) {
    AudioDeviceID d = defaultOutput(); if (!d) return;
    if (v < 0) v = 0; if (v > 1) v = 1;
    Float32 val = v;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyVolumeScalar,
                                     kAudioDevicePropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    if (AudioObjectHasProperty(d, &a) &&
        AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(val), &val) == noErr) return;
    a.mElement = 1; AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(val), &val);
    a.mElement = 2; AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(val), &val);
}

BOOL CtlGetMute(void) {
    AudioDeviceID d = defaultOutput(); if (!d) return NO;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyMute,
                                     kAudioDevicePropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    UInt32 m = 0, sz = sizeof(m);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &m) != noErr) return NO;
    return m != 0;
}

void CtlSetMute(BOOL mute) {
    AudioDeviceID d = defaultOutput(); if (!d) return;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyMute,
                                     kAudioDevicePropertyScopeOutput,
                                     kAudioObjectPropertyElementMain };
    UInt32 m = mute ? 1 : 0;
    if (AudioObjectHasProperty(d, &a))
        AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(m), &m);
}

// ===========================================================================
//  Brightness  (DisplayServices SPI via dlsym)
// ===========================================================================
typedef int (*DSGetFn)(CGDirectDisplayID, float *);
typedef int (*DSSetFn)(CGDirectDisplayID, float);
static DSGetFn g_dsGet = NULL;
static DSSetFn g_dsSet = NULL;

static void loadDS(void) {
    static int done = 0; if (done) return; done = 1;
    void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (ds) { g_dsGet = (DSGetFn)dlsym(ds, "DisplayServicesGetBrightness");
              g_dsSet = (DSSetFn)dlsym(ds, "DisplayServicesSetBrightness"); }
}

float CtlGetBrightness(void) {
    loadDS(); if (!g_dsGet) return -1;
    float b = -1; g_dsGet(CGMainDisplayID(), &b); return b;
}

void CtlSetBrightness(float v) {
    loadDS(); if (!g_dsSet) return;
    if (v < 0) v = 0; if (v > 1) v = 1;
    g_dsSet(CGMainDisplayID(), v);
}

// ===========================================================================
//  Media  (MediaRemote SPI via dlsym)
// ===========================================================================
typedef void    (*MRGetNPFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*MRSendFn)(int, CFDictionaryRef);
static MRGetNPFn   g_mrGet  = NULL;
static MRSendFn    g_mrSend = NULL;
static CFStringRef *g_kTitle = NULL, *g_kArtist = NULL, *g_kRate = NULL;
static NowPlaying  g_np;

static void loadMR(void) {
    static int done = 0; if (done) return; done = 1;
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (mr) {
        g_mrGet  = (MRGetNPFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        g_mrSend = (MRSendFn)dlsym(mr, "MRMediaRemoteSendCommand");
        g_kTitle  = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoTitle");
        g_kArtist = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoArtist");
        g_kRate   = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    }
}

void CtlMediaInit(void) { loadMR(); }

void CtlMediaRefresh(void) {
    loadMR(); if (!g_mrGet) return;
    g_mrGet(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NowPlaying np; memset(&np, 0, sizeof(np));
        if (info) {
            np.hasInfo = 1;
            if (g_kTitle) { CFStringRef t = CFDictionaryGetValue(info, *g_kTitle);
                            if (t) CFStringGetCString(t, np.title, sizeof(np.title), kCFStringEncodingUTF8); }
            if (g_kArtist){ CFStringRef a = CFDictionaryGetValue(info, *g_kArtist);
                            if (a) CFStringGetCString(a, np.artist, sizeof(np.artist), kCFStringEncodingUTF8); }
            if (g_kRate)  { CFNumberRef r = CFDictionaryGetValue(info, *g_kRate);
                            double rate = 0; if (r) CFNumberGetValue(r, kCFNumberDoubleType, &rate);
                            np.isPlaying = rate > 0.01; }
        }
        g_np = np;
    });
}

NowPlaying CtlNowPlaying(void) { return g_np; }
void CtlMediaPlayPause(void) { loadMR(); if (g_mrSend) g_mrSend(2, NULL); }  // kMRTogglePlayPause
void CtlMediaNext(void)      { loadMR(); if (g_mrSend) g_mrSend(4, NULL); }  // kMRNextTrack
void CtlMediaPrev(void)      { loadMR(); if (g_mrSend) g_mrSend(5, NULL); }  // kMRPreviousTrack
