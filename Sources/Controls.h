//
//  Controls.h — actionable system controls reclaimed onto the bar.
//  Volume/mute (CoreAudio, public) · brightness (DisplayServices SPI) ·
//  media now-playing + transport (MediaRemote SPI).
//
#import <Foundation/Foundation.h>

// --- Output volume / mute (0..1) -------------------------------------------
float CtlGetVolume(void);
void  CtlSetVolume(float v);
BOOL  CtlGetMute(void);
void  CtlSetMute(BOOL mute);

// --- Display brightness (0..1; returns -1 if unavailable) ------------------
float CtlGetBrightness(void);
void  CtlSetBrightness(float v);

// --- Now Playing / media transport -----------------------------------------
typedef struct {
    char   title[256];
    char   artist[256];
    int    isPlaying;
    int    hasInfo;
    double elapsed;     // seconds
    double duration;    // seconds (0 if unknown)
} NowPlaying;

void       CtlMediaInit(void);       // load the framework
void       CtlMediaRefresh(void);    // async-refresh the cached Now Playing
NowPlaying CtlNowPlaying(void);      // last-known Now Playing
void       CtlMediaPlayPause(void);
void       CtlMediaNext(void);
void       CtlMediaPrev(void);
