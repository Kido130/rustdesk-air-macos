#pragma once
#include <stddef.h>
#include <stdint.h>
#include "shell.h"
#include "overlay.h"
#include "spaces.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct AirDisplaySpec {
    uint32_t logical_width, logical_height, pixel_width, pixel_height;
} AirDisplaySpec;
int air_display_current(AirDisplaySpec *spec);
void air_microphone_menu(void (*callback)(int), int enabled);
int air_display_match(const AirDisplaySpec *spec);
int air_display_restore(void);
int air_display_shutdown(void);
void air_client_match_display(int enabled, int fullscreen);
int air_chosen_display_match(void);
int air_chosen_remote_mode(void);
int air_chosen_remote_spaces(void);
int air_chosen_raw_contacts(void);
typedef void (*AirNativeEvent)(const uint8_t *bytes, size_t len, uint64_t generation);
typedef void (*AirReleaseInput)(uint64_t generation);
typedef void (*AirNativeSpaceSwipe)(int phase, int finger_direction, uint64_t generation);
void air_input_space_swipe_callback(AirNativeSpaceSwipe callback);
int air_input_capture_test(int seconds, const char *path);
void air_input_capture_schedule(int seconds, const char *path);
int air_input_setup(AirNativeEvent event, AirReleaseInput release);
int air_keyboard_probe_configure(int enabled);
void air_keyboard_probe_ready(int ready);
void air_keyboard_probe_shutdown(void);
int air_cursor_probe_configure(int enabled);
void air_cursor_probe_ready(int ready);
void air_cursor_probe_shutdown(void);
int air_cursor_probe_enabled(void);
void air_cursor_probe_capture_drawable(void *command, void *texture);
void air_input_connected(int connected);
uint64_t air_input_generation(void);
void air_input_raw_enabled(int enabled);
int air_host_raw_supported(void);
int air_client_raw_supported(void);
int air_raw_probe_configure(int seconds);
int air_raw_full_configure(int enabled);
int air_raw_wire_version(void);
void air_input_shutdown(void);
int air_input_grabbing(void);
int air_host_input_begin(int id,int requested_raw);
int air_host_input_event(int id, const uint8_t *bytes, size_t len);
void air_host_edge_drag_event(int id, int kind, int x, int y);
void air_host_input_release(int id);
void air_host_input_end(int id);
void air_host_input_shutdown(void);
void air_input_metrics(uint64_t *sent, uint64_t *gesture, uint64_t *touch, uint64_t *posted, uint64_t *escaped);
void air_raw_metrics(uint64_t *sent, uint64_t *posted, uint64_t *stale, uint64_t *contact_duplicates);
typedef void (*AirInput)(int kind, double x, double y, uint32_t code, uint64_t flags, void *context);
int air_app_init(AirInput input, void *context, int host);
int air_is_host_bundle(void);
const char *air_choose_pairing(void);
int air_choose_mode(void);
void air_host_pairing(const char *path);
void air_show_error(const char *message);
void air_app_run(void);
void air_app_stop(void);
typedef void (*AirAppCleanup)(void *context);
void air_app_set_cleanup(AirAppCleanup cleanup, void *context);
void air_status(const char *message, int error);
int air_hardware_support(int codec);
int air_exact_begin(uint32_t width, uint32_t height, int full, size_t upload_bytes);
int air_exact_patch(uint32_t x, uint32_t y, uint32_t width, uint32_t height, const uint8_t *bytes, size_t len);
int air_exact_commit(void);
void air_exact_abort(void);
int air_decode(const uint8_t *bytes, size_t len);
void air_decoder_reset(void);
void air_cursor(double x, double y);
void air_request_draw(void);
int air_cursor_init(void *device);
int air_cursor_shape(uint64_t id, uint32_t w, uint32_t h, uint32_t hx, uint32_t hy, const uint8_t *rgba, size_t len);
void air_cursor_select(uint64_t id);
void air_cursor_reset(void);
void air_surface_clear(void);
void air_cursor_position(double x, double y, int local);
void air_cursor_draw(void *encoder, double logical_w, double logical_h, double fit_x, double fit_y, double backing_scale);
int air_cursor_selftest(void);
void air_cursor_metrics(uint64_t *uploads, uint64_t *draws, uint64_t *moves);
void air_cursor_probe_shape(uint64_t *id, uint32_t *width, uint32_t *height, uint32_t *hot_x, uint32_t *hot_y);
void air_input_dimensions(uint32_t width, uint32_t height);
void air_video_bytes(size_t bytes);
const char *air_last_error(void);
void air_set_error(const char *message);
const char *air_metrics(void);
uint32_t air_builtin_display(void);
typedef struct AirStageTiming {
    uint64_t calls, total_us, max_us;
} AirStageTiming;
typedef struct AirCaptureProfile {
    uint64_t complete_callbacks, latest_overwrites, next_successes;
    AirStageTiming encode_submit, encode_complete_wait;
} AirCaptureProfile;
void *air_capture_start(uint32_t display, int profile);
uint32_t air_capture_video_bitrate(void *capture);
int air_capture_set_video_bitrate(void *capture, uint32_t bits_per_second);
int air_capture_next(void *capture, const uint8_t **data, size_t *len, uint32_t *width, uint32_t *height, uint32_t *stride, uint32_t timeout_ms);
void air_capture_release_frame(void *capture);
void air_capture_stop(void *capture);
void air_capture_stop_profiled(void *capture, AirCaptureProfile *profile);
int air_encode(void *capture, int codec, const uint8_t **data, size_t *len, int force_key);
int air_encode_submit(void *capture, int codec, int force_key);
int air_encode_finish(void *capture, const uint8_t **data, size_t *len);
int air_codec_async_selftest(int codec);
int air_set_video_bitrate(uint32_t bits_per_second);
int air_native_selftest(void);
int air_transition_selftest(void);
int air_codec_selftest(int codec);
#ifdef __cplusplus
}
#endif
