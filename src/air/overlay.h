#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*AirSpaceChoose)(int slot);
typedef void (*AirSpaceLoop)(int enabled);
typedef void (*AirSpaceReconnect)(void);

void air_overlay_attach(void *host_view);
void air_overlay_setup(AirSpaceChoose choose, AirSpaceLoop loop);
void air_overlay_setup_reconnect(AirSpaceReconnect reconnect);
void air_overlay_state(int active_count, int current_slot, int flags);
int air_overlay_pointer(double x, double y);
int air_overlay_visible(void);
void air_overlay_shutdown(void);

#ifdef __cplusplus
}
#endif
