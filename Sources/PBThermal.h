//
//  PBThermal.h — CPU temperature + fan RPM for Apple-Silicon (and Intel) Macs.
//
//  M-series die temperatures are NOT in the SMC; they come from the
//  IOHIDEventSystemClient thermal-sensor services. Fans come from AppleSMC.
//  Both clients are opened once and reused; PBThermalRead() is cheap enough to
//  call at ~0.5 Hz from the 1 Hz sampling tick.
//
#ifndef PULSEBAR_THERMAL_H
#define PULSEBAR_THERMAL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int    hasTemp;     // 1 if a CPU temperature was read
    double cpuTempC;    // representative CPU temperature in °C (avg of die sensors)
    double cpuTempMaxC; // hottest contributing sensor (for the alert colour ramp)
    int    hasFan;      // 1 if a real fan RPM was read
    double fanRPM;      // primary fan speed
    double fanMaxRPM;   // that fan's max (0 if unknown) — for a fill gauge
} PBThermalSample;

// Sample temperature + fan now. Safe on machines lacking the SPI (fields just
// report hasTemp/hasFan = 0). Main-thread use like the rest of sampling.
PBThermalSample PBThermalRead(void);

#ifdef __cplusplus
}
#endif

#endif /* PULSEBAR_THERMAL_H */
