# Air → Pro native gesture timestamps: offline audit

The physical Intel Air `RDAICAP1` type-29 packet contains **two separate clocks**. [Apple's Core Graphics documentation](https://developer.apple.com/documentation/coregraphics/cgeventtimestamp) defines the outer CG timestamp in nanoseconds since startup. [Apple's IOHIDFamily implementation](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEvent.cpp) stores the embedded HID timestamp as `AbsoluteTime`, and [Apple's own HID monitor](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/tools/IOHIDEventSystemMonitor.c) creates HID events with `mach_absolute_time()` and applies `mach_timebase_info` when converting HID intervals to microseconds.

The [offline inspector](inspect_capture_timestamps.mm) decoded the saved Air sample on the ARM Pro without posting it:

| Field | Observed value |
|---|---:|
| Original Air outer CG timestamp | 32,244,431,142,481 ns |
| Original Air embedded HID parent timestamp | 32,244,413,469,960 Air mach ticks |
| All five embedded HID child timestamps | 32,244,413,469,960 Air mach ticks |
| Pro local `mach_absolute_time()` at inspection | 930,709,485,857 ticks |
| Pro local `CLOCK_UPTIME_RAW` at inspection | 38,779,561,910,750 ns |
| Pro `mach_timebase_info` | 125/3 ns per mach tick |

`CGEventSetTimestamp(event, proUptimeNs)` changed the outer timestamp only. A subsequent Core Graphics serialization/deserialization still preserved all six Air HID timestamps. `CGEventCopyIOHIDEvent` returned a retained **mutable backing object** on Pro macOS 27: setting its parent and five children to `mach_absolute_time()` changed the original CG event's serialized HID timestamps, including after releasing the copied reference. This means the host can normalize through IOHID APIs without scanning private serialized bytes. The test also spliced a rewritten `0x106d` field for comparison, but that byte edit is unnecessary in production. These are local packet results; they do **not** prove WindowServer accepts or interprets replayed gestures.

The clocks are not interchangeable. On the Pro, one mach tick was about 41.67 ns in this inspection, while the source Air HID ticks were close in magnitude to its outer CG nanoseconds. Forwarding the Air HID ticks unchanged makes them far outside the Pro's local mach-tick clock even after the outer CG timestamp is fixed. [WebKit's macOS wheel-event code](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/mac/WebEventFactory.mm) reads the embedded HID timestamp from `CGEventCopyIOHIDEvent` and converts it as Mach absolute time independently of `NSEvent.timestamp`, so receiving apps can observe this mismatch. No public Apple source found here states which timestamp WindowServer uses for type-29 gesture recognition. A live Air → Pro receiver test must settle that behavior.

The production host now resolves `CGEventCopyIOHIDEvent` and the IOHID timestamp functions dynamically. For serialized scroll/gesture events with an HID attachment, it updates the attached parent and children to the Pro's current Mach ticks, then copies the HID object again to verify that the timestamps, node types, sender IDs, and child counts survived the first reference's release. It rejects an event if an accessor is missing, the attached HID tree is malformed, or its original node timestamps differ within one event. A valid CG event without an HID attachment keeps its CG-only path. Keyboard events never enter the HID normalization path. The [offline packet test](input_packet_test.mm) uses the actual Air sample, confirms the normalized HID serialization equals applying the timestamp setters to an independent copy, roundtrips the normalized event, and observes the production host path with `CGEventPost` replaced by a recorder. Apple's setter may also clear the HID continuous-time option, so byte changes are not assumed to be limited to timestamp fields. The test also checks synthetic keyboard and magnify events with no HID attachment. Both architectures compile; ARM tests pass without posting.

The host checks the copied object's Core Foundation type before the first HID accessor. Client event and release callbacks now carry the generation captured when they were queued. Rust compares that generation to the current native generation while holding the same input lock used for all connection transitions. The native packet test pauses **inside** each callback, after the native queue's own generation check, then disconnects and reconnects before resuming. Its event and release recorders emulate Rust's final epoch check and drop both old callbacks; a new event is accepted. A separate Rust unit test uses a real `Session<NativeUi>` sender and production `control::input_event` / `native_release_input` callbacks around actual native FFI generation transitions, asserting that only current-generation event and release messages enter the new sender. These tests do not prove cross-process gesture delivery, which still needs the prepared live receiver window and a physical Air gesture.

Preserving different per-child time offsets would require a cross-machine timebase mapping; the host currently rejects such packets. Raw replay remains disabled pending actual Air → Pro delivery tests.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -std=c++17 -fobjc-arc -arch arm64 src/air/tests/inspect_capture_timestamps.mm -o /tmp/inspect_capture_timestamps -framework AppKit -framework ApplicationServices -framework IOKit
/tmp/inspect_capture_timestamps /absolute/physical-capture-air-1.bin
```
