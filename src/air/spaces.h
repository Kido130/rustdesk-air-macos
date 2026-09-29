#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Call prepare before display matching, activate after it, restore after display restoration.
// A failed activate retains the recovery journal; caller restores display first,
// then calls air_spaces_restore even after failure. If the original built-in
// display is offline, restoration retains the journal and retries on its return
// while the Host remains open. Host startup accepts only this validated deferred
// state; other recovery errors remain fatal. Shutdown cancels queued retries.
int air_spaces_recover(void);
int air_spaces_prepare(void);
int air_spaces_activate(void);
// Reconcile missed windows against their current physical displays without
// restoring or recreating an already active Remote Spaces session.
int air_spaces_reload(void);
int air_spaces_select(int slot);
// Call after a verified Air-owned left-button window drag has ended at a screen
// edge. The Host revalidates the exact journaled window and adjacent Space.
// Returns 0 only after the window and selected Space are verified at destination.
int air_spaces_transfer_window_edge(uint32_t window_id,int starting_slot,int direction);
// Loop is available only after a distinct-slot switch has passed its actual
// current-Space postcondition in this session. These APIs do not classify a
// swipe or provide continuous finger-following animation.
int air_spaces_loop_supported(void);
// logical_direction: -1 previous (1->3), +1 next (3->1). starting_slot is the
// Space observed when the gesture began. Returns 1 if wrapped, 0 if no longer
// at that boundary, -1 on error; the resulting actual Space is verified.
int air_spaces_wrap_boundary(int starting_slot,int logical_direction);
int air_spaces_restore(void);
// Latches Host shutdown before final restoration so late worker calls cannot
// start another prepare, activation, or Space selection.
int air_spaces_shutdown(void);
int air_spaces_enabled(void);
int air_spaces_supported_for_cross_app_migration(void);
int air_spaces_current_slot(void);
int air_spaces_slot_count(void);
uint64_t air_spaces_slot_id(int slot);
// Read-only JSON for the calling process. Pointer remains valid until the next
// call on the same thread. Never opens Mission Control or changes Spaces.
const char *air_spaces_diagnostics(void);
#ifdef __cplusplus
}
#endif
