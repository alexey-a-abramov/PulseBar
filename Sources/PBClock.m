//
//  PBClock.m — world-clock master city list + DST-correct formatting (PBClock.h).
//
#import "PBClock.h"

// Significant world cities, west→east-ish. IANA zone ids carry their own DST
// rules, so London auto-switches GMT/BST, Sydney AEST/AEDT, etc. APPEND only —
// the index is persisted as a tile's `arg`.
const PBCity gCities[] = {
    { "HNL", "Honolulu",     "Pacific/Honolulu"    },
    { "LA",  "Los Angeles",  "America/Los_Angeles" },
    { "SF",  "San Francisco","America/Los_Angeles" },
    { "DEN", "Denver",       "America/Denver"      },
    { "CHI", "Chicago",      "America/Chicago"     },
    { "NYC", "New York",     "America/New_York"    },
    { "TOR", "Toronto",      "America/Toronto"     },
    { "SAO", "São Paulo",    "America/Sao_Paulo"   },
    { "UTC", "UTC",          "UTC"                 },
    { "LDN", "London",       "Europe/London"       },
    { "PAR", "Paris",        "Europe/Paris"        },
    { "BER", "Berlin",       "Europe/Berlin"       },
    { "MAD", "Madrid",       "Europe/Madrid"       },
    { "ROM", "Rome",         "Europe/Rome"         },
    { "AMS", "Amsterdam",    "Europe/Amsterdam"    },
    { "STO", "Stockholm",    "Europe/Stockholm"    },
    { "ATH", "Athens",       "Europe/Athens"       },
    { "IST", "Istanbul",     "Europe/Istanbul"     },
    { "MOW", "Moscow",       "Europe/Moscow"       },
    { "DXB", "Dubai",        "Asia/Dubai"          },
    { "IND", "Mumbai",       "Asia/Kolkata"        },
    { "BLR", "Bengaluru",    "Asia/Kolkata"        },
    { "SIN", "Singapore",    "Asia/Singapore"      },
    { "HK",  "Hong Kong",    "Asia/Hong_Kong"      },
    { "PEK", "Beijing",      "Asia/Shanghai"       },
    { "TYO", "Tokyo",        "Asia/Tokyo"          },
    { "SEL", "Seoul",        "Asia/Seoul"          },
    { "SYD", "Sydney",       "Australia/Sydney"    },
    { "AKL", "Auckland",     "Pacific/Auckland"    },
};
const int gCityCount = (int)(sizeof(gCities) / sizeof(gCities[0]));

const PBCity *PBCityAt(int idx) {
    if (idx < 0 || idx >= gCityCount) idx = 0;
    return &gCities[idx];
}

// "Now" — the real current time, unless a test froze it (golden render).
static NSDate *gFrozenNow;
void PBClockSetFrozenNow(NSDate *fixed) { gFrozenNow = fixed; }
static NSDate *clockNow(void) { return gFrozenNow ?: [NSDate date]; }

// Cached NSTimeZone per city id (timeZoneWithName parses the zoneinfo file each
// call otherwise). Main-thread only, like all bar drawing.
static NSTimeZone *zoneForCity(int idx) {
    static NSMutableDictionary<NSString *, NSTimeZone *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *tzid = @(PBCityAt(idx)->tzid);
    NSTimeZone *tz = cache[tzid];
    if (!tz) { tz = [NSTimeZone timeZoneWithName:tzid] ?: NSTimeZone.localTimeZone; cache[tzid] = tz; }
    return tz;
}

NSString *PBClockTimeForCity(int idx) {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; }
    df.timeZone = zoneForCity(idx);
    return [df stringFromDate:clockNow()];
}

// Whole/half-hour offset of the city vs. the local zone, evaluated for *now* so
// asymmetric DST transitions are honoured.
static double offsetHoursVsLocal(int idx) {
    NSDate *now = clockNow();
    NSInteger city  = [zoneForCity(idx) secondsFromGMTForDate:now];
    NSInteger local = [NSTimeZone.localTimeZone secondsFromGMTForDate:now];
    return (city - local) / 3600.0;
}

NSString *PBClockOffsetTag(int idx) {
    double h = offsetHoursVsLocal(idx);
    if (h == 0) return @"";
    NSString *sign = h > 0 ? @"+" : @"−";   // U+2212 minus, matches the bar's typography
    double a = fabs(h);
    int whole = (int)a;
    BOOL half = (a - whole) >= 0.25 && (a - whole) < 0.75;
    return half ? [NSString stringWithFormat:@"%@%d½", sign, whole]
                : [NSString stringWithFormat:@"%@%d", sign, whole];
}

int PBClockDayDelta(int idx) {
    NSDate *now = clockNow();
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];

    cal.timeZone = NSTimeZone.localTimeZone;
    NSInteger localDay = [cal ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitEra forDate:now];
    cal.timeZone = zoneForCity(idx);
    NSInteger cityDay = [cal ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitEra forDate:now];

    NSInteger d = cityDay - localDay;
    return d < 0 ? -1 : (d > 0 ? 1 : 0);
}
