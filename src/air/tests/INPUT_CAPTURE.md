# Passive native input capture

The `--capture-input-test` app hook calls `air_input_capture_test(seconds, absolute_path)` while the Air app is frontmost. The capture ends after 1–60 seconds, when the app loses focus, or on Control–Option–Command–Escape. The tap passes every local input event through unchanged. It records no keyboard event or character data.

The file is created once with mode `0600`. Its binary format is:

| Offset | Type | Value |
|---:|---|---|
| 0 | 8 bytes | `RDAICAP1` |
| 8 | little-endian u32 | Latest gesture packet length, at most 65,536 bytes |
| 12 | little-endian u32 | Latest nonempty raw frame length, at most 336 bytes |
| 16 | little-endian u64 × 4 | Gesture event count, raw frame count, raw contact sample count, NSEvent touch sample count |
| 48 | bytes | Largest / highest-touch native CGEvent29 sample |
| 48 + gesture length | bytes | Latest nonempty `RDAF` MultitouchSupport frame |

The CGEvent29 sample contains the original event timestamp and fields in Apple's private serialization. The raw frame contains one device ID and up to 16 finger IDs, states, normalized positions, and pressures. The current capture format does not preserve the MultitouchSupport callback timestamp. The event counts and byte lengths can show whether each capture path fired; they do not prove that macOS accepts replayed gestures.

## Replay status

Remote Mode forwards native CGEvent gesture and scroll packets. Raw physical finger frames are captured only by this passive test. Host raw replay advertises capability `0` and rejects raw packets until a real device test verifies injection. The older TouchEvents synthesizer creates CGEvent29 packets on the Pro but AppKit reports zero touches after a serialize/decode round trip, so raw Mission Control/Spaces behavior is not established.

### Modern HID field probe on macOS 27 Pro

The read-only [CG/HID bridge probe](cg_hid_bridge_probe.mm) built a 508-byte IOHID digitizer event with two finger children. Passing those bytes directly to `CGEventCreateFromData` returned no event. Replacing the older serializer's flattened CGEvent field `0x106d` with those bytes produced a type-29 event: 700 bytes before decoding, 668 bytes after Core Graphics reserialization, and two touches in `NSEvent` before posting. The old 576-byte field construction reserialized to 156 bytes with zero touches. Its [fixture log](../../../../../work/remote-mode/cg-hid-bridge-probe.log) records the sizes and touch counts.

One bounded [window probe](modern_cg_window_probe.mm) posted only a two-contact begin/move/move/end sequence to its own focused window using the Pro's local trackpad device ID. The window received four gesture events with two touches each. AppKit called `touchesBegan` for two contacts, `touchesMoved` for four contact samples, and `touchesEnded` for two contacts; it called neither `magnifyWithEvent` nor `scrollWheel`. The delivered event reserialized to 825 bytes. The pointer and prior app focus were restored. The [fixture log](../../../../../work/remote-mode/modern-cg-window-probe.log) contains counts and sizes only.

This proves contact delivery for that two-finger fixture, not pinch recognition or Mission Control/Spaces control. The `0x106d` flattened field is private and may change across macOS versions. Raw replay remains disabled in Remote Mode. Apple's [IOHID monitor](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/tools/IOHIDEventSystemMonitor.c) uses direct HID dispatch with a [private event-dispatch entitlement](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/tools/IOHIDEventSystemMonitor-Entitlements.plist); this probe used the Core Graphics event path and did not use direct HID dispatch.

Both CG/HID probes link `TouchEvents.c` compiled as C with `-D CGEventCreateFromData=ProbeCGEventCreateFromData`. Their fixture wrapper captures the older serializer's predecode bytes, then calls the real Core Graphics function. The window probe must be run manually; it is not part of the application or automated test suite.

The window fixture also accepts `--magnify` to post the same two contacts with native magnify subtype and `--scroll` to post phased pixel scroll events. Each was run once in its own disposable window:

| Mode | Observed AppKit delivery | Limit |
|---|---|---|
| [Magnify](../../../../../work/remote-mode/modern-cg-magnify-probe.log) | Explicit type-30 begin/end events reached `magnifyWithEvent` twice, both with magnification `0`. The first move had zero touches before posting, so the fixture stopped and sent an end event. | No continuous magnification was demonstrated. Other type-29 events appeared during the test and were not tagged for attribution. |
| [Scroll](../../../../../work/remote-mode/modern-cg-scroll-probe.log) | Four type-22 events arrived with phases `1, 4, 4, 8`; `scrollWheel` ran three times for the phased pixel sequence. | This exercises explicit scroll events, not recognition of a finger movement as scroll. |

The first scroll attempt queried `allTouches` on a scroll event and AppKit threw before any scroll event was posted. The fixture now avoids that query and restores focus/pointer in `@finally`; the successful scroll run saved and restored cursor coordinates `(99.1, 678.2)`.

Before enabling raw replay, compare a physical Air type-29 packet with its `RDAF` frame. If type-29 already carries real contacts, forwarding both would duplicate one gesture. Choose one source for the whole gesture, verify receiver device identity and begin/move/end delivery across Intel Air → ARM Pro, and synthesize a release on disconnect. The Pro window test used the Pro's local trackpad ID; it does not establish that an Air device ID works on the Pro. Native magnify and Spaces recognition remain unverified.

### Physical Intel Air capture

The first [physical capture](../../../../../work/remote-mode/physical-capture-air-1.bin) recorded 2,419 type-29 events and 4,159 raw frames during the user's gestures. Its selected 812-byte type-29 event contains an IOHID digitizer parent with three digitizer children (IDs 2, 4, 3) and two other children. On the ARM Pro, `CGEventCreateFromData` decoded it and preserved all five HID children after Core Graphics reserialization (1,036 bytes). The [read-only Pro inspection](../../../../../work/remote-mode/physical-capture-air-1-pro-inspect.log) reported zero `NSEvent.allTouches` and zero CG/AppKit subtype and phase before WindowServer delivery. Replacing only the HID sender ID in an in-memory copy with the Pro's local trackpad ID still reported zero touches. Neither event was posted.

The capture's last `RDAF` frame has two contacts, while the selected type-29 sample has three digitizer children; they were taken at different times and cannot be paired. The [live receiver window](live_receiver_window.mm) is prepared to count actual Air→Pro AppKit touch callbacks, magnification values, scroll deltas, and phases. It has compiled but has not been run.

Inspect the file with `python3 src/air/tests/inspect_capture.py /absolute/capture.bin`. The inspector prints counts and raw finger coordinates, not the full CGEvent packet.
