#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

struct AirDockSwipe27Fields {
    uint32_t phase;
    uint32_t motion;
    double progress;
    double velocity;
};

bool air_dockswipe27_decode(CGEventRef source, AirDockSwipe27Fields *out);
bool air_dockswipe27_available(void);
// Caller serializes convert/cancel (input.mm already holds hostInputMutex).
// Returns a retained CGEvent. Does not post it. Returns null unless macOS >=27,
// source is an exact legacy type-30 DockSwipe, and every private API is present.
CGEventRef air_dockswipe27_convert(CGEventRef source, uint64_t timestamp);
// Returns a retained cancel event for an active converted swipe, else null.
CGEventRef air_dockswipe27_cancel(uint64_t timestamp);
