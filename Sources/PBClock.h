//
//  PBClock.h — world-clock master city list + DST-correct time formatting.
//  Pure Foundation; NSTimeZone resolves daylight-saving/summer-time on its own,
//  so a city is just a (short label, full name, IANA tz id) tuple and every
//  query reflects whatever offset that zone is on *right now*.
//
#import <Foundation/Foundation.h>

// One city in the master list. `label` is the compact bar caption (e.g. "TYO"),
// `name` the editor-facing name (e.g. "Tokyo"), `tzid` the IANA zone id.
typedef struct { const char *label; const char *name; const char *tzid; } PBCity;

// Curated master list of significant world cities, plus UTC. Order is the
// arg-index a TWCLOCK tile stores, so APPEND new cities — never reorder/remove.
extern const PBCity gCities[];
extern const int gCityCount;

// Index-safe accessor (clamps out-of-range to city 0).
const PBCity *PBCityAt(int idx);

// "HH:MM" (24h) wall-clock time in the city now — DST/summer-time applied.
NSString *PBClockTimeForCity(int idx);

// Hour offset vs. the local zone right now, as a compact tag: "+9", "−5", or
// "" when the city shares the local offset. Half-hour zones show "+5½".
NSString *PBClockOffsetTag(int idx);

// Calendar-day delta vs. local now: -1 (yesterday), 0 (today), +1 (tomorrow).
int PBClockDayDelta(int idx);

// Test seam: freeze "now" so clock output is deterministic (golden render).
// Pass nil to resume using the real current time.
void PBClockSetFrozenNow(NSDate *fixed);
