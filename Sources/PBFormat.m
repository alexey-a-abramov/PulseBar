//
//  PBFormat.m
//
#import "PBFormat.h"

NSString *PBFmtRate(double bps) {
    const char *u[] = {"B", "K", "M", "G"};
    int i = 0; double v = bps;
    while (v >= 1024.0 && i < 3) { v /= 1024.0; i++; }
    return (i == 0) ? [NSString stringWithFormat:@"%.0f%s", v, u[i]]
                    : [NSString stringWithFormat:@"%.1f%s", v, u[i]];
}
double PBToGB(uint64_t b) { return (double)b / (1024.0 * 1024.0 * 1024.0); }
NSString *PBFmtClock(double sec) { int s = sec < 0 ? 0 : (int)sec; return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60]; }
NSString *PBFmtUptime(double sec) {
    int s = (int)sec, d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    if (d > 0) return [NSString stringWithFormat:@"%dd %dh", d, h];
    if (h > 0) return [NSString stringWithFormat:@"%dh %dm", h, m];
    return [NSString stringWithFormat:@"%dm", m];
}
