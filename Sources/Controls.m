//
//  Controls.m
//
#import "Controls.h"
#import "PBProcess.h"
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
static CFStringRef *g_kTitle = NULL, *g_kArtist = NULL, *g_kRate = NULL, *g_kElapsed = NULL, *g_kDuration = NULL;
static NowPlaying  g_np;

static void loadMR(void) {
    static int done = 0; if (done) return; done = 1;
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (mr) {
        g_mrGet  = (MRGetNPFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        g_mrSend = (MRSendFn)dlsym(mr, "MRMediaRemoteSendCommand");
        g_kTitle    = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoTitle");
        g_kArtist   = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoArtist");
        g_kRate     = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
        g_kElapsed  = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoElapsedTime");
        g_kDuration = (CFStringRef *)dlsym(mr, "kMRMediaRemoteNowPlayingInfoDuration");
    }
}

// ---- configurable media app via AppleScript (default Spotify; MediaRemote fallback) ----
static NSString      *g_mediaApp = @"Spotify";
static NowPlaying     g_appNP;          // from the configured app (main-thread only)
static dispatch_queue_t g_mq;           // serial queue for (blocking) AppleScript

void CtlSetMediaApp(NSString *app) { if (app.length) g_mediaApp = [app copy]; }
NSString *CtlMediaApp(void) { return g_mediaApp; }

// Run osascript and return trimmed stdout. BLOCKING — only call on g_mq.
static NSString *osa(NSString *src) { return PBRunCapture(@"/usr/bin/osascript", @[@"-e", src]); }

static NowPlaying queryApp(NSString *app) {
    NowPlaying np; memset(&np, 0, sizeof(np));
    NSString *dur = [app isEqualToString:@"Music"] ? @"((duration of current track) as text)"
                                                   : @"(((duration of current track) / 1000) as text)";
    NSString *src = [NSString stringWithFormat:
        @"with timeout of 2 seconds\n"
        @"if application \"%@\" is running then\n"
        @"tell application \"%@\"\n"
        @"if player state is stopped then\nreturn \"stopped\"\nend if\n"
        @"return (player state as text) & tab & (name of current track) & tab & (artist of current track) & tab & (player position as text) & tab & %@\n"
        @"end tell\nelse\nreturn \"notrunning\"\nend if\nend timeout", app, app, dur];
    NSString *out = osa(src);
    if (out.length && ![out isEqualToString:@"notrunning"] && ![out isEqualToString:@"stopped"]) {
        NSArray<NSString *> *p = [out componentsSeparatedByString:@"\t"];
        if (p.count >= 3) {
            np.hasInfo = 1;
            np.isPlaying = [p[0] isEqualToString:@"playing"];
            strncpy(np.title,  p[1].UTF8String, sizeof(np.title) - 1);
            strncpy(np.artist, p[2].UTF8String, sizeof(np.artist) - 1);
            if (p.count >= 5) { np.elapsed = p[3].doubleValue; np.duration = p[4].doubleValue; }
        }
    }
    return np;
}

void CtlMediaInit(void) { loadMR(); g_mq = dispatch_queue_create("ai.pulsebar.media", DISPATCH_QUEUE_SERIAL); }

void CtlMediaRefresh(void) {
    if (g_mq) {
        NSString *app = g_mediaApp;
        dispatch_async(g_mq, ^{ NowPlaying np = queryApp(app); dispatch_async(dispatch_get_main_queue(), ^{ g_appNP = np; }); });
    }
    loadMR();
    if (g_mrGet) g_mrGet(dispatch_get_main_queue(), ^(CFDictionaryRef info) {   // fallback (browsers etc.)
        NowPlaying np; memset(&np, 0, sizeof(np));
        if (info) {
            np.hasInfo = 1;
            if (g_kTitle)    { CFStringRef t = CFDictionaryGetValue(info, *g_kTitle);   if (t) CFStringGetCString(t, np.title, sizeof(np.title), kCFStringEncodingUTF8); }
            if (g_kArtist)   { CFStringRef a = CFDictionaryGetValue(info, *g_kArtist);  if (a) CFStringGetCString(a, np.artist, sizeof(np.artist), kCFStringEncodingUTF8); }
            if (g_kRate)     { CFNumberRef r = CFDictionaryGetValue(info, *g_kRate); double rate = 0; if (r) CFNumberGetValue(r, kCFNumberDoubleType, &rate); np.isPlaying = rate > 0.01; }
            if (g_kElapsed)  { CFNumberRef n = CFDictionaryGetValue(info, *g_kElapsed);  if (n) CFNumberGetValue(n, kCFNumberDoubleType, &np.elapsed); }
            if (g_kDuration) { CFNumberRef n = CFDictionaryGetValue(info, *g_kDuration); if (n) CFNumberGetValue(n, kCFNumberDoubleType, &np.duration); }
        }
        g_np = np;
    });
}

NowPlaying CtlNowPlaying(void) { return g_appNP.hasInfo ? g_appNP : g_np; }

static void mediaCmd(NSString *cmd) {   // cmd: playpause | next track | previous track
    if (!g_mq) g_mq = dispatch_queue_create("ai.pulsebar.media", DISPATCH_QUEUE_SERIAL);
    NSString *app = g_mediaApp;
    dispatch_async(g_mq, ^{
        NSString *running = osa([NSString stringWithFormat:@"if application \"%@\" is running then\nreturn \"y\"\nelse\nreturn \"n\"\nend if", app]);
        if ([running isEqualToString:@"y"]) {
            osa([NSString stringWithFormat:@"with timeout of 3 seconds\ntell application \"%@\" to %@\nend timeout", app, cmd]);
        } else if ([cmd isEqualToString:@"playpause"]) {
            osa([NSString stringWithFormat:@"tell application \"%@\" to play", app]);   // launch + play
        } else {
            loadMR(); if (g_mrSend) g_mrSend([cmd isEqualToString:@"next track"] ? 4 : 5, NULL);
        }
        NowPlaying np = queryApp(app);
        dispatch_async(dispatch_get_main_queue(), ^{ g_appNP = np; });
    });
}

void CtlMediaPlayPause(void) { mediaCmd(@"playpause"); }
void CtlMediaNext(void)      { mediaCmd(@"next track"); }
void CtlMediaPrev(void)      { mediaCmd(@"previous track"); }

// Seek to `fraction` of the current track. Uses the cached duration (seconds);
// both Spotify and Music take `player position` in seconds.
void CtlMediaSeek(float fraction) {
    if (!g_mq) g_mq = dispatch_queue_create("ai.pulsebar.media", DISPATCH_QUEUE_SERIAL);
    double dur = g_appNP.duration;
    if (dur <= 0) return;                                   // unknown length → ignore
    if (fraction < 0) fraction = 0; if (fraction > 1) fraction = 1;
    double secs = fraction * dur;
    NSString *app = g_mediaApp;
    dispatch_async(g_mq, ^{
        osa([NSString stringWithFormat:@"with timeout of 2 seconds\ntell application \"%@\" to set player position to %.1f\nend timeout", app, secs]);
        NowPlaying np = queryApp(app);
        dispatch_async(dispatch_get_main_queue(), ^{ g_appNP = np; });
    });
}
