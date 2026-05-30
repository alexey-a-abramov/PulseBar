//
//  Queries.m — read-only status answers for the voice agent.
//
//  Each answer is a short, TTS-friendly sentence built from the existing
//  Stats.* samplers and Controls.* getters. This module performs ZERO writes
//  or side effects beyond the sampling the getters already do.
//
#import "Queries.h"
#import "Stats.h"
#import "Controls.h"
#import <unistd.h>

@implementation PBQueries

// Round to a whole-number percent, clamped to [0,100].
static int pbPct(double v) {
    long r = lroundl(v);
    if (r < 0) r = 0;
    if (r > 100) r = 100;
    return (int)r;
}

// Bytes → GB as a string with one decimal place (e.g. "13.7").
static NSString *pbGB(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.1f", (double)bytes / 1e9];
}

+ (NSString *)answerBattery {
    BatteryInfo b = StatsBattery();
    if (!b.hasBattery) {
        return @"This Mac doesn't have a battery.";
    }
    int pct = pbPct(b.percent);
    if (b.charging) {
        // On AC. If fully (or essentially) charged, say so; otherwise "charging".
        if (pct >= 100) {
            return @"Battery is 100% on AC power.";
        }
        return [NSString stringWithFormat:@"Battery is %d%% and charging.", pct];
    }
    // On battery. Append remaining time when known.
    int mins = b.timeToEmptyMin;
    if (mins > 0) {
        int h = mins / 60;
        int mn = mins % 60;
        if (h > 0 && mn > 0) {
            return [NSString stringWithFormat:@"Battery is %d%%, about %d hour%s %d minute%s left.",
                    pct, h, h == 1 ? "" : "s", mn, mn == 1 ? "" : "s"];
        } else if (h > 0) {
            return [NSString stringWithFormat:@"Battery is %d%%, about %d hour%s left.",
                    pct, h, h == 1 ? "" : "s"];
        } else {
            return [NSString stringWithFormat:@"Battery is %d%%, about %d minute%s left.",
                    pct, mn, mn == 1 ? "" : "s"];
        }
    }
    return [NSString stringWithFormat:@"Battery is %d%% on battery.", pct];
}

+ (NSString *)answerCPU {
    // CPU is a rate sampler: prime, wait briefly, then read a real value.
    StatsCPUPercent();
    usleep(300 * 1000);
    double cpu = StatsCPUPercent();
    return [NSString stringWithFormat:@"CPU is at %d%%.", pbPct(cpu)];
}

+ (NSString *)answerMemory {
    MemInfo m = StatsMemory();
    return [NSString stringWithFormat:@"Memory is %d%% used, %@ of %@ GB.",
            pbPct(m.usedPct), pbGB(m.usedBytes), pbGB(m.totalBytes)];
}

+ (NSString *)answerDisk {
    DiskSpace d = StatsDiskSpace();
    return [NSString stringWithFormat:@"%@ GB free of %@ GB.",
            pbGB(d.freeBytes), pbGB(d.totalBytes)];
}

+ (NSString *)answerUptime {
    double secs = StatsUptimeSeconds();
    long total = (long)secs;
    int days = (int)(total / 86400);
    int hours = (int)((total % 86400) / 3600);
    int mins = (int)((total % 3600) / 60);

    if (days > 0) {
        if (hours > 0) {
            return [NSString stringWithFormat:@"Up %d day%s, %d hour%s.",
                    days, days == 1 ? "" : "s", hours, hours == 1 ? "" : "s"];
        }
        return [NSString stringWithFormat:@"Up %d day%s.", days, days == 1 ? "" : "s"];
    }
    if (hours > 0) {
        if (mins > 0) {
            return [NSString stringWithFormat:@"Up %d hour%s, %d minute%s.",
                    hours, hours == 1 ? "" : "s", mins, mins == 1 ? "" : "s"];
        }
        return [NSString stringWithFormat:@"Up %d hour%s.", hours, hours == 1 ? "" : "s"];
    }
    // Less than an hour (always at least a minute, since uptime > 0).
    if (mins < 1) mins = 1;
    return [NSString stringWithFormat:@"Up %d minute%s.", mins, mins == 1 ? "" : "s"];
}

+ (NSString *)answerVolume {
    if (CtlGetMute()) {
        return @"Muted.";
    }
    int pct = pbPct((double)CtlGetVolume() * 100.0);
    return [NSString stringWithFormat:@"Volume is %d%%.", pct];
}

+ (NSString *)answerBrightness {
    float b = CtlGetBrightness();
    if (b < 0.0f) {
        return @"Brightness isn't available.";
    }
    int pct = pbPct((double)b * 100.0);
    return [NSString stringWithFormat:@"Brightness is %d%%.", pct];
}

+ (NSString *)answerNowPlaying {
    // Best-effort and non-blocking-friendly: kick a refresh, then give the
    // async result a brief moment to land on the main queue. We never block
    // indefinitely — if nothing arrives we just report the last-known state.
    CtlMediaInit();
    CtlMediaRefresh();

    // Spin the run loop briefly so dispatched results can populate the cache.
    // Capped well under half a second so we don't hang the caller.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.30];
    NowPlaying np = CtlNowPlaying();
    while (!np.hasInfo && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        np = CtlNowPlaying();
    }

    if (!np.hasInfo) {
        return @"Nothing is playing.";
    }

    NSString *title = (np.title[0] != '\0')
        ? [NSString stringWithUTF8String:np.title] : nil;
    NSString *artist = (np.artist[0] != '\0')
        ? [NSString stringWithUTF8String:np.artist] : nil;

    if (title.length == 0) {
        // Have info but no usable title — keep it graceful.
        return np.isPlaying ? @"Something is playing." : @"Playback is paused.";
    }

    if (np.isPlaying) {
        if (artist.length > 0) {
            return [NSString stringWithFormat:@"Playing %@ by %@.", title, artist];
        }
        return [NSString stringWithFormat:@"Playing %@.", title];
    } else {
        if (artist.length > 0) {
            return [NSString stringWithFormat:@"Paused: %@ by %@.", title, artist];
        }
        return [NSString stringWithFormat:@"Paused: %@.", title];
    }
}

+ (NSString *)answer:(NSString *)what {
    if (what.length == 0) return nil;

    if ([what isEqualToString:@"battery"])     return [self answerBattery];
    if ([what isEqualToString:@"cpu"])         return [self answerCPU];
    if ([what isEqualToString:@"memory"])      return [self answerMemory];
    if ([what isEqualToString:@"disk"])        return [self answerDisk];
    if ([what isEqualToString:@"uptime"])      return [self answerUptime];
    if ([what isEqualToString:@"volume"])      return [self answerVolume];
    if ([what isEqualToString:@"brightness"])  return [self answerBrightness];
    if ([what isEqualToString:@"now_playing"]) return [self answerNowPlaying];

    return nil; // unknown key
}

@end
